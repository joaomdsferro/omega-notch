import QtQuick
import QtQuick.Shapes
import OmegaNotch

// One provider in the notch: a gauge of twenty segments that fills with the
// headline limit, the provider's mark inside it, and the number underneath.
// The last two segments are the danger zone, painted in the critical colour
// from the start, so the risk shows before the number does. A white arc turns
// inside the gauge while a session works; it becomes a pulsing amber ring
// when one is waiting on you.
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

    readonly property real ringSize: Theme.px(44 * scale_)
    readonly property real labelGap: Theme.px(7 * scale_)
    readonly property string status: reading ? (reading.status || "ok") : "offline"
    readonly property bool hasData: reading && reading.windows && reading.windows.length > 0
                                    && (status === "ok" || status === "stale")
    readonly property real pct: hasData ? (Number(reading.windows[0].used_pct) || 0) : 0
    readonly property color accent: Theme.usageColor(pct)
    readonly property bool hovered: hover.hovered
    // Centre of the ring in this item's coordinates, for aiming the card.
    readonly property point ringCentre: Qt.point(width / 2, ringSize / 2)

    // The gauge: twenty segments, the last two the danger zone.
    readonly property int segments: 20
    readonly property real gaugeWidth: Theme.px(4.6 * scale_)
    readonly property real segmentAngle: 360 / segments
    readonly property real segmentGap: 3.4
    // Where the filled part ends, for the cap that rides on it.
    readonly property real headAngle: (-90 + 360 * Math.max(0, Math.min(1, shown / 100))) * Math.PI / 180

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
        x: Theme.px((root.width - width) / 2)
        scale: hover.hovered ? 1.06 : 1.0
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        readonly property real radius: (width - root.gaugeWidth) / 2

        // The gauge is real geometry: twenty dashes, each an arc of its own,
        // so every colour can have its own path and the dashes always line
        // up. (A dash pattern on a shape path is not drawn by Qt.)
        function arcPath(from, to) {
            const cx = width / 2, cy = height / 2
            const a0 = from * Math.PI / 180
            const a1 = to * Math.PI / 180
            const x0 = cx + Math.cos(a0) * radius
            const y0 = cy + Math.sin(a0) * radius
            const x1 = cx + Math.cos(a1) * radius
            const y1 = cy + Math.sin(a1) * radius
            return "M " + x0.toFixed(2) + " " + y0.toFixed(2)
                 + " A " + radius.toFixed(2) + " " + radius.toFixed(2)
                 + " 0 0 1 " + x1.toFixed(2) + " " + y1.toFixed(2)
        }

        // The dashes between two angles.
        function dashPath(from, to) {
            const steps = []
            const count = Math.round((to - from) / root.segmentAngle)
            for (let i = 0; i < count; ++i) {
                steps.push(arcPath(from + i * root.segmentAngle + root.segmentGap / 2,
                                   from + (i + 1) * root.segmentAngle - root.segmentGap / 2))
            }
            return steps.join(" ")
        }

        // The dashes that are used, the last one cut short at the head, so a
        // small percentage still reads as small.
        function usedPath(percent) {
            const used = Math.max(0, Math.min(1, percent / 100)) * 360
            const steps = []
            for (let i = 0; i < root.segments; ++i) {
                const start = i * root.segmentAngle + root.segmentGap / 2
                let end = (i + 1) * root.segmentAngle - root.segmentGap / 2
                if (start >= used)
                    break
                if (end > used)
                    end = used
                steps.push(arcPath(start - 90, end - 90))
            }
            return steps.join(" ")
        }

        Shape {
            id: gauge
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            // The track: twenty dashes all the way round.
            ShapePath {
                fillColor: "transparent"
                strokeColor: Theme.withAlpha(Theme.inkTrack(root.surface), 0.75)
                strokeWidth: root.gaugeWidth
                capStyle: ShapePath.FlatCap
                PathSvg { path: ring.dashPath(-90, 270) }
            }
            // The danger zone: the last two dashes, in the critical colour, so
            // the risk shows before the number does.
            ShapePath {
                fillColor: "transparent"
                strokeColor: Theme.withAlpha(Theme.critical, 0.5)
                strokeWidth: root.gaugeWidth
                capStyle: ShapePath.FlatCap
                PathSvg { path: ring.dashPath(234, 270) }
            }
            // The part in use.
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.shown > 0 ? root.accent : "transparent"
                strokeWidth: root.gaugeWidth
                capStyle: ShapePath.FlatCap
                PathSvg { path: ring.usedPath(root.shown) }
            }
        }

        // The cap that rides on the head of the used part: a speck of light
        // on the glass.
        Rectangle {
            visible: root.shown > 0
            width: Theme.px(4.2 * root.scale_)
            height: width
            radius: width / 2
            color: "#FFFFFF"
            opacity: 0.92
            x: Theme.px(ring.width / 2 + Math.cos(root.headAngle) * ring.radius - width / 2)
            y: Theme.px(ring.height / 2 + Math.sin(root.headAngle) * ring.radius - width / 2)
        }

        // Working: a short white arc orbiting between the mark and the ring.
        Item {
            id: spinner
            anchors.centerIn: parent
            width: Theme.px(27 * root.scale_)
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
                    strokeWidth: Theme.px(2 * root.scale_)
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
            width: Theme.px(27 * root.scale_)
            height: width
            radius: width / 2
            color: "transparent"
            border.color: Theme.waiting
            border.width: Theme.px(2 * root.scale_)
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
            width: Theme.px(17 * root.scale_)
            height: width
            provider: root.reading ? root.reading.provider : ""
            color: root.hasData ? Theme.ink(root.surface) : Theme.inkSecondary(root.surface)
            surface: root.surface
        }

        Rectangle {
            id: badge
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: Theme.px(-3 * root.scale_)
            anchors.topMargin: Theme.px(-2 * root.scale_)
            height: Theme.px(15 * root.scale_)
            width: Theme.px(Math.max(height, badgeText.implicitWidth + 8 * root.scale_))
            radius: height / 2
            color: Theme.unread
            border.color: root.surface
            border.width: Theme.px(1.5 * root.scale_)
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
