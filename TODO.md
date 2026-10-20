# TODO

Ordered roadmap. Close what is half-finished first, then earn trust in the data,
then invest in the interaction that justifies the notch. Effort: **S** ≤ 1 day,
**M** 2–4 days, **L** 1+ week. Every item says when it is done.

## Phases

- **Phase 0 — Foundation (done):** string ids and a dynamic provider registry;
  multi-profile accounts for Claude Code and Codex.
- **Phase 1 — Providers and accounts (done):** nine new providers (Kimi, Grok
  CLI, Amp, Apify, Kiro, Kilo, GLM, Command Code, Devin); per-account sessions,
  chats, tokens and jump for `~/.claude-*` and `~/.codex-*`; OpenCode working /
  waiting states and a finish announcement.
- **Phase 2 — More data sources:** Antigravity/Gemini quota and tokens; Ollama
  and LM Studio; oMLX; custom endpoints (URL + key, health check, and a reason
  when there is no data); fixtures and docs per provider; provider discovery on
  a new machine, favourites and search in the picker.
- **Phase 3 — Remote:** sessions over SSH; web views for remote dashboards; a
  doctor that separates local from remote.
- **Phase 4 — UI parity:** close items 1, 3, 4 and 5, plus the known bugs and
  the terminal-tab decision.
- **Phase 5 — Phone and multiple machines:** versioned export/import of
  aggregates, folder/LAN/Tailscale sync with an idempotent merge, and a phone
  companion reading the same snapshot.

## Next 15

### A. Foundation

1. **macOS parity in CI** · M
   Compile the macOS shell and run `swift test` in CI, and fix the Swift issues
   left by the theme work (`ThemeStore`, `RingView`, loading and states).
   *Done when:* a PR that breaks Swift fails in CI, and no Swift target is left
   unbuilt.

2. **Known dashboard bugs** · S
   Slow scrolling in the dashboard tab, and OpenCode model names listed wrong.
   *Done when:* scrolling stays smooth with 90 days of history, and OpenCode
   sessions show the vendor and model they actually ran on.

3. **Page-level error and exhausted states** · M
   Today there is only the generic "engine offline" and the limit inside a
   provider's card. Add a dashboard error page and a page-level 100% quota
   state.
   *Done when:* a failed dashboard offers a retry, and a provider at 100% reads
   on the page, not only on its ring.

4. **Keyboard, focus and reduced motion in Plasma** · M
   Dashboard controls are `TapHandler`s and cannot take focus; the theme picker
   already can. Honour the system motion setting or expose it in Settings.
   *Done when:* the whole dashboard is reachable with Tab/Enter/Esc and every
   control has a visible focus ring.

5. **Finish NOIR at component level** · M
   The full type scale from `DESIGN.md` and one motion curve across both shells
   (elevation shipped already).
   *Done when:* both shells use the same type steps and the same curve, and
   `check_themes.py` covers type and motion too.

### B. Trust in the data

6. **Reading provenance and freshness** · M
   Every reading says where it came from and how old it is: official, cached,
   estimated, no data. A Doctor panel in Settings explains what each provider
   can see (reusing `make doctor`).
   *Done when:* the card and dashboard tell a 3-minute-old reading from
   yesterday's, and a provider with no data says why.

7. **Burn rate and reset forecast** · M
   Linear projection of the current window: "at this pace you hit the limit at
   HH:MM" and "you run out before the reset". Shown in the card and dashboard.
   *Done when:* the forecast appears only with enough data, is marked as an
   estimate, and never replaces the official number.

8. **Honest cost** · M
   Show what you pay (subscription prorated to the range) before the API
   equivalent, cache misses/rebuilt tokens, and cost per prompt on the dearest
   sessions.
   *Done when:* the dashboard answers "why did this prompt cost that" without
   leaving the session row.

9. **Local budgets and quota history** · M
   Daily/monthly caps with a local notification, and keep window utilization
   over time to answer "how often did you hit the limit".
   *Done when:* a cap set in Settings raises a warning when crossed, and the
   history shows the quota trend without storing chat content.

### C. Interaction — what a menu bar cannot do

10. **Inline approvals in the notch** · L
    Claude Code permission requests through a long-poll hook, with Allow /
    Allow always / Deny in the notch and the decision returned to the CLI. One
    shell first (Plasma, where it can be tested), then the other.
    *Done when:* a session blocked on a request is resolved without opening a
    terminal, and "always" is honoured.

11. **One "Needs you" queue** · M
    Waiting sessions, approvals and questions from every provider in one list
    ordered by urgency, with a badge on the nub and on the provider ring.
    *Done when:* a session from another provider asking for input sits next to
    a Claude Code one, at the same priority.

12. **Tab-accurate focus** · M
    Use the `tty` the engine already resolves to pick the right tab (Terminal,
    iTerm2, Ghostty) instead of only raising the window, and `--resume` when
    the session is gone.
    *Done when:* clicking a chat with three tabs open lands on the right tab in
    the two most-used terminals.

13. **Live Codex sessions** · L
    Read Codex rollout logs to derive working / waiting / done, as already done
    for Claude Code and OpenCode.
    *Done when:* Codex has a live ring state and recent chats at the same
    quality as the other two.

### D. Reach

14. **Two machines, one dashboard** · L
    Versioned export/import of aggregates (no chat content) and an idempotent
    merge by provider/day/model; sync through a folder, LAN or Tailscale, with
    no account and no server.
    *Done when:* one machine's dashboard shows the summed totals from both, and
    importing the same file twice duplicates nothing.

15. **Provider status and incidents** · S
    Poll status pages (Anthropic, OpenAI, GitHub, Cursor) with a 5-minute
    cache, a badge on the ring and a note in the card when an incident is open.
    *Done when:* a provider outage is distinguishable from a local network
    failure, and the badge clears when the incident closes.

## Out of scope for now

Cross-provider skills (a sibling project, not a notch feature) and hosted
cloud/sync. Neither starts before items 1–9 are closed.
