import QtQuick
import OmegaNotch

// One session in the dearest list: its title and where it ran, a bar of its
// spend by model, tokens, estimated cost, share of the range's spend and the
// last day it ran. Click to see each model's tokens by kind.
Item {
    id: root

    property var session
    property string today: ""
    property bool first: false
    property real rangeCost: 0
    // Model name -> colour, as in the Models table.
    property var shades: ({})
    // For a model the table does not list.
    property color otherShade: Theme.shades[Theme.shades.length - 1]
    property bool expanded: false
    signal toggled()
    signal openRequested()
    // Narrows the page to this session; hidden once it is.
    property bool focusable: true
    signal focusRequested()

    readonly property var models: session && session.models ? session.models : []
    readonly property real cost: session ? (session.cost_usd || 0) : 0
    readonly property real share: rangeCost > 0 ? cost / rangeCost : 0

    readonly property string where: {
        if (!session) return ""
        const parts = []
        if (session.project) parts.push(session.project)
        if (session.surface) parts.push(session.surface)
        parts.push(models.map(m => m.model).join(", "))
        return parts.join("  ·  ")
    }

    function shadeOf(model) {
        return shades[model] !== undefined ? shades[model] : otherShade
    }
    function percent(share) {
        return share > 0 && share < 0.01 ? "<1%" : Math.round(share * 100) + "%"
    }

    height: 56 + (expanded ? details.implicitHeight + 14 : 0)
    clip: true
    Behavior on height { NumberAnimation { duration: Theme.motion(Theme.motionState); easing.type: Easing.Bezier; easing.bezierCurve: Theme.motionCurve } }

    component Cell: Text {
        horizontalAlignment: Text.AlignRight
        color: Theme.textSecondary
        font.pixelSize: 12
        font.features: { "tnum": 1 }
    }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -8
        anchors.rightMargin: -8
        radius: 8
        color: Theme.panelHover
        opacity: rowHover.hovered || root.expanded ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.motion(Theme.motionHover) } }
    }
    Rectangle {
        width: parent.width
        height: 1
        color: Theme.hairline
        visible: !root.first && !rowHover.hovered && !root.expanded
    }

    Item {
        id: summary
        width: parent.width
        height: 56

        Accessible.role: Accessible.Button
        Accessible.name: (root.session ? root.session.title : "") + (root.expanded ? ". Hide its models" : ". Show its models")
        Accessible.focusable: true
        activeFocusOnTab: true
        Keys.onReturnPressed: (event) => { root.toggled(); event.accepted = true }
        Keys.onEnterPressed: (event) => { root.toggled(); event.accepted = true }
        Keys.onSpacePressed: (event) => { root.toggled(); event.accepted = true }

        HoverHandler {
            id: rowHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler { onTapped: root.toggled() }
        FocusRing { target: summary }

        Rectangle {
            id: tile
            width: 32
            height: 32
            radius: 8
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.controlFill
            ProviderGlyph {
                anchors.centerIn: parent
                width: 16
                height: 16
                provider: root.session ? root.session.provider : ""
                color: Theme.textSecondary
            }
        }

        Column {
            anchors.left: tile.right
            anchors.leftMargin: 12
            anchors.right: cells.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Text {
                width: parent.width
                text: root.session ? root.session.title : ""
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: root.where
                color: Theme.textTertiary
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        Row {
            id: cells
            anchors.right: parent.right
            height: parent.height

            // The session's spend as one bar, a segment per model.
            Item {
                width: 112
                height: parent.height
                Rectangle {
                    id: mixTrack
                    anchors.centerIn: parent
                    width: 96
                    height: 6
                    radius: 3
                    color: Theme.track
                    clip: true
                    Row {
                        height: parent.height
                        spacing: 2
                        Repeater {
                            model: root.models
                            delegate: Rectangle {
                                required property var modelData
                                height: parent.height
                                width: Math.max(2, (mixTrack.width - Math.max(0, root.models.length - 1) * 2)
                                                   * (modelData.cost_usd || 0) / Math.max(root.cost, 0.0001))
                                color: root.shadeOf(modelData.model)
                            }
                        }
                    }
                }
            }
            Cell {
                width: 76
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.tokens(root.session ? root.session.total : 0)
            }
            Cell {
                width: 84
                anchors.verticalCenter: parent.verticalCenter
                text: Theme.usd(root.cost)
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
            Cell {
                width: 64
                anchors.verticalCenter: parent.verticalCenter
                text: root.percent(root.share)
            }
            Cell {
                width: 84
                anchors.verticalCenter: parent.verticalCenter
                text: root.session ? Theme.day(root.session.last_date, root.today) : ""
            }
        }
    }

    // Each model's tokens by kind, its cost and share of the session.
    Column {
        id: details
        anchors.top: summary.bottom
        x: 44
        width: parent.width - 44
        visible: root.expanded

        Item {
            width: parent.width
            height: 22
            Text { text: "Model"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: ["Input", "Output", "Cache write", "Cache read", "Est. cost"]
                    delegate: Cell {
                        required property string modelData
                        width: 84
                        text: modelData
                        color: Theme.textTertiary
                        font.pixelSize: 11
                        font.weight: Font.Medium
                    }
                }
                Cell { width: 64; text: "Share"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
            }
        }

        Repeater {
            model: root.models
            delegate: Item {
                id: modelRow
                required property var modelData
                width: details.width
                height: 30
                Rectangle {
                    id: swatch
                    width: 8
                    height: 8
                    radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.shadeOf(modelRow.modelData.model)
                }
                Text {
                    anchors.left: swatch.right
                    anchors.leftMargin: 10
                    anchors.right: modelCells.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelRow.modelData.model
                    color: Theme.text
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }
                Row {
                    id: modelCells
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    Cell { width: 84; text: Theme.tokens(modelRow.modelData.input || 0) }
                    Cell { width: 84; text: Theme.tokens(modelRow.modelData.output || 0) }
                    Cell { width: 84; text: Theme.tokens(modelRow.modelData.cache_write || 0) }
                    Cell { width: 84; text: Theme.tokens(modelRow.modelData.cache_read || 0) }
                    Cell { width: 84; text: Theme.usd(modelRow.modelData.cost_usd || 0); color: Theme.text; font.weight: Font.DemiBold }
                    Cell { width: 64; text: root.percent(root.cost > 0 ? (modelRow.modelData.cost_usd || 0) / root.cost : 0) }
                }
            }
        }

        Item {
            width: parent.width
            height: 36
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.session && root.session.total > 0
                      ? Math.round(100 * (root.session.cache_read || 0) / root.session.total) + "% served from cache"
                      : ""
                color: Theme.textTertiary
                font.pixelSize: 11
                font.features: { "tnum": 1 }
            }
            Rectangle {
                id: openButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: openText.implicitWidth + 20
                height: 28
                radius: 7
                color: openHover.hovered ? Theme.controlChosen : Theme.controlFill
                Behavior on color { ColorAnimation { duration: Theme.motion(Theme.motionHover) } }
                activeFocusOnTab: true
                Keys.onReturnPressed: (event) => { if (root.session) root.openRequested(); event.accepted = true }
                Keys.onEnterPressed: (event) => { if (root.session) root.openRequested(); event.accepted = true }
                Keys.onSpacePressed: (event) => { if (root.session) root.openRequested(); event.accepted = true }
                Accessible.role: Accessible.Button
                Accessible.name: "Open chat"
                Accessible.focusable: true
                Text {
                    id: openText
                    anchors.centerIn: parent
                    text: "Open chat"
                    color: Theme.text
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
                HoverHandler {
                    id: openHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler { onTapped: if (root.session) root.openRequested() }
                FocusRing { target: openButton }
            }
            Rectangle {
                id: focusButton
                visible: root.focusable
                anchors.right: openButton.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: focusText.implicitWidth + 20
                height: 28
                radius: 7
                color: focusHover.hovered ? Theme.controlChosen : Theme.controlFill
                Behavior on color { ColorAnimation { duration: Theme.motion(Theme.motionHover) } }
                activeFocusOnTab: true
                Keys.onReturnPressed: (event) => { if (root.session) root.focusRequested(); event.accepted = true }
                Keys.onEnterPressed: (event) => { if (root.session) root.focusRequested(); event.accepted = true }
                Keys.onSpacePressed: (event) => { if (root.session) root.focusRequested(); event.accepted = true }
                Accessible.role: Accessible.Button
                Accessible.name: "Only this chat"
                Accessible.focusable: true
                Text {
                    id: focusText
                    anchors.centerIn: parent
                    text: "Only this chat"
                    color: Theme.text
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
                HoverHandler {
                    id: focusHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler { onTapped: if (root.session) root.focusRequested() }
                FocusRing { target: focusButton }
            }
        }
    }
}
