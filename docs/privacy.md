# Privacy

- Everything except the usage endpoints is read from local files, read-only.
- Network requests go to each tool's own usage endpoint, with the sign-in that tool already saved;
  on macOS, to GitHub for the update check (below); and, only when you press "Ask Claude" in the
  dashboard, to Anthropic through your own `claude` command (see below). Nothing goes to a server
  of ours, because there is none.
- On macOS, the downloaded app also checks GitHub once a day for a newer release (you can switch
  that off in Settings → General). It asks before installing anything, and installs only updates
  signed with the project's key. The check sends nothing about you or your usage.
- The Copilot sign-in made through the notch is kept in `~/.local/share/omega-notch/copilot.json`
  (mode 600). Settings live in `~/.config/omega-notch/config.json`. On macOS both are in
  `~/Library/Application Support/omega-notch`.
- The dashboard's daily token history is kept in `history.db`, in the same folder as the Copilot
  sign-in: token counts per day and model, and per Claude Code session with its title, project
  folder and where it ran. No chat content is kept. Session rows are deleted once they are more than
  90 days old.
- Which finished chats you have read is kept in `seen.json` in the same folder (mode 600): chat ids
  and when you last looked at each, for 30 days. On macOS, while a finished chat is still to read
  and you are using the Mac, the app tells the engine which app is in front and, with
  Accessibility, its window's title, so it can tell when you are looking at that chat. That
  stays on your Mac, goes no further than the engine, and is not stored.
- "Ask Claude" in the dashboard's Suggestions sends Anthropic, through your own `claude` command,
  only numbers: totals, ratios, models, cost per day and the dearest sessions as S1, S2… No title,
  folder, project name or chat text. It runs with no tools and does not save a session. Nothing is
  sent unless you press it.
- The hook server listens on `127.0.0.1` only.
