import QtQuick
import QtQuick.Controls
import OmegaNotch

// The hover hint used across Settings: a small dark bubble that wraps past a
// few words, so labels can stay short and the detail lives here.
ToolTip {
    id: tip

    delay: 350
    timeout: -1
    padding: 0
    width: Math.min(implicitWidth, 260)

    contentItem: Text {
        leftPadding: 10
        rightPadding: 10
        topPadding: 7
        bottomPadding: 7
        text: tip.text
        color: Theme.text
        font.pixelSize: 12
        lineHeight: 1.15
        wrapMode: Text.Wrap
    }
    background: Rectangle {
        radius: 8
        color: "#2A2A31"
        border.width: 1
        border.color: Theme.cardStroke
    }

    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 110 } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 80 } }
}
