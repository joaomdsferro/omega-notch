import QtQuick
import QtQuick.Window
import org.kde.layershell 1.0 as LayerShell
import OmegaNotch

// The surface spans the whole screen edge and is transparent: the notch slides
// along it and the card opens beside it without the window ever moving. Only
// the notch and an open card take input; everywhere else the pointer falls
// through to the desktop (see `applyMask`).
//
// Unless told to stay, the notch tucks behind the edge, leaving a nub, until a
// session finishes or asks for you, or the pointer touches the edge where it
// lives. It shows as many providers as Settings allows: the ones working
// first, then the ones that moved last.
Window {
    id: root
    title: "Omega Notch"
    visible: true
    color: "transparent"
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus

    readonly property string edge: Engine.edge
    readonly property bool vertical: edge === "left" || edge === "right"
    readonly property real s: Theme.scaleFor(Engine.sizePreset)

    // ---- Notch metrics (medium preset, scaled by s, snapped to the pixel) ----
    readonly property real cellWidth: Theme.px(56 * s)        // room for tagged dual chip
    readonly property real cellHeight: Theme.px(72 * s)       // ring + gap + chip / %
    readonly property real cellAlong: vertical ? cellHeight : cellWidth
    readonly property real cellSpacing: Theme.px((vertical ? 20 : 22) * s)
    readonly property real padStart: Theme.px((vertical ? 24 : 26) * s)
    readonly property real padEnd: Theme.px((vertical ? 16 : 26) * s)
    readonly property real padAcross: Theme.px(14 * s)
    readonly property real depth: vertical ? Theme.px(72 * s)
                                          : cellHeight + padAcross + Theme.px(12 * s)
    readonly property real curl: Theme.px(34 * s)
    readonly property real footerLength: Theme.px(68 * s)
    readonly property real cardGap: Theme.px(19 * s)          // notch edge -> card, tail included

    readonly property var activeReadings: {
        const out = []
        const all = Engine.readings
        for (let i = 0; i < all.length; ++i) {
            if (all[i].status !== "disabled")
                out.push(all[i])
        }
        return out
    }
    // Painted apart from the nub, so either can stay black.
    readonly property color notchColor: Engine.notchColor
    // The nub's colour, as a colour the theme can measure against.
    readonly property color nubColor: Qt.color(Engine.idleColor)
    // A session is working somewhere, or waiting for you: the nub moves to
    // say so, each in the motion chosen in Settings.
    function anySession(kind) {
        const all = activeReadings
        for (let i = 0; i < all.length; ++i) {
            const session = sessionFor(all[i].provider)
            if (session !== null && session.kind === kind)
                return true
        }
        return false
    }
    readonly property bool working: anySession("busy")
    readonly property bool waiting: anySession("waiting_you")
    readonly property int cellCount: Math.max(1, shownReadings.length)
    readonly property real collapsedLength: padStart + cellCount * cellAlong
                                            + (cellCount - 1) * cellSpacing + padEnd
    readonly property real expandedLength: collapsedLength + footerLength
    readonly property bool expanded: notchHover.hovered || dragging || Engine.peekOpen
    property real bodyLength: expanded ? expandedLength : collapsedLength
    Behavior on bodyLength { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    // ---- Position along the edge ----
    property bool dragging: false
    property real dragPosition: 0.5
    readonly property real axisLength: vertical ? height : width
    // Travel is measured against the expanded length so that unfolding never
    // pushes the rings out from under the pointer.
    readonly property real travel: Math.max(0, axisLength - expandedLength - 2 * curl)
    readonly property real bodyStart: Theme.px(curl + (dragging ? dragPosition : Engine.edgePosition) * travel)

    width: vertical ? depth + cardGap + card.width + 40 : Screen.width
    height: vertical ? Screen.height : depth + cardGap + 660 * s

    LayerShell.Window.scope: "omega-notch"
    LayerShell.Window.layer: LayerShell.Window.LayerOverlay
    LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone
    LayerShell.Window.exclusionZone: -1
    LayerShell.Window.anchors: {
        const along = vertical
            ? LayerShell.Window.AnchorTop | LayerShell.Window.AnchorBottom
            : LayerShell.Window.AnchorLeft | LayerShell.Window.AnchorRight
        switch (edge) {
        case "left": return along | LayerShell.Window.AnchorLeft
        case "top": return along | LayerShell.Window.AnchorTop
        case "bottom": return along | LayerShell.Window.AnchorBottom
        default: return along | LayerShell.Window.AnchorRight
        }
    }

    // ---- Hiding ----
    readonly property bool wanted: !Engine.autoHide || edgeHover.hovered || dragging
                                   || Engine.peekOpen || previewIndex >= 0
    property bool revealed: true
    onWantedChanged: {
        if (wanted) {
            hideTimer.stop()
            revealed = true
        } else {
            hideTimer.restart()
        }
    }
    onRevealedChanged: if (!revealed) manualProvider = ""
    Timer {
        id: hideTimer
        interval: 450
        onTriggered: root.revealed = false
    }
    // How far the notch is pushed out past its edge.
    property real tuck: revealed ? 0 : depth + 2
    Behavior on tuck { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

    // ---- Input region ----
    // Hidden, only the nub's sliver of the edge listens for the pointer.
    readonly property real nubDepth: Theme.px(6 * s * Engine.idleSize)
    readonly property real maskDepth: revealed ? depth : nubDepth
    readonly property rect maskRect: vertical
        ? Qt.rect(edge === "right" ? width - maskDepth : 0, bodyStart - curl,
                  maskDepth, expandedLength + 2 * curl)
        : Qt.rect(bodyStart - curl, edge === "top" ? 0 : height - maskDepth,
                  expandedLength + 2 * curl, maskDepth)
    // The card where it rests, stretched back to the notch so the pointer can
    // cross over to it.
    readonly property rect cardMask: vertical
        ? Qt.rect(edge === "right" ? width - depth - cardGap - card.width : depth,
                  card.alongStart, card.width + cardGap, card.height)
        : Qt.rect(card.alongStart,
                  edge === "top" ? depth : height - depth - cardGap - card.height,
                  card.width, card.height + cardGap)
    onMaskRectChanged: applyMask()
    onCardMaskChanged: applyMask()
    onCardActiveChanged: applyMask()
    onVisibleChanged: applyMask()
    Component.onCompleted: {
        Engine.placeOnScreen(root)
        applyMask()
        if (Engine.previewProvider === "settings")
            settingsLoader.active = true
        // Shows itself once at launch, then tucks away.
        if (!wanted)
            hideTimer.restart()
    }
    function applyMask() {
        Engine.setInputRegion(root, cardActive ? [maskRect, cardMask] : [maskRect])
    }
    // The platform window may not exist yet on the first call.
    Timer { interval: 250; running: true; onTriggered: root.applyMask() }

    // ---- Per-provider lookups ----
    function sessionFor(provider) {
        const list = Engine.sessions
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === provider)
                return list[i]
        }
        return null
    }
    function chatsFor(provider) {
        const out = []
        const list = Engine.chats
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === provider)
                out.push(list[i])
        }
        return out
    }
    function unreadFor(provider) {
        let count = 0
        const list = Engine.chats
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === provider && list[i].unread)
                count += 1
        }
        return count
    }
    readonly property int unreadCount: {
        let count = 0
        for (let i = 0; i < activeReadings.length; ++i)
            count += unreadFor(activeReadings[i].provider)
        return count
    }
    function tokensFor(provider) {
        const list = Engine.tokens
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === provider)
                return list[i]
        }
        return null
    }
    function indexOfProvider(provider) {
        for (let i = 0; i < activeReadings.length; ++i) {
            if (activeReadings[i].provider === provider)
                return i
        }
        return -1
    }

    function readingFor(provider) {
        const i = indexOfProvider(provider)
        return i >= 0 ? activeReadings[i] : null
    }
    // Newest chat of a provider, in ms; 0 when it keeps none.
    function lastChatAt(provider) {
        let latest = 0
        const list = Engine.chats
        for (let i = 0; i < list.length; ++i) {
            if (list[i].provider === provider)
                latest = Math.max(latest, Date.parse(list[i].updated_at) || 0)
        }
        return latest
    }

    // ---- Which providers the notch shows ----
    // A provider with a session running outranks an idle one; among equals the
    // one whose session started or ended last comes first.
    readonly property var ranked: {
        const rows = []
        for (let i = 0; i < activeReadings.length; ++i) {
            const provider = activeReadings[i].provider
            const session = sessionFor(provider)
            const running = session !== null && session.kind !== "idle"
            rows.push({
                provider: provider,
                running: running,
                favorite: Engine.favorites.indexOf(provider) >= 0,
                at: running ? (Date.parse(session.updated_at) || 0) : lastChatAt(provider)
            })
        }
        // Working first, then the starred, then whichever moved last.
        rows.sort((a, b) => a.running !== b.running ? (a.running ? -1 : 1)
                          : a.favorite !== b.favorite ? (a.favorite ? -1 : 1)
                          : b.at - a.at)
        return rows.map(row => row.provider)
    }
    // Picked with the wheel; forgotten when the notch hides.
    property string manualProvider: ""
    readonly property int peekIndex: Engine.peekOpen ? indexOfProvider(Engine.peekProvider) : -1
    readonly property int previewIndex: indexOfProvider(Engine.previewProvider)
    // Always among the rings, whatever its rank.
    readonly property string pinnedProvider: indexOfProvider(manualProvider) >= 0 ? manualProvider
                                           : peekIndex >= 0 ? Engine.peekProvider
                                           : previewIndex >= 0 ? Engine.previewProvider
                                           : ""
    // Chosen by rank, laid out in the order set in Settings (the registry's
    // for any it does not name) so rings do not swap places as sessions come
    // and go.
    readonly property var shownReadings: {
        const picked = ranked.slice(0, Math.max(1, Engine.maxProviders))
        if (pinnedProvider !== "" && picked.length > 0 && picked.indexOf(pinnedProvider) < 0)
            picked[picked.length - 1] = pinnedProvider
        const place = {}
        const order = Engine.notchProviders
        for (let i = 0; i < order.length; ++i)
            place[order[i].id] = i
        const at = reading => place[reading.provider] === undefined ? order.length : place[reading.provider]
        return activeReadings.filter(reading => picked.indexOf(reading.provider) >= 0)
                             .sort((a, b) => at(a) - at(b))
    }
    function shownIndexOf(provider) {
        for (let i = 0; i < shownReadings.length; ++i) {
            if (shownReadings[i].provider === provider)
                return i
        }
        return -1
    }

    // Brings up the next provider that has no ring at the moment.
    function cycleProvider(step) {
        const count = activeReadings.length
        if (shownReadings.length === 0 || shownReadings.length >= count)
            return
        const from = pinnedProvider !== "" ? pinnedProvider
                                           : shownReadings[shownReadings.length - 1].provider
        let i = indexOfProvider(from)
        for (let tries = 0; tries < count; ++tries) {
            i = (i + step + count) % count
            const candidate = activeReadings[i].provider
            if (shownIndexOf(candidate) < 0 || candidate === from) {
                manualProvider = candidate
                return
            }
        }
    }

    // ---- The card ----
    // The ring under the pointer, kept while the pointer is on the card. A
    // session finishing only brings the notch out; the card waits for the
    // pointer.
    property string hoveredProvider: ""
    readonly property string cardTarget: hoveredProvider !== "" ? hoveredProvider
                                       : previewIndex >= 0 ? Engine.previewProvider
                                       : ""
    // Held through the fade-out so the card does not empty while it leaves.
    property string cardProvider: ""
    onCardTargetChanged: {
        if (cardTarget !== "") {
            cardProvider = cardTarget
            now = Date.now()
        }
    }
    readonly property bool cardShown: cardTarget !== "" && shownIndexOf(cardTarget) >= 0
    readonly property bool cardActive: cardShown && !dragging
    readonly property var cardReading: readingFor(cardProvider)
    readonly property var cardSession: cardReading ? sessionFor(cardProvider) : null
    readonly property real cardAim: bodyStart + padStart
                                    + Math.max(0, shownIndexOf(cardProvider)) * (cellAlong + cellSpacing)
                                    + (vertical ? 22 * s : cellWidth / 2)

    property real now: Date.now()
    Timer {
        interval: 20000
        repeat: true
        running: root.cardShown
        onTriggered: root.now = Date.now()
    }
    // Long enough to carry the pointer across the gap from ring to card.
    Timer {
        id: unhover
        interval: 260
        onTriggered: root.hoveredProvider = ""
    }

    Connections {
        target: Engine
        function onOpenSettingsRequested() { root.showSettings() }
        function onOpenDashboardRequested() { root.showDashboard() }
        // Follows the chosen output, and the primary one while it is unplugged;
        // a no-op when the notch is already there.
        function onConfigChanged() { Engine.placeOnScreen(root) }
        function onScreensChanged() { Engine.placeOnScreen(root) }
        // A session that just finished is the news; drop any manual pick.
        function onPeekOpenChanged() { if (Engine.peekOpen) root.manualProvider = "" }
    }

    // Everything drawn lives under one item, so its hover handler is true
    // while the pointer is anywhere inside the input region.
    Item {
        anchors.fill: parent
        HoverHandler { id: edgeHover }

        // The nub: what is left on the edge while the notch is tucked away.
        NotchShape {
            id: nub
            readonly property real centre: root.bodyStart + root.collapsedLength / 2 + motion.along
            // Waiting for you outranks working.
            NubMotion {
                id: motion
                style: root.waiting ? Engine.nubWaiting : Engine.nubWorking
                active: nub.visible && (root.waiting || root.working)
                unit: root.s
            }
            edge: root.edge
            length: 30 * root.s * Engine.idleSize * motion.lengthScale
            depth: root.nubDepth * motion.depthScale
            wave: motion.wave * depth
            wavePhase: motion.wavePhase
            // Breathing fades the paint; the nub's own opacity belongs to
            // hiding and showing.
            readonly property color paint: Engine.idleColor
            color: Qt.rgba(paint.r, paint.g, paint.b, motion.fade)
            rim: Theme.withAlpha("#FFFFFF", 0.25)
            curl: depth / 2
            radius: depth / 2
            x: root.vertical ? (root.edge === "right" ? root.width - depth : 0)
                             : centre - length / 2 - curl
            y: root.vertical ? centre - length / 2 - curl
                             : (root.edge === "top" ? 0 : root.height - depth)
            opacity: root.revealed ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 240 } }

            // Finished chats to read: a dot on the nub, in a colour that
            // reads on whatever colour the nub is, breathing so the eye
            // finds it.
            Rectangle {
                id: unreadDot
                visible: root.unreadCount > 0
                width: root.nubDepth * 0.7
                height: width
                radius: width / 2
                color: Theme.markColor(root.nubColor)
                x: (nub.width - width) / 2
                y: (nub.height - height) / 2
                // A slow breath, and a touch smaller while it is faint.
                scale: 0.9 + 0.1 * opacity
                SequentialAnimation on opacity {
                    running: unreadDot.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.65; to: 1; duration: 2200; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1; to: 0.65; duration: 2200; easing.type: Easing.InOutSine }
                }
            }
        }

        // ---- The notch ----
        NotchShape {
            edge: root.edge
            length: root.bodyLength
            depth: root.depth
            curl: root.curl
            radius: Theme.px(28 * root.s)
            color: root.notchColor
            rim: Theme.withAlpha("#FFFFFF", 0.10)
            x: root.vertical ? notch.x : notch.x - root.curl
            y: root.vertical ? notch.y - root.curl : notch.y
        }

        Item {
            id: notch
            x: root.vertical ? (root.edge === "right" ? root.width - root.depth + root.tuck : -root.tuck)
                             : root.bodyStart
            y: root.vertical ? root.bodyStart
                             : (root.edge === "top" ? -root.tuck : root.height - root.depth + root.tuck)
            width: root.vertical ? root.depth : root.bodyLength
            height: root.vertical ? root.bodyLength : root.depth

            HoverHandler { id: notchHover }
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: Engine.openSettings()
            }

            // Scroll to look at another provider.
            WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                property real travelled: 0
                onWheel: (event) => {
                    travelled += event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
                    if (Math.abs(travelled) >= 120) {
                        root.cycleProvider(travelled < 0 ? 1 : -1)
                        travelled = 0
                    }
                }
            }

            Repeater {
                model: root.shownReadings.length > 0 ? root.shownReadings : [null]
                delegate: ProviderRing {
                    required property var modelData
                    required property int index

                    readonly property string provider: modelData ? modelData.provider : ""
                    readonly property var session: modelData ? root.sessionFor(provider) : null

                    width: root.cellWidth
                    height: root.cellHeight
                    x: root.vertical ? Theme.px((root.depth - width) / 2)
                                     : root.padStart + index * (root.cellAlong + root.cellSpacing)
                    y: root.vertical ? root.padStart + index * (root.cellAlong + root.cellSpacing)
                                     : root.padAcross
                    scale_: root.s
                    surface: root.notchColor
                    reading: modelData
                    sessionKind: session ? session.kind : "idle"
                    unread: root.unreadFor(provider)

                    onClicked: Engine.refresh(provider)
                    onHoveredChanged_: (hovered) => {
                        if (hovered && provider !== "") {
                            unhover.stop()
                            root.hoveredProvider = provider
                        } else if (root.hoveredProvider === provider) {
                            unhover.restart()
                        }
                    }
                }
            }

            // Footer: unfolds under the rings when the pointer arrives. A pair of
            // buttons across the notch, the grip centred after them, so it fits
            // the notch's depth on any edge.
            Grid {
                columns: root.vertical ? 1 : 2
                spacing: Theme.px(6 * root.s)
                horizontalItemAlignment: Grid.AlignHCenter
                verticalItemAlignment: Grid.AlignVCenter
                x: root.vertical ? Theme.px((root.depth - width) / 2)
                                 : Theme.px(root.collapsedLength + (root.footerLength - width) / 2 - 8 * root.s)
                y: root.vertical ? Theme.px(root.collapsedLength + (root.footerLength - height) / 2 - 6 * root.s)
                                 : (root.depth - height) / 2
                opacity: root.expanded ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Grid {
                    columns: root.vertical ? 2 : 1
                    spacing: Theme.px(6 * root.s)

                    ToolButton {
                        icon: "dashboard"
                        scale_: root.s
                        surface: root.notchColor
                        onClicked: Engine.openDashboard()
                    }
                    ToolButton {
                        icon: "settings"
                        scale_: root.s
                        surface: root.notchColor
                        onClicked: Engine.openSettings()
                    }
                }
                ToolButton {
                    icon: "grip"
                    scale_: root.s
                    surface: root.notchColor
                    cursor: root.vertical ? Qt.SizeVerCursor : Qt.SizeHorCursor

                    // Drag to slide the notch along its edge.
                    DragHandler {
                        target: null
                        property real grabAt: 0
                        property real startPosition: 0
                        function along() {
                            return root.vertical ? centroid.scenePosition.y : centroid.scenePosition.x
                        }
                        onActiveChanged: {
                            if (active) {
                                grabAt = along()
                                startPosition = Engine.edgePosition
                                root.dragPosition = startPosition
                                root.dragging = true
                            } else if (root.dragging) {
                                Engine.setEdgePosition(root.dragPosition)
                                root.dragging = false
                            }
                        }
                        onCentroidChanged: {
                            if (active && root.travel > 0) {
                                root.dragPosition = Math.max(0, Math.min(1,
                                    startPosition + (along() - grabAt) / root.travel))
                            }
                        }
                    }
                }
            }
        }

        // ---- The card ----
        DetailCard {
            id: card
            edge: root.edge
            scale_: root.s
            now: root.now
            engineConnected: Engine.connected
            reading: root.cardReading
            sessionKind: root.cardSession ? root.cardSession.kind : "idle"
            sessionLabel: root.cardSession && root.cardSession.label ? root.cardSession.label : ""
            chats: root.cardReading ? root.chatsFor(root.cardProvider) : []
            tokenStats: root.cardReading ? root.tokensFor(root.cardProvider) : null
            bannerKind: root.peekIndex >= 0 && root.cardProvider === Engine.peekProvider ? Engine.peekKind : ""
            bannerLabel: Engine.peekLabel

            // The pointer may come over to read it; the card stays while it does.
            HoverHandler {
                onHoveredChanged: {
                    if (hovered && root.cardActive) {
                        unhover.stop()
                        root.hoveredProvider = root.cardProvider
                    } else if (!hovered) {
                        unhover.restart()
                    }
                }
            }

            readonly property bool shown: root.cardActive
            readonly property real margin: 12
            // Slides a few pixels out of the notch as it appears, and grows a
            // touch from the side that faces it: the card settles into place
            // instead of simply showing up.
            property real slide: shown ? 0 : 8 * root.s
            property real appear: shown ? 1 : 0
            Behavior on slide { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on appear { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            transformOrigin: root.vertical
                ? (root.edge === "right" ? Item.Right : Item.Left)
                : (root.edge === "top" ? Item.Top : Item.Bottom)

            readonly property real alongStart: Theme.px(root.vertical
                ? Math.max(margin, Math.min(root.height - height - margin, root.cardAim - height / 2))
                : Math.max(margin, Math.min(root.width - width - margin, root.cardAim - width / 2)))
            tailOffset: root.cardAim - alongStart

            x: root.vertical
                ? (root.edge === "right" ? notch.x - root.cardGap - width + slide
                                         : root.depth + root.cardGap - slide)
                : alongStart
            y: root.vertical
                ? alongStart
                : (root.edge === "top" ? root.depth + root.cardGap - slide
                                       : root.height - root.depth - root.cardGap - height + slide)

            opacity: appear
            visible: opacity > 0
            scale: 0.985 + 0.015 * appear
        }
    }

    // Opens Settings, or brings the window forward if it is already open.
    function showSettings() {
        if (!settingsLoader.active) {
            settingsLoader.active = true
            return
        }
        const w = settingsLoader.item
        if (w.active)
            return
        w.raise()
        w.requestActivate()
        refocusSettings.restart()
    }

    // Same dance for the dashboard: a plain window, focus-friendly.
    function showDashboard() {
        Engine.requestDashboard(30)
        if (!dashboardLoader.active) {
            dashboardLoader.active = true
            return
        }
        const w = dashboardLoader.item
        if (w.active)
            return
        w.raise()
        w.requestActivate()
        refocusDashboard.restart()
    }

    // The notch never holds keyboard focus, so the compositor may refuse to
    // activate an existing window on its behalf. A fresh window does get focus.
    Timer {
        id: refocusSettings
        interval: 200
        onTriggered: {
            if (settingsLoader.item && !settingsLoader.item.active) {
                settingsLoader.active = false
                settingsLoader.active = true
            }
        }
    }
    Timer {
        id: refocusDashboard
        interval: 200
        onTriggered: {
            if (dashboardLoader.item && !dashboardLoader.item.active) {
                dashboardLoader.active = false
                dashboardLoader.active = true
            }
        }
    }

    Loader {
        id: settingsLoader
        active: false
        sourceComponent: SettingsWindow {
            onRequestClose: settingsLoader.active = false
        }
    }
    Loader {
        id: dashboardLoader
        active: false
        sourceComponent: DashboardWindow {
            onRequestClose: dashboardLoader.active = false
        }
    }
}
