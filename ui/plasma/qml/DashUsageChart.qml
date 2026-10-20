import QtQuick
import OmegaNotch

// A daily value as stacked columns, one segment per series, on a
// round axis. Every day of the range gets a slot, so gaps read as quiet days.
// Hover a column for its breakdown.
Item {
    id: root

    property var days: []              // [{ date, total, <series key>: tokens… }]
    property var series: []            // [{ key, label, color }], bottom of the stack first
    property string today: ""
    property string format: "tokens"   // "tokens" | "usd"
    property string emptyText: "No history yet — it fills in as you work."

    // The axis rounds to whole dollars; the tooltip keeps the cents.
    function fmt(v, axis) {
        if (format !== "usd") return Theme.tokens(v)
        if (axis && (v === 0 || v >= 10)) return "$" + Math.round(v)
        return Theme.usd(v)
    }

    // Top of the stack first, for drawing and for the tooltip.
    readonly property var topDown: {
        const out = []
        for (let i = series.length - 1; i >= 0; --i) out.push(i)
        return out
    }

    readonly property real peak: {
        let m = 0
        for (let i = 0; i < days.length; ++i)
            m = Math.max(m, days[i].total || 0)
        return m
    }
    // Four gridline steps, each a round number.
    readonly property real axisMax: 4 * Theme.niceCeil(peak / 4)
    readonly property bool empty: peak <= 0

    readonly property real axisWidth: 44
    readonly property real xAxisHeight: 24
    readonly property real plotWidth: width - axisWidth
    readonly property real plotHeight: height - xAxisHeight
    readonly property real slot: days.length > 0 ? plotWidth / days.length : plotWidth
    readonly property real gap: slot > 14 ? 4 : slot > 6 ? 2 : 1

    property int hovered: -1

    function dayLabel(iso, long) {
        const d = new Date(iso + "T12:00:00")
        if (isNaN(d.getTime())) return iso
        return Qt.formatDate(d, long ? "ddd, d MMM" : "d MMM")
    }

    // Gridlines with their values, bottom to top.
    Repeater {
        model: 5
        delegate: Item {
            required property int index
            readonly property real frac: index / 4
            width: root.width
            y: root.plotHeight * (1 - frac)

            Text {
                width: root.axisWidth - 10
                y: -implicitHeight / 2
                horizontalAlignment: Text.AlignRight
                visible: !root.empty || index === 0
                text: root.fmt(root.axisMax * frac, true)
                color: Theme.textTertiary
                font.pixelSize: 11
                font.features: { "tnum": 1 }
            }
            Rectangle {
                x: root.axisWidth
                width: root.plotWidth
                height: 1
                color: index === 0 ? Theme.cardStroke : Theme.hairline
                opacity: index === 0 ? 1 : 0.6
            }
        }
    }

    // Columns.
    Item {
        id: plot
        x: root.axisWidth
        width: root.plotWidth
        height: root.plotHeight

        Repeater {
            model: root.days
            delegate: Item {
                id: col
                required property var modelData
                required property int index
                readonly property bool isToday: modelData.date === root.today
                readonly property bool dimmed: root.hovered >= 0 && root.hovered !== index

                x: index * root.slot
                width: root.slot
                height: plot.height

                Rectangle {
                    anchors.fill: parent
                    color: Theme.controlHover
                    radius: 4
                    visible: root.hovered === index
                }

                Column {
                    anchors.bottom: parent.bottom
                    x: root.gap / 2
                    width: parent.width - root.gap
                    opacity: col.dimmed ? 0.45 : 1
                    Behavior on opacity { NumberAnimation { duration: Theme.motion(Theme.motionHover) } }

                    Repeater {
                        model: root.topDown
                        delegate: Rectangle {
                            required property int modelData
                            readonly property var kind: root.series[modelData]
                            readonly property real v: col.modelData[kind.key] || 0
                            width: parent.width
                            height: root.axisMax > 0 ? Math.round(plot.height * v / root.axisMax) : 0
                            visible: height > 0
                            color: kind.color
                            Behavior on height { NumberAnimation { duration: Theme.motion(Theme.motionFill); easing.type: Easing.Bezier; easing.bezierCurve: Theme.motionCurve } }
                        }
                    }
                }
            }
        }

        HoverHandler {
            id: plotHover
            enabled: !root.empty
            onPointChanged: {
                const i = Math.floor(point.position.x / root.slot)
                root.hovered = hovered && i >= 0 && i < root.days.length ? i : -1
            }
            onHoveredChanged: if (!hovered) root.hovered = -1
        }
    }

    // X axis: first, middle and last day, or every day when there is room.
    Repeater {
        model: {
            const n = root.days.length
            if (n === 0) return []
            if (n <= 8) return Array.from({ length: n }, (_, i) => i)
            const step = Math.ceil(n / 6)
            const out = []
            for (let i = n - 1; i >= 0; i -= step) out.unshift(i)
            return out
        }
        delegate: Text {
            required property int modelData
            readonly property var day: root.days[modelData]
            x: Math.max(0, Math.min(root.width - implicitWidth,
                         root.axisWidth + (modelData + 0.5) * root.slot - implicitWidth / 2))
            y: root.plotHeight + 8
            text: day.date === root.today ? "Today" : root.dayLabel(day.date, false)
            color: day.date === root.today ? Theme.text : Theme.textTertiary
            font.pixelSize: 11
            font.features: { "tnum": 1 }
        }
    }

    Text {
        anchors.centerIn: plot
        visible: root.empty
        text: root.emptyText
        color: Theme.textTertiary
        font.pixelSize: 13
    }

    // Tooltip for the hovered day.
    Rectangle {
        id: tip
        readonly property var day: root.hovered >= 0 ? root.days[root.hovered] : null
        visible: day !== null
        width: 260
        height: tipCol.implicitHeight + 24
        radius: 10
        color: "#E61C1C21"
        border.width: 1
        border.color: Theme.cardStroke
        z: 10
        readonly property real anchorX: root.axisWidth + (root.hovered + 0.5) * root.slot
        x: anchorX + 14 + width > root.width ? anchorX - 14 - width : anchorX + 14
        y: 4

        Column {
            id: tipCol
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 6

            Item {
                width: parent.width
                height: tipDate.implicitHeight
                Text {
                    id: tipDate
                    text: tip.day ? root.dayLabel(tip.day.date, true) : ""
                    color: Theme.textSecondary
                    font.pixelSize: 11
                }
                Text {
                    anchors.right: parent.right
                    text: tip.day ? root.fmt(tip.day.total) : ""
                    color: Theme.text
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
            Repeater {
                model: root.series.map((_, i) => i)
                delegate: Item {
                    required property int modelData
                    readonly property var kind: root.series[modelData]
                    width: tipCol.width
                    height: 16
                    Rectangle {
                        width: 8
                        height: 8
                        radius: 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: kind.color
                    }
                    Text {
                        id: tipLabel
                        x: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 16 - tipValue.width - 8
                        text: kind.label
                        color: Theme.textSecondary
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    Text {
                        id: tipValue
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: tip.day ? root.fmt(tip.day[kind.key] || 0) : ""
                        color: Theme.text
                        font.pixelSize: 11
                        font.features: { "tnum": 1 }
                    }
                }
            }
        }
    }
}
