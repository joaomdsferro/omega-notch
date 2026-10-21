import QtQuick
import OmegaNotch

// One chat in the dashboard list: tool, title and where it ran, its tokens,
// how full its context is, and when it last moved. Click to jump to it.
Item {
    id: root

    property var chat
    property real now: Date.now()
    property bool first: false
    property bool showContext: true

    readonly property string kind: chat ? (chat.state || "idle") : "idle"
    readonly property bool unread: chat ? !!chat.unread : false
    readonly property bool hasAvatar: chat ? !!chat.avatar_shape : false
    readonly property real tokens: chat && chat.tokens ? Theme.totalTokens(chat.tokens) : 0
    readonly property real ctx: chat && chat.context_pct !== undefined && chat.context_pct !== null
                                ? Number(chat.context_pct) : -1

    readonly property string where: {
        if (!chat) return ""
        const parts = []
        if (chat.project) parts.push(chat.project)
        if (chat.model) parts.push(chat.model)
        if (chat.surface) parts.push(chat.surface)
        if (chat.lines_added || chat.lines_removed)
            parts.push("+" + (chat.lines_added || 0) + " −" + (chat.lines_removed || 0))
        return parts.join("  ·  ")
    }

    // Column widths, shared with the header row in DashboardWindow.
    readonly property real tokensWidth: 84
    readonly property real ctxWidth: showContext ? 96 : 0
    readonly property real whenWidth: 76

    height: 56

    Accessible.role: Accessible.Button
    Accessible.name: (chat ? chat.title : "") + ". Open chat"
    Accessible.focusable: true
    activeFocusOnTab: true
    Keys.onReturnPressed: (event) => {
        if (root.chat) Engine.openChat(root.chat)
        event.accepted = true
    }
    Keys.onEnterPressed: (event) => {
        if (root.chat) Engine.openChat(root.chat)
        event.accepted = true
    }
    Keys.onSpacePressed: (event) => {
        if (root.chat) Engine.openChat(root.chat)
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -8
        anchors.rightMargin: -8
        radius: 8
        color: Theme.panelHover
        opacity: rowHover.hovered ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.motion(Theme.motionHover) } }
    }
    Rectangle {
        width: parent.width
        height: 1
        color: Theme.hairline
        visible: !root.first && !rowHover.hovered
    }

    HoverHandler {
        id: rowHover
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        onTapped: if (root.chat) Engine.openChat(root.chat)
    }

    // Tool mark with the live state as a dot on its corner. A bot the roster
    // styled gets its drawn avatar instead of the tool's mark.
    Rectangle {
        id: tile
        width: 32
        height: 32
        radius: 8
        anchors.verticalCenter: parent.verticalCenter
        color: Theme.controlFill

        ProviderGlyph {
            anchors.centerIn: parent
            visible: !root.hasAvatar
            width: 16
            height: 16
            provider: root.chat ? root.chat.provider : ""
            color: root.kind === "idle" ? Theme.textSecondary : Theme.text
        }
        BotAvatar {
            anchors.centerIn: parent
            visible: root.hasAvatar
            width: 20
            height: 20
            shape: root.hasAvatar ? root.chat.avatar_shape : ""
            colorName: root.chat && root.chat.avatar_color ? root.chat.avatar_color : ""
        }
        Rectangle {
            visible: root.kind !== "idle" || root.unread
            x: parent.width - width / 2 - 2
            y: -width / 2 + 2
            width: 10
            height: 10
            radius: 5
            color: root.unread ? Theme.unread : Theme.stateColor(root.kind)
            border.width: 2
            border.color: Theme.panelRaised

            SequentialAnimation on opacity {
                running: root.kind !== "idle" && root.visible && !Theme.reducedMotion
                loops: Animation.Infinite
                alwaysRunToEnd: true
                NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
            }
        }
    }

    Column {
        anchors.left: tile.right
        anchors.leftMargin: 12
        anchors.right: tokensCell.left
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3

        Text {
            width: parent.width
            text: root.chat ? root.chat.title : ""
            color: Theme.text
            font.pixelSize: 13
            font.weight: root.unread ? Font.DemiBold : Font.Medium
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Text {
            width: parent.width
            text: root.where || (root.chat ? (root.chat.preview || "") : "")
            color: Theme.textTertiary
            font.pixelSize: 11
            font.features: { "tnum": 1 }
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }

    Text {
        id: tokensCell
        anchors.right: ctxCell.left
        anchors.verticalCenter: parent.verticalCenter
        width: root.tokensWidth
        horizontalAlignment: Text.AlignRight
        text: root.tokens > 0 ? Theme.tokens(root.tokens) : "—"
        color: root.tokens > 0 ? Theme.text : Theme.textTertiary
        font.pixelSize: 12
        font.features: { "tnum": 1 }
    }

    // Context fill: a short bar with its number.
    Item {
        id: ctxCell
        visible: root.showContext
        anchors.right: whenCell.left
        anchors.verticalCenter: parent.verticalCenter
        width: root.ctxWidth
        height: 16

        Rectangle {
            visible: root.ctx >= 0
            x: 24
            anchors.verticalCenter: parent.verticalCenter
            width: 36
            height: 4
            radius: 2
            color: Theme.track
            Rectangle {
                width: parent.width * Math.min(1, root.ctx / 100)
                height: parent.height
                radius: 2
                color: Theme.usageColor(root.ctx)
            }
        }
        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.ctx >= 0 ? Math.round(root.ctx) + "%" : "—"
            color: root.ctx >= 0 ? Theme.textSecondary : Theme.textTertiary
            font.pixelSize: 12
            font.features: { "tnum": 1 }
        }
    }

    Text {
        id: whenCell
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: root.whenWidth
        horizontalAlignment: Text.AlignRight
        text: root.kind === "busy" ? "Working"
            : root.kind === "waiting_you" ? "Needs you"
            : root.unread ? "To read"
            : root.chat ? Theme.ago(root.chat.updated_at, root.now) : ""
        color: root.unread ? Theme.unread
             : root.kind === "waiting_you" ? Theme.waiting
             : root.kind === "busy" ? Theme.text : Theme.textSecondary
        font.pixelSize: 12
        font.weight: root.kind === "idle" && !root.unread ? Font.Normal : Font.DemiBold
        font.features: { "tnum": 1 }
    }
    FocusRing { target: root }
}
