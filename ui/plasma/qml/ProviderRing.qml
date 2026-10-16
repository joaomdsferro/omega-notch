import QtQuick
import QtQuick.Shapes
import OmegaNotch

// One provider in the notch: a ring that fills with the headline limit, the
// provider's mark inside it, and the number underneath. A white arc turns
// inside the ring while a session works; it becomes a pulsing amber ring when
// one is waiting on you.
Item {
    id: root

    property var reading
    property string sessionKind: "idle"
    // Finished chats to read, counted on a green badge.
    property int unread: 0
    property real scale_: 1.0
    property color surface: Theme.notch    // what the ring is drawn on

    signal clicked()
    signal hoveredChanged_(bool hovered)

    readonly property real ringSize: 44 * scale_
    readonly property real labelGap: 7 * scale_
    readonly property string status: reading ? (reading.status || "ok") : "offline"
    readonly property bool hasData: reading && reading.windows && reading.windows.length > 0
                                    && (status === "ok" || status === "stale")
    readonly property real pct: hasData ? (Number(reading.windows[0].used_pct) || 0) : 0
    readonly property color accent: Theme.usageColor(pct)
    readonly property bool hovered: hover.hovered
    // Centre of the ring in this item's coordinates, for aiming the card.
    readonly property point ringCentre: Qt.point(width / 2, ringSize / 2)

    // Eased copy of pct, so a refresh sweeps rather than jumps.
    property real shown: pct
    Behavior on shown { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

    property bool refreshing: false

    implicitWidth: Math.max(ringSize, label.implicitWidth)
    implicitHeight: ringSize + labelGap + label.implicitHeight

    Item {
        id: ring
        width: root.ringSize
        height: root.ringSize
        anchors.horizontalCenter: parent.horizontalCenter
        scale: hover.hovered ? 1.06 : 1.0
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        readonly property real trackWidth: 5.2 * root.scale_
        readonly property real radius: (width - trackWidth) / 2

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "transparent"
                strokeColor: Theme.inkTrack(root.surface)
                strokeWidth: ring.trackWidth
                PathAngleArc {
                    centerX: ring.width / 2; centerY: ring.height / 2
                    radiusX: ring.radius; radiusY: ring.radius
                    startAngle: 0; sweepAngle: 360
                }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.shown > 0.4 ? root.accent : "transparent"
                strokeWidth: 3.4 * root.scale_
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: ring.width / 2; centerY: ring.height / 2
                    radiusX: ring.radius; radiusY: ring.radius
                    startAngle: -90
                    sweepAngle: 360 * Math.max(0, Math.min(1, root.shown / 100))
                }
            }
        }

        // Working: a short white arc orbiting between the mark and the ring.
        Item {
            id: spinner
            anchors.centerIn: parent
            width: 27 * root.scale_
            height: width
            visible: opacity > 0
            opacity: (root.sessionKind === "busy" || root.refreshing) ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: Theme.ink(root.surface)
                    strokeWidth: 2 * root.scale_
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: spinner.width / 2; centerY: spinner.height / 2
                        radiusX: spinner.width / 2 - root.scale_; radiusY: spinner.width / 2 - root.scale_
                        startAngle: 0; sweepAngle: 95
                    }
                }
            }
            RotationAnimator on rotation {
                running: spinner.visible
                from: 0; to: 360
                duration: 1100
                loops: Animation.Infinite
            }
        }

        // Waiting on you: the same orbit, closed and breathing amber.
        Rectangle {
            id: waitingRing
            anchors.centerIn: parent
            width: 27 * root.scale_
            height: width
            radius: width / 2
            color: "transparent"
            border.color: Theme.waiting
            border.width: 2 * root.scale_
            visible: root.sessionKind === "waiting_you" && !root.refreshing
            SequentialAnimation on opacity {
                running: waitingRing.visible
                loops: Animation.Infinite
                NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            }
        }

        ProviderGlyph {
            anchors.centerIn: parent
            width: 17 * root.scale_
            height: width
            provider: root.reading ? root.reading.provider : ""
            color: root.hasData ? Theme.ink(root.surface) : Theme.inkSecondary(root.surface)
        }

        Rectangle {
            id: badge
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: -3 * root.scale_
            anchors.topMargin: -2 * root.scale_
            height: 15 * root.scale_
            width: Math.max(height, badgeText.implicitWidth + 8 * root.scale_)
            radius: height / 2
            color: Theme.unread
            border.color: root.surface
            border.width: 1.5 * root.scale_
            opacity: root.unread > 0 ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
            Accessible.name: root.unread + (root.unread === 1 ? " finished chat" : " finished chats") + " to read"
            Text {
                id: badgeText
                anchors.centerIn: parent
                text: root.unread
                color: "black"
                font.pixelSize: 9.5 * root.scale_
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
            }
        }
    }

    Text {
        id: label
        anchors.top: ring.bottom
        anchors.topMargin: root.labelGap
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.hasData ? Math.round(root.shown) + "%"
            : root.status === "error" ? "!"
            : "—"
        color: root.status === "error" ? Theme.critical
             : root.hasData ? Theme.ink(root.surface) : Theme.inkSecondary(root.surface)
        font.pixelSize: 13 * root.scale_
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
    }

    Timer {
        id: refreshTimer
        interval: 1200
        onTriggered: root.refreshing = false
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
        onHoveredChanged: root.hoveredChanged_(hovered)
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: {
            root.refreshing = true
            refreshTimer.restart()
            root.clicked()
        }
    }
}
