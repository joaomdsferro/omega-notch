import QtQuick
import QtQuick.Controls
import QtQuick.Window
import OmegaNotch

Window {
    id: root
    title: "Omega Notch Settings"
    width: 440
    height: Math.min(Screen.desktopAvailableHeight - 80, page.implicitHeight + 48)
    minimumWidth: 400
    minimumHeight: 360
    visible: true
    color: Theme.panel

    signal requestClose()

    onClosing: (close) => {
        root.requestClose()
    }

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

    // What a provider's row says under its name.
    function summary(provider, enabled) {
        if (!enabled) return "Off"
        const r = readingFor(provider)
        if (!r) return Engine.connected ? "Waiting for the first reading…" : "Engine offline"
        if (r.status === "needs_auth" || r.status === "error") return r.message || "Unavailable"
        if (!r.windows || r.windows.length === 0) return "No limits reported"
        const w = r.windows[0]
        return Math.round(w.used_pct || 0) + "% of " + (w.label || "usage").toLowerCase()
               + (r.status === "stale" ? " · stale" : "")
    }
    function summaryIsError(provider, enabled) {
        const r = readingFor(provider)
        return enabled && r !== null && r.status === "error"
    }

    component Section: Rectangle {
        default property alias content: body.data
        property string heading: ""

        width: parent.width
        height: body.implicitHeight + 28 + headingText.implicitHeight + 8
        radius: 14
        color: Theme.panelRaised

        Text {
            id: headingText
            x: 16
            y: 14
            text: parent.heading.toUpperCase()
            color: Theme.textSecondary
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.6
        }
        Column {
            id: body
            x: 16
            y: headingText.y + headingText.implicitHeight + 8
            width: parent.width - 32
            spacing: 6
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
            scale: slider.pressed ? 1.15 : 1
            Behavior on scale { NumberAnimation { duration: 100 } }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }

    // Swatches plus a hex field for any other colour.
    component ColorPicker: Item {
        id: picker
        property string value: "#000000"
        signal picked(string color)

        width: parent.width
        height: 34

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Repeater {
                model: root.idleColors
                delegate: Rectangle {
                    required property string modelData
                    readonly property bool chosen: modelData === picker.value

                    width: 24
                    height: 24
                    radius: 12
                    color: modelData
                    border.width: chosen ? 2 : 1
                    border.color: chosen ? Theme.text : Theme.cardStroke
                    scale: swatchHover.hovered ? 1.12 : 1
                    Behavior on scale { NumberAnimation { duration: 100 } }

                    HoverHandler {
                        id: swatchHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: picker.picked(modelData)
                    }
                }
            }
        }
        Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 92
            height: 32
            radius: 9
            color: "#14FFFFFF"
            border.width: 1
            border.color: hex.activeFocus ? Theme.text
                        : hex.acceptableInput ? "transparent" : Theme.critical

            TextInput {
                id: hex
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: picker.value
                color: Theme.text
                selectionColor: Theme.textTertiary
                selectByMouse: true
                font.pixelSize: 13
                font.family: "monospace"
                maximumLength: 7
                validator: RegularExpressionValidator {
                    regularExpression: /^#[0-9A-Fa-f]{6}$/
                }
                onTextEdited: if (acceptableInput) picker.picked(text)
                onEditingFinished: text = picker.value
            }
            HoverHandler { cursorShape: Qt.IBeamCursor }
        }
    }

    // One output per row; the chosen one carries a tick.
    component ScreenRow: Item {
        id: screenRow
        property string title: ""
        property string subtitle: ""
        property bool chosen: false
        signal picked()

        width: parent.width
        implicitHeight: Math.max(40, screenLabels.implicitHeight + 12)

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -8
            anchors.rightMargin: -8
            radius: 8
            color: screenRow.chosen ? "#1AFFFFFF" : screenHover.hovered ? Theme.panelHover : "transparent"
        }
        Column {
            id: screenLabels
            anchors.left: parent.left
            anchors.right: tick.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
                width: parent.width
                text: screenRow.title
                color: Theme.text
                font.pixelSize: 14
                font.weight: screenRow.chosen ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                visible: text.length > 0
                text: screenRow.subtitle
                color: Theme.textSecondary
                font.pixelSize: 12
                elide: Text.ElideRight
            }
        }
        Text {
            id: tick
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "✓"
            color: Theme.text
            font.pixelSize: 15
            opacity: screenRow.chosen ? 1 : 0
        }
        HoverHandler {
            id: screenHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: screenRow.picked()
        }
    }

    function screenSubtitle(screen) {
        const parts = []
        if (screen.model) parts.push(screen.model)
        parts.push(screen.width + "×" + screen.height)
        if (screen.primary) parts.push("primary")
        return parts.join(" · ")
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

    component FieldLabel: Text {
        color: Theme.textSecondary
        font.pixelSize: 12
        topPadding: 4
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: page.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: page
            x: 20
            y: 24
            width: parent.width - 40
            spacing: 14

            Item {
                width: parent.width
                height: 44

                Text {
                    id: appName
                    text: "Omega Notch"
                    color: Theme.text
                    font.pixelSize: 22
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.left: appName.right
                    anchors.leftMargin: 8
                    anchors.baseline: appName.baseline
                    text: "v" + Qt.application.version
                    color: Theme.textSecondary
                    font.pixelSize: 12
                }
                Row {
                    anchors.top: appName.bottom
                    anchors.topMargin: 4
                    spacing: 7
                    Rectangle {
                        width: 7; height: 7; radius: 3.5
                        anchors.verticalCenter: parent.verticalCenter
                        color: Engine.connected ? Theme.ample : Theme.critical
                    }
                    Text {
                        text: Engine.connected ? "Engine connected" : "Engine offline — waiting for it to start"
                        color: Theme.textSecondary
                        font.pixelSize: 12
                    }
                }
            }

            Section {
                heading: "Placement"

                FieldLabel { text: "Screen" }
                ScreenRow {
                    title: "Primary screen"
                    subtitle: "Follows whichever screen is primary"
                    chosen: Engine.screenName === ""
                    onPicked: Engine.setScreenName("")
                }
                Repeater {
                    model: Engine.screens
                    delegate: ScreenRow {
                        required property var modelData
                        title: modelData.name
                        subtitle: root.screenSubtitle(modelData)
                        chosen: modelData.name === Engine.screenName
                        onPicked: Engine.setScreenName(modelData.name)
                    }
                }
                ScreenRow {
                    visible: root.chosenScreenMissing
                    title: Engine.screenName
                    subtitle: "Not connected — on the primary screen until it is"
                    chosen: true
                }

                FieldLabel { text: "Screen edge" }
                SettingsSegmented {
                    width: parent.width
                    value: Engine.edge
                    options: [
                        { value: "left", label: "Left" },
                        { value: "right", label: "Right" },
                        { value: "top", label: "Top" },
                        { value: "bottom", label: "Bottom" }
                    ]
                    onPicked: (value) => Engine.setEdge(value)
                }

                FieldLabel { text: "Size" }
                SettingsSegmented {
                    width: parent.width
                    value: Engine.sizePreset
                    options: [
                        { value: "small", label: "Small" },
                        { value: "medium", label: "Medium" },
                        { value: "large", label: "Large" }
                    ]
                    onPicked: (value) => Engine.setSizePreset(value)
                }

                FieldLabel { text: "Position along the edge" }
                Item {
                    width: parent.width
                    height: 34

                    SettingsSlider {
                        anchors.left: parent.left
                        anchors.right: recentre.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        from: 0
                        to: 1
                        value: Engine.edgePosition
                        // Saving refetches every provider, so commit on release.
                        onPressedChanged: if (!pressed) Engine.setEdgePosition(value)
                    }
                    SettingsButton {
                        id: recentre
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Recentre"
                        onClicked: Engine.setEdgePosition(0.5)
                    }
                }
                Text {
                    width: parent.width
                    text: "Or drag the grip that appears under the rings."
                    color: Theme.textTertiary
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            Section {
                heading: "Notch"

                SettingsSwitch {
                    width: parent.width
                    title: "Hide when idle"
                    subtitle: Engine.autoHide
                        ? "Tucked away until a session finishes or the pointer touches its edge"
                        : "Always on screen"
                    checked: Engine.autoHide
                    onToggled: (checked) => Engine.setAutoHide(checked)
                }

                FieldLabel {
                    visible: Engine.autoHide
                    text: "Size when idle"
                }
                Item {
                    visible: Engine.autoHide
                    width: parent.width
                    height: 34

                    SettingsSlider {
                        anchors.left: parent.left
                        anchors.right: idleSizeReset.left
                        anchors.rightMargin: 12
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
                        text: "Reset"
                        onClicked: Engine.setIdleSize(1)
                    }
                }

                FieldLabel { text: "Notch colour" }
                ColorPicker {
                    value: Engine.notchColor
                    onPicked: (color) => Engine.setNotchColor(color)
                }

                FieldLabel {
                    visible: Engine.autoHide
                    text: "Nub colour when idle"
                }
                ColorPicker {
                    visible: Engine.autoHide
                    value: Engine.idleColor
                    onPicked: (color) => Engine.setIdleColor(color)
                }

                FieldLabel { text: "Providers shown at once" }
                SettingsSegmented {
                    width: parent.width
                    value: String(Engine.maxProviders)
                    options: [
                        { value: "1", label: "1" },
                        { value: "2", label: "2" },
                        { value: "3", label: "3" },
                        { value: "4", label: "4" },
                        { value: "5", label: "5" }
                    ]
                    onPicked: (value) => Engine.setMaxProviders(parseInt(value))
                }
                Text {
                    width: parent.width
                    text: "Working providers come first, then the most recently used. Scroll on the notch to bring up another."
                    color: Theme.textTertiary
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
            }

            Section {
                heading: "Providers"

                Repeater {
                    model: root.providers
                    delegate: SettingsSwitch {
                        required property var modelData
                        width: parent.width
                        provider: modelData.id
                        title: modelData.name
                        subtitle: root.summary(modelData.id, modelData.enabled)
                        subtitleIsError: root.summaryIsError(modelData.id, modelData.enabled)
                        checked: modelData.enabled
                        onToggled: (checked) => Engine.setProviderEnabled(modelData.id, checked)
                    }
                }

                CopilotSignIn {
                    width: parent.width
                }
            }

            Section {
                heading: "Alerts"

                SettingsSwitch {
                    width: parent.width
                    title: "Notify me"
                    subtitle: "When a session finishes or stops to ask you something"
                    checked: Engine.alertsEnabled
                    onToggled: (checked) => Engine.setAlertsEnabled(checked)
                }
                SettingsSwitch {
                    width: parent.width
                    title: "Play a sound"
                    subtitle: Engine.alertsEnabled ? "" : "Notifications are off"
                    checked: Engine.soundEnabled
                    onToggled: (checked) => Engine.setSoundEnabled(checked)
                }
            }

            Item {
                width: parent.width
                height: 34

                SettingsButton {
                    anchors.left: parent.left
                    text: "Refresh all now"
                    enabled_: Engine.connected
                    onClicked: Engine.refresh("")
                }
                SettingsButton {
                    anchors.right: parent.right
                    text: "Quit Omega Notch"
                    destructive: true
                    onClicked: Qt.quit()
                }
            }
        }
    }
}
