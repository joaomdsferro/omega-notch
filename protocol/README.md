# Omega Notch IPC protocol

Newline-delimited JSON over a Unix domain socket:

```
$XDG_RUNTIME_DIR/omega-notch.sock                                  (Linux)
~/Library/Application Support/omega-notch/omega-notch.sock          (macOS)
```

Only its owner can connect: the socket is `0600`, in a folder only its owner
can open.

Protocol version: **6**

New messages and new fields are optional, and clients ignore what they do
not know, so adding them leaves the version as it is. It goes up only when a
message or field is removed or changes meaning. The `(vN)` tags below mark
when something arrived before this rule.

The socket path can be overridden with `OMEGA_NOTCH_SOCKET`.

## Client → Engine

| type | fields | purpose |
|---|---|---|
| `hello` | `client`, `version` | identify shell |
| `subscribe` | — | receive push events + immediate snapshot |
| `get_snapshot` | — | one-shot snapshot |
| `refresh` | `provider?` | force provider refresh |
| `get_config` | — | current config |
| `set_config` | `config` | replace config (persisted) |
| `open_chat` | `provider`, `id`, `cwd?`, `title?`, `surface?` | raise the chat's window, or resume it in a new one |
| `get_dashboard` | `days?` (7–90, default 30), `search?`, `project?`, `session?` | persisted history + cost estimates |
| `window_focused` | `pid`, `title?` | the window now in front (macOS); a finished chat it shows is read |
| `ping` | — | liveness |

## Engine → Client

| type | fields |
|---|---|
| `hello` | `server`, `version`, `protocol` |
| `snapshot` | `readings`, `sessions`, `chats`, `tokens`, `config` |
| `activity_updated` | `chats`, `tokens` |
| `usage_updated` | `reading` |
| `dashboard` | `points`, `costs`, `total_usd`, `models`, `sessions`, `search?`, `project?`, `session?`, `projects`, `suggestions` |
| `session_updated` | `session` |
| `session_finished` | `session` |
| `session_waiting` | `session` |
| `limit_reached` | `limit` |
| `config_updated` | `config` |
| `raise_window` | `pids`, `hints`, `tty?` |
| `pong` | — |
| `error` | `message` |

`raise_window` (v4) answers `open_chat` on macOS when the chat runs in a
live session: the engine has brought the app forward, and the client picks the
window. `pids` is the session's process and its parents, nearest first; the
first one that is an app owns the window. `hints` are words its title may
carry, best first. `tty` is the session's terminal (`/dev/ttys003`), for
picking the tab. Other clients ignore it.

`limit_reached` (v5) says a provider's headline window (its first) has passed
80% or reached 100%: `limit` has `provider`, `display_name`, `label` (the
window's name), `used_pct`, `threshold` (80 or 100) and `resets_at?`. Each
threshold is sent once, and again only after usage falls 10 points below it
(a new window); the engine's first reading of a provider sets the starting
point without one. Muted providers, and `alerts.limits` off, send none. Older
clients ignore it.

`session_updated` carries a provider's overall state (waiting outranks busy,
busy outranks idle). `session_finished` and `session_waiting` are about one
session and are there to be announced; they do not replace that state.

## Chats and tokens

```json
{
  "provider": "claude_code", "id": "…", "title": "Sidebar resize performance",
  "project": "omega-zap", "cwd": "/home/me/omega-zap", "model": "Opus 5.5",
  "surface": "VS Code", "state": "busy", "live": true,
  "updated_at": "2026-09-30T14:42:26Z", "messages": 12,
  "tokens": { "input": 412, "output": 28247, "cache_read": 3357968, "cache_write": 128178 },
  "context_tokens": 151320
}
```

Optional per provider: `tokens`, `context_tokens`, `context_pct`,
`lines_added`, `lines_removed`. Chats arrive newest first, at most 8 per
provider.

`unread` (v6) is true for a chat that stopped with a reply newer than both
your latest prompt in it and the last time you looked at it. Looking means
`open_chat` on it that succeeds, or (macOS) `window_focused` naming the app that runs it:
the engine picks the live session under `pid` whose chat title, name or
folder the window's `title` carries best, or the only one when there is no
title. Sessions the title fits equally well (VS Code captions a chat's tab
with the folder alone) go to the only one of them that is unread. Anything
less clear marks nothing. Only Claude Code says when it last replied,
so other tools' chats are never unread. The marks are kept in `seen.json`
(mode 600) next to `history.db`; on the first run every chat already on disk
counts as read. Older clients ignore the field.

```json
{
  "provider": "claude_code",
  "today": { "input": 0, "output": 0, "cache_read": 0, "cache_write": 0 },
  "week":  { "input": 0, "output": 0, "cache_read": 0, "cache_write": 0 },
  "daily": [{ "date": "2026-09-24", "total": 0 }],
  "models_today": [{ "model": "Opus 5.5", "total": 0 }]
}
```

`daily` is the last seven local days, oldest first. A streamed message is
counted once, at its final size.

## Dashboard history

Persisted by the engine in `~/.local/share/omega-notch/history.db`
(`~/Library/Application Support/omega-notch/history.db` on macOS). Every
activity refresh rewrites the days it covers (the last seven), and on first
start the engine backfills every older Claude Code day still on disk.
`daily_tokens` holds one row per tool and day (`points`):

```json
{
  "provider": "claude_code", "date": "2026-10-01",
  "input": 412, "output": 28247, "cache_read": 3357968,
  "cache_write": 128178, "total": 3490835
}
```

`models` comes from `daily_model_tokens`, one row per tool, day and model,
with its estimated cost:

```json
{
  "provider": "claude_code", "date": "2026-10-01", "model": "Opus 5.5",
  "input": 412, "output": 28247, "cache_read": 3357968,
  "cache_write": 128178, "total": 3490835, "cost_usd": 1.27
}
```

`costs` is today only, one entry per model:

```json
{
  "provider": "claude_code", "model": "Opus 5.5",
  "total": 3490835, "cost_usd": 1.27
}
```

`sessions` (v6) comes from `session_model_tokens`: the range's dearest
sessions, at most 100, each split by model, dearest first. A subagent's tokens
count towards the session that ran it. `last_date` is the session's last day
in the range with tokens. `title`, `project`, `cwd` and `surface` come from
`session_meta`; a session whose transcript is gone is named by its id. Session
rows hold chat titles, so the engine drops them once they are older than the
history (90 days). Older clients ignore the field.

`get_dashboard` can narrow the whole dashboard. With a `search`, only the
sessions that carry every word of it (case aside) in their title, project,
folder, id or a model's name count; with a `project` (a name from
`projects`), only the sessions run there. Then `points`, `models`, `costs`
and `total_usd` are summed from those sessions' rows instead of the daily
tables, so they cover Claude Code alone, and `sessions` is every match in
the range, dearest first, still at most 100: a cheap session is found too.
The engine reads at most 8 words from 200 characters and sends back what it
read as `search` and `project`, so a client knows what the numbers answer;
both are left out when empty. `projects` is every project in the range,
dearest first, with its `sessions`, `total` and `cost_usd`, whatever the
scope: what a client offers to narrow to. A `session` (an id from
`sessions`) narrows the numbers further, to that one session, but not
`sessions` itself, so a client can still offer the others; it is echoed
like the rest.

`suggestions` are what to change, from local rules over the sessions the
numbers cover (every one in scope, not only the first 100) and the live chats
among them, likeliest saving first, at most 5. Each has a `kind`, a `title`
and a `detail` to show as they are, the `provider`, the `sessions` it is about
(dearest first) and, when it can be told, `saving_usd`: roughly what following
it would have saved over the range at list prices. Kinds so far:
`model_choice` (small jobs, under 20k output tokens, on Opus or Fable; saving
against Sonnet 5.5), `cache_churn` (sessions that rebuild their prompt cache
more than they reuse it; half the extra cost of those writes), `long_session`
(30M+ tokens of history re-read) and `context_full` (a live chat 80%+ full).
A client should show an unknown kind like any other.

```json
{
  "provider": "claude_code", "id": "3f1c9a52-…", "title": "Sidebar resize performance",
  "project": "omega-zap", "cwd": "/home/me/omega-zap", "surface": "VS Code",
  "last_date": "2026-10-01", "input": 412, "output": 28247,
  "cache_read": 3357968, "cache_write": 128178, "total": 3514805, "cost_usd": 1.27,
  "models": [{ "model": "Opus 5.5", "input": 412, "output": 28247,
    "cache_read": 3357968, "cache_write": 128178, "total": 3514805, "cost_usd": 1.27 }]
}
```

`total_usd` is the sum over `costs`. All costs are estimates from a static
per-model price table (cache-aware) — never a bill.

## Provider ids

`cursor` · `claude_code` · `claude_desktop` · `copilot` · `grok_bot` · `codex` · (reserved) `claude_web` · `chatgpt_web` · `gemini_web`

## Hook HTTP (localhost)

`POST http://127.0.0.1:17337/hooks/session`

```json
{ "provider": "claude_code", "kind": "busy|waiting_you|idle", "label": "optional" }
```

Only local tools may post, never a web page. A request must send
`Content-Type: application/json` (otherwise `415`), a `Host` of
`127.0.0.1:17337` or `localhost:17337`, and no `Origin` header (otherwise
`403`). curl does all of that by default once given the content type.
