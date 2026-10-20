import QtQuick
import QtQuick.Shapes
import OmegaNotch

// The notch's ring, dashboard-sized: track, coloured sweep, number inside.
Item {
    id: root

    property real pct: 0          // 0..100, or < 0 for no data
    property real stroke: 6

    readonly property bool hasData: pct >= 0
    property real shown: hasData ? Math.min(100, pct) : 0
    Behavior on shown { NumberAnimation { duration: Theme.motion(Theme.motionFill); easing.type: Easing.Bezier; easing.bezierCurve: Theme.motionCurve } }

    readonly property real r: (Math.min(width, height) - stroke) / 2

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: Theme.track
            strokeWidth: root.stroke
            PathAngleArc {
                centerX: root.width / 2; centerY: root.height / 2
                radiusX: root.r; radiusY: root.r
                startAngle: 0; sweepAngle: 360
            }
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: Theme.usageColor(root.pct)
            strokeWidth: root.stroke
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: root.width / 2; centerY: root.height / 2
                radiusX: root.r; radiusY: root.r
                startAngle: -90; sweepAngle: 360 * root.shown / 100
            }
        }
    }

    Row {
        anchors.centerIn: parent
        Text {
            text: root.hasData ? Math.round(root.pct) : "—"
            color: root.hasData ? Theme.text : Theme.textTertiary
            font.pixelSize: Math.round(root.width * 0.3)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        Text {
            visible: root.hasData
            anchors.baseline: parent.children[0].baseline
            text: "%"
            color: Theme.textSecondary
            font.pixelSize: Math.round(root.width * 0.16)
            font.weight: Font.DemiBold
        }
    }
}
