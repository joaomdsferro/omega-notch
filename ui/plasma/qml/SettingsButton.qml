import QtQuick
import OmegaNotch

// A text button, an icon and text, or (with no text) a square icon button
// whose name lives in its tooltip.
Rectangle {
    id: root

    property string text: ""
    property string icon: ""            // a SettingsIcon name
    property string tip: ""
    property bool destructive: false
    property bool enabled_: true

    signal clicked()

    readonly property bool iconOnly: text.length === 0 && icon.length > 0
    readonly property color ink: root.destructive ? Theme.critical : Theme.text

    implicitWidth: iconOnly ? 34 : content.implicitWidth + 28
    implicitHeight: 34
    radius: 9
    color: !enabled_ ? "#0DFFFFFF"
         : hover.hovered ? (destructive ? "#26FF5A36" : "#2BFFFFFF")
         : "#1AFFFFFF"
    opacity: enabled_ ? 1 : 0.5
    Behavior on color { ColorAnimation { duration: 120 } }

    Accessible.role: Accessible.Button
    Accessible.name: text.length > 0 ? text : tip

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 7

        SettingsIcon {
            visible: root.icon.length > 0
            anchors.verticalCenter: parent.verticalCenter
            width: 15
            height: 15
            name: root.icon
            color: root.ink
        }
        Text {
            visible: root.text.length > 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.ink
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }

    HoverHandler {
        id: hover
        cursorShape: root.enabled_ ? Qt.PointingHandCursor : Qt.ForbiddenCursor
    }
    TapHandler {
        enabled: root.enabled_
        onTapped: root.clicked()
    }
    SettingsToolTip {
        visible: hover.hovered && root.tip.length > 0
        text: root.tip
    }
}
