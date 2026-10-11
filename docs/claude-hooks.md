# Claude Code hooks example for Omega Notch

Recent Claude Code keeps a session registry in `~/.claude/sessions/`, and Omega
Notch reads working / waiting / finished straight from it — no hooks needed.
With the registry present, hook events for `claude_code` only update the ring
and are not announced a second time.

For older builds without the registry, add to `~/.claude/settings.json` (merge with your existing hooks):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "omega-notch-claude-hook idle \"claude finished\""
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "omega-notch-claude-hook waiting_you \"needs input\""
          }
        ]
      }
    ]
  }
}
```

The engine also accepts:

```sh
curl -sS -X POST http://127.0.0.1:17337/hooks/session \
  -H 'content-type: application/json' \
  -d '{"provider":"claude_code","kind":"busy","label":"working"}'
```
