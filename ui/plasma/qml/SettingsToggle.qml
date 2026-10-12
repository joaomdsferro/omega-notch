import QtQuick
import OmegaNotch

// A bare on/off knob, for rows whose name already sits beside it.
Rectangle {
    id: root

    property bool checked: false
    property bool enabled_: true
    property string accessibleName: ""

    signal toggled(bool checked)

    implicitWidth: 38
    implicitHeight: 22
    radius: 11
    color: root.checked ? Theme.ample : hover.hovered && enabled_ ? "#45FFFFFF" : "#33FFFFFF"
    opacity: enabled_ ? 1 : 0.45
    Behavior on color { ColorAnimation { duration: 140 } }

    Accessible.role: Accessible.CheckBox
    Accessible.name: accessibleName
    Accessible.checked: checked

    Rectangle {
        width: 18
        height: 18
        radius: 9
        y: 2
        x: root.checked ? parent.width - width - 2 : 2
        color: root.checked ? "#000000" : "#FFFFFF"
        Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }

    HoverHandler {
        id: hover
        cursorShape: root.enabled_ ? Qt.PointingHandCursor : Qt.ForbiddenCursor
    }
    TapHandler {
        enabled: root.enabled_
        onTapped: root.toggled(!root.checked)
    }
}
