//! Which finished chats you have read.
//!
//! A chat is unread when it has stopped and its latest reply came after both
//! your latest prompt in it and the last time you looked at it: opening it
//! from Omega Notch, or its window coming to the front (macOS, and KWin on
//! Plasma). Kept in
//! `seen.json` next to the history, owner-only. On the first run every chat
//! already on disk counts as read, so installing does not flood the notch.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::paths;
use crate::protocol::{ChatRef, ChatSummary, ProviderId, SessionKind, MARK_READ_MAX};

/// Marks older than this are dropped; the chat list never reaches back so far.
const KEEP_DAYS: i64 = 30;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Seen {
    /// Replies before this count as read.
    since: DateTime<Utc>,
    /// `<provider>:<chat id>` → when it was last looked at.
    #[serde(default)]
    chats: HashMap<String, DateTime<Utc>>,
}

pub fn seen_path() -> PathBuf {
    paths::app_data_dir().join("seen.json")
}

fn key(provider: &ProviderId, id: &str) -> String {
    format!("{}:{id}", provider.as_str())
}

impl Seen {
    pub fn new(since: DateTime<Utc>) -> Self {
        Self {
            since,
            chats: HashMap::new(),
        }
    }

    /// The stored marks, or a fresh start from now when there are none (or
    /// they cannot be read). A fresh start is saved at once, so the next run
    /// does not move its starting point.
    pub fn load() -> Self {
        if let Some(seen) = std::fs::read_to_string(seen_path())
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
        {
            return seen;
        }
        let fresh = Self::new(Utc::now());
        if let Err(err) = fresh.save() {
            tracing::warn!(error = %err, "could not save which chats were read");
        }
        fresh
    }

    /// Written whole to a temporary file, then moved over the old one.
    pub fn save(&self) -> anyhow::Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        paths::create_private_dir(&paths::app_data_dir())?;
        let path = seen_path();
        let tmp = path.with_extension("json.tmp");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(serde_json::to_string(self)?.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    fn seen_at(&self, provider: &ProviderId, id: &str) -> DateTime<Utc> {
        self.chats
            .get(&key(provider, id))
            .copied()
            .map_or(self.since, |at| at.max(self.since))
    }

    /// Records a look at `at`; false when it changes nothing.
    pub fn mark(&mut self, provider: &ProviderId, id: &str, at: DateTime<Utc>) -> bool {
        let changed = self.record(provider, id, at);
        if changed {
            self.prune(at);
        }
        changed
    }

    /// Records a look at `at` on each chat; false when it changes none.
    pub fn mark_all(&mut self, chats: &[ChatRef], at: DateTime<Utc>) -> bool {
        // Every mark is tried: no short-circuit once one changes.
        let changed = chats
            .iter()
            .fold(false, |any, c| self.record(&c.provider, &c.id, at) | any);
        if changed {
            self.prune(at);
        }
        changed
    }

    fn record(&mut self, provider: &ProviderId, id: &str, at: DateTime<Utc>) -> bool {
        if at <= self.seen_at(provider, id) {
            return false;
        }
        self.chats.insert(key(provider, id), at);
        true
    }

    /// Drops marks older than `KEEP_DAYS` before `at`.
    fn prune(&mut self, at: DateTime<Utc>) {
        let oldest = at - Duration::days(KEEP_DAYS);
        self.chats.retain(|_, seen| *seen >= oldest);
    }

    /// Stopped, with a reply newer than both your last prompt and your last look.
    pub fn is_unread(&self, chat: &ChatSummary) -> bool {
        let Some(replied) = chat.replied_at else {
            return false;
        };
        chat.state == SessionKind::Idle
            && chat.prompted_at.is_none_or(|prompted| replied > prompted)
            && replied > self.seen_at(&chat.provider, &chat.id)
    }

    /// Sets every chat's `unread` from the marks.
    pub fn apply(&self, chats: &mut [ChatSummary]) {
        for chat in chats {
            chat.unread = self.is_unread(chat);
        }
    }
}

/// The asked-for chats that are among `listed` and unread there, at most
/// `MARK_READ_MAX`. A `mark_read` line can then only mark chats the engine
/// already shows as unread, never grow the marks with made-up ids.
pub fn only_listed_unread(listed: &[ChatSummary], asked: &[ChatRef]) -> Vec<ChatRef> {
    let unread: HashSet<(&ProviderId, &str)> = listed
        .iter()
        .filter(|c| c.unread)
        .map(|c| (&c.provider, c.id.as_str()))
        .collect();
    let mut kept: Vec<ChatRef> = Vec::new();
    for c in asked {
        if kept.len() == MARK_READ_MAX {
            break;
        }
        if unread.contains(&(&c.provider, c.id.as_str())) && !kept.contains(c) {
            kept.push(c.clone());
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(minute: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(1_790_000_000, 0).unwrap() + Duration::minutes(minute)
    }

    fn chat(state: SessionKind, prompted: Option<i64>, replied: Option<i64>) -> ChatSummary {
        ChatSummary {
            provider: ProviderId::ClaudeCode,
            id: "abc".into(),
            title: "Chat".into(),
            project: None,
            cwd: None,
            model: None,
            surface: None,
            preview: None,
            avatar_shape: None,
            avatar_color: None,
            state,
            live: true,
            updated_at: at(0),
            messages: 1,
            tokens: None,
            context_tokens: None,
            context_pct: None,
            lines_added: None,
            lines_removed: None,
            unread: false,
            prompted_at: prompted.map(at),
            replied_at: replied.map(at),
        }
    }

    #[test]
    fn a_reply_after_your_prompt_is_unread_until_you_look() {
        let mut seen = Seen::new(at(0));
        let done = chat(SessionKind::Idle, Some(5), Some(9));
        assert!(seen.is_unread(&done));
        assert!(seen.mark(&ProviderId::ClaudeCode, "abc", at(10)));
        assert!(!seen.is_unread(&done));
        // The next reply is news again.
        assert!(seen.is_unread(&chat(SessionKind::Idle, Some(11), Some(12))));
    }

    #[test]
    fn a_chat_still_going_or_answered_is_not_unread() {
        let seen = Seen::new(at(0));
        assert!(!seen.is_unread(&chat(SessionKind::Busy, Some(5), Some(9))));
        assert!(!seen.is_unread(&chat(SessionKind::WaitingYou, Some(5), Some(9))));
        // You wrote back after the reply, so you read it.
        assert!(!seen.is_unread(&chat(SessionKind::Idle, Some(10), Some(9))));
        // Nothing to read, or a tool that does not say when it replied.
        assert!(!seen.is_unread(&chat(SessionKind::Idle, Some(5), None)));
    }

    #[test]
    fn replies_from_before_the_first_run_count_as_read() {
        let seen = Seen::new(at(60));
        assert!(!seen.is_unread(&chat(SessionKind::Idle, Some(5), Some(9))));
        assert!(seen.is_unread(&chat(SessionKind::Idle, Some(5), Some(61))));
    }

    #[test]
    fn an_older_look_changes_nothing_and_old_marks_are_dropped() {
        let mut seen = Seen::new(at(0));
        assert!(seen.mark(&ProviderId::ClaudeCode, "old", at(1)));
        assert!(!seen.mark(&ProviderId::ClaudeCode, "old", at(1)));
        assert!(seen.mark(
            &ProviderId::ClaudeCode,
            "new",
            at(1) + Duration::days(KEEP_DAYS + 1)
        ));
        assert!(!seen.chats.contains_key("claude_code:old"));
        assert!(seen.chats.contains_key("claude_code:new"));
    }

    #[test]
    fn mark_all_reads_every_chat_it_names() {
        let mut seen = Seen::new(at(0));
        let mut other = chat(SessionKind::Idle, Some(5), Some(9));
        other.id = "def".into();
        let done = chat(SessionKind::Idle, Some(5), Some(9));
        let both = [
            ChatRef {
                provider: ProviderId::ClaudeCode,
                id: "abc".into(),
            },
            ChatRef {
                provider: ProviderId::ClaudeCode,
                id: "def".into(),
            },
        ];
        // Both unread: the first one changing must not stop the second.
        let mut fresh = Seen::new(at(0));
        assert!(fresh.is_unread(&done) && fresh.is_unread(&other));
        assert!(fresh.mark_all(&both, at(10)));
        assert!(!fresh.is_unread(&done));
        assert!(!fresh.is_unread(&other));
        // One already read must not stop the next being marked.
        assert!(seen.mark(&ProviderId::ClaudeCode, "abc", at(10)));
        assert!(seen.mark_all(&both, at(10)));
        assert!(!seen.is_unread(&done));
        assert!(!seen.is_unread(&other));
        assert!(!seen.mark_all(&both, at(10)));
        assert!(!seen.mark_all(&[], at(11)));
    }

    #[test]
    fn only_listed_unread_drops_unknown_read_and_repeated_chats() {
        let r = |id: &str| ChatRef {
            provider: ProviderId::ClaudeCode,
            id: id.into(),
        };
        let mut unread = chat(SessionKind::Idle, Some(5), Some(9));
        unread.unread = true;
        let mut read = unread.clone();
        read.id = "old".into();
        read.unread = false;
        let listed = [unread, read];
        let asked = [r("made-up"), r("abc"), r("old"), r("abc")];
        assert_eq!(only_listed_unread(&listed, &asked), vec![r("abc")]);
        // Same id under another provider is a different chat.
        let other = ChatRef {
            provider: ProviderId::Codex,
            id: "abc".into(),
        };
        assert!(only_listed_unread(&listed, &[other]).is_empty());
        assert!(only_listed_unread(&listed, &[]).is_empty());
    }

    #[test]
    fn only_listed_unread_keeps_at_most_the_cap() {
        let listed: Vec<ChatSummary> = (0..MARK_READ_MAX + 10)
            .map(|i| {
                let mut c = chat(SessionKind::Idle, Some(5), Some(9));
                c.id = format!("c{i}");
                c.unread = true;
                c
            })
            .collect();
        let asked: Vec<ChatRef> = listed
            .iter()
            .map(|c| ChatRef {
                provider: c.provider.clone(),
                id: c.id.clone(),
            })
            .collect();
        assert_eq!(only_listed_unread(&listed, &asked).len(), MARK_READ_MAX);
    }

    #[test]
    fn mark_read_parses_from_the_wire() {
        let line = r#"{"type":"mark_read","chats":[{"provider":"claude_code","id":"abc"}]}"#;
        let msg: crate::protocol::ClientMessage = serde_json::from_str(line).unwrap();
        let crate::protocol::ClientMessage::MarkRead { chats } = msg else {
            panic!("not mark_read");
        };
        assert_eq!(
            chats,
            vec![ChatRef {
                provider: ProviderId::ClaudeCode,
                id: "abc".into()
            }]
        );
    }

    #[test]
    fn round_trips_through_json() {
        let mut seen = Seen::new(at(0));
        seen.mark(&ProviderId::Cursor, "x", at(3));
        let back: Seen = serde_json::from_str(&serde_json::to_string(&seen).unwrap()).unwrap();
        assert_eq!(back, seen);
    }
}
