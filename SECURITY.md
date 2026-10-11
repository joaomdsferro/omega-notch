# Security

Omega Notch reads the sign-ins of your AI coding tools (Claude Code, Cursor, Codex, GitHub Copilot) and
the transcripts of your chats, so security problems matter a great deal.

## Reporting a vulnerability

Please report privately, not in a public issue: use
[GitHub's private vulnerability reporting](https://github.com/joaomdsferro/omega-notch/security/advisories/new).
Include what an attacker could do, how to reproduce it, and the version affected.

You will get an answer within a week. Once a fix is released, the report can be made public, with
credit if you want it.

## Supported versions

Omega Notch is in early testing. Only the latest release gets fixes.

## In scope

- Tokens or chat contents leaving the computer anywhere other than the tool's own usage endpoint
- Other users or other machines reaching the engine's socket or hook server
- Running code through a transcript, a chat title or a hook request
- Omega Notch writing to, or corrupting, the files of the tools it reads

Problems in Claude Code, Cursor, Codex, Copilot or their APIs themselves should go to those projects.
