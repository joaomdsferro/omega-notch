# Features

- A notch fused to any edge of any screen, in black or any colour. It hides behind a small nub until
  a session finishes or the pointer touches its edge, or stays on screen if you prefer
- One ring per tool, up to five: the ones working right now first, then the most recently used, each
  showing how much of its limit is gone. Scroll on the notch to bring up the others
- A white arc orbits inside a ring while a session works, and turns into a breathing amber ring when
  one is waiting on you
- Hover a ring for its card:
  - every limit window, with its reset time
  - **tokens today** (input, output, cache), the last seven days, and the split per model
  - **recent chats**: title, project, model, tokens spent, and which ones are working or need you.
    Click one to jump to it: the terminal or VS Code window running it, or a new one resuming it
- The card opens by itself for a few seconds, with a sound, when a session finishes or asks
  something, and when a tool's main limit passes 80% and when it reaches 100%. System
  notifications for these are optional and off by default
- A **dashboard** window, from the bars button in the notch's footer: every limit, estimated cost and
  tokens per day over 7, 30 or 90 days (by model, by tool or by kind), each model's share of the
  spend, today's mix, the dearest sessions with each one's models, and the recent chats. History
  starts with every Claude Code day still on disk. Costs are estimates at API list prices, not a bill
  - Its charts and tables come in greys, a vivid palette or a colour-blind safe one (Okabe–Ito), and
    any series can have a colour of its own, in Settings → Notch
  - Narrow the whole page to one project, one chat, or a search by title, folder or model: costs,
    tokens, models, sessions and chats then cover only those Claude Code sessions, cheap ones too
  - Suggestions from local rules over those sessions, with what each would roughly have saved: small
    jobs run on a top model, a prompt cache rebuilt more than reused, a very long session, a chat
    near its context limit. Each can narrow the page to the chat it is about, or open it. On
    request, Claude (Sonnet or Opus, through your own `claude` and subscription) adds its own advice
- **Chats to read.** A chat that finished since you last looked at it gets a green badge on its
  tool's ring (a green dot on the nub, or under the camera housing, while the notch is tucked away)
  and its own "To read" list in the card and the dashboard. It counts as read once you open it from
  the notch, write in it again, or (on macOS) bring its window or tab to the front while you are at
  the Mac. Claude Code only, for now: other tools do not say when they last replied
- Click a ring to refresh it; hover the notch for Settings and a grip to slide it along the edge;
  right-click opens Settings
- Only the notch takes input; the rest of the edge stays click-through
- A failed refresh keeps the last good numbers instead of blanking the ring
