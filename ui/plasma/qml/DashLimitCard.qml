import QtQuick
import OmegaNotch

// One tool's limits: a ring for the headline window, then every window with
// its bar and reset time. Click refreshes the tool.
Rectangle {
    id: root

    property var reading
    property var session: null
    property real now: Date.now()
    property int windowSlots: 1        // rows to reserve so a row of cards lines up

    readonly property string status: reading ? (reading.status || "ok") : "offline"
    readonly property var windows: reading && reading.windows ? reading.windows : []
    readonly property bool hasData: windows.length > 0 && (status === "ok" || status === "stale")
    // The ring shows the tightest window: the one that will stop you first.
    readonly property int tightest: {
        let best = 0
        for (let i = 1; i < windows.length; ++i) {
            if ((Number(windows[i].used_pct) || 0) > (Number(windows[best].used_pct) || 0))
                best = i
        }
        return best
    }
    readonly property real headline: hasData ? (Number(windows[tightest].used_pct) || 0) : -1
    readonly property string verdict: headline < 0 ? ""
        : headline >= Theme.criticalAt ? "Almost out"
        : headline >= Theme.watchAt ? "Getting close" : "Plenty left"
    readonly property string sessionKind: session ? session.kind : "idle"

    // "Checked just now", "Checked 4m ago", "Checked 3 Oct".
    function checked(iso) {
        const a = Theme.ago(iso, now)
        if (a.length === 0) return ""
        if (a === "now") return "Checked just now"
        return "Checked " + a + (/^\d+[mhd]$/.test(a) ? " ago" : "")
    }

    readonly property var badge: {
        if (sessionKind === "waiting_you") return { text: "Needs you", color: Theme.waiting }
        if (sessionKind === "busy") return { text: "Working", color: Theme.text }
        if (status === "stale") return { text: "Stale", color: Theme.watch }
        if (status === "needs_auth") return { text: "Sign in", color: Theme.watch }
        if (status === "error") return { text: "Error", color: Theme.critical }
        return null
    }

    implicitHeight: 20 + 64 + 16 + windowSlots * 40 + 12
    radius: 12
    color: cardHover.hovered ? Theme.panelHover : Theme.panelRaised
    border.width: 1
    border.color: Theme.cardStroke
    Behavior on color { ColorAnimation { duration: 120 } }

    // The top edge catches the light, like the other cards.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
            GradientStop { position: 0; color: Theme.withAlpha("#FFFFFF", 0.09) }
            GradientStop { position: 0.16; color: "transparent" }
        }
    }

    Accessible.role: Accessible.Button
    Accessible.name: (reading ? reading.display_name : "") + ", "
                     + (hasData ? Math.round(headline) + "% used" : "no data") + ". Refresh"

    HoverHandler {
        id: cardHover
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        onTapped: if (root.reading) Engine.refresh(root.reading.provider)
    }

    // Header: ring, name, headline window.
    DashRing {
        id: ring
        x: 20
        y: 20
        width: 64
        height: 64
        pct: root.headline
    }

    Column {
        anchors.left: ring.right
        anchors.leftMargin: 16
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.verticalCenter: ring.verticalCenter
        spacing: 4

        Item {
            width: parent.width
            height: 20
            ProviderGlyph {
                id: glyph
                width: 16
                height: 16
                anchors.verticalCenter: parent.verticalCenter
                provider: root.reading ? root.reading.provider : ""
            }
            Text {
                anchors.left: glyph.right
                anchors.leftMargin: 8
                anchors.right: badgePill.visible ? badgePill.left : parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: root.reading ? (root.reading.display_name || root.reading.provider) : ""
                color: Theme.text
                font.pixelSize: 14
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Rectangle {
                id: badgePill
                visible: root.badge !== null
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                height: 20
                width: badgeText.implicitWidth + 16
                radius: 10
                color: Qt.rgba(badgeText.color.r, badgeText.color.g, badgeText.color.b, 0.12)
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: root.badge ? root.badge.text : ""
                    color: root.badge ? root.badge.color : Theme.text
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }
            }
        }
        Text {
            width: parent.width
            text: root.hasData
                  ? root.verdict + (root.windows.length > 1 ? " · " + (root.windows[root.tightest].label || "Usage").toLowerCase() : "")
                  : ""
            visible: text.length > 0
            color: Theme.usageColor(root.headline)
            font.weight: Font.Medium
            font.pixelSize: 12
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: root.hasData
                  ? root.checked(root.reading.fetched_at)
                  : (root.reading && root.reading.message) || "No limits reported"
            color: root.status === "error" ? Theme.critical : Theme.textTertiary
            font.pixelSize: 12
            font.features: { "tnum": 1 }
            elide: Text.ElideRight
            maximumLineCount: root.hasData ? 1 : 2
            wrapMode: root.hasData ? Text.NoWrap : Text.Wrap
        }
    }

    // Every window, headline included, as a labelled bar.
    Column {
        x: 20
        y: ring.y + ring.height + 16
        width: parent.width - 40
        spacing: 0

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.hairline
            visible: root.hasData
        }

        Repeater {
            model: root.hasData ? root.windows : []
            delegate: Item {
                required property var modelData
                readonly property real pct: Math.max(0, Math.min(100, Number(modelData.used_pct) || 0))
                width: parent.width
                height: 40

                Text {
                    id: wLabel
                    y: 10
                    text: modelData.label || "Usage"
                    color: Theme.textSecondary
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    width: parent.width - wPct.implicitWidth - wReset.implicitWidth - 24
                }
                Text {
                    id: wReset
                    anchors.right: wPct.left
                    anchors.rightMargin: 12
                    anchors.baseline: wLabel.baseline
                    text: Theme.resetsIn(modelData.resets_at, root.now).replace("Resets ", "")
                    color: Theme.textTertiary
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                }
                Text {
                    id: wPct
                    anchors.right: parent.right
                    anchors.baseline: wLabel.baseline
                    text: Math.round(parent.pct) + "%"
                    color: Theme.text
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
                Rectangle {
                    y: 30
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Theme.track
                    Rectangle {
                        width: parent.width * parent.parent.pct / 100
                        height: parent.height
                        radius: 2
                        color: Theme.usageColor(parent.parent.pct)
                        Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
    }
}
