import QtQuick
import OmegaNotch

// One click to sign in to GitHub Copilot: the engine asks GitHub for a code,
// which lands on the clipboard while the GitHub page opens, so signing in is
// a paste and a confirm. Shown only while Copilot has no working sign-in.
Column {
    id: root

    readonly property var login: Engine.copilotLogin
    readonly property string state_: login.state || ""
    readonly property bool needsAuth: {
        const list = Engine.readings
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === "copilot")
                return list[i].status === "needs_auth"
        }
        return false
    }

    function providerEnabled(id) {
        const list = Engine.providers
        for (let i = 0; i < list.length; ++i) {
            if (list[i].id === id)
                return list[i].enabled
        }
        return true
    }

    visible: providerEnabled("copilot")
             && (needsAuth || state_ === "starting" || state_ === "pending" || state_ === "failed")
    spacing: 8
    topPadding: 2
    bottomPadding: 6

    Text {
        width: parent.width
        visible: root.state_ === "failed"
        text: root.login.message || "Sign-in failed"
        color: Theme.critical
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }

    SettingsButton {
        visible: root.state_ !== "pending"
        text: root.state_ === "starting" ? "Asking GitHub for a code…" : "Sign in to GitHub Copilot"
        enabled_: Engine.connected && root.state_ !== "starting"
        onClicked: Engine.copilotSignIn()
    }

    Rectangle {
        visible: root.state_ === "pending"
        width: parent.width
        height: pending.implicitHeight + 24
        radius: 10
        color: Theme.panelHover

        Column {
            id: pending
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 10

            Text {
                width: parent.width
                text: "Paste this code on the GitHub page that just opened — it is already copied."
                color: Theme.textSecondary
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
            Text {
                text: root.login.user_code || ""
                color: Theme.text
                font.pixelSize: 22
                font.weight: Font.DemiBold
                font.letterSpacing: 2
                font.family: "monospace"
            }
            Row {
                spacing: 8
                SettingsButton {
                    text: "Open GitHub"
                    onClicked: Engine.openCopilotVerification()
                }
                SettingsButton {
                    text: "Copy code"
                    onClicked: Engine.copyCopilotCode()
                }
            }
        }
    }
}
