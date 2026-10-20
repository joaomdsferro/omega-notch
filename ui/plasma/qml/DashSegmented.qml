import QtQuick
import OmegaNotch

// Compact segmented control for the dashboard toolbar: each segment as wide
// as its label, the chosen one raised. Optional glyph per option.
Rectangle {
    id: root

    property var options: []           // [{ value, label, provider? }]
    property string value: ""

    signal picked(string value)

    implicitWidth: row.implicitWidth + 6
    implicitHeight: 32
    radius: 9
    color: Theme.controlFill

    Row {
        id: row
        x: 3
        y: 3
        height: parent.height - 6

        Repeater {
            model: root.options
            delegate: Rectangle {
                id: seg
                required property var modelData
                readonly property bool chosen: modelData.value === root.value
                readonly property bool hasGlyph: !!modelData.provider

                width: segLabel.implicitWidth + (hasGlyph ? 22 : 0) + 24
                height: parent.height
                radius: 7
                color: chosen ? Theme.controlChosen : segHover.hovered ? Theme.controlHover : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion(Theme.motionHover) } }

                activeFocusOnTab: true
                Keys.onReturnPressed: (event) => { root.picked(seg.modelData.value); event.accepted = true }
                Keys.onEnterPressed: (event) => { root.picked(seg.modelData.value); event.accepted = true }
                Keys.onSpacePressed: (event) => { root.picked(seg.modelData.value); event.accepted = true }

                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.label
                Accessible.checked: chosen
                Accessible.focusable: true

                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    ProviderGlyph {
                        visible: seg.hasGlyph
                        width: 14
                        height: 14
                        anchors.verticalCenter: parent.verticalCenter
                        provider: seg.modelData.provider || ""
                        color: seg.chosen ? Theme.text : Theme.textSecondary
                    }
                    Text {
                        id: segLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: seg.modelData.label
                        color: seg.chosen ? Theme.text : Theme.textSecondary
                        font.pixelSize: 12
                        font.weight: seg.chosen ? Font.DemiBold : Font.Medium
                    }
                }

                HoverHandler {
                    id: segHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: root.picked(seg.modelData.value)
                }
                FocusRing { target: seg }
            }
        }
    }
}
