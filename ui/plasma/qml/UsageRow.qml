import QtQuick
import OmegaNotch

// One limit window: what it is, when it resets, and how much is gone.
Column {
    id: root

    property var window
    property real now: Date.now()
    property real scale_: 1.0
    property bool stale: false

    readonly property real pct: window ? Math.max(0, Math.min(100, Number(window.used_pct) || 0)) : 0

    spacing: 6 * scale_

    Item {
        width: parent.width
        height: name.implicitHeight

        Text {
            id: name
            anchors.left: parent.left
            anchors.right: reset.left
            anchors.rightMargin: 8 * root.scale_
            text: root.window ? (root.window.label || "Usage") : ""
            color: Theme.text
            font.pixelSize: 12.5 * root.scale_
            elide: Text.ElideRight
        }
        Text {
            id: reset
            anchors.right: parent.right
            anchors.baseline: name.baseline
            text: root.window ? Theme.resetsIn(root.window.resets_at, root.now) : ""
            color: Theme.textSecondary
            font.pixelSize: 11.5 * root.scale_
        }
    }

    Rectangle {
        width: parent.width
        height: 4 * root.scale_
        radius: height / 2
        color: Theme.track

        Rectangle {
            width: Math.max(root.pct > 0 ? parent.height : 0, parent.width * root.pct / 100)
            height: parent.height
            radius: height / 2
            color: Theme.usageColor(root.pct)
            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        }
    }

    Text {
        text: Math.round(root.pct) + "% used"
        color: Theme.textSecondary
        font.pixelSize: 11 * root.scale_
        font.features: { "tnum": 1 }
    }
}
