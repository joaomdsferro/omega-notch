//! Grok Bot's bots, read from its local sand store.
//!
//! The store keeps one blob per key, the file name being the key in lower
//! case, unpadded base32. The roster names every bot with its latest message
//! and when it arrived; when several accounts left one behind, the signed-in
//! account's slot (`client-meta.account-slot`) picks it.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::Value;

use crate::chats::MAX_CHATS;
use crate::paths;
use crate::protocol::{BotUsage, ChatSummary, ProviderId, SessionKind};

/// How much of the latest message a preview keeps.
const PREVIEW_CHARS: usize = 120;

const ACCOUNT_SLOT_KEY: &str = "sand.client.slice.client-meta.account-slot";

/// The bots, newest speaker first; rows hidden from the sidebar are left out.
pub fn bots() -> Vec<ChatSummary> {
    bots_from(&paths::grok_bot_sand_dir())
}

fn bots_from(dir: &Path) -> Vec<ChatSummary> {
    let Some(roster) = read_roster(dir) else {
        return Vec::new();
    };
    let mut chats: Vec<ChatSummary> = roster
        .value
        .rows
        .into_iter()
        .filter(|row| !row.is_hidden_from_sidebar)
        .filter_map(chat_from)
        .collect();
    chats.sort_by_key(|chat| std::cmp::Reverse(chat.updated_at));
    chats.truncate(MAX_CHATS);
    chats
}

/// What each bot exchanged over the last `days`, busiest first. Grok Bot
/// records no per-bot counters, so `messages` counts the transcript's
/// entries and `tokens` estimates a quarter of the text's characters;
/// `routines` are the automations the bot carries now. A bot without a
/// local transcript is left out.
pub fn activity(days: u32) -> Vec<BotUsage> {
    activity_from(&paths::grok_bot_sand_dir(), days)
}

fn activity_from(dir: &Path, days: u32) -> Vec<BotUsage> {
    let Some(roster) = read_roster(dir) else {
        return Vec::new();
    };
    let rows: HashMap<&str, &RosterRow> = roster
        .value
        .rows
        .iter()
        .map(|row| (row.id.as_str(), row))
        .collect();
    let cutoff = (Utc::now() - Duration::days(i64::from(days))).timestamp_millis();
    let mut bots: Vec<BotUsage> = Vec::new();
    for blob in transcript_blobs(dir) {
        let Some(row) = rows.get(blob.id.as_str()) else {
            continue;
        };
        let Some(transcript) = read_transcript(&blob.path) else {
            continue;
        };
        let mut usage = BotUsage {
            id: blob.id,
            name: row.name.clone(),
            messages: 0,
            tokens: 0,
            routines: Vec::new(),
            avatar_shape: non_empty(row.avatar_shape.as_deref()),
            avatar_color: non_empty(row.avatar_color.as_deref()),
        };
        let mut routines: BTreeMap<String, String> = BTreeMap::new();
        for entry in transcript.value.entries {
            if entry.kind == "event" {
                if let Some(event) = entry.event {
                    apply_automation(&mut routines, &event);
                }
                continue;
            }
            if entry.timestamp_ms.is_none_or(|at| at < cutoff) {
                continue;
            }
            let text = match entry.kind.as_str() {
                "message" => entry.content.as_deref(),
                "send-message" => entry
                    .message
                    .as_ref()
                    .and_then(|message| message.get("content"))
                    .and_then(Value::as_str),
                _ => continue,
            };
            usage.messages += 1;
            usage.tokens += count_chars(text.unwrap_or("")).div_ceil(4);
        }
        if usage.messages == 0 {
            continue;
        }
        usage.routines = routines.into_values().collect();
        bots.push(usage);
    }
    bots.sort_by(|a, b| {
        b.tokens
            .cmp(&a.tokens)
            .then(b.messages.cmp(&a.messages))
            .then(a.name.cmp(&b.name))
    });
    bots
}

/// One `automation-changed` event: the last action per id decides whether it
/// is there now.
fn apply_automation(routines: &mut BTreeMap<String, String>, event: &Value) {
    if event.get("type").and_then(Value::as_str) != Some("automation-changed") {
        return;
    }
    let (Some(id), Some(action)) = (
        event.get("automationId").and_then(Value::as_str),
        event.get("action").and_then(Value::as_str),
    ) else {
        return;
    };
    if action == "deleted" {
        routines.remove(id);
    } else if let Some(name) = event.get("automationName").and_then(Value::as_str) {
        routines.insert(id.to_string(), name.to_string());
    }
}

/// Characters, not bytes, so accented text is not overcounted.
fn count_chars(text: &str) -> u64 {
    text.chars().count() as u64
}

/// The roster leaves avatars it never styled as empty strings; a chat then
/// simply carries none.
fn non_empty(text: Option<&str>) -> Option<String> {
    text.filter(|text| !text.is_empty()).map(str::to_string)
}

/// A bot's transcript blob: its key names the bot.
struct TranscriptBlob {
    id: String,
    path: PathBuf,
}

fn transcript_blobs(dir: &Path) -> Vec<TranscriptBlob> {
    let mut blobs = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return blobs;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(key) = name
            .to_str()
            .and_then(|name| name.strip_suffix(".blob").and_then(base32_decode))
        else {
            continue;
        };
        let Some((_, id)) = key.rsplit_once("transcript.replicas.") else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        blobs.push(TranscriptBlob {
            id: id.to_string(),
            path: entry.path(),
        });
    }
    blobs
}

fn read_transcript(path: &Path) -> Option<Transcript> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

fn read_roster(dir: &Path) -> Option<Roster> {
    let slot = read_account_slot(dir);
    let mut candidates: Vec<(bool, std::time::SystemTime, PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let name = entry.file_name();
        let Some(key) = name
            .to_str()
            .and_then(|name| name.strip_suffix(".blob").and_then(base32_decode))
        else {
            continue;
        };
        if !key.ends_with(".roster.last-roster") {
            continue;
        }
        let preferred = slot.as_deref().is_some_and(|slot| key.contains(slot));
        let modified = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        candidates.push((preferred, modified, entry.path()));
    }
    candidates.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
    let (_, _, path) = candidates.into_iter().next()?;
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// The signed-in account's slot, as it appears inside roster keys (`|` is
/// `%7C` there).
fn read_account_slot(dir: &Path) -> Option<String> {
    let path = dir.join(format!("{}.blob", base32_encode(ACCOUNT_SLOT_KEY)));
    let slot: AccountSlot = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    Some(slot.value.replace('|', "%7C"))
}

fn chat_from(row: RosterRow) -> Option<ChatSummary> {
    let updated_at = timestamp(row.last_activity_at?)?;
    let preview = row
        .last_entry
        .as_ref()
        .and_then(entry_text)
        .and_then(clean_preview);
    let waiting = row
        .awaiting_user_response
        .as_ref()
        .is_some_and(|value| !value.is_null());
    Some(ChatSummary {
        provider: ProviderId::GrokBot,
        id: row.id,
        title: row.name,
        project: None,
        cwd: None,
        model: None,
        surface: None,
        preview,
        avatar_shape: non_empty(row.avatar_shape.as_deref()),
        avatar_color: non_empty(row.avatar_color.as_deref()),
        state: if waiting {
            SessionKind::WaitingYou
        } else {
            SessionKind::Idle
        },
        live: false,
        updated_at,
        messages: 0,
        tokens: None,
        context_tokens: None,
        context_pct: None,
        lines_added: None,
        lines_removed: None,
        unread: false,
        prompted_at: row.last_viewed_at.and_then(timestamp),
        replied_at: row.last_entry.is_some().then_some(updated_at),
    })
}

fn entry_text(entry: &Value) -> Option<String> {
    Some(entry.get("text")?.as_str()?.to_string())
}

/// Collapses a message to one line and caps it.
fn clean_preview(text: String) -> Option<String> {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.is_empty() {
        return None;
    }
    if flat.chars().count() <= PREVIEW_CHARS {
        return Some(flat);
    }
    let mut short: String = flat.chars().take(PREVIEW_CHARS - 1).collect();
    short.push('…');
    Some(short)
}

fn timestamp(ms: i64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp_millis(ms)
}

#[derive(Deserialize)]
struct Roster {
    value: RosterValue,
}

#[derive(Deserialize)]
struct RosterValue {
    rows: Vec<RosterRow>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RosterRow {
    id: String,
    name: String,
    #[serde(default)]
    avatar_shape: Option<String>,
    #[serde(default)]
    avatar_color: Option<String>,
    #[serde(default)]
    is_hidden_from_sidebar: bool,
    #[serde(default)]
    last_entry: Option<Value>,
    #[serde(default)]
    last_activity_at: Option<i64>,
    #[serde(default)]
    last_viewed_at: Option<i64>,
    #[serde(default)]
    awaiting_user_response: Option<Value>,
}

#[derive(Deserialize)]
struct Transcript {
    value: TranscriptValue,
}

#[derive(Deserialize)]
struct TranscriptValue {
    #[serde(default)]
    entries: Vec<TranscriptEntry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscriptEntry {
    kind: String,
    #[serde(default)]
    timestamp_ms: Option<i64>,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    message: Option<Value>,
    #[serde(default)]
    event: Option<Value>,
}

#[derive(Deserialize)]
struct AccountSlot {
    value: String,
}

const BASE32: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";

/// Decodes a blob file name: lower case, unpadded base32.
fn base32_decode(name: &str) -> Option<String> {
    let mut acc: u32 = 0;
    let mut bits = 0;
    let mut out = Vec::new();
    for byte in name.bytes() {
        let digit = match byte.to_ascii_uppercase() {
            b'A'..=b'Z' => byte.to_ascii_uppercase() - b'A',
            b'2'..=b'7' => byte - b'2' + 26,
            _ => return None,
        } as u32;
        acc = (acc << 5) | digit;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    String::from_utf8(out).ok()
}

fn base32_encode(key: &str) -> String {
    let mut acc: u32 = 0;
    let mut bits = 0;
    let mut out = String::new();
    for byte in key.bytes() {
        acc = (acc << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(BASE32[((acc >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        out.push(BASE32[((acc << (5 - bits)) & 31) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("omega-notch-grok-bot-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_blob(dir: &Path, key: &str, body: &Value) {
        let path = dir.join(format!("{}.blob", base32_encode(key)));
        std::fs::write(path, body.to_string()).unwrap();
    }

    fn row(name: &str, id: &str, activity: i64, viewed: Option<i64>) -> Value {
        serde_json::json!({
            "id": id,
            "name": name,
            "avatarShape": "",
            "avatarColor": "",
            "lastEntry": { "kind": "text", "text": format!("{name} speaking\nwith   spaces") },
            "lastActivityAt": activity,
            "lastViewedAt": viewed,
            "awaitingUserResponse": null,
            "isHiddenFromSidebar": false,
        })
    }

    fn roster(rows: Vec<Value>) -> Value {
        serde_json::json!({ "schemaVersion": 4, "value": { "rows": rows } })
    }

    #[test]
    fn keys_round_trip_through_base32() {
        for key in [
            "sand.client.slice.client-meta.account-slot",
            "sand.client.slice.account.google-oauth2%7Cuser_0000000000000000000000000000.roster.last-roster",
            "sand.client.slice.ui-layout",
        ] {
            assert_eq!(base32_decode(&base32_encode(key)).as_deref(), Some(key));
        }
    }

    #[test]
    fn the_roster_becomes_chats_newest_first() {
        let dir = temp_dir("roster");
        let account = "sand.client.slice.account.google-oauth2%7Cuser_1.";
        let mut rows = vec![
            row("Ops Bot", "a", 2_000, Some(1_000)),
            row("Old Timer", "b", 500, None),
        ];
        rows[0]["avatarShape"] = serde_json::json!("cloud");
        rows[0]["avatarColor"] = serde_json::json!("orange");
        rows.push(serde_json::json!({
            "id": "c",
            "name": "Hidden",
            "lastActivityAt": 9_000,
            "isHiddenFromSidebar": true,
        }));
        rows.push({
            let mut asker = row("Asker", "d", 4_000, Some(3_000));
            asker["awaitingUserResponse"] = serde_json::json!({ "prompt": "Approve?" });
            asker
        });
        write_blob(&dir, &format!("{account}roster.last-roster"), &roster(rows));

        let chats = bots_from(&dir);
        let names: Vec<&str> = chats.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(names, ["Asker", "Ops Bot", "Old Timer"]);
        assert!(chats.iter().all(|c| c.provider == ProviderId::GrokBot));

        let ops = &chats[1];
        assert_eq!(ops.preview.as_deref(), Some("Ops Bot speaking with spaces"));
        assert_eq!(ops.avatar_shape.as_deref(), Some("cloud"));
        assert_eq!(ops.avatar_color.as_deref(), Some("orange"));
        assert_eq!(ops.messages, 0);
        assert_eq!(ops.prompted_at, timestamp(1_000));
        assert_eq!(ops.replied_at, timestamp(2_000));

        assert_eq!(chats[0].state, SessionKind::WaitingYou);
        assert_eq!(chats[2].replied_at, timestamp(500));
        assert_eq!(chats[2].prompted_at, None);
        // Avatars the roster left empty become none.
        assert_eq!(chats[2].avatar_shape, None);
        assert_eq!(chats[2].avatar_color, None);
    }

    #[test]
    fn the_signed_in_accounts_roster_wins() {
        let dir = temp_dir("slot");
        write_blob(
            &dir,
            "sand.client.slice.account.google-oauth2%7Cuser_old.roster.last-roster",
            &roster(vec![row("Stale", "a", 1_000, None)]),
        );
        write_blob(
            &dir,
            "sand.client.slice.account.google-oauth2%7Cuser_new.roster.last-roster",
            &roster(vec![row("Fresh", "b", 2_000, None)]),
        );
        write_blob(
            &dir,
            ACCOUNT_SLOT_KEY,
            &serde_json::json!({ "schemaVersion": 1, "value": "google-oauth2|user_new" }),
        );

        let chats = bots_from(&dir);
        assert_eq!(chats.len(), 1);
        assert_eq!(chats[0].title, "Fresh");
    }

    #[test]
    fn a_preview_keeps_one_short_line() {
        assert_eq!(clean_preview("  a\n\nb  ".into()).as_deref(), Some("a b"));
        assert_eq!(clean_preview("   ".into()), None);
        let long = "word ".repeat(60);
        let preview = clean_preview(long).unwrap();
        assert_eq!(preview.chars().count(), PREVIEW_CHARS);
        assert!(preview.ends_with('…'));
    }

    #[test]
    fn activity_counts_exchanges_and_carries_routines() {
        let dir = temp_dir("activity");
        let account = "sand.client.slice.account.google-oauth2%7Cuser_1.";
        let mut rows = vec![
            row("Ops Bot", "bot-a", 2_000, None),
            row("Quiet", "bot-b", 1_000, None),
        ];
        rows[0]["avatarShape"] = serde_json::json!("teardrop");
        rows[0]["avatarColor"] = serde_json::json!("violet");
        write_blob(&dir, &format!("{account}roster.last-roster"), &roster(rows));
        let now = Utc::now().timestamp_millis();
        let old = now - Duration::days(30).num_milliseconds();
        let entries = serde_json::json!([
            { "kind": "message", "role": "user", "content": "hello there!", "timestampMs": now },
            { "kind": "send-message", "message": { "type": "text", "content": "hi" }, "timestampMs": now },
            { "kind": "send-message", "message": { "type": "widget" }, "timestampMs": now },
            { "kind": "message", "role": "assistant", "content": "long gone", "timestampMs": old },
            { "kind": "event", "event": { "type": "automation-changed", "action": "created", "automationId": "r1", "automationName": "Nightly check" }, "timestampMs": old },
            { "kind": "event", "event": { "type": "automation-changed", "action": "created", "automationId": "r2", "automationName": "Old job" }, "timestampMs": old },
            { "kind": "event", "event": { "type": "automation-changed", "action": "deleted", "automationId": "r2", "automationName": "Old job" }, "timestampMs": old },
        ]);
        write_blob(
            &dir,
            &format!("{account}transcript.replicas.bot-a"),
            &serde_json::json!({ "schemaVersion": 1, "value": { "entries": entries } }),
        );
        write_blob(
            &dir,
            &format!("{account}transcript.replicas.bot-b"),
            &serde_json::json!({ "schemaVersion": 1, "value": { "entries": [
                { "kind": "event", "event": { "type": "automation-changed", "action": "created", "automationId": "r3", "automationName": "Idle" }, "timestampMs": now },
            ] } }),
        );

        let bots = activity_from(&dir, 7);
        assert_eq!(bots.len(), 1);
        let ops = &bots[0];
        assert_eq!(ops.id, "bot-a");
        assert_eq!(ops.name, "Ops Bot");
        assert_eq!(ops.avatar_shape.as_deref(), Some("teardrop"));
        assert_eq!(ops.avatar_color.as_deref(), Some("violet"));
        // An event-only bot is not spending.
        assert_eq!(ops.messages, 3);
        // "hello there!" (12) → 3, "hi" (2) → 1, the widget → 0.
        assert_eq!(ops.tokens, 4);
        assert_eq!(ops.routines, ["Nightly check"]);
    }
}
