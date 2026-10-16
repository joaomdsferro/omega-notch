import QtQuick
import OmegaNotch

// Today at a glance: estimated spend, a share bar across models, each model
// with its tokens, cost and share, then today's tokens split by kind.
Column {
    id: root

    property var costs: []             // [{ provider, model, total, cost_usd }]
    property real total: 0
    property var today: ({})           // TokenTotals: input, output, cache_read, cache_write

    readonly property var mix: [
        { label: "Cache read", value: today.cache_read || 0 },
        { label: "Cache write", value: today.cache_write || 0 },
        { label: "Input", value: today.input || 0 },
        { label: "Output", value: today.output || 0 }
    ]
    readonly property real mixTotal: Theme.totalTokens(today)

    readonly property var rows: {
        const out = costs.slice().sort((a, b) => (b.cost_usd || 0) - (a.cost_usd || 0))
        return out.slice(0, 6)
    }
    property var shades: Theme.shades

    spacing: 16

    Row {
        spacing: 8
        Text {
            id: totalText
            text: Theme.usd(root.total)
            color: Theme.text
            font.pixelSize: 32
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        Text {
            anchors.baseline: totalText.baseline
            text: "today"
            color: Theme.textSecondary
            font.pixelSize: 13
        }
    }

    // Share of today's spend per model.
    Rectangle {
        width: parent.width
        height: 8
        radius: 4
        color: Theme.track
        clip: true
        visible: root.rows.length > 1

        Row {
            anchors.fill: parent
            spacing: 2
            Repeater {
                model: root.rows
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: Math.max(2, (parent.width - (root.rows.length - 1) * 2)
                                       * (modelData.cost_usd || 0) / root.total)
                    height: parent.height
                    color: root.shades[index % root.shades.length]
                }
            }
        }
    }

    Column {
        width: parent.width
        spacing: 0

        Repeater {
            model: root.rows
            delegate: Item {
                required property var modelData
                required property int index
                readonly property real share: root.total > 0 ? (modelData.cost_usd || 0) / root.total : 0
                width: parent.width
                height: 44

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.hairline
                    visible: index > 0
                }
                Rectangle {
                    id: swatch
                    width: 8
                    height: 8
                    radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.shades[index % root.shades.length]
                }
                ProviderGlyph {
                    id: glyph
                    anchors.left: swatch.right
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    height: 14
                    provider: modelData.provider || ""
                    color: Theme.textSecondary
                }
                Column {
                    anchors.left: glyph.right
                    anchors.leftMargin: 10
                    anchors.right: costCol.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        width: parent.width
                        text: modelData.model || "Unknown model"
                        color: Theme.text
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        text: Theme.tokens(modelData.total) + " tokens"
                        color: Theme.textTertiary
                        font.pixelSize: 11
                        font.features: { "tnum": 1 }
                    }
                }
                Column {
                    id: costCol
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        anchors.right: parent.right
                        text: Theme.usd(modelData.cost_usd)
                        color: Theme.text
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                    }
                    Text {
                        anchors.right: parent.right
                        text: Math.round(share * 100) + "%"
                        color: Theme.textTertiary
                        font.pixelSize: 11
                        font.features: { "tnum": 1 }
                    }
                }
            }
        }
    }

    Text {
        visible: root.rows.length === 0
        width: parent.width
        text: "Nothing spent yet today."
        color: Theme.textTertiary
        font.pixelSize: 13
    }

    // Today's tokens by kind, each as a share of the day.
    Column {
        width: parent.width
        spacing: 12
        visible: root.mixTotal > 0

        Rectangle { width: parent.width; height: 1; color: Theme.hairline }
        Item {
            width: parent.width
            height: mixTitle.implicitHeight
            Text {
                id: mixTitle
                text: "Tokens today"
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
            Text {
                anchors.right: parent.right
                anchors.baseline: mixTitle.baseline
                text: Theme.tokens(root.mixTotal)
                color: Theme.textSecondary
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }
        Repeater {
            model: root.mix
            delegate: Column {
                required property var modelData
                readonly property real share: root.mixTotal > 0 ? modelData.value / root.mixTotal : 0
                width: parent.width
                spacing: 6
                Item {
                    width: parent.width
                    height: kindLabel.implicitHeight
                    Text {
                        id: kindLabel
                        text: modelData.label
                        color: Theme.textSecondary
                        font.pixelSize: 12
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.baseline: kindLabel.baseline
                        text: Theme.tokens(modelData.value) + "  ·  " + (share > 0 && share < 0.01 ? "<1" : Math.round(share * 100)) + "%"
                        color: Theme.text
                        font.pixelSize: 12
                        font.features: { "tnum": 1 }
                    }
                }
                Rectangle {
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Theme.track
                    Rectangle {
                        width: Math.max(share > 0 ? 2 : 0, parent.width * share)
                        height: parent.height
                        radius: 2
                        color: Theme.text
                        Behavior on width { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
    }

    Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: "Estimated from list prices per model, cache-aware. Not a bill: plans and vendors price differently."
        color: Theme.textTertiary
        font.pixelSize: 11
        lineHeight: 1.2
    }
}
