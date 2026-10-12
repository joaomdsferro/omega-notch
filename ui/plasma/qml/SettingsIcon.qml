import QtQuick
import QtQuick.Shapes
import OmegaNotch

// Line icons for Settings, drawn on a 24x24 grid with round caps so they stay
// crisp at any size and take the colour of wherever they sit. "ring-s|m|l" is
// generated: a ring of that size.
Item {
    id: root

    property string name: ""
    property color color: Theme.text
    // In grid units, so it scales with the icon: 2 is about 1.5px at 18px.
    property real strokeWidth: 2

    implicitWidth: 18
    implicitHeight: 18

    readonly property real s: Math.min(width, height)

    function circle(cx, cy, r) {
        return "M" + (cx - r) + " " + cy + "a" + r + " " + r + " 0 1 0 " + (2 * r) + " 0"
             + "a" + r + " " + r + " 0 1 0 " + (-2 * r) + " 0"
    }

    // [path, filled]
    readonly property var glyph: {
        if (name.startsWith("ring-")) {
            const r = { s: 4.5, m: 6.75, l: 9 }[name.slice(5)] || 6.75
            return [circle(12, 12, r), false]
        }
        switch (name) {
        case "monitor":
            return ["M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM8 21h8M12 17v4", false]
        case "laptop":
            return ["M5 4h14a1 1 0 0 1 1 1v11H4V5a1 1 0 0 1 1-1zM2 20h20", false]
        case "star":
            return ["M12 2.5l2.9 5.9 6.5.95-4.7 4.6 1.1 6.45L12 17.35 6.2 20.4l1.1-6.45-4.7-4.6 6.5-.95z", false]
        case "notch":
            return ["M5 3h10a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM21 8.5v7", false]
        case "grid":
            return ["M4 3h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"
                    + "M15 3h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1h-5a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z"
                    + "M15 14h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1h-5a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1z"
                    + "M4 14h5a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1z", false]
        case "bell":
            return ["M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9M10.3 21a1.94 1.94 0 0 0 3.4 0", false]
        case "volume":
            return ["M11 5 6 9H2v6h4l5 4zM15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14", false]
        case "check-circle":
            return ["M22 11.1V12a10 10 0 1 1-5.9-9.1M22 4 12 14l-3-3", false]
        case "message":
            return ["M7.9 20A9 9 0 1 0 4 16.1L2 22zM9.6 9.5a2.5 2.5 0 0 1 4.8.8c0 1.7-2.4 2.2-2.4 2.2M12 15.5h.01", false]
        case "eye-off":
            return ["M10.7 5.1A10.4 10.4 0 0 1 12 5c7 0 10 7 10 7a13 13 0 0 1-1.7 2.7"
                    + "M6.6 6.6A13.5 13.5 0 0 0 2 12s3 7 10 7a9.7 9.7 0 0 0 5.4-1.6"
                    + "M9.9 9.9a3 3 0 1 0 4.2 4.2M2 2l20 20", false]
        case "maximize":
            return ["M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7", false]
        case "layers":
            return ["M12 2 2 7l10 5 10-5zM2 17l10 5 10-5M2 12l10 5 10-5", false]
        case "droplet":
            return ["M12 22a7 7 0 0 0 7-7c0-2-1-3.9-3-5.5S12.5 5.5 12 3c-.5 2.5-2 4.9-4 6.5S5 13 5 15a7 7 0 0 0 7 7z", false]
        case "moon":
            return ["M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z", false]
        case "move":
            return ["M5 9l-3 3 3 3M9 5l3-3 3 3M15 19l-3 3-3-3M19 9l3 3-3 3M2 12h20M12 2v20", false]
        case "target":
            return [circle(12, 12, 9) + circle(12, 12, 3), false]
        case "reset":
            return ["M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8M3 3v5h5", false]
        case "refresh":
            return ["M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8M21 3v5h-5"
                    + "M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16M8 16H3v5", false]
        case "power":
            return ["M12 2v10M18.4 6.6a9 9 0 1 1-12.8 0", false]
        case "play":
            return ["M7 4.5v15a1 1 0 0 0 1.5.86l12-7.5a1 1 0 0 0 0-1.72l-12-7.5A1 1 0 0 0 7 4.5z", true]
        case "info":
            return [circle(12, 12, 10) + "M12 16v-4M12 8h.01", false]
        case "chevron-down":
            return ["M6 9l6 6 6-6", false]
        case "activity":
            return ["M22 12h-4l-3 9L9 3l-3 9H2", false]
        case "check":
            return ["M20 6 9 17l-5-5", false]
        case "plug-off":
            return ["M12 22v-5M9 8V2M15 8V2M18 8v5a4 4 0 0 1-.6 2.1M6 8h2M6 8v5a6 6 0 0 0 9.5 4.9M2 2l20 20", false]
        default:
            return ["", false]
        }
    }

    Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: root.s / 24
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.glyph[1] ? root.color : "transparent"
            strokeColor: root.glyph[1] ? "transparent" : root.color
            strokeWidth: root.strokeWidth
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.glyph[0] }
        }
    }
}
