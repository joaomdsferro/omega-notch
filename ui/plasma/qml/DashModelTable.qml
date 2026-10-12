import QtQuick
import OmegaNotch

// Every model used in the range: a daily-token sparkline, tokens, estimated
// cost and its share of the spend.
Column {
    id: root

    // [{ model, provider, total, cost, activeDays, daily: [tokens per day] }], dearest first
    property var models: []
    property real totalCost: 0

    readonly property real sparkWidth: 112
    readonly property real tokensWidth: 76
    readonly property real costWidth: 84
    readonly property real shareWidth: 96

    component HeaderCell: Text {
        color: Theme.textTertiary
        font.pixelSize: 11
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignRight
    }

    Item {
        width: parent.width
        height: 20
        visible: root.models.length > 0
        HeaderCell { text: "Model"; horizontalAlignment: Text.AlignLeft }
        Row {
            anchors.right: parent.right
            HeaderCell { width: root.sparkWidth; text: "Daily tokens"; horizontalAlignment: Text.AlignHCenter }
            HeaderCell { width: root.tokensWidth; text: "Tokens" }
            HeaderCell { width: root.costWidth; text: "Est. cost" }
            HeaderCell { width: root.shareWidth; text: "Share" }
        }
    }

    Repeater {
        model: root.models
        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property real share: root.totalCost > 0 ? modelData.cost / root.totalCost : 0
            readonly property real peak: Math.max(1, Math.max.apply(null, modelData.daily))
            width: root.width
            height: 52

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.hairline
                visible: row.index > 0
            }

            Rectangle {
                id: swatch
                width: 8
                height: 8
                radius: 2
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.shades[row.index % Theme.shades.length]
            }
            ProviderGlyph {
                id: glyph
                anchors.left: swatch.right
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                height: 14
                provider: row.modelData.provider || ""
                color: Theme.textSecondary
            }
            Column {
                anchors.left: glyph.right
                anchors.leftMargin: 10
                anchors.right: cells.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                    width: parent.width
                    text: row.modelData.model
                    color: Theme.text
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: row.modelData.activeDays + (row.modelData.activeDays === 1 ? " day" : " days") + " used"
                    color: Theme.textTertiary
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            Row {
                id: cells
                anchors.right: parent.right
                height: parent.height

                // Sparkline: one hairline column per day of the range.
                Item {
                    width: root.sparkWidth
                    height: parent.height
                    Row {
                        anchors.centerIn: parent
                        height: 22
                        spacing: row.modelData.daily.length > 45 ? 0 : 1
                        Repeater {
                            model: row.modelData.daily
                            delegate: Rectangle {
                                required property real modelData
                                width: Math.max(1, (root.sparkWidth - 16) / row.modelData.daily.length
                                                   - (row.modelData.daily.length > 45 ? 0 : 1))
                                height: modelData > 0 ? Math.max(2, 22 * modelData / row.peak) : 1
                                anchors.bottom: parent.bottom
                                color: modelData > 0 ? Theme.text : Theme.track
                                opacity: modelData > 0 ? 0.85 : 1
                            }
                        }
                    }
                }
                Text {
                    width: root.tokensWidth
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: Theme.tokens(row.modelData.total)
                    color: Theme.textSecondary
                    font.pixelSize: 12
                    font.features: { "tnum": 1 }
                }
                Text {
                    width: root.costWidth
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: Theme.usd(row.modelData.cost)
                    color: Theme.text
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
                Item {
                    width: root.shareWidth
                    height: parent.height
                    Rectangle {
                        anchors.right: shareText.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40
                        height: 4
                        radius: 2
                        color: Theme.track
                        Rectangle {
                            width: Math.max(row.share > 0 ? 2 : 0, parent.width * row.share)
                            height: parent.height
                            radius: 2
                            color: Theme.text
                        }
                    }
                    Text {
                        id: shareText
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 32
                        horizontalAlignment: Text.AlignRight
                        text: row.share > 0 && row.share < 0.01 ? "<1%" : Math.round(row.share * 100) + "%"
                        color: Theme.textSecondary
                        font.pixelSize: 12
                        font.features: { "tnum": 1 }
                    }
                }
            }
        }
    }

    Text {
        visible: root.models.length === 0
        topPadding: 4
        text: "No model history in this range yet."
        color: Theme.textTertiary
        font.pixelSize: 13
    }
}
