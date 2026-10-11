import QtQuick
import OmegaNotch

// A small round control in the notch's footer.
Item {
    id: root

    property string icon: "settings"   // "settings" | "grip"
    property real scale_: 1.0
    property int cursor: Qt.PointingHandCursor
    property color surface: Theme.notch    // what the button is drawn on
    readonly property bool onLight: Theme.isLight(surface)
    readonly property bool hovered: hover.hovered

    signal clicked()

    width: 26 * scale_
    height: width

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.onLight ? (hover.hovered ? "#2B000000" : "#17000000")
                            : (hover.hovered ? "#2BFFFFFF" : "#17FFFFFF")
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    // Settings: three sliders.
    Item {
        anchors.centerIn: parent
        width: 12 * root.scale_
        height: 10 * root.scale_
        visible: root.icon === "settings"

        Repeater {
            model: [0.68, 0.28, 0.55]
            delegate: Item {
                required property real modelData
                required property int index
                y: index * (parent.height - 1.5 * root.scale_) / 2
                width: parent.width
                height: 1.5 * root.scale_

                Rectangle { anchors.fill: parent; radius: height / 2; color: Theme.inkSecondary(root.surface) }
                Rectangle {
                    width: 4 * root.scale_
                    height: width
                    radius: width / 2
                    color: Theme.ink(root.surface)
                    x: (parent.width - width) * modelData
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // Grip: six dots.
    Grid {
        anchors.centerIn: parent
        visible: root.icon === "grip"
        columns: 2
        spacing: 2.5 * root.scale_
        Repeater {
            model: 6
            delegate: Rectangle {
                width: 2.5 * root.scale_
                height: width
                radius: width / 2
                color: hover.hovered ? Theme.ink(root.surface) : Theme.inkSecondary(root.surface)
            }
        }
    }

    HoverHandler {
        id: hover
        cursorShape: root.cursor
    }
    TapHandler {
        onTapped: root.clicked()
    }
}
