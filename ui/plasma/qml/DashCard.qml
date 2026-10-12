import QtQuick
import OmegaNotch

// A dashboard surface: raised panel, hairline edge, optional heading row with
// a trailing slot for controls or a legend.
Rectangle {
    id: root

    property string heading: ""
    property string caption: ""
    default property alias content: body.data
    property alias trailing: trailingSlot.data
    property real padding: 20

    readonly property real bodyTop: heading.length > 0 ? headRow.y + headRow.height + 16 : padding
    readonly property alias bodyItem: body

    implicitHeight: bodyTop + body.childrenRect.height + padding
    radius: 12
    color: Theme.panelRaised
    border.width: 1
    border.color: Theme.hairline

    Item {
        id: headRow
        visible: root.heading.length > 0
        x: root.padding
        y: root.padding - 2
        width: parent.width - 2 * root.padding
        height: Math.max(headCol.implicitHeight, trailingSlot.childrenRect.height)

        Column {
            id: headCol
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
                text: root.heading
                color: Theme.text
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }
            Text {
                visible: root.caption.length > 0
                text: root.caption
                color: Theme.textSecondary
                font.pixelSize: 12
            }
        }
        Item {
            id: trailingSlot
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    Item {
        id: body
        x: root.padding
        y: root.bodyTop
        width: parent.width - 2 * root.padding
        height: childrenRect.height
    }
}
