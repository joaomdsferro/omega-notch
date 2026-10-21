# Omega Notch — design system

The tokens the app is painted with. The two shells hold the same values:
`ui/plasma/qml/Theme.qml` and `ui/macos/Sources/OmegaNotch/Theme.swift` read
them from `Theme.qml` and `ThemeCatalog.swift`; this file is where they are
written down, so the two cannot drift.

A theme is a set of tokens. The engine's config says which one is in use
(`theme`, default `noir`); Settings › Appearance picks it. Changing the theme
changes the tokens, and every binding that reads one follows.

## The themes

| Name | What it is | Accent |
| --- | --- | --- |
| `noir` | Graphite with one accent. The default. | `#5B8CFF` |
| `classic` | The look the app had before the themes. | `#4C8DFF` |
| `vidro` | Translucent material, for a mac first. | `#7AA2FF` |
| `clube` | An instrument panel: dense, mono, a green accent. | `#7FD1AE` |
| `aurora` | A field of light: soft, roomy, a violet accent. | `#7C8CFF` |
| `terminal` | Mono, hairlines, one electric accent. | `#00E5A0` |

`noir` is the default; `classic` keeps the old look, with one change: the
faintest ink is lifted so it reads on the raised surfaces (below).

## The tokens

Every theme sets the same twenty-two tokens.

| Token | What it paints | Noir |
| --- | --- | --- |
| `panel` | The dashboard's page | `#0C0C10` |
| `panelRaised` | A card on the page | `#15151B` |
| `panelHover` | A row under the pointer | `#1E1E26` |
| `card` | The notch's card | `#08080A` |
| `notch` | The notch itself | `#000000` |
| `cardStroke` | A card's edge | white 14% |
| `hairline` | A rule between rows | white 8% |
| `track` | The empty part of a bar | `#3A3A45` |
| `text` | Primary ink | `#FFFFFF` |
| `textSecondary` | Secondary ink | `#A9A9B5` |
| `textTertiary` | Faintest ink: table heads, footnotes | `#8B8B97` |
| `accent` | What is chosen or interactive | `#5B8CFF` |
| `ample` | Plenty of quota | `#3DDC97` |
| `watch` | Getting close to the limit | `#F5C542` |
| `critical` | Out of quota | `#FF6A4D` |
| `waiting` | A session needs you | `#FFB020` |
| `unread` | A finished chat to read | `#5B8CFF` |
| `busy` | A session is working | `#FFFFFF` |
| `botEye` | A bot avatar's eyes | `#08080A` |
| `controlFill` | A control's own fill | white 8% |
| `controlChosen` | A chosen control's fill | accent 12% |
| `controlHover` | A control under the pointer | white 7% |

### Rules the tokens follow

- **Text is never below 4.5:1** on the surface it sits on, and never below
  3:1 for large text. `textTertiary` on `panelRaised` was `#5F5F68` (2.86:1)
  and is now `#8B8B97` (5.40:1). A theme that cannot keep that rule is not a
  theme.
- **A colour never carries a meaning alone.** A limit is a number and a bar,
  not only a colour; a state is a word as well as a hue.
- **`unread` is not `ample`.** In Noir the unread dot is the accent, so
  "a chat to read" never looks like "plenty of quota".
- **A track is decoration.** The filled part of a bar is the meaningful
  graphic, and it has to pass 3:1 against the surface.
- **The notch can be painted**, so what sits on it flips to black once the
  surface is light enough (`Theme.ink`).

## Type

| Role | Size | Weight |
| --- | --- | --- |
| A big number | 26–32 | semibold, tabular |
| Page title | 26 | semibold |
| Section title | 15 | semibold |
| Card title | 14 | semibold |
| Body | 13 | regular |
| Label | 12 | medium |
| Caption | 11.5 | regular |
| Micro label | 10.5 | semibold, +0.06em, upper |

Numbers that change use tabular figures, in both shells, so a column does not
jump as the digits move. A label in caps is for a short word only.

## Space, radius, depth

- Space is a scale of 4: 4, 8, 12, 16, 20, 24, 32. Nothing outside it.
- Radius: 6 for a chip, 10 for a control, 14 for a card, 20 for the notch's
  card, 999 for a pill. A theme may lower them (`clube`, `terminal`).
- Depth is a 1 px stroke and a 1 px highlight along the top edge. Only the
  notch's card, which floats over the desktop, has a shadow.

## Motion

| Duration | What it is for |
| --- | --- |
| 120 ms | Hover, a colour change |
| 180 ms | A state change: a row, a segment |
| 240 ms | Something entering or leaving |
| 420 ms | A bar or a ring filling |

One curve, `cubic-bezier(.22, .61, .36, 1)` (out-cubic), in both shells. The
breathing dot is 1.4 s, between 35% and full opacity. Nothing loops without a
reason, and reduced motion replaces movement with a fade.

## Where the themes live

| | Plasma | macOS |
| --- | --- | --- |
| The tokens | `ui/plasma/qml/Theme.qml` | `ui/macos/Sources/OmegaNotch/Theme.swift` |
| The catalogue | the same file | `ui/macos/Sources/OmegaNotchKit/ThemeCatalog.swift` |
| The config key | `theme` | `theme` |

Both shells follow the engine's config: Plasma through `Theme.apply()`
(`Theme.qml`), macOS through `ThemeStore` (`Theme.swift`). A mock of all six
themes, with their contrast measured, is in `docs/design/theme-lab.html`.
