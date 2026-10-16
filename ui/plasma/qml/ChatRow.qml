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

    readonly property string detail: {
        if (!chat) return ""
        const parts = []
        if (chat.project) parts.push(chat.project)
        if (chat.model) parts.push(chat.model)
        else if (chat.surface) parts.push(chat.surface)
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

    Rectangle {
        id: dot
        x: 0
        anchors.verticalCenter: title.verticalCenter
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

    Text {
        id: title
        anchors.left: dot.right
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
        text: root.detail
        color: Theme.textSecondary
        font.pixelSize: 11 * root.scale_
        font.features: { "tnum": 1 }
        elide: Text.ElideRight
        maximumLineCount: 1
    }
}
