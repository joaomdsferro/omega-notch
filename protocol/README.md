# Omega Notch IPC protocol

Newline-delimited JSON over a Unix domain socket:

```
$XDG_RUNTIME_DIR/omega-notch.sock
```

Protocol version: **3**

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
| `get_dashboard` | `days?` (7–90, default 30) | persisted history + cost estimates |
| `ping` | — | liveness |

## Engine → Client

| type | fields |
|---|---|
| `hello` | `server`, `version`, `protocol` |
| `snapshot` | `readings`, `sessions`, `chats`, `tokens`, `config` |
| `activity_updated` | `chats`, `tokens` |
| `usage_updated` | `reading` |
| `dashboard` | `points`, `costs`, `total_usd`, `models` |
| `session_updated` | `session` |
| `session_finished` | `session` |
| `session_waiting` | `session` |
| `config_updated` | `config` |
| `pong` | — |
| `error` | `message` |

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

Persisted by the engine in `~/.local/share/omega-notch/history.db`. Every
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
