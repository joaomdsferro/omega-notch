pragma Singleton
import QtQuick

// One place for every colour, size and piece of copy formatting, so the notch,
// its card and Settings stay in the same visual language.
QtObject {
    // Surfaces
    readonly property color notch: "#000000"
    readonly property color card: "#000000"
    readonly property color cardStroke: "#1FFFFFFF"
    readonly property color hairline: "#1AFFFFFF"
    readonly property color track: "#2EFFFFFF"
    readonly property color panel: "#0B0B0D"
    readonly property color panelRaised: "#16161A"
    readonly property color panelHover: "#1F1F25"

    // Ink
    readonly property color text: "#FFFFFF"
    readonly property color textSecondary: "#9A9AA2"
    readonly property color textTertiary: "#5F5F68"

    // Meaning
    readonly property color ample: "#3DDC97"
    readonly property color watch: "#F5C542"
    readonly property color critical: "#FF5A36"
    readonly property color waiting: "#FFB020"
    readonly property color busy: "#FFFFFF"

    // Dashboard series, brightest first: the biggest share gets the most ink.
    readonly property var shades: ["#F2F2F5", "#B4B4BE", "#808089", "#5C5C66", "#44444D", "#33333B"]
    readonly property color controlFill: "#14FFFFFF"
    readonly property color controlChosen: "#2EFFFFFF"
    readonly property color controlHover: "#12FFFFFF"

    readonly property int watchAt: 75
    readonly property int criticalAt: 90

    // Medium is the size everything was drawn at; presets scale the lot.
    function scaleFor(preset) {
        return preset === "small" ? 0.86 : preset === "large" ? 1.18 : 1.0
    }

    // Ink for a surface of any colour: the notch can be painted, so what sits
    // on it flips to black once the surface is light enough.
    function isLight(surface) {
        return 0.299 * surface.r + 0.587 * surface.g + 0.114 * surface.b > 0.6
    }
    function ink(surface) { return isLight(surface) ? "#000000" : text }
    function inkSecondary(surface) { return isLight(surface) ? "#99000000" : textSecondary }
    function inkTrack(surface) { return isLight(surface) ? "#2E000000" : track }

    function usageColor(pct) {
        if (pct >= criticalAt) return critical
        if (pct >= watchAt) return watch
        return ample
    }

    function stateColor(kind) {
        return kind === "waiting_you" ? waiting : kind === "busy" ? busy : textTertiary
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
