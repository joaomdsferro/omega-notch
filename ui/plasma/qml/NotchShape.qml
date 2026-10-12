import QtQuick
import QtQuick.Shapes
import OmegaNotch

// The black body, fused to the screen edge: rounded on the inside, and flaring
// into the bezel with a concave curl at each end so it reads as part of the
// screen rather than a bar parked on it.
//
// The outline is written once in edge-local coordinates (u along the edge,
// v away from it) and mapped onto whichever edge the notch lives on.
Item {
    id: root

    property string edge: "right"
    property real length: 200      // along the edge, curls excluded
    property real depth: 72        // away from the edge
    property real curl: 36
    property real radius: 30
    property color color: Theme.notch
    // A ripple along the outer side, in px, travelling as `wavePhase` turns;
    // it fades out towards the corners so they stay round.
    property real wave: 0
    property real wavePhase: 0

    readonly property bool vertical: edge === "left" || edge === "right"

    width: vertical ? depth : length + 2 * curl
    height: vertical ? length + 2 * curl : depth

    function point(u, v) {
        switch (edge) {
        case "left": return v + " " + (u + curl)
        case "top": return (u + curl) + " " + v
        case "bottom": return (u + curl) + " " + (depth - v)
        default: return (depth - v) + " " + (u + curl)
        }
    }

    // The outer side, straight or rippling.
    function side(from, to, D) {
        if (wave <= 0 || to - from < 4)
            return " L " + point(to, D)
        const n = 32, span = to - from, crests = 1.25
        let out = ""
        for (let i = 1; i <= n; ++i) {
            const t = i / n
            const v = D + wave * Math.sin(Math.PI * t)
                          * Math.sin(2 * Math.PI * crests * t - wavePhase)
            out += " L " + point(from + span * t, v)
        }
        return out
    }

    readonly property string outline: {
        const k = 0.5523, L = length, D = depth
        const C = Math.min(curl, D / 2), R = Math.min(radius, D - C, L / 2)
        const p = point
        return "M " + p(-C, 0)
            + " C " + p(-C + k * C, 0) + " " + p(0, C - k * C) + " " + p(0, C)
            + " L " + p(0, D - R)
            + " C " + p(0, D - R + k * R) + " " + p(R - k * R, D) + " " + p(R, D)
            + side(R, L - R, D)
            + " C " + p(L - R + k * R, D) + " " + p(L, D - R + k * R) + " " + p(L, D - R)
            + " L " + p(L, C)
            + " C " + p(L, C - k * C) + " " + p(L + C - k * C, 0) + " " + p(L + C, 0)
            + " Z"
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.color
            strokeColor: "transparent"
            strokeWidth: 0
            PathSvg { path: root.outline }
        }
    }
}
