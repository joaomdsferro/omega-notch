import QtQuick
import OmegaNotch

// Pick one of a few: a row of segments with the chosen one raised.
Rectangle {
    id: root

    property var options: []           // [{ value, label }]
    property string value: ""

    signal picked(string value)

    implicitHeight: 32
    radius: 9
    color: "#14FFFFFF"

    Row {
        anchors.fill: parent
        anchors.margins: 3

        Repeater {
            model: root.options
            delegate: Rectangle {
                required property var modelData
                readonly property bool chosen: modelData.value === root.value

                width: parent.width / root.options.length
                height: parent.height
                radius: 7
                color: chosen ? "#2EFFFFFF" : segmentHover.hovered ? "#12FFFFFF" : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.chosen ? Theme.text : Theme.textSecondary
                    font.pixelSize: 13
                    font.weight: parent.chosen ? Font.DemiBold : Font.Normal
                }

                HoverHandler {
                    id: segmentHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: root.picked(modelData.value)
                }
            }
        }
    }
}
