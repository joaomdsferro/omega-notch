# Providers

Where each tool's numbers come from. Everything except the usage endpoints is read from local files, read-only.

| | Limits | Live sessions | Chats | Tokens |
|---|---|---|---|---|
| **Claude Code** | OAuth usage endpoint (sign-in from the login Keychain on macOS) | `~/.claude/sessions/*.json` | `~/.claude/projects/**/*.jsonl` | the same transcripts |
| **Cursor** | usage summary endpoint | composer live flags + open agent transcripts (`turn_ended`) | `composerHeaders` + `composerData` model in `state.vscdb` | usage-events API (in/out/cache); context % and lines on chats |
| **Claude Desktop** | `~/.config/Claude/plan-usage-history.json` (no reset times) | — | — | — |
| **GitHub Copilot** | `copilot_internal/user` endpoint (premium requests, or chat/completions on Free) | VS Code Copilot Chat transcripts (best effort) | — | — |
| **Codex** | `wham/usage` endpoint (5h + weekly, or monthly on Free) with the ChatGPT sign-in from `~/.codex/auth.json` | — | `~/.codex/session_index.jsonl` + rollout `session_meta` / `turn_context` (incl. model) | — |
| **OpenCode** | the sub-provider's own limits when known (Anthropic, GitHub Copilot); its local data otherwise | — | `~/.local/share/opencode/opencode.db` (model per session) | the same database, last 7 days |
| **Grok Bot** | `GetSandUsageStatus` on Cursor's dashboard API (weekly included usage), with your Cursor sign-in | — | the sand store's bot roster (`~/.config/Grok Bot/sand-client-persistence`), name and last message per bot | — |
| **Kimi** | `api.kimi.com/coding/v1/usages` with the Kimi Code CLI's OAuth session (`~/.kimi-code/credentials/kimi-code.json`) | — | — | — |
| **Grok** | `cli-chat-proxy.grok.com` credits, with Grok CLI's `~/.grok/auth.json` (renewed in memory) | — | — | — |
| **Amp** | `ampcode.com/api/internal` balance, with the Amp CLI's key (`~/.local/share/amp/secrets.json`) | — | — | — |
| **Apify** | `api.apify.com/v2/users/me/limits` (monthly spend against the account cap), with `APIFY_TOKEN` or `~/.apify/auth.json` | — | — | — |
| **Kiro** | `kiro-cli chat --no-interactive /usage`, parsed from its card | — | — | — |
| **Kilo** | `api.kilo.ai` coding-plan windows and credit balance, with the Kilo CLI's sign-in (`~/.local/share/kilo/auth.json`) | — | — | — |
| **GLM** | Z.ai's quota monitor, with a GLM Coding Plan key from `~/.claude/settings.json` or opencode's sign-in | — | — | — |
| **Command Code** | `/alpha` usage, credits and subscription, with `~/.commandcode/auth.json` | — | — | — |
| **Devin** | `GetUserStatus`, with Devin Desktop's store or `devin auth login`'s credentials | — | — | — |

Claude Code and Codex accounts kept apart in `~/.claude-<name>` and `~/.codex-<name>` get their own
ring, their own chats and their own token totals: the id is `claude_code-<name>` or `codex-<name>`,
and switching the base provider off switches its accounts off too. On macOS a Claude Code profile
signed in through Keychain storage is not found; sign it in with `CLAUDE_CONFIG_DIR=~/.claude-<name>`
so Claude Code writes `.credentials.json` there.

On macOS, the folders under `~/.config` in this table are under `~/Library/Application Support`
instead, such as `~/Library/Application Support/Claude` and `~/Library/Application Support/Cursor`.

Grok Bot runs on Cursor's backend and keeps its own token in the system keyring, so its ring uses the
Cursor account signed in to `state.vscdb`. It fills in when Cursor and Grok Bot use the same account.

To sign in to Copilot, open Settings and click **Sign in to GitHub Copilot**. GitHub's page opens with
the code already on the clipboard; paste it, confirm, and the ring fills in. A sign-in another Copilot
client already saved is picked up as well: `~/.config/github-copilot/apps.json` / `hosts.json`
(copilot.vim, copilot.lua, JetBrains) or `~/.local/share/opencode/auth.json`.

Codex's ring uses the ChatGPT sign-in Codex already saved in `~/.codex/auth.json` (or `$CODEX_HOME`),
read-only. Codex refreshes that token itself; if it has expired, opening Codex once brings the ring back.

OpenCode's data lives in `~/.local/share/opencode/opencode.db`, read-only: its sessions, the model each
turn ran on, and token counts. The ring follows the sub-provider of your latest session — Anthropic and
GitHub Copilot limits come from their own endpoints using the sign-ins OpenCode saved in `auth.json`,
while every other sub-provider (opencode zen, OpenRouter, …) falls back to the local usage of the last
7 days, labelled with the model and who it bills.
