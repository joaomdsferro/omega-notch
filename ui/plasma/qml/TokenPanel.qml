import QtQuick
import OmegaNotch

// Tokens the provider burned today, with the last seven days for scale.
Column {
    id: root

    property var stats
    property real scale_: 1.0

    readonly property real todayTotal: stats ? Theme.totalTokens(stats.today) : 0
    readonly property var days: stats && stats.daily ? stats.daily : []
    readonly property real peak: {
        let m = 1
        for (let i = 0; i < days.length; ++i)
            m = Math.max(m, days[i].total || 0)
        return m
    }

    spacing: 6 * scale_

    Item {
        width: parent.width
        height: heading.implicitHeight

        Text {
            id: heading
            text: "TOKENS TODAY"
            color: Theme.textSecondary
            font.pixelSize: 10.5 * root.scale_
            font.weight: Font.DemiBold
            font.letterSpacing: 0.6
        }
        Text {
            anchors.right: parent.right
            anchors.baseline: heading.baseline
            text: root.stats ? Theme.tokens(Theme.totalTokens(root.stats.week)) + " this week" : ""
            color: Theme.textSecondary
            font.pixelSize: 11 * root.scale_
            font.features: { "tnum": 1 }
        }
    }

    Item {
        width: parent.width
        height: 30 * root.scale_

        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Theme.tokens(root.todayTotal)
            color: Theme.text
            font.pixelSize: 24 * root.scale_
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }

        // Seven days, oldest first; today is the bright bar on the right.
        Row {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.height
            spacing: 4 * root.scale_

            Repeater {
                model: root.days
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: 8 * root.scale_
                    height: parent.height

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(2 * root.scale_, parent.height * (modelData.total || 0) / root.peak)
                        radius: 2 * root.scale_
                        color: index === root.days.length - 1 ? Theme.text : Theme.track
                    }
                }
            }
        }
    }

    Text {
        width: parent.width
        visible: root.stats !== null && root.stats !== undefined
        text: root.stats
            ? "in " + Theme.tokens(root.stats.today.input)
              + "  ·  out " + Theme.tokens(root.stats.today.output)
              + "  ·  cache " + Theme.tokens((root.stats.today.cache_read || 0) + (root.stats.today.cache_write || 0))
            : ""
        color: Theme.textSecondary
        font.pixelSize: 11 * root.scale_
        font.features: { "tnum": 1 }
        elide: Text.ElideRight
    }

    Text {
        width: parent.width
        visible: text.length > 0
        text: {
            const models = root.stats && root.stats.models_today ? root.stats.models_today : []
            const parts = []
            for (let i = 0; i < Math.min(3, models.length); ++i)
                parts.push(models[i].model + " " + Theme.tokens(models[i].total))
            return parts.join("  ·  ")
        }
        color: Theme.textTertiary
        font.pixelSize: 11 * root.scale_
        font.features: { "tnum": 1 }
        elide: Text.ElideRight
    }
}
