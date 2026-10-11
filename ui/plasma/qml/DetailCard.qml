import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import OmegaNotch

// What a ring means, spelled out: limit windows, today's tokens, and the
// chats behind them. It stays open while the pointer is on it.
Item {
    id: root

    property string edge: "right"
    property var reading: null
    property string sessionKind: "idle"
    property string sessionLabel: ""
    property var chats: []
    property var tokenStats: null
    property real now: Date.now()
    property real scale_: 1.0
    property bool engineConnected: true
    // Peek: why the card opened on its own.
    property string bannerKind: ""
    property string bannerLabel: ""
    // Where the tail sits along the side facing the notch.
    property real tailOffset: height / 2

    readonly property real pad: 16 * scale_
    readonly property real tailLength: 11 * scale_
    readonly property int maxChats: 5
    readonly property string status: reading ? (reading.status || "ok") : "offline"
    readonly property bool stale: status === "stale"

    width: 320 * scale_
    height: content.implicitHeight + 2 * pad

    function tailPoint(a, b) {
        switch (edge) {
        case "left": return (-b) + " " + (tailOffset + a)
        case "top": return (tailOffset + a) + " " + (-b)
        case "bottom": return (tailOffset + a) + " " + (height + b)
        default: return (width + b) + " " + (tailOffset + a)
        }
    }

    Rectangle {
        id: plate
        anchors.fill: parent
        radius: 20 * root.scale_
        color: Theme.card
        border.color: Theme.cardStroke
        border.width: 1

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#99000000"
            shadowBlur: 0.9
            shadowVerticalOffset: 8
        }
    }

    Shape {
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: Theme.card
            strokeColor: "transparent"
            strokeWidth: 0
            PathSvg {
                path: {
                    const h = 10 * root.scale_, t = root.tailLength, p = root.tailPoint
                    return "M " + p(-h, -1.5)
                         + " Q " + p(-h * 0.25, 1) + " " + p(0, t)
                         + " Q " + p(h * 0.25, 1) + " " + p(h, -1.5) + " Z"
                }
            }
        }
    }

    Column {
        id: content
        x: root.pad
        y: root.pad
        width: root.width - 2 * root.pad
        spacing: 12 * root.scale_

        // Peek banner
        Rectangle {
            width: parent.width
            height: bannerText.implicitHeight + 12 * root.scale_
            radius: 9 * root.scale_
            visible: root.bannerKind.length > 0
            readonly property color tint: root.bannerKind === "waiting_you" ? Theme.waiting : Theme.ample
            color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)

            Text {
                id: bannerText
                anchors.verticalCenter: parent.verticalCenter
                x: 10 * root.scale_
                width: parent.width - 20 * root.scale_
                text: (root.bannerKind === "waiting_you" ? "Needs you" : "Finished")
                      + (root.bannerLabel.length > 0 ? "  ·  " + root.bannerLabel : "")
                color: parent.tint
                font.pixelSize: 12 * root.scale_
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
        }

        // Header
        Item {
            width: parent.width
            height: 20 * root.scale_

            ProviderGlyph {
                id: glyph
                width: 18 * root.scale_
                height: width
                anchors.verticalCenter: parent.verticalCenter
                provider: root.reading ? root.reading.provider : ""
            }
            Text {
                id: titleText
                anchors.left: glyph.right
                anchors.leftMargin: 9 * root.scale_
                anchors.right: stateText.left
                anchors.rightMargin: 8 * root.scale_
                anchors.verticalCenter: parent.verticalCenter
                text: root.reading ? (root.reading.display_name || "") : "Omega Notch"
                color: Theme.text
                font.pixelSize: 14.5 * root.scale_
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                id: stateText
                anchors.right: parent.right
                anchors.baseline: titleText.baseline
                text: root.sessionKind === "busy" ? "Working"
                    : root.sessionKind === "waiting_you" ? "Needs you"
                    : root.reading && root.reading.fidelity === "derived" ? "Estimated"
                    : root.reading && root.reading.fetched_at && (root.status === "ok" || root.stale)
                        ? "Updated " + Theme.ago(root.reading.fetched_at, root.now) : ""
                color: root.sessionKind === "waiting_you" ? Theme.waiting
                     : root.sessionKind === "busy" ? Theme.text : Theme.textSecondary
                font.pixelSize: 11.5 * root.scale_
                font.weight: root.sessionKind === "idle" ? Font.Normal : Font.DemiBold
            }
        }

        // The session that is working or waiting
        Text {
            width: parent.width
            visible: root.sessionKind !== "idle" && root.sessionLabel.length > 0
            text: root.sessionLabel
            color: Theme.textSecondary
            font.pixelSize: 11.5 * root.scale_
            elide: Text.ElideRight
            topPadding: -6 * root.scale_
        }

        // Anything the provider has to say for itself
        Text {
            width: parent.width
            wrapMode: Text.Wrap
            visible: text.length > 0
            text: !root.reading
                    ? (root.engineConnected ? "No providers are switched on. Open Settings to pick some."
                                            : "Engine offline — waiting for omega-notch-engine.")
                : root.reading.message ? root.reading.message : ""
            color: root.status === "error" ? Theme.critical : Theme.textSecondary
            font.pixelSize: 11.5 * root.scale_
            lineHeight: 1.15
        }

        Repeater {
            model: root.reading && root.reading.windows ? root.reading.windows : []
            delegate: UsageRow {
                required property var modelData
                width: content.width
                window: modelData
                now: root.now
                scale_: root.scale_
                stale: root.stale
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.hairline
            visible: tokenPanel.visible
        }

        TokenPanel {
            id: tokenPanel
            width: parent.width
            visible: root.tokenStats !== null && root.tokenStats !== undefined
            stats: root.tokenStats
            scale_: root.scale_
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.hairline
            visible: chatList.visible
        }

        Column {
            id: chatList
            width: parent.width
            spacing: 9 * root.scale_
            visible: root.chats.length > 0

            Text {
                text: "RECENT CHATS"
                color: Theme.textSecondary
                font.pixelSize: 10.5 * root.scale_
                font.weight: Font.DemiBold
                font.letterSpacing: 0.6
            }

            Repeater {
                model: root.chats.slice(0, root.maxChats)
                delegate: ChatRow {
                    required property var modelData
                    width: chatList.width
                    chat: modelData
                    now: root.now
                    scale_: root.scale_
                }
            }
        }
    }
}
