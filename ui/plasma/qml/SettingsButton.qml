import QtQuick
import OmegaNotch

Rectangle {
    id: root

    property string text: ""
    property bool destructive: false
    property bool enabled_: true

    signal clicked()

    implicitWidth: label.implicitWidth + 28
    implicitHeight: 34
    radius: 9
    color: !enabled_ ? "#0DFFFFFF" : hover.hovered ? "#2BFFFFFF" : "#1AFFFFFF"
    opacity: enabled_ ? 1 : 0.5
    Behavior on color { ColorAnimation { duration: 120 } }

    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: root.destructive ? Theme.critical : Theme.text
        font.pixelSize: 13
        font.weight: Font.Medium
    }

    HoverHandler {
        id: hover
        cursorShape: root.enabled_ ? Qt.PointingHandCursor : Qt.ForbiddenCursor
    }
    TapHandler {
        enabled: root.enabled_
        onTapped: root.clicked()
    }
}
