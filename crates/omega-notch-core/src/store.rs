use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{info, warn};

use crate::chats::{self, ActivityIndex};
use crate::config::AppConfig;
use crate::copilot_auth;
use crate::limits::LimitWatch;
use crate::protocol::{
    Activity, CopilotLogin, CostEstimate, HistoryPoint, ModelDayPoint, ProviderId, ProviderInfo,
    ReadingStatus, ServerMessage, SessionKind, SessionState, UsageReading,
};
use crate::providers;
use crate::seen::Seen;
use crate::sessions::{self, SessionEvent};
use crate::{history, pricing};

#[derive(Clone)]
pub struct UsageStore {
    inner: Arc<Inner>,
}

struct Inner {
    config: RwLock<AppConfig>,
    readings: RwLock<HashMap<ProviderId, UsageReading>>,
    sessions: RwLock<HashMap<ProviderId, SessionState>>,
    activity: RwLock<Activity>,
    /// Held across a scan, so a slow one is skipped over rather than queued.
    index: Arc<Mutex<ActivityIndex>>,
    /// Held for the length of a Copilot sign-in, so a second click joins it.
    copilot_login: Arc<Mutex<()>>,
    /// Set once the history backfill has been looked at this run.
    backfill_checked: AtomicBool,
    /// An analysis by Claude is under way; one at a time.
    analyzing: AtomicBool,
    /// The usage thresholds already announced, per provider. Never held
    /// across an await.
    limits: std::sync::Mutex<LimitWatch>,
    /// Which finished chats have been looked at. Never held across an await.
    seen: std::sync::Mutex<Seen>,
    events: broadcast::Sender<ServerMessage>,
}

impl UsageStore {
    pub fn new(config: AppConfig) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(Inner {
                config: RwLock::new(config),
                readings: RwLock::new(HashMap::new()),
                sessions: RwLock::new(HashMap::new()),
                activity: RwLock::new(Activity::default()),
                index: Arc::new(Mutex::new(ActivityIndex::new())),
                copilot_login: Arc::new(Mutex::new(())),
                backfill_checked: AtomicBool::new(false),
                analyzing: AtomicBool::new(false),
                limits: std::sync::Mutex::new(LimitWatch::default()),
                seen: std::sync::Mutex::new(Seen::load()),
                events,
            }),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ServerMessage> {
        self.inner.events.subscribe()
    }

    pub async fn config(&self) -> AppConfig {
        self.inner.config.read().await.clone()
    }

    pub async fn set_config(&self, config: AppConfig) -> anyhow::Result<()> {
        let config = config.normalized();
        config.save()?;
        let previous = {
            let mut guard = self.inner.config.write().await;
            std::mem::replace(&mut *guard, config.clone())
        };
        let _ = self.inner.events.send(ServerMessage::ConfigUpdated {
            config: config.clone(),
        });
        // Moving the notch or muting a sound is no reason to spend a vendor's
        // rate limit; only providers that were switched need a new reading.
        let mut toggled = false;
        for provider in providers::PROVIDERS {
            let id = provider.id();
            if previous.provider_enabled(id) != config.provider_enabled(id) {
                self.refresh_one(id.clone()).await;
                toggled = true;
            }
        }
        if toggled {
            self.refresh_activity().await;
        }
        Ok(())
    }

    pub async fn snapshot(&self) -> ServerMessage {
        let readings = {
            let guard = self.inner.readings.read().await;
            providers::PROVIDERS
                .iter()
                .filter_map(|provider| guard.get(provider.id()).cloned())
                .collect()
        };
        let sessions = {
            let guard = self.inner.sessions.read().await;
            guard.values().cloned().collect()
        };
        let providers = providers::PROVIDERS
            .iter()
            .map(|provider| ProviderInfo {
                id: provider.id().clone(),
                display_name: provider.display_name().to_string(),
            })
            .collect();
        let config = self.config().await;
        let activity = self.inner.activity.read().await.clone();
        ServerMessage::Snapshot {
            providers,
            readings,
            sessions,
            chats: activity.chats,
            tokens: activity.tokens,
            config,
        }
    }

    /// Runs GitHub's device flow in the background, reporting each step to
    /// every client, and refreshes Copilot once signed in.
    pub fn copilot_sign_in(&self) {
        let Ok(guard) = self.inner.copilot_login.clone().try_lock_owned() else {
            return;
        };
        let store = self.clone();
        tokio::spawn(async move {
            let _guard = guard;
            let login = match store.run_copilot_sign_in().await {
                Ok(()) => CopilotLogin::SignedIn,
                Err(err) => {
                    warn!(error = %err, "copilot sign-in failed");
                    CopilotLogin::Failed {
                        message: err.to_string(),
                    }
                }
            };
            let _ = store
                .inner
                .events
                .send(ServerMessage::CopilotLogin { login });
        });
    }

    async fn run_copilot_sign_in(&self) -> anyhow::Result<()> {
        let code = copilot_auth::request_device_code().await?;
        let _ = self.inner.events.send(ServerMessage::CopilotLogin {
            login: CopilotLogin::Pending {
                user_code: code.user_code.clone(),
                verification_uri: code.verification_uri.clone(),
                expires_at: code.expires_at(),
            },
        });
        let token = copilot_auth::wait_for_token(&code).await?;
        copilot_auth::save_token(&token)?;
        info!("signed in to GitHub Copilot");
        self.refresh_one(ProviderId::Copilot).await;
        Ok(())
    }

    pub async fn refresh_one(&self, id: ProviderId) {
        let config = self.config().await;
        let reading = providers::fetch_provider(id, &config).await;
        self.publish_reading(reading).await;
    }

    pub async fn refresh_all(&self) {
        let config = self.config().await;
        for provider in providers::PROVIDERS {
            let reading = providers::fetch_provider(provider.id().clone(), &config).await;
            self.publish_reading(reading).await;
        }
    }

    async fn publish_reading(&self, mut reading: UsageReading) {
        {
            let mut guard = self.inner.readings.write().await;
            // A failed refresh says nothing about usage: keep the last good
            // numbers, marked stale, rather than blanking the ring.
            if reading.status == ReadingStatus::Error {
                if let Some(last) = guard.get(&reading.provider) {
                    if !last.windows.is_empty()
                        && matches!(last.status, ReadingStatus::Ok | ReadingStatus::Stale)
                    {
                        let mut kept = last.clone();
                        kept.status = ReadingStatus::Stale;
                        kept.message = reading.message.take();
                        reading = kept;
                    }
                }
            }
            guard.insert(reading.provider.clone(), reading.clone());
        }
        // Followed even while muted, so unmuting does not announce a
        // threshold passed long ago.
        let limit = self
            .inner
            .limits
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .check(&reading);
        let _ = self
            .inner
            .events
            .send(ServerMessage::UsageUpdated { reading });

        if let Some(limit) = limit {
            let config = self.config().await;
            if config.alerts.limits && !config.alerts_muted(&limit.provider) {
                info!(provider = ?limit.provider, threshold = limit.threshold, "usage limit");
                let _ = self
                    .inner
                    .events
                    .send(ServerMessage::LimitReached { limit });
            }
        }
    }

    /// Re-reads recent chats and token totals; publishes only when they moved.
    pub async fn refresh_activity(&self) {
        let Ok(mut index) = self.inner.index.clone().try_lock_owned() else {
            return;
        };
        let config = self.config().await;
        if config.provider_enabled(&ProviderId::ClaudeCode)
            && !self.inner.backfill_checked.swap(true, Ordering::SeqCst)
        {
            tokio::task::spawn_blocking(backfill_history);
        }
        let scanned = tokio::task::spawn_blocking(move || index.scan(&config)).await;
        let Ok(mut activity) = scanned else {
            return;
        };
        {
            let mut guard = self.inner.activity.write().await;
            // Under the write lock, so a chat read during the scan keeps it.
            if let Ok(seen) = self.inner.seen.lock() {
                seen.apply(&mut activity.chats);
            }
            if *guard == activity {
                return;
            }
            *guard = activity.clone();
        }
        // Persist for the dashboard chart; failures must not break polling.
        let snapshot = activity.tokens.clone();
        tokio::task::spawn_blocking(move || {
            if let Err(err) = history::record_tokens(&snapshot) {
                warn!(error = %err, "could not record token history");
            }
        });
        let _ = self.inner.events.send(ServerMessage::ActivityUpdated {
            chats: activity.chats,
            tokens: activity.tokens,
        });
    }

    /// Marks a chat read now, and tells the shells when that changes it.
    pub async fn mark_seen(&self, provider: ProviderId, id: &str) {
        let changed = match self.inner.seen.lock() {
            Ok(mut seen) => seen.mark(&provider, id, Utc::now()),
            Err(_) => false,
        };
        if !changed {
            return;
        }
        // Saved under the lock, from the marks as they are by then: two saves
        // never share the temporary file, and the last one has every mark.
        let inner = self.inner.clone();
        tokio::task::spawn_blocking(move || {
            let saved = match inner.seen.lock() {
                Ok(seen) => seen.save(),
                Err(_) => return,
            };
            if let Err(err) = saved {
                warn!(error = %err, "could not save which chats were read");
            }
        });
        let activity = {
            let mut guard = self.inner.activity.write().await;
            let before: Vec<bool> = guard.chats.iter().map(|c| c.unread).collect();
            if let Ok(seen) = self.inner.seen.lock() {
                seen.apply(&mut guard.chats);
            }
            if guard.chats.iter().map(|c| c.unread).eq(before) {
                return;
            }
            guard.clone()
        };
        let _ = self.inner.events.send(ServerMessage::ActivityUpdated {
            chats: activity.chats,
            tokens: activity.tokens,
        });
    }

    /// The window in front changed: an unread chat it shows is now read.
    pub async fn window_focused(&self, pid: u32, title: Option<String>) {
        let (titles, unread) = {
            let guard = self.inner.activity.read().await;
            let claude = || {
                guard
                    .chats
                    .iter()
                    .filter(|c| c.provider == ProviderId::ClaudeCode)
            };
            let unread: std::collections::HashSet<String> = claude()
                .filter(|c| c.unread && c.live)
                .map(|c| c.id.clone())
                .collect();
            if unread.is_empty() {
                return;
            }
            let titles: HashMap<String, String> =
                claude().map(|c| (c.id.clone(), c.title.clone())).collect();
            (titles, unread)
        };
        let found = tokio::task::spawn_blocking(move || {
            crate::jump::session_in_window(pid, title.as_deref(), &titles, &unread)
        })
        .await
        .ok()
        .flatten();
        if let Some(id) = found {
            self.mark_seen(ProviderId::ClaudeCode, &id).await;
        }
    }

    /// Dashboard payload: persisted daily points, the range's dearest
    /// sessions, and today's per-model cost estimates. `days` clamps to
    /// 7..=90 inside `history`.
    pub async fn dashboard(
        &self,
        days: u32,
        search: String,
        project: String,
        session: String,
    ) -> ServerMessage {
        let days = days.clamp(7, history::MAX_HISTORY_DAYS);
        let scope = history::Scope::normalized(&search, &project, &session);
        let points: Vec<HistoryPoint> =
            tokio::task::spawn_blocking(move || history::query_history(days))
                .await
                .ok()
                .and_then(|r| r.ok())
                .unwrap_or_default();
        let models: Vec<ModelDayPoint> =
            tokio::task::spawn_blocking(move || history::query_models(days))
                .await
                .ok()
                .and_then(|r| r.ok())
                .unwrap_or_default();
        let asked = scope.clone();
        let scoped: history::Scoped = tokio::task::spawn_blocking(move || {
            history::query_scoped(days, history::MAX_SESSIONS, &asked)
        })
        .await
        .ok()
        .and_then(|r| r.ok())
        .unwrap_or_default();
        let activity = self.inner.activity.read().await.clone();
        let mut costs = Vec::new();
        for stats in &activity.tokens {
            let today_total = stats.today.total();
            if today_total == 0 {
                continue;
            }
            for model in &stats.models_today {
                if model.total == 0 {
                    continue;
                }
                let share = model.total as f64 / today_total as f64;
                let bucket = crate::protocol::TokenTotals {
                    input: (stats.today.input as f64 * share).round() as u64,
                    output: (stats.today.output as f64 * share).round() as u64,
                    cache_read: (stats.today.cache_read as f64 * share).round() as u64,
                    cache_write: (stats.today.cache_write as f64 * share).round() as u64,
                };
                costs.push(CostEstimate {
                    provider: stats.provider.clone(),
                    model: model.model.clone(),
                    total: model.total,
                    cost_usd: pricing::estimate_cost_usd(&model.model, &bucket),
                });
            }
        }
        costs.sort_by(|a, b| {
            b.cost_usd
                .partial_cmp(&a.cost_usd)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        // Narrowed, everything comes from the sessions in scope: only they
        // know their project and title.
        let (points, models, costs) = if scope.is_empty() {
            (points, models, costs)
        } else {
            (scoped.points, scoped.models, scoped.today)
        };
        let total_usd = costs.iter().map(|c| c.cost_usd).sum();
        // The same sessions the numbers cover, and the live chats among them.
        let advised: Vec<_> = scoped
            .matched
            .iter()
            .filter(|s| scope.session.is_empty() || s.id == scope.session)
            .cloned()
            .collect();
        let chats: Vec<_> = activity
            .chats
            .iter()
            .filter(|c| scope.is_empty() || advised.iter().any(|s| s.id == c.id))
            .cloned()
            .collect();
        let suggestions = crate::advice::suggest(&advised, &chats);
        // Grok Bot's bots are ranked by their own transcripts; a narrowed
        // dashboard is about sessions, so they answer the unscoped one only.
        let bots = if scope.is_empty() {
            tokio::task::spawn_blocking(move || crate::grok_bot::activity(days))
                .await
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        ServerMessage::Dashboard {
            points,
            costs,
            total_usd,
            models,
            sessions: scoped.sessions,
            bots,
            search: scope.search,
            project: scope.project,
            session: scope.session,
            projects: scoped.projects,
            suggestions,
        }
    }

    /// Asks Claude for advice on the sessions this scope covers, in the
    /// background; every shell hears `running`, then the answer. A second
    /// request while one runs is turned away.
    /// `request` is the asking shell's own id for it, sent back with every
    /// answer so each shell keeps only answers to what it asked.
    pub fn analyze_usage(&self, days: u32, scope: history::Scope, model: String, request: String) {
        let request: String = request.chars().take(64).collect();
        // Read as the dashboard reads it, whoever calls, so both see the
        // same sessions.
        let scope = history::Scope::normalized(&scope.search, &scope.project, &scope.session);
        let send = |state: &str, text: String| {
            let _ = self.inner.events.send(ServerMessage::UsageAnalysis {
                state: state.into(),
                model: model.clone(),
                text,
                request: request.clone(),
            });
        };
        if !crate::analysis::MODELS.contains(&model.as_str()) {
            return send("failed", "Pick Sonnet or Opus.".into());
        }
        if self.inner.analyzing.swap(true, Ordering::SeqCst) {
            return send("failed", "An analysis is already running.".into());
        }
        send("running", String::new());
        let inner = self.inner.clone();
        tokio::spawn(async move {
            let days = days.clamp(7, history::MAX_HISTORY_DAYS);
            let what = if !scope.session.trim().is_empty() {
                "for one chat"
            } else if !scope.project.trim().is_empty() {
                "for one project"
            } else if !history::search_words(&scope.search).is_empty() {
                "for the sessions matching a search"
            } else {
                "for the whole account"
            };
            let asked = scope.clone();
            let scoped = tokio::task::spawn_blocking(move || {
                history::query_scoped(days, history::MAX_SESSIONS, &asked)
            })
            .await;
            let result = match scoped {
                Ok(Ok(mut scoped)) => {
                    // Claude Code's own sessions only: another tool's usage is
                    // not Anthropic's to see.
                    scoped
                        .matched
                        .retain(|s| s.provider == ProviderId::ClaudeCode);
                    scoped
                        .models
                        .retain(|m| m.provider == ProviderId::ClaudeCode);
                    if !scope.session.trim().is_empty() {
                        scoped.matched.retain(|s| s.id == scope.session.trim());
                    }
                    if scoped.matched.is_empty() {
                        Err(anyhow::anyhow!("No sessions in this range to look at."))
                    } else {
                        let flagged = crate::advice::suggest(&scoped.matched, &[]);
                        let summary = crate::analysis::summary(days, what, &scoped, &flagged);
                        crate::analysis::ask(&model, &summary).await
                    }
                }
                _ => Err(anyhow::anyhow!("Could not read the usage history.")),
            };
            inner.analyzing.store(false, Ordering::SeqCst);
            let (state, text) = match result {
                Ok(text) => ("done", text),
                Err(err) => {
                    warn!(error = %err, "usage analysis failed");
                    ("failed", err.to_string())
                }
            };
            let _ = inner.events.send(ServerMessage::UsageAnalysis {
                state: state.into(),
                model,
                text,
                request,
            });
        });
    }

    /// Records a provider's state without reading a transition into it.
    /// Returns the state it replaced.
    pub async fn set_session(&self, mut session: SessionState) -> Option<SessionState> {
        let mut guard = self.inner.sessions.write().await;
        let unchanged = guard
            .get(&session.provider)
            .is_some_and(|p| p.kind == session.kind && p.label == session.label);
        // `updated_at` is when the state last changed, not when it was last
        // looked at: shells use it to tell which provider moved most recently.
        if let (true, Some(previous)) = (unchanged, guard.get(&session.provider)) {
            session.updated_at = previous.updated_at;
        }
        let previous = guard.insert(session.provider.clone(), session.clone());
        drop(guard);
        if !unchanged {
            let _ = self
                .inner
                .events
                .send(ServerMessage::SessionUpdated { session });
        }
        previous
    }

    /// Announces one session finishing or stopping to ask, for providers that
    /// report each session on its own.
    pub async fn announce(&self, session: SessionState) {
        if self.config().await.alerts_muted(&session.provider) {
            return;
        }
        let message = match session.kind {
            SessionKind::Idle => ServerMessage::SessionFinished { session },
            SessionKind::WaitingYou => ServerMessage::SessionWaiting { session },
            SessionKind::Busy => return,
        };
        let _ = self.inner.events.send(message);
    }

    pub async fn apply_session(&self, session: SessionState) {
        let config = self.config().await;
        let previous = self.set_session(session.clone()).await;

        if config.alerts_muted(&session.provider) {
            return;
        }

        let prev_kind = previous.as_ref().map(|p| p.kind);
        match (prev_kind, session.kind) {
            (Some(SessionKind::Busy), SessionKind::Idle)
            | (Some(SessionKind::WaitingYou), SessionKind::Idle) => {
                let _ = self
                    .inner
                    .events
                    .send(ServerMessage::SessionFinished { session });
            }
            (_, SessionKind::WaitingYou) if prev_kind != Some(SessionKind::WaitingYou) => {
                let _ = self
                    .inner
                    .events
                    .send(ServerMessage::SessionWaiting { session });
            }
            _ => {}
        }
    }

    pub fn spawn_background(self) {
        let store = self.clone();
        tokio::spawn(async move {
            store.run_poll_loop().await;
        });

        let store = self.clone();
        tokio::spawn(async move {
            if let Err(err) = sessions::watch_sessions(store).await {
                warn!(error = %err, "session watcher stopped");
            }
        });
    }

    async fn run_poll_loop(&self) {
        // Initial fetch.
        self.refresh_all().await;
        info!("initial usage refresh complete");

        loop {
            let busy = {
                let sessions = self.inner.sessions.read().await;
                sessions
                    .values()
                    .any(|s| matches!(s.kind, SessionKind::Busy | SessionKind::WaitingYou))
            };

            // Faster while agents are active; slower when idle.
            let wait = if busy {
                Duration::from_secs(30)
            } else {
                Duration::from_secs(300)
            };

            // Also wake early if a usage window is about to roll over.
            let until_reset = self.ms_until_next_reset().await;
            let wait = match until_reset {
                Some(ms) if ms < wait.as_millis() as u64 => {
                    Duration::from_millis(ms.saturating_add(500))
                }
                _ => wait,
            };

            tokio::time::sleep(wait).await;
            self.refresh_all().await;
        }
    }

    async fn ms_until_next_reset(&self) -> Option<u64> {
        let now = Utc::now();
        let readings = self.inner.readings.read().await;
        readings
            .values()
            .filter(|r| matches!(r.status, ReadingStatus::Ok | ReadingStatus::Stale))
            .flat_map(|r| r.windows.iter())
            .filter_map(|w| w.resets_at)
            .filter(|t| *t > now)
            .map(|t| (t - now).num_milliseconds().max(0) as u64)
            .min()
    }

    pub async fn ingest_hook(&self, event: SessionEvent) {
        let session = SessionState {
            provider: event.provider,
            kind: event.kind,
            label: event.label,
            updated_at: Utc::now(),
        };
        // Claude Code's own session registry already announces each session;
        // a hook on top of it would ring twice for the same event.
        if session.provider == ProviderId::ClaudeCode && sessions::claude_registry_available() {
            self.set_session(session).await;
            return;
        }
        self.apply_session(session).await;
    }
}

/// Fills the dashboard history once from every Claude Code transcript still
/// on disk, up to the days the live scan already covers. Runs in the
/// background; a failure only means a shorter history.
fn backfill_history() {
    match history::backfill_done() {
        Ok(true) => return,
        Ok(false) => {}
        Err(err) => {
            warn!(error = %err, "could not read token history");
            return;
        }
    }
    let today = chrono::Local::now().date_naive();
    let first_day = today - chrono::Duration::days(history::MAX_HISTORY_DAYS as i64 - 1);
    let live_from = today - chrono::Duration::days(chats::HISTORY_DAYS - 1);
    let started = std::time::Instant::now();
    let found = chats::backfill_claude(first_day, live_from);
    match history::record_backfill(
        ProviderId::ClaudeCode,
        &found.days,
        &found.sessions,
        &found.meta,
    ) {
        Ok(()) => info!(
            rows = found.days.len(),
            sessions = found.meta.len(),
            took = ?started.elapsed(),
            "token history backfilled"
        ),
        Err(err) => warn!(error = %err, "could not backfill token history"),
    }
}
