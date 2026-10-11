# Omega Notch IPC protocol

Newline-delimited JSON over a Unix domain socket:

```
$XDG_RUNTIME_DIR/omega-notch.sock
```

Protocol version: **2**

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
| `ping` | — | liveness |

## Engine → Client

| type | fields |
|---|---|
| `hello` | `server`, `version`, `protocol` |
| `snapshot` | `readings`, `sessions`, `chats`, `tokens`, `config` |
| `activity_updated` | `chats`, `tokens` |
| `usage_updated` | `reading` |
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

## Provider ids

`cursor` · `claude_code` · `claude_desktop` · `copilot` · `grok_bot` · `codex` · (reserved) `claude_web` · `chatgpt_web` · `gemini_web`

## Hook HTTP (localhost)

`POST http://127.0.0.1:17337/hooks/session`

```json
{ "provider": "claude_code", "kind": "busy|waiting_you|idle", "label": "optional" }
```
