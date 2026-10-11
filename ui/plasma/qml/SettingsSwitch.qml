import QtQuick
import OmegaNotch

// A labelled on/off row. The whole row is the target, not just the knob.
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    property string provider: ""       // optional mark in front of the title
    property bool checked: false
    property bool subtitleIsError: false

    signal toggled(bool checked)

    implicitHeight: Math.max(44, labels.implicitHeight + 16)

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -8
        anchors.rightMargin: -8
        radius: 8
        color: hover.hovered ? Theme.panelHover : "transparent"
    }

    ProviderGlyph {
        id: mark
        visible: root.provider.length > 0
        width: visible ? 18 : 0
        height: 18
        anchors.verticalCenter: parent.verticalCenter
        provider: root.provider
        color: root.checked ? Theme.text : Theme.textSecondary
    }

    Column {
        id: labels
        anchors.left: mark.right
        anchors.leftMargin: mark.visible ? 12 : 0
        anchors.right: knobTrack.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        Text {
            width: parent.width
            text: root.title
            color: Theme.text
            font.pixelSize: 14
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            visible: root.subtitle.length > 0
            text: root.subtitle
            color: root.subtitleIsError ? Theme.critical : Theme.textSecondary
            font.pixelSize: 12
            elide: Text.ElideRight
        }
    }

    Rectangle {
        id: knobTrack
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 38
        height: 22
        radius: 11
        color: root.checked ? Theme.ample : "#33FFFFFF"
        Behavior on color { ColorAnimation { duration: 140 } }

        Rectangle {
            width: 18
            height: 18
            radius: 9
            y: 2
            x: root.checked ? parent.width - width - 2 : 2
            color: root.checked ? "#000000" : "#FFFFFF"
            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        onTapped: root.toggled(!root.checked)
    }
}
