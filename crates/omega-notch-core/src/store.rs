use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{info, warn};

use crate::chats::ActivityIndex;
use crate::config::AppConfig;
use crate::copilot_auth;
use crate::protocol::{
    Activity, CopilotLogin, ProviderId, ReadingStatus, ServerMessage, SessionKind, SessionState, UsageReading,
};
use crate::providers;
use crate::sessions::{self, SessionEvent};

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
        for id in ProviderId::mvp_providers() {
            if previous.provider_enabled(*id) != config.provider_enabled(*id) {
                self.refresh_one(*id).await;
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
            ProviderId::mvp_providers()
                .iter()
                .filter_map(|id| guard.get(id).cloned())
                .collect()
        };
        let sessions = {
            let guard = self.inner.sessions.read().await;
            guard.values().cloned().collect()
        };
        let config = self.config().await;
        let activity = self.inner.activity.read().await.clone();
        ServerMessage::Snapshot {
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
            let _ = store.inner.events.send(ServerMessage::CopilotLogin { login });
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
        for id in ProviderId::mvp_providers() {
            let reading = providers::fetch_provider(*id, &config).await;
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
            guard.insert(reading.provider, reading.clone());
        }
        let _ = self
            .inner
            .events
            .send(ServerMessage::UsageUpdated { reading });
    }

    /// Re-reads recent chats and token totals; publishes only when they moved.
    pub async fn refresh_activity(&self) {
        let Ok(mut index) = self.inner.index.clone().try_lock_owned() else {
            return;
        };
        let config = self.config().await;
        let scanned = tokio::task::spawn_blocking(move || index.scan(&config)).await;
        let Ok(activity) = scanned else {
            return;
        };
        {
            let mut guard = self.inner.activity.write().await;
            if *guard == activity {
                return;
            }
            *guard = activity.clone();
        }
        let _ = self.inner.events.send(ServerMessage::ActivityUpdated {
            chats: activity.chats,
            tokens: activity.tokens,
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
        let previous = guard.insert(session.provider, session.clone());
        drop(guard);
        if !unchanged {
            let _ = self.inner.events.send(ServerMessage::SessionUpdated { session });
        }
        previous
    }

    /// Announces one session finishing or stopping to ask, for providers that
    /// report each session on its own.
    pub async fn announce(&self, session: SessionState) {
        if self.config().await.alerts_muted(session.provider) {
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

        if config.alerts_muted(session.provider) {
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
            (_, SessionKind::WaitingYou)
                if prev_kind != Some(SessionKind::WaitingYou) =>
            {
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
