import QtQuick
import OmegaNotch

// A focus ring drawn over the control that has keyboard focus, so Tab never
// leaves you guessing where you are. Put it last among a control's children
// and let `target` be the control itself.
Rectangle {
    id: ring

    property Item target: parent
    property real radius_: target && target.radius !== undefined ? target.radius : 8

    anchors.fill: target
    anchors.margins: -2
    radius: ring.radius_ + 2
    color: "transparent"
    border.width: 2
    border.color: Theme.text
    visible: target !== null && target.activeFocus
    z: 1000
}
