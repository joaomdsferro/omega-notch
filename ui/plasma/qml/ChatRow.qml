import QtQuick
import OmegaNotch

// One recent chat: is it alive, what is it, where, and what it has cost.
Item {
    id: root

    property var chat
    property real now: Date.now()
    property real scale_: 1.0

    readonly property string kind: chat ? (chat.state || "idle") : "idle"
    readonly property bool unread: chat ? !!chat.unread : false
    readonly property bool hasAvatar: chat ? !!chat.avatar_shape : false

    readonly property string detail: {
        if (!chat) return ""
        const parts = []
        if (chat.project) parts.push(chat.project)
        if (chat.model) parts.push(chat.model)
        if (chat.surface) parts.push(chat.surface)
        if (chat.tokens) {
            const total = Theme.totalTokens(chat.tokens)
            if (total > 0) parts.push(Theme.tokens(total) + " tok")
        }
        if (chat.context_pct !== undefined && chat.context_pct !== null)
            parts.push(Math.round(chat.context_pct) + "% ctx")
        if (chat.lines_added || chat.lines_removed)
            parts.push("+" + (chat.lines_added || 0) + " −" + (chat.lines_removed || 0))
        return parts.join("  ·  ")
    }

    implicitHeight: title.implicitHeight + sub.implicitHeight + 2 * scale_

    // Click to jump to the chat: its window, or a new one resuming it.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -4 * root.scale_
        radius: 6 * root.scale_
        color: Theme.panelHover
        visible: click.containsMouse
    }

    MouseArea {
        id: click
        anchors.fill: parent
        anchors.margins: -4 * root.scale_
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.chat) Engine.openChat(root.chat)
    }

    // The mark column: a bot's drawn avatar when the roster styled one, a
    // plain dot otherwise. The live state rides its corner when an avatar
    // sits there, so the signal survives the drawing.
    Item {
        id: mark
        x: 0
        width: 16 * root.scale_
        height: width
        anchors.verticalCenter: title.verticalCenter

        BotAvatar {
            anchors.fill: parent
            visible: root.hasAvatar
            shape: root.hasAvatar ? root.chat.avatar_shape : ""
            colorName: root.chat && root.chat.avatar_color ? root.chat.avatar_color : ""
        }

        Rectangle {
            id: dot
            visible: !root.hasAvatar
            anchors.centerIn: parent
            width: 7 * root.scale_
            height: width
            radius: width / 2
            color: root.unread ? Theme.unread : Theme.stateColor(root.kind)

            SequentialAnimation on opacity {
                running: root.kind !== "idle" && root.visible
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }

        Rectangle {
            id: badge
            visible: root.hasAvatar && (root.kind !== "idle" || root.unread)
            x: parent.width - width / 2 - 1 * root.scale_
            y: -height / 2 + 1 * root.scale_
            width: 7 * root.scale_
            height: width
            radius: width / 2
            color: root.unread ? Theme.unread : Theme.stateColor(root.kind)

            SequentialAnimation on opacity {
                running: root.kind !== "idle" && root.visible
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
    }

    Text {
        id: title
        anchors.left: mark.right
        anchors.leftMargin: 9 * root.scale_
        anchors.right: when.left
        anchors.rightMargin: 8 * root.scale_
        text: root.chat ? root.chat.title : ""
        color: Theme.text
        font.pixelSize: 12.5 * root.scale_
        font.weight: root.unread ? Font.DemiBold : Font.Normal
        elide: Text.ElideRight
        maximumLineCount: 1
    }

    Text {
        id: when
        anchors.right: parent.right
        anchors.baseline: title.baseline
        text: root.kind === "busy" ? "working"
            : root.kind === "waiting_you" ? "needs you"
            : !root.chat ? ""
            : (root.unread ? "finished " : "") + Theme.ago(root.chat.updated_at, root.now)
        color: root.unread ? Theme.unread
             : root.kind === "waiting_you" ? Theme.waiting
             : root.kind === "busy" ? Theme.text : Theme.textSecondary
        font.pixelSize: 11 * root.scale_
        font.features: { "tnum": 1 }
    }

    Text {
        id: sub
        anchors.left: title.left
        anchors.right: parent.right
        anchors.top: title.bottom
        anchors.topMargin: 2 * root.scale_
        text: root.detail || (root.chat ? (root.chat.preview || "") : "")
        color: Theme.textSecondary
        font.pixelSize: 11 * root.scale_
        font.features: { "tnum": 1 }
        elide: Text.ElideRight
        maximumLineCount: 1
    }
}
