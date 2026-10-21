import QtQuick
import QtQuick.Shapes
import OmegaNotch

// One bot's avatar, as Grok Bot draws it: a shape in a colour with two eye
// slots, all named by the bot's roster row (`blob`, `cloud`… in `orange`,
// `blue`…). Shapes are our own 24x24 silhouettes; an unknown or missing
// shape becomes a disc.
Item {
    id: root

    property string shape: ""
    property string colorName: ""

    readonly property color color: Theme.botColor(colorName)
    readonly property real s: Math.min(width, height)
    readonly property real u: s / 24

    // Where the eyes sit on each silhouette, and how far apart, in the 24x24
    // design box. The wedge's face is narrow, so its eyes sit lower and
    // closer, clear of its slopes.
    readonly property var eyeLine: {
        switch (shape) {
        case "blob": return { x: 12.0, y: 10.3, spread: 3.3 }
        case "cloud": return { x: 12.0, y: 10.6, spread: 3.3 }
        case "tablet": return { x: 12.0, y: 9.2, spread: 3.3 }
        case "wedge": return { x: 12.0, y: 14.2, spread: 2.2 }
        case "squircle": return { x: 12.0, y: 10.1, spread: 3.3 }
        case "teardrop": return { x: 12.0, y: 11.2, spread: 3.3 }
        case "hex": return { x: 12.0, y: 10.3, spread: 3.3 }
        case "pebble": return { x: 12.1, y: 10.0, spread: 3.3 }
        case "crystal": return { x: 12.0, y: 9.9, spread: 3.3 }
        case "shield": return { x: 12.0, y: 9.7, spread: 3.3 }
        default: return { x: 12.0, y: 10.3, spread: 3.3 }
        }
    }

    readonly property string mark: {
        switch (shape) {
        case "blob":
            return "M12 2.1 C16.9 2.1 21.4 5.6 21.9 10.3 C22.4 14.6 19.4 19 15 20.9 C10.7 22.7 5.4 21.1 3.1 17.2 C0.8 13.3 2.2 8.2 5.6 5.1 C7.3 3.5 9.6 2.1 12 2.1 Z"
        case "cloud":
            return "M7.2 17.8 C4.3 17.8 2 15.6 2 13 C2 10.6 3.9 8.7 6.4 8.4 C7.1 5.6 9.4 3.7 12.3 3.7 C15.4 3.7 17.9 5.9 18.3 8.8 C20.6 9 22 10.9 22 13.2 C22 15.7 20 17.8 17.3 17.8 Z"
        case "tablet":
            return "M6.2 3 H17.8 C19.6 3 21 4.4 21 6.2 V17.8 C21 19.6 19.6 21 17.8 21 H6.2 C4.4 21 3 19.6 3 17.8 V6.2 C3 4.4 4.4 3 6.2 3 Z"
        case "wedge":
            return "M4.3 20.4 C3.4 20.4 2.9 19.4 3.5 18.7 L11 3.6 C11.4 2.8 12.6 2.8 13 3.6 L20.5 18.7 C21.1 19.4 20.6 20.4 19.7 20.4 Z"
        case "squircle":
            return "M12 2 C19.5 2 22 4.5 22 12 C22 19.5 19.5 22 12 22 C4.5 22 2 19.5 2 12 C2 4.5 4.5 2 12 2 Z"
        case "teardrop":
            return "M12 1.8 C13.8 3.9 20 10.6 20 15.2 C20 19.5 16.4 22.2 12 22.2 C7.6 22.2 4 19.5 4 15.2 C4 10.6 10.2 3.9 12 1.8 Z"
        case "hex":
            return "M12 2.3 L20.1 6.9 V17.1 L12 21.7 L3.9 17.1 V6.9 Z"
        case "pebble":
            return "M12.2 4.8 C17.4 4.8 21.3 7.9 21.3 12 C21.3 16.1 17.4 19.2 12.2 19.2 C7 19.2 2.7 16.1 2.7 12 C2.7 7.9 6.8 4.8 12.2 4.8 Z"
        case "crystal":
            return "M12 2 L20.4 8.8 L12 22 L3.6 8.8 Z"
        case "shield":
            return "M12 2.1 L20 5 V11.2 C20 16.3 16.7 20.4 12 22 C7.3 20.4 4 16.3 4 11.2 V5 Z"
        default:
            return "M12 3 C17 3 21 7 21 12 C21 17 17 21 12 21 C7 21 3 17 3 12 C3 7 7 3 12 3 Z"
        }
    }

    Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: root.s / 24
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.color
            strokeColor: "transparent"
            PathSvg { path: root.mark }
        }
    }

    // The eyes: thick slots leaning the same way, as Grok Bot draws them.
    Rectangle {
        width: 3.4 * root.u
        height: 6.6 * root.u
        radius: 1.7 * root.u
        color: Theme.botEye
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: (root.eyeLine.x - root.eyeLine.spread - 12) * root.u
        anchors.verticalCenterOffset: (root.eyeLine.y - 12) * root.u
        rotation: 18
    }
    Rectangle {
        width: 3.4 * root.u
        height: 6.6 * root.u
        radius: 1.7 * root.u
        color: Theme.botEye
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: (root.eyeLine.x + root.eyeLine.spread - 12) * root.u
        anchors.verticalCenterOffset: (root.eyeLine.y - 12) * root.u
        rotation: 18
    }
}
