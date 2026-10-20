import QtQuick
import OmegaNotch

// A small round control in the notch's footer.
Item {
    id: root

    property string icon: "settings"   // "settings" | "grip" | "dashboard"
    property real scale_: 1.0
    property int cursor: Qt.PointingHandCursor
    property color surface: Theme.notch    // what the button is drawn on
    readonly property bool onLight: Theme.isLight(surface)
    readonly property bool hovered: hover.hovered

    signal clicked()

    width: Theme.px(26 * scale_)
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
        width: Theme.px(12 * root.scale_)
        height: Theme.px(10 * root.scale_)
        x: Theme.px((parent.width - width) / 2)
        y: Theme.px((parent.height - height) / 2)
        visible: root.icon === "settings"

        Repeater {
            model: [0.68, 0.28, 0.55]
            delegate: Item {
                required property real modelData
                required property int index
                y: Theme.px(index * (parent.height - Theme.px(1.5 * root.scale_)) / 2)
                width: parent.width
                height: Theme.px(1.5 * root.scale_)

                Rectangle { anchors.fill: parent; radius: height / 2; color: Theme.inkSecondary(root.surface) }
                Rectangle {
                    width: Theme.px(4 * root.scale_)
                    height: width
                    radius: width / 2
                    color: Theme.ink(root.surface)
                    x: Theme.px((parent.width - width) * modelData)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // Grip: six dots.
    Grid {
        x: Theme.px((parent.width - width) / 2)
        y: Theme.px((parent.height - height) / 2)
        visible: root.icon === "grip"
        columns: 2
        spacing: Theme.px(2.5 * root.scale_)
        Repeater {
            model: 6
            delegate: Rectangle {
                width: Theme.px(2.5 * root.scale_)
                height: width
                radius: width / 2
                color: hover.hovered ? Theme.ink(root.surface) : Theme.inkSecondary(root.surface)
            }
        }
    }

    // Dashboard: three rising bars.
    Row {
        x: Theme.px((parent.width - width) / 2)
        y: Theme.px((parent.height - height) / 2)
        visible: root.icon === "dashboard"
        spacing: Theme.px(2 * root.scale_)
        Repeater {
            model: [5, 9, 7]
            delegate: Rectangle {
                required property real modelData
                width: Theme.px(3 * root.scale_)
                height: Theme.px(modelData * root.scale_)
                anchors.bottom: parent.bottom
                radius: Theme.px(1 * root.scale_)
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
