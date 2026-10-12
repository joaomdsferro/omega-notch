import QtQuick
import OmegaNotch

// Pick one of a few: a row of segments with the chosen one raised. A segment
// shows an icon, a row of dots, a label, or a mix; a tip names it on hover.
Rectangle {
    id: root

    property var options: []           // [{ value, label?, icon?, dots?, tip? }]
    property string value: ""

    signal picked(string value)

    implicitHeight: 34
    radius: 9
    color: Theme.controlFill

    Row {
        anchors.fill: parent
        anchors.margins: 3

        Repeater {
            model: root.options
            delegate: Rectangle {
                id: segment
                required property var modelData
                readonly property bool chosen: modelData.value === root.value
                readonly property color ink: chosen || segmentHover.hovered ? Theme.text : Theme.textSecondary

                width: parent.width / root.options.length
                height: parent.height
                radius: 7
                color: chosen ? Theme.controlChosen : segmentHover.hovered ? Theme.controlHover : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }

                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.tip || modelData.label || modelData.value
                Accessible.checked: chosen

                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    SettingsIcon {
                        visible: !!segment.modelData.icon
                        anchors.verticalCenter: parent.verticalCenter
                        width: 20
                        height: 20
                        name: segment.modelData.icon || ""
                        color: segment.ink
                    }
                    // A count shown as that many dots.
                    Row {
                        visible: !!segment.modelData.dots
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3
                        Repeater {
                            model: segment.modelData.dots || 0
                            delegate: Rectangle {
                                width: 5
                                height: 5
                                radius: 2.5
                                color: segment.ink
                            }
                        }
                    }
                    Text {
                        visible: !!segment.modelData.label
                        anchors.verticalCenter: parent.verticalCenter
                        text: segment.modelData.label || ""
                        color: segment.ink
                        font.pixelSize: 13
                        font.weight: segment.chosen ? Font.DemiBold : Font.Normal
                    }
                }

                HoverHandler {
                    id: segmentHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: root.picked(segment.modelData.value)
                }
                SettingsToolTip {
                    visible: segmentHover.hovered && !!segment.modelData.tip
                    text: segment.modelData.tip || ""
                }
            }
        }
    }
}
