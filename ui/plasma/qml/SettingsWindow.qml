import QtQuick
import QtQuick.Controls
import QtQuick.Window
import OmegaNotch

// Settings: a sidebar of tabs on the left, the chosen tab on the right. Each
// setting is one row: an icon and a short name on the left, its control on
// the right. Explanations live in tooltips, and controls show what they do
// (a little screen for the edge, rings for the size, dots for the count)
// rather than saying it.
Window {
    id: root
    title: "Omega Notch Settings"
    width: 880
    height: Math.min(Screen.desktopAvailableHeight - 80, 620)
    minimumWidth: 780
    minimumHeight: 460
    visible: true
    color: Theme.panel

    signal requestClose()

    onClosing: (close) => {
        root.requestClose()
    }

    property string tab: "placement"

    readonly property var tabs: [
        { id: "placement", label: "Placement", icon: "monitor" },
        { id: "notch", label: "Notch", icon: "notch" },
        { id: "providers", label: "Providers", icon: "grid" },
        { id: "alerts", label: "Alerts", icon: "bell" }
    ]

    readonly property var providers: [
        { id: "cursor", name: "Cursor", enabled: Engine.providerCursor },
        { id: "claude_code", name: "Claude Code", enabled: Engine.providerClaudeCode },
        { id: "claude_desktop", name: "Claude Desktop", enabled: Engine.providerClaudeDesktop },
        { id: "copilot", name: "GitHub Copilot", enabled: Engine.providerCopilot },
        { id: "grok_bot", name: "Grok Bot", enabled: Engine.providerGrokBot },
        { id: "codex", name: "Codex", enabled: Engine.providerCodex }
    ]

    // Swatches offered for the notch; any other colour goes in the field.
    readonly property var idleColors: ["#000000", "#FFFFFF", "#3DDC97", "#F5C542",
                                       "#FF5A36", "#4C8DFF", "#B07CFF"]

    function readingFor(provider) {
        const list = Engine.readings
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === provider)
                return list[i]
        }
        return null
    }

    // A provider's state for its card: a usage bar when there is a reading,
    // a short word otherwise, with the detail kept for the tooltip.
    function providerState(provider, enabled) {
        if (!enabled) return { kind: "off", text: "Off", detail: "" }
        const r = readingFor(provider)
        if (!r) return Engine.connected
            ? { kind: "pending", text: "Waiting…", detail: "Waiting for the first reading" }
            : { kind: "pending", text: "Offline", detail: "The engine is not running" }
        if (r.status === "needs_auth")
            return { kind: "error", text: "Sign in needed", detail: r.message || "" }
        if (r.status === "error")
            return { kind: "error", text: "Unavailable", detail: r.message || "" }
        if (!r.windows || r.windows.length === 0)
            return { kind: "pending", text: "No limits", detail: "This provider reports no usage limits" }
        const w = r.windows[0]
        const pct = Math.round(w.used_pct || 0)
        const lines = []
        for (let i = 0; i < r.windows.length; ++i) {
            const x = r.windows[i]
            lines.push(Math.round(x.used_pct || 0) + "% · " + (x.label || "Usage"))
        }
        if (r.status === "stale") lines.push("Last reading is stale")
        return { kind: "usage", pct: pct, text: pct + "%", detail: lines.join("\n") }
    }

    // The sound an alert plays: the saved one when Plasma offers it, the
    // default otherwise. Matches Notifications::finishedSound/waitingSound.
    function effectiveSound(saved, fallback) {
        const list = Notify.sounds
        for (let i = 0; i < list.length; ++i) {
            if (list[i].name === saved)
                return saved
        }
        return fallback
    }
    function soundLabel(name) {
        const list = Notify.sounds
        for (let i = 0; i < list.length; ++i) {
            if (list[i].name === name)
                return list[i].label
        }
        return name
    }

    function screenDetail(screen) {
        const parts = []
        if (screen.model) parts.push(screen.model)
        parts.push(screen.width + "×" + screen.height)
        if (screen.primary) parts.push("primary")
        return parts.join(" · ")
    }
    function screenIcon(name) {
        return /^(eDP|LVDS|DSI)/.test(name) ? "laptop" : "monitor"
    }
    // The screen the notch is on: the chosen one, else the primary.
    readonly property var targetScreen: {
        const list = Engine.screens
        let primary = null
        for (let i = 0; i < list.length; ++i) {
            if (list[i].name === Engine.screenName) return list[i]
            if (list[i].primary) primary = list[i]
        }
        return primary || (list.length > 0 ? list[0] : null)
    }
    // The chosen output, when it is not plugged in right now.
    readonly property bool chosenScreenMissing: {
        if (Engine.screenName === "") return false
        const list = Engine.screens
        for (let i = 0; i < list.length; ++i) {
            if (list[i].name === Engine.screenName) return false
        }
        return true
    }

    // ---- Building blocks ----

    // A rounded group of rows, with hairlines between them.
    component Card: Rectangle {
        default property alias content: body.data
        property string heading: ""

        width: parent.width
        height: body.implicitHeight + (heading.length > 0 ? headingText.implicitHeight + 8 : 0) + 16
        radius: 14
        color: Theme.panelRaised

        Text {
            id: headingText
            visible: parent.heading.length > 0
            x: 18
            y: 14
            text: parent.heading.toUpperCase()
            color: Theme.textTertiary
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
        }
        Column {
            id: body
            x: 18
            y: headingText.visible ? headingText.y + headingText.implicitHeight + 2 : 8
            width: parent.width - 36
        }
    }

    // An ⓘ that explains the row it sits in.
    component InfoTip: Item {
        id: info
        property string text: ""
        width: 16
        height: 16
        visible: text.length > 0

        SettingsIcon {
            anchors.fill: parent
            name: "info"
            color: infoHover.hovered ? Theme.textSecondary : Theme.textTertiary
        }
        HoverHandler { id: infoHover }
        SettingsToolTip {
            visible: infoHover.hovered
            text: info.text
        }
    }

    // One setting: an icon and its name on the left, its control on the right.
    component FormRow: Item {
        id: formRow
        default property alias control: slot.data
        property string icon: ""
        property string title: ""
        property string hint: ""
        property bool divider: true
        property real labelWidth: 190

        width: parent.width
        implicitHeight: Math.max(36, slot.childrenRect.height) + 20

        Rectangle {
            visible: formRow.divider
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Theme.hairline
        }
        Row {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            SettingsIcon {
                visible: formRow.icon.length > 0
                anchors.verticalCenter: parent.verticalCenter
                width: 18
                height: 18
                name: formRow.icon
                color: Theme.textSecondary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: formRow.title
                color: Theme.text
                font.pixelSize: 13
                font.weight: Font.Medium
            }
            InfoTip {
                anchors.verticalCenter: parent.verticalCenter
                text: formRow.hint
            }
        }
        Item {
            id: slot
            anchors.left: parent.left
            anchors.leftMargin: formRow.labelWidth
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: childrenRect.height
        }
    }

    component SettingsSlider: Slider {
        id: slider

        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: slider.availableWidth
            height: 4
            radius: 2
            color: Theme.track
            Rectangle {
                width: slider.visualPosition * parent.width
                height: parent.height
                radius: 2
                color: Theme.text
            }
        }
        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            width: 16
            height: 16
            radius: 8
            color: Theme.text
            scale: slider.pressed ? 1.15 : sliderHover.hovered ? 1.08 : 1
            Behavior on scale { NumberAnimation { duration: 100 } }
        }
        HoverHandler {
            id: sliderHover
            cursorShape: Qt.PointingHandCursor
        }
    }

    // Swatches plus a hex field for any other colour.
    component ColorPicker: Item {
        id: picker
        property string value: "#000000"
        property bool enabled_: true
        signal picked(string color)

        width: parent.width
        height: 32
        opacity: enabled_ ? 1 : 0.4

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Repeater {
                model: root.idleColors
                delegate: Rectangle {
                    id: swatch
                    required property string modelData
                    readonly property bool chosen: modelData.toUpperCase() === picker.value.toUpperCase()

                    width: 24
                    height: 24
                    radius: 12
                    color: modelData
                    border.width: 1
                    border.color: Theme.cardStroke
                    scale: swatchHover.hovered && picker.enabled_ ? 1.12 : 1
                    Behavior on scale { NumberAnimation { duration: 100 } }

                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData
                    Accessible.checked: chosen

                    // The chosen swatch wears a ring and a tick in its own ink.
                    Rectangle {
                        visible: swatch.chosen
                        anchors.centerIn: parent
                        width: parent.width + 6
                        height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: 1.5
                        border.color: Theme.text
                    }
                    SettingsIcon {
                        visible: swatch.chosen
                        anchors.centerIn: parent
                        width: 13
                        height: 13
                        strokeWidth: 3
                        name: "check"
                        color: Theme.ink(swatch.color)
                    }

                    HoverHandler {
                        id: swatchHover
                        cursorShape: picker.enabled_ ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                    }
                    TapHandler {
                        enabled: picker.enabled_
                        onTapped: picker.picked(swatch.modelData)
                    }
                }
            }
        }
        Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 86
            height: 30
            radius: 8
            color: Theme.controlFill
            border.width: 1
            border.color: hex.activeFocus ? Theme.text
                        : hex.acceptableInput ? "transparent" : Theme.critical

            // A dot of the colour typed so far, beside the code.
            Rectangle {
                id: hexDot
                x: 9
                anchors.verticalCenter: parent.verticalCenter
                width: 10
                height: 10
                radius: 5
                color: picker.value
                border.width: 1
                border.color: Theme.cardStroke
            }
            TextInput {
                id: hex
                anchors.left: hexDot.right
                anchors.leftMargin: 6
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                enabled: picker.enabled_
                text: picker.value
                color: Theme.text
                selectionColor: Theme.textTertiary
                selectByMouse: true
                font.pixelSize: 12
                font.family: "monospace"
                maximumLength: 7
                validator: RegularExpressionValidator {
                    regularExpression: /^#[0-9A-Fa-f]{6}$/
                }
                onTextEdited: if (acceptableInput) picker.picked(text)
                onEditingFinished: text = picker.value
                Accessible.name: "Hex colour"
            }
            HoverHandler { cursorShape: picker.enabled_ ? Qt.IBeamCursor : Qt.ForbiddenCursor }
        }
    }

    // A screen to pick, as a tile: its kind as an icon, its name under it,
    // and its model and resolution in the tooltip.
    component ScreenTile: Rectangle {
        id: tile
        property string title: ""
        property string icon: "monitor"
        property string detail: ""
        property string badge: ""          // a short note under the name
        property color badgeColor: Theme.textSecondary
        property bool chosen: false
        property bool interactive: true
        signal picked()

        width: 118
        height: 78
        radius: 10
        color: chosen ? Theme.controlChosen
             : tileHover.hovered && interactive ? Theme.panelHover : Theme.controlFill
        border.width: chosen ? 1 : 0
        border.color: "#40FFFFFF"
        Behavior on color { ColorAnimation { duration: 120 } }

        Accessible.role: Accessible.RadioButton
        Accessible.name: title
        Accessible.checked: chosen

        SettingsIcon {
            x: 12
            y: 12
            width: 22
            height: 22
            name: tile.icon
            color: tile.chosen ? Theme.text : Theme.textSecondary
        }
        Rectangle {
            visible: tile.chosen
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 9
            width: 18
            height: 18
            radius: 9
            color: Theme.text
            SettingsIcon {
                anchors.centerIn: parent
                width: 11
                height: 11
                strokeWidth: 3.2
                name: "check"
                color: Theme.panel
            }
        }
        Column {
            x: 12
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 10
            width: parent.width - 24
            spacing: 1
            Text {
                width: parent.width
                text: tile.title
                color: Theme.text
                font.pixelSize: 13
                font.weight: tile.chosen ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }
            Text {
                visible: tile.badge.length > 0
                text: tile.badge
                color: tile.badgeColor
                font.pixelSize: 11
            }
        }
        HoverHandler {
            id: tileHover
            cursorShape: tile.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
        TapHandler {
            enabled: tile.interactive
            onTapped: tile.picked()
        }
        SettingsToolTip {
            visible: tileHover.hovered && tile.detail.length > 0
            text: tile.detail
        }
    }

    // The screen in miniature, shaped like the one the notch lives on (its
    // proportions, and a stand or a laptop's base under it), with the notch
    // drawn where it sits. Click an edge to move the notch there; on its
    // edge, click or drag to slide it.
    component EdgePicker: Item {
        id: edgePicker

        readonly property var target: root.targetScreen
        readonly property bool laptop: target !== null && root.screenIcon(target.name) === "laptop"

        readonly property real bezel: 6
        readonly property real displayWidth: 300
        readonly property real displayHeight: target && target.width > 0 && target.height > 0
            ? Math.max(140, Math.min(220, displayWidth * target.height / target.width))
            : 188
        readonly property real lidWidth: displayWidth + 2 * bezel
        readonly property real lidHeight: displayHeight + 2 * bezel
        readonly property real standHeight: laptop ? 8 : 20

        readonly property real band: 26                 // hit area along each edge
        readonly property real pill: 40 * Theme.scaleFor(Engine.sizePreset)
        readonly property real notchDepth: 9
        readonly property real notchCurl: 6
        property real livePosition: Engine.edgePosition
        property bool dragging: false
        property string hoverEdge: ""

        implicitWidth: laptop ? lidWidth + 32 : lidWidth
        implicitHeight: lidHeight + standHeight

        // A monitor stands on a neck and a foot; a laptop sits on its base.
        Rectangle {
            visible: !edgePicker.laptop
            anchors.horizontalCenter: lid.horizontalCenter
            y: edgePicker.lidHeight - 1
            width: 30
            height: 14
            color: "#1E1E24"
        }
        Rectangle {
            visible: !edgePicker.laptop
            anchors.horizontalCenter: lid.horizontalCenter
            y: edgePicker.lidHeight + 12
            width: 84
            height: 6
            radius: 3
            color: "#2A2A31"
        }
        Rectangle {
            visible: edgePicker.laptop
            x: 0
            y: edgePicker.lidHeight - 1
            width: parent.width
            height: 9
            radius: 4.5
            gradient: Gradient {
                GradientStop { position: 0; color: "#3A3A42" }
                GradientStop { position: 1; color: "#202026" }
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 40
                height: 3
                radius: 1.5
                color: "#1E1E24"
            }
        }

        Rectangle {
            id: lid
            anchors.horizontalCenter: parent.horizontalCenter
            width: edgePicker.lidWidth
            height: edgePicker.lidHeight
            radius: 16
            color: "#050506"
            border.width: 1
            border.color: Theme.cardStroke

            Rectangle {
                id: display
                x: edgePicker.bezel
                y: edgePicker.bezel
                width: edgePicker.displayWidth
                height: edgePicker.displayHeight
                radius: 11
                gradient: Gradient {
                    GradientStop { position: 0; color: "#2C303C" }
                    GradientStop { position: 1; color: "#17181E" }
                }

                // Where the notch sits on an edge, from a position along it.
                function notchAt(edge, pos) {
                    const vertical = edge === "left" || edge === "right"
                    const len = vertical ? height : width
                    const c = edgePicker.notchCurl, p = edgePicker.pill, d = edgePicker.notchDepth
                    const start = 8 + pos * (len - p - 2 * c - 16)      // where its curl begins
                    if (edge === "left") return Qt.point(0, start)
                    if (edge === "right") return Qt.point(width - d, start)
                    if (edge === "top") return Qt.point(start, 0)
                    return Qt.point(start, height - d)
                }
                function positionAt(edge, x, y) {
                    const vertical = edge === "left" || edge === "right"
                    const len = vertical ? height : width
                    const c = edgePicker.notchCurl, p = edgePicker.pill
                    const pos = ((vertical ? y : x) - 8 - c - p / 2) / (len - p - 2 * c - 16)
                    return Math.max(0, Math.min(1, pos))
                }

                // A ghost of the notch on the hovered edge.
                NotchShape {
                    readonly property point at: display.notchAt(edge, 0.5)
                    visible: edgePicker.hoverEdge !== "" && edgePicker.hoverEdge !== Engine.edge
                    edge: edgePicker.hoverEdge !== "" ? edgePicker.hoverEdge : "top"
                    length: edgePicker.pill
                    depth: edgePicker.notchDepth
                    curl: edgePicker.notchCurl
                    radius: edgePicker.notchDepth / 2
                    color: "#4DFFFFFF"
                    x: at.x
                    y: at.y
                }
                // The notch itself, in its own colour, fused to the bezel.
                NotchShape {
                    readonly property point at: display.notchAt(Engine.edge, edgePicker.livePosition)
                    edge: Engine.edge
                    length: edgePicker.pill
                    depth: edgePicker.notchDepth
                    curl: edgePicker.notchCurl
                    radius: edgePicker.notchDepth / 2
                    color: Engine.notchColor
                    x: at.x
                    y: at.y
                    Behavior on x { enabled: !edgePicker.dragging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on y { enabled: !edgePicker.dragging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
                Text {
                    anchors.centerIn: parent
                    text: Math.round(edgePicker.livePosition * 100) + "%"
                    color: Theme.textSecondary
                    font.pixelSize: 12
                    font.family: "monospace"
                    opacity: edgePicker.dragging ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                Repeater {
                    model: [
                        { edge: "left", tip: "Left edge" },
                        { edge: "right", tip: "Right edge" },
                        { edge: "top", tip: "Top edge" },
                        { edge: "bottom", tip: "Bottom edge" }
                    ]
                    delegate: MouseArea {
                        id: zone
                        required property var modelData
                        readonly property string edge: modelData.edge
                        readonly property bool vertical: edge === "left" || edge === "right"

                        x: edge === "right" ? display.width - edgePicker.band : vertical ? 0 : edgePicker.band
                        y: edge === "bottom" ? display.height - edgePicker.band : vertical ? edgePicker.band * 0.6 : 0
                        width: vertical ? edgePicker.band : display.width - 2 * edgePicker.band
                        height: vertical ? display.height - 1.2 * edgePicker.band : edgePicker.band
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true

                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.tip
                        Accessible.checked: edge === Engine.edge

                        onContainsMouseChanged: edgePicker.hoverEdge = containsMouse ? edge : (edgePicker.hoverEdge === edge ? "" : edgePicker.hoverEdge)
                        onPressed: (mouse) => {
                            if (edge !== Engine.edge) return
                            edgePicker.dragging = true
                            edgePicker.livePosition = display.positionAt(edge, mouse.x + x, mouse.y + y)
                        }
                        onPositionChanged: (mouse) => {
                            if (edgePicker.dragging)
                                edgePicker.livePosition = display.positionAt(edge, mouse.x + x, mouse.y + y)
                        }
                        onReleased: {
                            if (edge !== Engine.edge) {
                                Engine.setEdge(edge)
                                return
                            }
                            edgePicker.dragging = false
                            // Saving refetches every provider, so commit on release.
                            Engine.setEdgePosition(edgePicker.livePosition)
                        }

                        SettingsToolTip {
                            visible: zone.containsMouse && !edgePicker.dragging
                            text: zone.edge === Engine.edge ? "Click or drag to slide the notch along this edge"
                                                            : zone.modelData.tip
                        }
                    }
                }
            }
        }

        Connections {
            target: Engine
            function onConfigChanged() {
                if (!edgePicker.dragging) edgePicker.livePosition = Engine.edgePosition
            }
        }
    }

    // One motion for the nub, played on a sliver of screen edge so the tile
    // shows what it does; its name sits under it and the detail in the tip.
    component MotionTile: Rectangle {
        id: motionTile
        property var option: ({})              // one of NubMotion.styles
        property bool chosen: false
        property bool enabled_: true
        signal picked()

        readonly property color ink: chosen ? Theme.text : Theme.textSecondary

        height: 66
        radius: 10
        color: chosen ? Theme.controlChosen
             : motionHover.hovered && enabled_ ? Theme.panelHover : Theme.controlFill
        border.width: chosen ? 1 : 0
        border.color: "#40FFFFFF"
        opacity: enabled_ ? 1 : 0.45
        Behavior on color { ColorAnimation { duration: 120 } }

        Accessible.role: Accessible.RadioButton
        Accessible.name: option.label || ""
        Accessible.description: option.tip || ""
        Accessible.checked: chosen

        NubMotion {
            id: tileMotion
            style: motionTile.option.value || "none"
            active: motionTile.enabled_
            unit: 1.3
        }
        // The edge of the screen, and the nub hanging from it.
        Rectangle {
            x: 8
            y: 12
            width: parent.width - 16
            height: 1
            color: Theme.track
        }
        NotchShape {
            readonly property real centre: motionTile.width / 2 + tileMotion.along
            edge: "top"
            length: 22 * tileMotion.lengthScale
            depth: 7 * tileMotion.depthScale
            wave: tileMotion.wave * depth
            wavePhase: tileMotion.wavePhase
            curl: depth / 2
            radius: depth / 2
            color: Qt.rgba(motionTile.ink.r, motionTile.ink.g, motionTile.ink.b, tileMotion.fade)
            x: centre - length / 2 - curl
            y: 12
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 9
            text: motionTile.option.label || ""
            color: motionTile.ink
            font.pixelSize: 11
            font.weight: motionTile.chosen ? Font.DemiBold : Font.Normal
        }

        HoverHandler {
            id: motionHover
            cursorShape: motionTile.enabled_ ? Qt.PointingHandCursor : Qt.ForbiddenCursor
        }
        TapHandler {
            enabled: motionTile.enabled_
            onTapped: motionTile.picked()
        }
        SettingsToolTip {
            visible: motionHover.hovered && !!motionTile.option.tip
            text: motionTile.option.tip || ""
        }
    }

    // Every motion, side by side, each playing; the chosen one raised.
    component MotionPicker: Item {
        id: motionPicker
        property string value: ""
        property bool enabled_: true
        signal picked(string value)

        width: parent.width
        height: tiles.height

        NubMotion { id: catalogue }
        Row {
            id: tiles
            width: parent.width
            spacing: 6

            Repeater {
                model: catalogue.styles
                delegate: MotionTile {
                    required property var modelData
                    width: (tiles.width - tiles.spacing * (catalogue.styles.length - 1))
                           / catalogue.styles.length
                    option: modelData
                    chosen: modelData.value === motionPicker.value
                    enabled_: motionPicker.enabled_
                    onPicked: motionPicker.picked(modelData.value)
                }
            }
        }
    }

    // A sound for one alert: a menu of the theme's sounds, and a button to
    // hear the chosen one. Picking a sound plays it too.
    component SoundPicker: Item {
        id: soundPicker
        property string value: ""
        property bool enabled_: true
        signal picked(string name)

        width: parent.width
        height: 34
        opacity: enabled_ ? 1 : 0.45

        Rectangle {
            id: menuButton
            anchors.left: parent.left
            anchors.right: playButton.left
            anchors.rightMargin: 8
            height: parent.height
            radius: 9
            color: menuHover.hovered && soundPicker.enabled_ ? Theme.panelHover : Theme.controlFill
            Behavior on color { ColorAnimation { duration: 120 } }

            Accessible.role: Accessible.ComboBox
            Accessible.name: root.soundLabel(soundPicker.value)

            SettingsIcon {
                id: soundIcon
                x: 11
                anchors.verticalCenter: parent.verticalCenter
                width: 15
                height: 15
                name: "volume"
                color: Theme.textSecondary
            }
            Text {
                anchors.left: soundIcon.right
                anchors.leftMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                text: root.soundLabel(soundPicker.value)
                color: Theme.text
                font.pixelSize: 13
            }
            SettingsIcon {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                height: 14
                name: "chevron-down"
                color: Theme.textSecondary
                rotation: menu.visible ? 180 : 0
                Behavior on rotation { NumberAnimation { duration: 140 } }
            }
            HoverHandler {
                id: menuHover
                cursorShape: soundPicker.enabled_ ? Qt.PointingHandCursor : Qt.ForbiddenCursor
            }
            TapHandler {
                enabled: soundPicker.enabled_
                onTapped: menu.open()
            }
        }
        SettingsButton {
            id: playButton
            anchors.right: parent.right
            icon: "play"
            tip: "Preview"
            enabled_: soundPicker.enabled_
            onClicked: Notify.playSound(soundPicker.value)
        }

        Popup {
            id: menu
            y: menuButton.height + 4
            width: menuButton.width
            padding: 4
            background: Rectangle {
                radius: 10
                color: "#1E1E24"
                border.width: 1
                border.color: Theme.cardStroke
            }
            enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 100 } }
            contentItem: Column {
                Repeater {
                    model: Notify.sounds
                    delegate: Rectangle {
                        id: option
                        required property var modelData
                        readonly property bool chosen: modelData.name === soundPicker.value

                        width: menu.availableWidth
                        height: 30
                        radius: 7
                        color: optionHover.hovered ? Theme.panelHover : "transparent"

                        SettingsIcon {
                            id: optionIcon
                            x: 9
                            anchors.verticalCenter: parent.verticalCenter
                            width: 13
                            height: 13
                            strokeWidth: 2.6
                            name: option.chosen ? "check" : optionHover.hovered ? "play" : ""
                            color: Theme.text
                        }
                        Text {
                            anchors.left: optionIcon.right
                            anchors.leftMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            text: option.modelData.label
                            color: option.chosen || optionHover.hovered ? Theme.text : Theme.textSecondary
                            font.pixelSize: 13
                            font.weight: option.chosen ? Font.DemiBold : Font.Normal
                        }
                        HoverHandler {
                            id: optionHover
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            onTapped: {
                                soundPicker.picked(option.modelData.name)
                                Notify.playSound(option.modelData.name)
                                menu.close()
                            }
                        }
                    }
                }
            }
        }
    }

    // A provider: its mark, name, how much of its limit is gone, and a switch.
    component ProviderCard: Rectangle {
        id: card
        required property var modelData
        readonly property var state_: root.providerState(modelData.id, modelData.enabled)

        height: 62
        radius: 12
        color: Theme.panelRaised

        ProviderGlyph {
            id: glyph
            x: 16
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            height: 22
            provider: card.modelData.id
            color: card.modelData.enabled ? Theme.text : Theme.textTertiary
        }
        Column {
            anchors.left: glyph.right
            anchors.leftMargin: 14
            anchors.right: toggle.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7

            Text {
                width: parent.width
                text: card.modelData.name
                color: card.modelData.enabled ? Theme.text : Theme.textSecondary
                font.pixelSize: 13
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            // Usage: a thin bar coloured by how close the limit is.
            Item {
                id: status
                width: parent.width
                height: 12

                Rectangle {
                    visible: card.state_.kind === "usage"
                    anchors.left: parent.left
                    anchors.right: pctText.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4
                    radius: 2
                    color: Theme.track
                    Rectangle {
                        width: parent.width * Math.min(1, (card.state_.pct || 0) / 100)
                        height: parent.height
                        radius: 2
                        color: Theme.usageColor(card.state_.pct || 0)
                        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                    }
                }
                Text {
                    id: pctText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: card.state_.kind === "usage"
                    text: card.state_.text
                    color: Theme.textSecondary
                    font.pixelSize: 11
                    font.family: "monospace"
                }
                Text {
                    visible: card.state_.kind !== "usage"
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    text: card.state_.text
                    color: card.state_.kind === "error" ? Theme.critical : Theme.textTertiary
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
                HoverHandler { id: statusHover }
                SettingsToolTip {
                    visible: statusHover.hovered && card.state_.detail.length > 0
                    text: card.state_.detail
                }
            }
        }
        SettingsToggle {
            id: toggle
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            checked: card.modelData.enabled
            accessibleName: card.modelData.name
            onToggled: (checked) => Engine.setProviderEnabled(card.modelData.id, checked)
        }
    }

    // ---- Sidebar ----

    Rectangle {
        id: sidebar
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        width: 196
        color: Theme.panel

        Column {
            id: brand
            x: 20
            y: 22
            width: parent.width - 40
            spacing: 6

            Row {
                spacing: 6
                Text {
                    id: appName
                    text: "Omega Notch"
                    color: Theme.text
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.baseline: appName.baseline
                    text: Qt.application.version
                    color: Theme.textTertiary
                    font.pixelSize: 11
                }
            }
            // Engine state: a dot, with the words in the tooltip.
            Row {
                spacing: 6
                Rectangle {
                    width: 7; height: 7; radius: 3.5
                    anchors.verticalCenter: parent.verticalCenter
                    color: Engine.connected ? Theme.ample : Theme.critical

                    SequentialAnimation on opacity {
                        running: !Engine.connected
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 700 }
                        NumberAnimation { to: 1; duration: 700 }
                    }
                }
                Text {
                    text: Engine.connected ? "Connected" : "Engine offline"
                    color: Theme.textSecondary
                    font.pixelSize: 11
                }
            }
        }

        Column {
            anchors.top: brand.bottom
            anchors.topMargin: 24
            x: 10
            width: parent.width - 20
            spacing: 2

            Repeater {
                model: root.tabs
                delegate: Rectangle {
                    id: nav
                    required property var modelData
                    readonly property bool chosen: modelData.id === root.tab

                    width: parent.width
                    height: 38
                    radius: 9
                    color: chosen ? Theme.controlChosen : navHover.hovered ? Theme.controlHover : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.label
                    Accessible.checked: chosen

                    SettingsIcon {
                        id: navIcon
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 17
                        height: 17
                        name: nav.modelData.icon
                        color: nav.chosen ? Theme.text : Theme.textSecondary
                    }
                    Text {
                        anchors.left: navIcon.right
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        text: nav.modelData.label
                        color: nav.chosen || navHover.hovered ? Theme.text : Theme.textSecondary
                        font.pixelSize: 13
                        font.weight: nav.chosen ? Font.DemiBold : Font.Normal
                    }
                    HoverHandler {
                        id: navHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: root.tab = nav.modelData.id
                    }
                }
            }
        }

        Row {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 16
            x: 10
            spacing: 8

            SettingsButton {
                width: sidebar.width - 20 - 34 - 8
                icon: "refresh"
                text: "Refresh"
                tip: "Fetch every provider's usage now"
                enabled_: Engine.connected
                onClicked: Engine.refresh("")
            }
            SettingsButton {
                icon: "power"
                tip: "Quit Omega Notch"
                destructive: true
                onClicked: Qt.quit()
            }
        }

        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Theme.hairline
        }
    }

    // ---- The chosen tab ----

    Flickable {
        id: pane
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: sidebar.right
        anchors.right: parent.right
        contentWidth: width
        contentHeight: page.implicitHeight + 44
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Connections {
            target: root
            function onTabChanged() { pane.contentY = 0 }
        }

        Column {
            id: page
            x: 22
            y: 22
            width: parent.width - 44
            spacing: 12

            // Placement
            Card {
                visible: root.tab === "placement"
                heading: "Screen"

                Flow {
                    width: parent.width
                    spacing: 8
                    topPadding: 4
                    bottomPadding: 8

                    ScreenTile {
                        title: "Primary"
                        icon: "star"
                        detail: "Follows whichever screen is primary"
                        chosen: Engine.screenName === ""
                        onPicked: Engine.setScreenName("")
                    }
                    Repeater {
                        model: Engine.screens
                        delegate: ScreenTile {
                            required property var modelData
                            title: modelData.name
                            icon: root.screenIcon(modelData.name)
                            detail: root.screenDetail(modelData)
                            chosen: modelData.name === Engine.screenName
                            onPicked: Engine.setScreenName(modelData.name)
                        }
                    }
                    ScreenTile {
                        visible: root.chosenScreenMissing
                        interactive: false
                        title: Engine.screenName
                        icon: "plug-off"
                        badge: "Not connected"
                        badgeColor: Theme.watch
                        detail: "Not plugged in. The notch stays on the primary screen until it is"
                        chosen: true
                    }
                }
            }
            Card {
                visible: root.tab === "placement"
                heading: "On screen"

                Item {
                    width: parent.width
                    height: edgePicker.implicitHeight + 20

                    EdgePicker {
                        id: edgePicker
                        y: 8
                    }
                    Column {
                        anchors.left: edgePicker.right
                        anchors.leftMargin: 28
                        anchors.right: parent.right
                        anchors.verticalCenter: edgePicker.verticalCenter
                        spacing: 16

                        Column {
                            width: parent.width
                            spacing: 6
                            Row {
                                spacing: 8
                                SettingsIcon { width: 15; height: 15; name: "maximize"; color: Theme.textSecondary; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: "Size"; color: Theme.textSecondary; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                            }
                            SettingsSegmented {
                                width: parent.width
                                value: Engine.sizePreset
                                options: [
                                    { value: "small", icon: "ring-s", tip: "Small" },
                                    { value: "medium", icon: "ring-m", tip: "Medium" },
                                    { value: "large", icon: "ring-l", tip: "Large" }
                                ]
                                onPicked: (value) => Engine.setSizePreset(value)
                            }
                        }
                        Row {
                            spacing: 8
                            SettingsButton {
                                icon: "target"
                                text: "Recentre"
                                tip: "Put the notch in the middle of its edge"
                                onClicked: Engine.setEdgePosition(0.5)
                            }
                            InfoTip {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Click an edge of the little screen to move the notch there, or drag it along its edge. You can also drag the grip under the rings."
                            }
                        }
                    }
                }
            }

            // Notch
            Card {
                visible: root.tab === "notch"
                heading: "Behaviour"

                FormRow {
                    divider: false
                    icon: "eye-off"
                    title: "Hide when idle"
                    hint: "Tucked behind a small nub until a session finishes or the pointer touches its edge"

                    SettingsToggle {
                        anchors.right: parent.right
                        checked: Engine.autoHide
                        accessibleName: "Hide when idle"
                        onToggled: (checked) => Engine.setAutoHide(checked)
                    }
                }
                FormRow {
                    visible: Engine.autoHide
                    icon: "maximize"
                    title: "Nub size"
                    hint: "How big the nub is while the notch hides"

                    Item {
                        width: parent.width
                        height: 34

                        SettingsSlider {
                            anchors.left: parent.left
                            anchors.right: idleSizeReset.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            from: 1
                            to: 3
                            stepSize: 0.25
                            value: Engine.idleSize
                            onPressedChanged: if (!pressed) Engine.setIdleSize(value)
                        }
                        SettingsButton {
                            id: idleSizeReset
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            icon: "reset"
                            tip: "Back to the smallest"
                            onClicked: Engine.setIdleSize(1)
                        }
                    }
                }
                FormRow {
                    icon: "layers"
                    title: "Rings at once"
                    hint: "How many providers the notch shows. Working ones come first, then the most recent; scroll on the notch for the rest."

                    SettingsSegmented {
                        width: parent.width
                        value: String(Engine.maxProviders)
                        options: [1, 2, 3, 4, 5].map(n => ({
                            value: String(n),
                            dots: n,
                            tip: n === 1 ? "1 provider" : n + " providers"
                        }))
                        onPicked: (value) => Engine.setMaxProviders(parseInt(value))
                    }
                }
            }
            Card {
                visible: root.tab === "notch"
                heading: "Colours"

                FormRow {
                    divider: false
                    icon: "droplet"
                    title: "Notch"

                    ColorPicker {
                        value: Engine.notchColor
                        onPicked: (color) => Engine.setNotchColor(color)
                    }
                }
                FormRow {
                    icon: "moon"
                    title: "Nub"
                    hint: Engine.autoHide ? "The colour of the nub while the notch hides"
                                          : "Used only while Hide when idle is on"

                    ColorPicker {
                        enabled_: Engine.autoHide
                        value: Engine.idleColor
                        onPicked: (color) => Engine.setIdleColor(color)
                    }
                }
            }
            Card {
                visible: root.tab === "notch"
                heading: "Nub motion"

                FormRow {
                    divider: false
                    icon: "activity"
                    title: "While working"
                    hint: Engine.autoHide ? "How the nub moves while an agent is working"
                                          : "Used only while Hide when idle is on"

                    MotionPicker {
                        enabled_: Engine.autoHide
                        value: Engine.nubWorking
                        onPicked: (value) => Engine.setNubWorking(value)
                    }
                }
                FormRow {
                    icon: "message"
                    title: "Needs you"
                    hint: Engine.autoHide ? "How the nub moves while a session waits for your answer. It takes over from the working one."
                                          : "Used only while Hide when idle is on"

                    MotionPicker {
                        enabled_: Engine.autoHide
                        value: Engine.nubWaiting
                        onPicked: (value) => Engine.setNubWaiting(value)
                    }
                }
            }

            // Providers
            Grid {
                id: providerGrid
                visible: root.tab === "providers"
                width: parent.width
                columns: 2
                columnSpacing: 10
                rowSpacing: 10

                Repeater {
                    model: root.providers
                    delegate: ProviderCard {
                        width: (providerGrid.width - providerGrid.columnSpacing) / 2
                    }
                }
            }
            Card {
                visible: root.tab === "providers" && copilot.visible
                heading: "GitHub Copilot"

                CopilotSignIn {
                    id: copilot
                    width: parent.width
                }
            }

            // Alerts
            Card {
                visible: root.tab === "alerts"

                FormRow {
                    divider: false
                    icon: "bell"
                    title: "Notifications"
                    hint: "A notification when a session finishes or stops to ask you something"

                    SettingsToggle {
                        anchors.right: parent.right
                        checked: Engine.alertsEnabled
                        accessibleName: "Notifications"
                        onToggled: (checked) => Engine.setAlertsEnabled(checked)
                    }
                }
                FormRow {
                    icon: "volume"
                    title: "Sound"
                    hint: Engine.alertsEnabled ? "Play a sound with each notification"
                                               : "Notifications are off, so no sound plays"

                    SettingsToggle {
                        anchors.right: parent.right
                        enabled_: Engine.alertsEnabled
                        checked: Engine.soundEnabled
                        accessibleName: "Sound"
                        onToggled: (checked) => Engine.setSoundEnabled(checked)
                    }
                }
                // The rows keep their places: the per-alert switches are added
                // under the one that asks for them, and the single switch
                // steps aside.
                FormRow {
                    icon: "notch"
                    title: "Open the notch"
                    hint: Engine.openNotchSplit ? "Set for each alert below"
                        : Engine.alertsEnabled ? "For a few seconds, on the session that finished or needs you"
                                               : "Notifications are off, so the notch stays as it is"

                    SettingsToggle {
                        anchors.right: parent.right
                        enabled_: Engine.alertsEnabled && !Engine.openNotchSplit
                        checked: Engine.openNotchOnAlert
                        accessibleName: "Open the notch"
                        onToggled: (checked) => Engine.setOpenNotchOnAlert(checked)
                    }
                }
                FormRow {
                    icon: "layers"
                    title: "Separately for each alert"
                    hint: "Choose for finished and for needs-you on their own"

                    SettingsToggle {
                        anchors.right: parent.right
                        enabled_: Engine.alertsEnabled
                        checked: Engine.openNotchSplit
                        accessibleName: "Separately for each alert"
                        onToggled: (checked) => Engine.setOpenNotchSplit(checked)
                    }
                }
                FormRow {
                    visible: Engine.openNotchSplit
                    icon: "check-circle"
                    title: "When a session finishes"

                    SettingsToggle {
                        anchors.right: parent.right
                        enabled_: Engine.alertsEnabled
                        checked: Engine.openNotchFinished
                        accessibleName: "Open the notch when a session finishes"
                        onToggled: (checked) => Engine.setOpenNotchFinished(checked)
                    }
                }
                FormRow {
                    visible: Engine.openNotchSplit
                    icon: "message"
                    title: "When a session needs you"

                    SettingsToggle {
                        anchors.right: parent.right
                        enabled_: Engine.alertsEnabled
                        checked: Engine.openNotchWaiting
                        accessibleName: "Open the notch when a session needs you"
                        onToggled: (checked) => Engine.setOpenNotchWaiting(checked)
                    }
                }
            }
            Card {
                visible: root.tab === "alerts"
                heading: "Sounds"

                FormRow {
                    divider: false
                    icon: "check-circle"
                    title: "Finished"
                    hint: "Plays when a session is done"

                    SoundPicker {
                        enabled_: Engine.alertsEnabled && Engine.soundEnabled
                        value: root.effectiveSound(Engine.soundFinished, "completion-success")
                        onPicked: (name) => Engine.setSoundFinished(name)
                    }
                }
                FormRow {
                    icon: "message"
                    title: "Needs you"
                    hint: "Plays when a session stops to ask you something"

                    SoundPicker {
                        enabled_: Engine.alertsEnabled && Engine.soundEnabled
                        value: root.effectiveSound(Engine.soundWaiting, "message-attention")
                        onPicked: (name) => Engine.setSoundWaiting(name)
                    }
                }
            }
        }
    }
}
