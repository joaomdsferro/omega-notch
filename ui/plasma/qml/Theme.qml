pragma Singleton
import QtQuick
import QtQuick.Window

// One place for every colour, size and piece of copy formatting, so the notch,
// its card and Settings stay in the same visual language.
//
// The colours are the tokens of the theme in use. A theme is a set of them
// (see `themes`), and the engine's config says which one is in use: Settings
// › Appearance picks it, and `apply` puts its tokens in place. Every binding
// that reads a token here follows along, so the whole app changes at once.
Item {
    id: root

    // The theme in use, by name.
    property string name: "noir"

    // ---- The tokens of the theme in use ----
    // Surfaces
    property color notch: "#000000"
    property color card: "#08080A"
    property color cardStroke: "#24FFFFFF"
    property color hairline: "#14FFFFFF"
    property color track: "#3A3A45"
    property color panel: "#0C0C10"
    property color panelRaised: "#15151B"
    property color panelHover: "#1E1E26"

    // Ink
    property color text: "#FFFFFF"
    property color textSecondary: "#A9A9B5"
    property color textTertiary: "#8B8B97"

    // Meaning
    property color ample: "#3DDC97"
    property color watch: "#F5C542"
    property color critical: "#FF6A4D"
    property color waiting: "#FFB020"
    // A finished chat you have not read yet. In Noir this is the accent, so
    // "unread" never looks like "plenty of quota".
    property color unread: "#5B8CFF"
    property color busy: "#FFFFFF"
    // The one accent, for what is chosen or interactive.
    property color accent: "#5B8CFF"
    // A bot avatar's eye slots, as good as the card behind them.
    property color botEye: "#08080A"

    property color controlFill: "#14FFFFFF"
    property color controlChosen: "#1F5B8CFF"
    property color controlHover: "#12FFFFFF"

    // ---- The themes ----
    // The colours of each one; the first is the default. `label` and `blurb`
    // are what Settings shows, and `swatches` what it previews.
    readonly property var themes: ({
        noir: {
            label: "Noir",
            blurb: "Graphite with one accent",
            swatches: ["#0C0C10", "#15151B", "#5B8CFF"],
            colors: {
                notch: "#000000", card: "#08080A", cardStroke: "#24FFFFFF",
                hairline: "#14FFFFFF", track: "#3A3A45",
                panel: "#0C0C10", panelRaised: "#15151B", panelHover: "#1E1E26",
                text: "#FFFFFF", textSecondary: "#A9A9B5", textTertiary: "#8B8B97",
                ample: "#3DDC97", watch: "#F5C542", critical: "#FF6A4D",
                waiting: "#FFB020", unread: "#5B8CFF", busy: "#FFFFFF",
                accent: "#5B8CFF", botEye: "#08080A",
                controlFill: "#14FFFFFF", controlChosen: "#1F5B8CFF",
                controlHover: "#12FFFFFF"
            }
        },
        classic: {
            label: "Classic",
            blurb: "The look as it was",
            swatches: ["#0B0B0D", "#16161A", "#3DDC97"],
            colors: {
                notch: "#000000", card: "#000000", cardStroke: "#1FFFFFFF",
                hairline: "#1AFFFFFF", track: "#2EFFFFFF",
                panel: "#0B0B0D", panelRaised: "#16161A", panelHover: "#1F1F25",
                text: "#FFFFFF", textSecondary: "#9A9AA2", textTertiary: "#8B8B95",
                ample: "#3DDC97", watch: "#F5C542", critical: "#FF5A36",
                waiting: "#FFB020", unread: "#3DDC97", busy: "#FFFFFF",
                accent: "#4C8DFF", botEye: "#0B0B0D",
                controlFill: "#14FFFFFF", controlChosen: "#2EFFFFFF",
                controlHover: "#12FFFFFF"
            }
        },
        vidro: {
            label: "Vidro",
            blurb: "Translucent material",
            swatches: ["#0C0E14", "#161923", "#7AA2FF"],
            colors: {
                notch: "#0A0B0F", card: "#14161E", cardStroke: "#38FFFFFF",
                hairline: "#24FFFFFF", track: "#39404F",
                panel: "#0C0E14", panelRaised: "#161923", panelHover: "#1F232F",
                text: "#FFFFFF", textSecondary: "#ADB3C4", textTertiary: "#8E95A8",
                ample: "#4FE3A4", watch: "#FFD166", critical: "#FF7A5C",
                waiting: "#FFB84D", unread: "#7AA2FF", busy: "#FFFFFF",
                accent: "#7AA2FF", botEye: "#14161E",
                controlFill: "#1AFFFFFF", controlChosen: "#2A7AA2FF",
                controlHover: "#12FFFFFF"
            }
        },
        clube: {
            label: "Clube",
            blurb: "An instrument panel",
            swatches: ["#0A0A0C", "#131317", "#7FD1AE"],
            colors: {
                notch: "#000000", card: "#0D0D10", cardStroke: "#24FFFFFF",
                hairline: "#1AFFFFFF", track: "#383841",
                panel: "#0A0A0C", panelRaised: "#131317", panelHover: "#1C1C22",
                text: "#FFFFFF", textSecondary: "#A4A4AE", textTertiary: "#86868F",
                ample: "#3DDC97", watch: "#F5C542", critical: "#FF6A4D",
                waiting: "#FFB020", unread: "#7FD1AE", busy: "#FFFFFF",
                accent: "#7FD1AE", botEye: "#0D0D10",
                controlFill: "#14FFFFFF", controlChosen: "#1F7FD1AE",
                controlHover: "#12FFFFFF"
            }
        },
        aurora: {
            label: "Aurora",
            blurb: "A field of light",
            swatches: ["#0D0F1A", "#161A28", "#7C8CFF"],
            colors: {
                notch: "#05060B", card: "#141827", cardStroke: "#24FFFFFF",
                hairline: "#1AFFFFFF", track: "#3C4256",
                panel: "#0D0F1A", panelRaised: "#161A28", panelHover: "#202639",
                text: "#FFFFFF", textSecondary: "#ADB3C8", textTertiary: "#8E95AD",
                ample: "#3DDC97", watch: "#F5C542", critical: "#FF6A4D",
                waiting: "#FFB020", unread: "#E86BD0", busy: "#FFFFFF",
                accent: "#7C8CFF", botEye: "#141827",
                controlFill: "#14FFFFFF", controlChosen: "#1F7C8CFF",
                controlHover: "#12FFFFFF"
            }
        },
        terminal: {
            label: "Terminal",
            blurb: "Mono, hairlines, one accent",
            swatches: ["#000000", "#0D0D0D", "#00E5A0"],
            colors: {
                notch: "#000000", card: "#0A0A0A", cardStroke: "#2EFFFFFF",
                hairline: "#1FFFFFFF", track: "#2A2A2A",
                panel: "#000000", panelRaised: "#0D0D0D", panelHover: "#171717",
                text: "#FFFFFF", textSecondary: "#A0A0A0", textTertiary: "#7E7E7E",
                ample: "#3DDC97", watch: "#F5C542", critical: "#FF5A36",
                waiting: "#FFB020", unread: "#00E5A0", busy: "#FFFFFF",
                accent: "#00E5A0", botEye: "#0A0A0A",
                controlFill: "#14FFFFFF", controlChosen: "#1F00E5A0",
                controlHover: "#12FFFFFF"
            }
        }
    })

    // The themes, in the order Settings lists them.
    readonly property var themeList: {
        const out = []
        for (const id in themes) {
            const theme = themes[id]
            out.push({ id: id, label: theme.label, blurb: theme.blurb,
                       swatches: theme.swatches })
        }
        return out
    }

    // Puts a theme's tokens in place. An unknown name leaves the current
    // theme alone, and the theme in use is not applied twice.
    function apply(themeName) {
        const theme = themes[themeName]
        if (!theme || themeName === root.name)
            return false
        for (const key in theme.colors)
            root[key] = theme.colors[key]
        root.name = themeName
        return true
    }

    // The engine's config says which theme is in use; follow it. The
    // singleton is an Item because a QtObject has nowhere to put the
    // Connections that watch it.
    Component.onCompleted: {
        if (typeof Engine !== "undefined")
            root.apply(Engine.theme)
    }
    Connections {
        target: typeof Engine !== "undefined" ? Engine : null
        function onConfigChanged() {
            if (typeof Engine !== "undefined")
                root.apply(Engine.theme)
        }
    }

    // Dashboard palettes, first series first, as in the engine's config
    // (`dashboard_palette`). Mono is brightest first: the biggest share gets
    // the most ink; colour-blind safe is Okabe–Ito.
    readonly property var palettes: ({
        mono: ["#F2F2F5", "#B4B4BE", "#808089", "#5C5C66", "#44444D", "#33333B"],
        vivid: ["#5B9BFF", "#FF8A3D", "#43D9AD", "#E86BD0", "#F2D04B", "#9C8CFF"],
        colorblind: ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#CC79A7", "#0072B2"]
    })
    readonly property var paletteNames: [
        { value: "mono", label: "Monochrome" },
        { value: "vivid", label: "Vivid" },
        { value: "colorblind", label: "Colour-blind safe" }
    ]
    // The default series colours; the dashboard draws with seriesShades().
    readonly property var shades: palettes.mono
    // Swatches for a series colour, light enough for the dark panel.
    readonly property var seriesSwatches: ["#F2F2F5", "#5B9BFF", "#43D9AD", "#F2D04B",
                                           "#FF8A3D", "#E86BD0", "#9C8CFF"]

    // A palette's colours with each one set in Settings in its place.
    function seriesShades(palette, overrides) {
        const base = palettes[palette] || palettes.mono
        return base.map((c, i) => (overrides && overrides[i]) ? overrides[i] : c)
    }

    readonly property int watchAt: 75
    readonly property int criticalAt: 90

    // ---- Motion ----
    // The desktop's own setting (KDE's AnimationDurationFactor at 0), read by
    // the engine. Reduced motion keeps every state change instant and stops
    // anything that loops.
    readonly property bool reducedMotion: typeof Engine !== "undefined" && Engine.reducedMotion
    // Durations in milliseconds, the same steps in both shells (DESIGN.md).
    readonly property int motionHover: 120
    readonly property int motionState: 180
    readonly property int motionEnter: 240
    readonly property int motionFill: 420
    readonly property int motionBreath: 1400
    // One curve, out-cubic, in both shells: cubic-bezier(.22, .61, .36, 1).
    readonly property var motionCurve: [0.22, 0.61, 0.36, 1]
    // A duration as the desktop wants it: instant when motion is reduced.
    function motion(ms) { return reducedMotion ? 0 : ms }

    // ---- Type ----
    // The scale from DESIGN.md; the same steps in both shells.
    readonly property int typeBigNumber: 26
    readonly property int typePageTitle: 26
    readonly property int typeSectionTitle: 15
    readonly property int typeCardTitle: 14
    readonly property int typeBody: 13
    readonly property int typeLabel: 12
    readonly property real typeCaption: 11.5
    readonly property real typeMicro: 10.5
    readonly property int typeWeightRegular: 400
    readonly property int typeWeightMedium: 500
    readonly property int typeWeightSemibold: 600
    readonly property real typeMicroTracking: 0.06

    // Medium is the size everything was drawn at; presets scale the lot.
    function scaleFor(preset) {
        return preset === "small" ? 0.86 : preset === "large" ? 1.18 : 1.0
    }

    // Most Linux panels run at 1x, where a half-pixel offset blurs every line
    // it touches. Snap sizes and positions to whole device pixels before
    // drawing, so the scaled presets stay sharp too.
    readonly property real dpr: Screen.devicePixelRatio || 1
    function px(value) { return Math.round(value * dpr) / dpr }

    // Ink for a surface of any colour: the notch can be painted, so what sits
    // on it flips to black once the surface is light enough.
    function isLight(surface) {
        return 0.299 * surface.r + 0.587 * surface.g + 0.114 * surface.b > 0.6
    }
    function ink(surface) { return isLight(surface) ? "#000000" : text }
    function inkSecondary(surface) { return isLight(surface) ? "#99000000" : textSecondary }
    function inkTrack(surface) { return isLight(surface) ? "#2E000000" : track }

    // The WCAG contrast between two colours, from 1 to 21. A colour may be
    // given as a hex string or as a colour.
    function contrast(a, b) {
        const lum = (c) => {
            const col = typeof c === "string" ? Qt.color(c) : c
            // A colour's parts run from 0 to 1.
            const f = (v) => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
            return 0.2126 * f(col.r) + 0.7152 * f(col.g) + 0.0722 * f(col.b)
        }
        const first = lum(a)
        const second = lum(b)
        return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05)
    }

    // The ink of a surface: black or white, whichever reads better on it.
    function readableInk(surface) {
        return contrast("#000000", surface) >= contrast("#FFFFFF", surface)
            ? "#000000" : "#FFFFFF"
    }

    // The colour of a mark on a surface of any colour: the unread colour
    // when it reads there, the ink otherwise. A blue dot on a blue nub is
    // invisible, and the nub's colour is the user's to choose.
    function markColor(surface) {
        return contrast(unread, surface) >= 3 ? unread : readableInk(surface)
    }

    // A colour with its alpha scaled: the gauge's dashes need one, and a
    // shape path has no opacity of its own.
    function withAlpha(color, alpha) {
        const c = typeof color === "string" ? Qt.lighter(color, 1.0) : color
        return Qt.rgba(c.r, c.g, c.b, c.a * alpha)
    }

    function usageColor(pct) {
        if (pct >= criticalAt) return critical
        if (pct >= watchAt) return watch
        return ample
    }

    function stateColor(kind) {
        return kind === "waiting_you" ? waiting : kind === "busy" ? busy : textTertiary
    }

    // A bot avatar's ink, by the colour name Grok Bot's roster uses. Chosen
    // to sit legibly on the black cards; black and gray stay distinguishable.
    function botColor(name) {
        switch (name) {
        case "orange": return "#E8914B"
        case "yellow": return "#DFC04C"
        case "green": return "#55C57D"
        case "cyan": return "#46C2D6"
        case "blue": return "#5C90E8"
        case "violet": return "#9C82EA"
        case "magenta": return "#D96CBB"
        case "red": return "#DE655C"
        case "brown": return "#B18257"
        case "black": return "#62666E"
        case "gray": return "#8A8F98"
        default: return textTertiary
        }
    }

    // 412 -> "412", 282472 -> "282K", 35144356 -> "35.1M"
    function tokens(n) {
        n = Number(n) || 0
        if (n < 1000) return Math.round(n).toString()
        const units = [[1e9, "B"], [1e6, "M"], [1e3, "K"]]
        for (let i = 0; i < units.length; ++i) {
            if (n >= units[i][0]) {
                const v = n / units[i][0]
                return (v >= 100 ? Math.round(v).toString() : v.toFixed(1).replace(/\.0$/, "")) + units[i][1]
            }
        }
        return n.toString()
    }

    // 13.2 -> "$13.20", 0.004 -> "<$0.01"
    function usd(v) {
        v = Number(v) || 0
        if (v > 0 && v < 0.01) return "<$0.01"
        if (v >= 1000) return "$" + Math.round(v).toLocaleString(Qt.locale("en_US"), "f", 0)
        return "$" + v.toFixed(2)
    }

    // A round number at or above n: 1, 1.5, 2, 2.5, 3, 4, 5, 6 or 8 times a
    // power of ten.
    function niceCeil(n) {
        if (n <= 0) return 1
        const mag = Math.pow(10, Math.floor(Math.log(n) / Math.LN10))
        const steps = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        for (let i = 0; i < steps.length; ++i) {
            if (steps[i] * mag >= n) return steps[i] * mag
        }
        return 10 * mag
    }

    function totalTokens(t) {
        if (!t) return 0
        return (t.input || 0) + (t.output || 0) + (t.cache_read || 0) + (t.cache_write || 0)
    }

    // "now", "4m", "3h", "2d", then a date.
    function ago(iso, now) {
        const d = new Date(iso)
        if (isNaN(d.getTime())) return ""
        const s = Math.max(0, (now - d.getTime()) / 1000)
        if (s < 60) return "now"
        if (s < 3600) return Math.floor(s / 60) + "m"
        if (s < 86400) return Math.floor(s / 3600) + "h"
        if (s < 7 * 86400) return Math.floor(s / 86400) + "d"
        return Qt.formatDate(d, "d MMM")
    }

    // A "yyyy-MM-dd" day against today's: "Today", "Yesterday", then "14 Oct".
    function day(iso, today) {
        if (iso === today) return "Today"
        const d = new Date(iso + "T12:00:00")
        const t = new Date(today + "T12:00:00")
        if (isNaN(d.getTime()) || isNaN(t.getTime())) return iso
        t.setDate(t.getDate() - 1)
        if (Qt.formatDate(t, "yyyy-MM-dd") === iso) return "Yesterday"
        return Qt.formatDate(d, "d MMM")
    }

    function resetsIn(iso, now) {
        if (!iso) return ""
        const d = new Date(iso)
        if (isNaN(d.getTime())) return ""
        const mins = Math.round((d.getTime() - now) / 60000)
        if (mins <= 0) return "Resets now"
        if (mins < 60) return "Resets in " + mins + " min"
        const hours = Math.floor(mins / 60)
        if (hours < 24) return "Resets in " + hours + "h " + (mins % 60) + "m"
        if (hours < 24 * 6) return "Resets " + Qt.formatDateTime(d, "ddd HH:mm")
        return "Resets " + Qt.formatDateTime(d, "d MMM")
    }
}
