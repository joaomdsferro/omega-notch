import QtQuick
import QtQuick.Controls
import QtQuick.Window
import OmegaNotch

// Separate native dashboard window: every tool's limits, token history from
// the persisted DB, today's estimated cost and the recent chats. Data comes
// from the same Engine singleton as the notch; history arrives via
// Engine.requestDashboard(days) -> Engine.dashboardPoints/Costs.
// One tool filter at the top scopes the whole page.
Window {
    id: root
    title: "Omega Notch Dashboard"
    width: 1180
    height: 820
    minimumWidth: 920
    minimumHeight: 620
    visible: true
    color: Theme.panel

    signal requestClose()

    onClosing: (close) => {
        root.requestClose()
    }

    property int days: 30
    property string providerFilter: "all"
    property real now: Date.now()
    property bool showAllChats: false
    property bool showAllSessions: false
    property string openSession: ""
    // Words that sessions must carry, and the project they ran in: both
    // narrow the whole page. The engine narrows its numbers; the chats are
    // already here.
    property string search: ""
    property string project: ""
    // One session, by id, that the numbers narrow to.
    property string chat: ""
    // The model Claude's analysis runs on.
    property string analysisModel: "sonnet"
    onProjectChanged: {
        // A chat from another project would leave nothing to show.
        chat = ""
        Engine.setDashboardProject(project)
    }
    onChatChanged: Engine.setDashboardSession(chat)
    // A session's title, short enough for a button.
    function chatTitle(id) {
        const s = Engine.dashboardSessions.find(x => x.id === id)
        const title = s ? s.title : "One chat"
        return title.length > 40 ? title.slice(0, 39) + "…" : title
    }
    // The sessions card: only the picked one, when one is.
    readonly property var listedSessions: Engine.dashboardSession.length > 0
                                          ? shownSessions.filter(s => s.id === Engine.dashboardSession)
                                          : shownSessions
    // Sessions in scope: one when one is picked.
    readonly property int scopedCount: Engine.dashboardSession.length > 0 ? 1 : shownSessions.length
    // Whether the numbers on screen are narrowed; they lag the field a little.
    readonly property bool scoped: Engine.dashboardSearch.length > 0 || Engine.dashboardProject.length > 0
                                   || Engine.dashboardSession.length > 0
    readonly property string scopeLabel: [Engine.dashboardProject,
                                          Engine.dashboardSearch.length > 0 ? "“" + Engine.dashboardSearch + "”" : "",
                                          Engine.dashboardSession.length > 0 ? chatTitle(Engine.dashboardSession) : ""]
                                         .filter(p => p.length > 0).join(" · ")
    // Narrowed, today and the days before come from the sessions in scope.
    function scopedDay(date) { return root.points.filter(p => p.date === date) }
    // The words of a search, as the engine reads them.
    readonly property var searchWords: search.slice(0, 200).toLowerCase().split(/\s+/).filter(w => w.length > 0).slice(0, 8)
    function found(fields) {
        const haystack = fields.filter(f => !!f).join(" ").toLowerCase()
        return searchWords.every(w => haystack.indexOf(w) >= 0)
    }

    // Typing settles before the engine is asked again.
    onSearchChanged: searchSettle.restart()
    Timer {
        id: searchSettle
        interval: 250
        onTriggered: Engine.searchDashboard(root.search)
    }

    Component.onCompleted: Engine.requestDashboard(root.days)
    onDaysChanged: Engine.requestDashboard(root.days)

    Timer {
        interval: 30000
        repeat: true
        running: root.visible
        onTriggered: {
            root.now = Date.now()
            Engine.requestDashboard(root.days)
        }
    }

    // ---- Data ----
    function matches(provider) {
        return root.providerFilter === "all" || provider === root.providerFilter
    }
    function isoDay(ms) {
        return Qt.formatDate(new Date(ms), "yyyy-MM-dd")
    }

    readonly property string today: isoDay(now)

    readonly property var activeReadings: {
        const out = []
        for (let i = 0; i < Engine.readings.length; ++i) {
            if (Engine.readings[i].status !== "disabled")
                out.push(Engine.readings[i])
        }
        return out
    }
    readonly property var shownReadings: activeReadings.filter(r => root.matches(r.provider))

    readonly property var filterOptions: {
        const out = [{ value: "all", label: "All tools" }]
        for (let i = 0; i < activeReadings.length; ++i) {
            const r = activeReadings[i]
            out.push({ value: r.provider, label: r.display_name || r.provider, provider: r.provider })
        }
        return out
    }
    // A tool that was switched off cannot stay selected.
    onFilterOptionsChanged: {
        if (!filterOptions.some(o => o.value === providerFilter))
            providerFilter = "all"
    }

    function sessionFor(provider) {
        for (let i = 0; i < Engine.sessions.length; ++i) {
            if (Engine.sessions[i].provider === provider)
                return Engine.sessions[i]
        }
        return null
    }
    readonly property int workingCount: Engine.sessions.filter(
        s => s.kind === "busy" && root.matches(s.provider)).length
    readonly property int waitingCount: Engine.sessions.filter(
        s => s.kind === "waiting_you" && root.matches(s.provider)).length

    // Every day of the range, oldest first. Steps from local noon so a DST
    // change never skips or repeats a day.
    readonly property var rangeDates: {
        const noon = new Date(root.now)
        noon.setHours(12, 0, 0, 0)
        const out = []
        for (let i = root.days - 1; i >= 0; --i)
            out.push(root.isoDay(noon.getTime() - i * 86400000))
        return out
    }

    readonly property var points: Engine.dashboardPoints.filter(p => root.matches(p.provider))
    readonly property var modelPoints: Engine.dashboardModels.filter(m => root.matches(m.provider))

    readonly property var kindLabels: ({
        output: "Output", input: "Input", cache_write: "Cache write", cache_read: "Cache read"
    })

    // Stacks [{ date, key, value }] into one column per day of the range.
    // Series are ordered largest first, so the biggest sits at the bottom in
    // the brightest shade; past `limit`, the smallest fold into "Other".
    function stack(entries, labelOf, limit) {
        const totals = {}
        for (let i = 0; i < entries.length; ++i)
            totals[entries[i].key] = (totals[entries[i].key] || 0) + entries[i].value
        let keys = Object.keys(totals).filter(k => totals[k] > 0).sort((x, y) => totals[y] - totals[x])
        const folded = keys.length > limit ? keys.slice(limit - 1) : []
        if (folded.length > 0) keys = keys.slice(0, limit - 1)
        const keyFor = k => folded.indexOf(k) >= 0 ? "__other" : k

        const byDate = {}
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i]
            const d = byDate[e.date] || (byDate[e.date] = { total: 0 })
            const k = keyFor(e.key)
            d[k] = (d[k] || 0) + e.value
            d.total += e.value
        }
        const series = keys.map((k, i) => ({
            key: k, label: labelOf(k), total: totals[k],
            color: root.shades[i % root.shades.length]
        }))
        if (folded.length > 0) {
            series.push({
                key: "__other", label: "Other (" + folded.length + ")",
                total: folded.reduce((a, k) => a + totals[k], 0),
                color: root.shades[root.shades.length - 1]
            })
        }
        const days = root.rangeDates.map(date => Object.assign({ date: date, total: 0 }, byDate[date] || {}))
        return { series: series, days: days, total: days.reduce((a, d) => a + d.total, 0) }
    }

    property string tokensBy: "tool"       // "tool" | "model" | "kind"
    property string costBy: "model"        // "model" | "tool"

    readonly property var tokenChart: {
        if (tokensBy === "model")
            return stack(modelPoints.map(m => ({ date: m.date, key: m.model, value: m.total || 0 })), k => k, 6)
        if (tokensBy === "kind") {
            const entries = []
            for (let i = 0; i < points.length; ++i) {
                for (const k in kindLabels)
                    entries.push({ date: points[i].date, key: k, value: points[i][k] || 0 })
            }
            return stack(entries, k => root.kindLabels[k], 6)
        }
        return stack(points.map(p => ({ date: p.date, key: p.provider, value: p.total || 0 })),
                     k => Engine.displayName(k), 6)
    }
    readonly property var costChart: costBy === "tool"
        ? stack(modelPoints.map(m => ({ date: m.date, key: m.provider, value: m.cost_usd || 0 })),
                k => Engine.displayName(k), 6)
        : stack(modelPoints.map(m => ({ date: m.date, key: m.model, value: m.cost_usd || 0 })), k => k, 6)

    readonly property var rangeKinds: {
        const t = { input: 0, output: 0, cache_read: 0, cache_write: 0 }
        for (let i = 0; i < points.length; ++i) {
            for (const k in t) t[k] += points[i][k] || 0
        }
        return t
    }
    readonly property real rangeTotal: Theme.totalTokens(rangeKinds)
    readonly property int activeDays: tokenChart.days.filter(d => d.total > 0).length

    readonly property real rangeCost: costChart.total
    readonly property int costDays: costChart.days.filter(d => d.total > 0).length

    // One row per model over the range, dearest first, with a daily sparkline.
    readonly property var modelRows: {
        const byModel = {}
        const index = {}
        for (let i = 0; i < rangeDates.length; ++i) index[rangeDates[i]] = i
        for (let i = 0; i < modelPoints.length; ++i) {
            const m = modelPoints[i]
            const row = byModel[m.model] || (byModel[m.model] = {
                model: m.model, provider: m.provider, total: 0, cost: 0, activeDays: 0,
                daily: rangeDates.map(() => 0)
            })
            row.total += m.total || 0
            row.cost += m.cost_usd || 0
            const at = index[m.date]
            if (at !== undefined) {
                if (row.daily[at] === 0 && (m.total || 0) > 0) row.activeDays += 1
                row.daily[at] += m.total || 0
            }
        }
        return Object.values(byModel).sort((a, b) => b.cost - a.cost || b.total - a.total)
    }

    readonly property real tokensToday: {
        if (root.scoped)
            return root.scopedDay(root.today).reduce((a, p) => a + (p.total || 0), 0)
        let sum = 0
        for (let i = 0; i < Engine.tokens.length; ++i) {
            if (root.matches(Engine.tokens[i].provider))
                sum += Theme.totalTokens(Engine.tokens[i].today)
        }
        return sum
    }
    // Mean of the six days before today, from the live seven-day window.
    readonly property real priorAverage: {
        if (root.scoped) {
            let sum = 0
            for (let i = 1; i <= 6; ++i)
                sum += root.scopedDay(root.isoDay(root.now - i * 86400000)).reduce((a, p) => a + (p.total || 0), 0)
            return sum / 6
        }
        const sums = [0, 0, 0, 0, 0, 0]
        for (let i = 0; i < Engine.tokens.length; ++i) {
            if (!root.matches(Engine.tokens[i].provider)) continue
            const daily = Engine.tokens[i].daily || []
            for (let j = 0; j < Math.min(6, daily.length - 1); ++j)
                sums[j] += daily[j].total || 0
        }
        return sums.reduce((a, b) => a + b, 0) / 6
    }

    readonly property var shownCosts: Engine.dashboardCosts.filter(c => root.matches(c.provider))
    readonly property real costToday: shownCosts.reduce((a, c) => a + (c.cost_usd || 0), 0)

    // The series colours chosen in Settings.
    readonly property var shades: Theme.seriesShades(Engine.dashboardPalette, Engine.dashboardColors)

    readonly property var shownChats: Engine.chats.filter(c => root.matches(c.provider))
    readonly property var shownSessions: Engine.dashboardSessions.filter(s => root.matches(s.provider))
    // A model keeps the colour it has in the Models table, so the two read together.
    readonly property var modelShades: {
        const shades = {}
        for (let i = 0; i < modelRows.length; ++i)
            if (shades[modelRows[i].model] === undefined)
                shades[modelRows[i].model] = root.shades[i % root.shades.length]
        return shades
    }
    readonly property int unreadCount: shownChats.filter(c => c.unread).length
    readonly property bool chatsNarrowed: searchWords.length > 0 || project.length > 0 || chat.length > 0
    readonly property var foundChats: shownChats.filter(c => (root.project.length === 0 || c.project === root.project)
                                                             && (root.chat.length === 0 || c.id === root.chat)
                                                             && root.found([c.title, c.project, c.cwd, c.model, c.id]))
    readonly property int foundUnread: foundChats.filter(c => c.unread).length
    // Chats to read first, so the ones counted are never past "Show all".
    readonly property var listedChats: foundChats.filter(c => c.unread).concat(foundChats.filter(c => !c.unread))
    readonly property bool chatsHaveContext: foundChats.some(
        c => c.context_pct !== undefined && c.context_pct !== null)

    readonly property var todayTotals: {
        const t = { input: 0, output: 0, cache_read: 0, cache_write: 0 }
        if (root.scoped) {
            const day = root.scopedDay(root.today)
            for (let i = 0; i < day.length; ++i)
                for (const k in t) t[k] += day[i][k] || 0
            return t
        }
        for (let i = 0; i < Engine.tokens.length; ++i) {
            if (!root.matches(Engine.tokens[i].provider)) continue
            const d = Engine.tokens[i].today || {}
            for (const k in t) t[k] += d[k] || 0
        }
        return t
    }

    readonly property int maxWindows: {
        let m = 1
        for (let i = 0; i < shownReadings.length; ++i) {
            const r = shownReadings[i]
            if (r.windows && (r.status === "ok" || r.status === "stale"))
                m = Math.max(m, r.windows.length)
        }
        return m
    }

    // ---- Pieces ----
    component SectionHeading: Item {
        property string text: ""
        property string caption: ""
        width: parent.width
        height: 22
        Text {
            id: sectionText
            anchors.verticalCenter: parent.verticalCenter
            text: parent.text
            color: Theme.text
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Text {
            anchors.left: sectionText.right
            anchors.leftMargin: 10
            anchors.baseline: sectionText.baseline
            text: parent.caption
            color: Theme.textTertiary
            font.pixelSize: 12
        }
    }

    component Stat: Item {
        id: stat
        property string label: ""
        property string value: ""
        property string note: ""
        property color noteColor: Theme.textTertiary
        height: 96

        Column {
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 40
            spacing: 6
            Text {
                text: stat.label
                color: Theme.textSecondary
                font.pixelSize: 12
                font.weight: Font.Medium
            }
            Text {
                text: stat.value
                color: Theme.text
                font.pixelSize: 26
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                elide: Text.ElideRight
                width: parent.width
            }
            Text {
                text: stat.note
                color: stat.noteColor
                font.pixelSize: 12
                font.features: { "tnum": 1 }
                elide: Text.ElideRight
                width: parent.width
            }
        }
    }

    component LegendItem: Row {
        property color swatch: Theme.text
        property string label: ""
        property string value: ""
        spacing: 6
        Rectangle {
            width: 8
            height: 8
            radius: 2
            color: parent.swatch
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: parent.label
            color: Theme.textSecondary
            font.pixelSize: 12
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: parent.value
            color: Theme.text
            font.pixelSize: 12
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // Every series of a chart with its total and share of the range.
    component Legend: Flow {
        id: legend
        property var series: []
        property bool money: false
        readonly property real sum: series.reduce((a, x) => a + x.total, 0)
        spacing: 20
        Repeater {
            model: legend.series
            delegate: LegendItem {
                required property var modelData
                swatch: modelData.color
                label: modelData.label
                value: (legend.money ? Theme.usd(modelData.total) : Theme.tokens(modelData.total))
                       + (legend.series.length > 1 && legend.sum > 0
                          ? "  " + Math.round(100 * modelData.total / legend.sum) + "%" : "")
            }
        }
    }

    // Narrows the page to one of a few: "All …" first, then each choice
    // with what it spent. The chosen one wears a tick.
    component ScopeMenu: Rectangle {
        id: menuButton
        property string icon: ""
        property string allLabel: ""
        property string value: ""
        property string chosenLabel: ""
        property var choices: []        // [{ value, label, detail }]
        signal picked(string value)

        readonly property bool chosen: value.length > 0
        width: Math.min(menuRow.implicitWidth, 320) + 24
        height: 32
        radius: 9
        color: chosen ? Theme.controlChosen : Theme.controlFill
        Accessible.role: Accessible.ComboBox
        Accessible.name: chosen ? chosenLabel : allLabel

        Row {
            id: menuRow
            anchors.verticalCenter: parent.verticalCenter
            x: 12
            spacing: 7
            SettingsIcon {
                width: 14; height: 14
                anchors.verticalCenter: parent.verticalCenter
                name: menuButton.icon
                color: menuButton.chosen ? Theme.text : Theme.textSecondary
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, 320 - 46)
                elide: Text.ElideRight
                text: menuButton.chosen ? menuButton.chosenLabel : menuButton.allLabel
                color: menuButton.chosen ? Theme.text : Theme.textSecondary
                font.pixelSize: 13
                font.weight: menuButton.chosen ? Font.DemiBold : Font.Normal
            }
            SettingsIcon {
                width: 11; height: 11
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron-down"
                color: Theme.textSecondary
            }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: menuPopup.opened ? menuPopup.close() : menuPopup.open() }

        Popup {
            id: menuPopup
            y: menuButton.height + 6
            width: 380
            height: Math.min(menuList.contentHeight + 12, 360)
            padding: 6
            background: Rectangle {
                radius: 10
                color: Theme.panelRaised
                border.width: 1
                border.color: Theme.cardStroke
            }
            contentItem: ListView {
                id: menuList
                clip: true
                model: [{ value: "", label: menuButton.allLabel, detail: "" }].concat(menuButton.choices)
                delegate: Rectangle {
                    id: menuItem
                    required property var modelData
                    readonly property bool chosen: modelData.value === menuButton.value
                    width: menuList.width
                    height: 30
                    radius: 6
                    color: itemHover.hovered ? Theme.controlHover : "transparent"

                    Text {
                        x: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 30 - itemDetail.width
                        elide: Text.ElideRight
                        text: (menuItem.chosen ? "✓ " : "") + menuItem.modelData.label
                        color: Theme.text
                        font.pixelSize: 13
                        font.weight: menuItem.chosen ? Font.DemiBold : Font.Normal
                    }
                    Text {
                        id: itemDetail
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: menuItem.modelData.detail
                        color: Theme.textSecondary
                        font.pixelSize: 12
                    }
                    HoverHandler { id: itemHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            menuButton.picked(menuItem.modelData.value)
                            menuPopup.close()
                        }
                    }
                }
            }
        }
    }

    component TextButton: Rectangle {
        id: tb
        property string label: ""
        signal clicked()
        width: tbText.implicitWidth + 20
        height: 28
        radius: 7
        color: tbHover.hovered ? Theme.controlChosen : Theme.controlFill
        Behavior on color { ColorAnimation { duration: 120 } }
        Accessible.role: Accessible.Button
        Accessible.name: label
        Text {
            id: tbText
            anchors.centerIn: parent
            text: tb.label
            color: Theme.text
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        HoverHandler {
            id: tbHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler { onTapped: tb.clicked() }
    }

    // ---- Page ----
    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: page.implicitHeight + 64
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: page
            x: 32
            y: 28
            width: flick.width - 64
            spacing: 24

            // Header: title and live state, range on the right.
            Item {
                width: parent.width
                height: 52

                Column {
                    spacing: 6
                    Text {
                        text: "Usage"
                        color: Theme.text
                        font.pixelSize: 26
                        font.weight: Font.DemiBold
                    }
                    Row {
                        spacing: 8
                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: !Engine.connected ? Theme.critical
                                 : root.waitingCount > 0 ? Theme.waiting
                                 : root.workingCount > 0 ? Theme.text : Theme.ample
                        }
                        Text {
                            text: {
                                if (!Engine.connected) return "Engine offline — numbers may be out of date"
                                const parts = []
                                if (root.workingCount > 0) parts.push(root.workingCount + " working")
                                if (root.waitingCount > 0) parts.push(root.waitingCount + " waiting on you")
                                if (root.unreadCount > 0) parts.push(root.unreadCount + " to read")
                                if (parts.length === 0) parts.push("All quiet")
                                return parts.join(" · ") + " · updated " + Qt.formatTime(new Date(root.now), "HH:mm")
                            }
                            color: Engine.connected ? Theme.textSecondary : Theme.critical
                            font.pixelSize: 13
                        }
                    }
                }

                DashSegmented {
                    id: daysPicker
                    anchors.right: parent.right
                    anchors.top: parent.top
                    options: [
                        { value: "7", label: "7 days" },
                        { value: "30", label: "30 days" },
                        { value: "90", label: "90 days" }
                    ]
                    value: String(root.days)
                    onPicked: (v) => root.days = Number(v)
                }
            }

            // Search, project and tool: what the whole page is narrowed to.
            Column {
                width: parent.width
                spacing: 12

                // Search box: a magnifier, the words, and a cross to clear
                // them. Escape clears too.
                Rectangle {
                    width: parent.width
                    height: 42
                    radius: 11
                    color: Theme.panelRaised
                    border.width: 1
                    border.color: searchInput.activeFocus ? Theme.textSecondary : Theme.cardStroke

                    SettingsIcon {
                        id: searchIcon
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        name: "search"
                        color: root.search.length > 0 ? Theme.text : Theme.textTertiary
                    }
                    TextInput {
                        id: searchInput
                        anchors.left: searchIcon.right
                        anchors.leftMargin: 8
                        anchors.right: clearSearch.visible ? clearSearch.left : parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.search
                        onTextEdited: root.search = text
                        color: Theme.text
                        selectionColor: Theme.textTertiary
                        selectByMouse: true
                        clip: true
                        font.pixelSize: 15
                        Keys.onEscapePressed: (event) => {
                            event.accepted = root.search.length > 0
                            root.search = ""
                        }
                        Accessible.name: "Search sessions and chats"

                        Text {
                            visible: searchInput.text.length === 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Search sessions and chats by title, project, folder or model"
                            color: Theme.textTertiary
                            font.pixelSize: 15
                        }
                    }
                    SettingsIcon {
                        id: clearSearch
                        visible: root.search.length > 0
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 13
                        height: 13
                        name: "x"
                        color: Theme.textTertiary
                        Accessible.role: Accessible.Button
                        Accessible.name: "Clear the search"
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.search = "" }
                    }
                    HoverHandler { cursorShape: Qt.IBeamCursor }
                    TapHandler { onTapped: searchInput.forceActiveFocus() }
                }

                Row {
                    spacing: 12

                    ScopeMenu {
                        icon: "layers"
                        allLabel: "All projects"
                        value: root.project
                        chosenLabel: root.project
                        choices: Engine.dashboardProjects.map(p => ({
                            value: p.project, label: p.project,
                            detail: Theme.usd(p.cost_usd) + " · " + p.sessions + (p.sessions === 1 ? " session" : " sessions")
                        }))
                        onPicked: (value) => root.project = value
                    }
                    ScopeMenu {
                        icon: "message"
                        allLabel: "All chats"
                        value: root.chat
                        chosenLabel: root.chatTitle(root.chat)
                        choices: root.shownSessions.map(x => ({
                            value: x.id, label: x.title, detail: Theme.usd(x.cost_usd)
                        }))
                        onPicked: (value) => root.chat = value
                    }

                    DashSegmented {
                        visible: root.activeReadings.length > 1
                        options: root.filterOptions
                        value: root.providerFilter
                        onPicked: (v) => root.providerFilter = v
                    }
                }

                // What the page is narrowed to, and how to undo it.
                Rectangle {
                    visible: root.scoped
                    width: parent.width
                    height: scopeText.implicitHeight + 24
                    radius: 10
                    color: Theme.panelRaised

                    Rectangle {
                        x: 12
                        y: 12
                        width: 3
                        height: parent.height - 24
                        radius: 2
                        color: Theme.text
                    }
                    Column {
                        id: scopeText
                        x: 27
                        y: 12
                        width: parent.width - 27 - clearScope.width - 24
                        spacing: 3
                        Text {
                            text: "Showing " + root.scopeLabel
                            color: Theme.text
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: root.scopedCount + (root.scopedCount === 1 ? " session · " : " sessions · ")
                                  + Theme.usd(root.rangeCost) + " in the last " + root.days
                                  + " days. Only Claude Code sessions know their project and title, so the numbers below are theirs; limits are the account's."
                            color: Theme.textSecondary
                            font.pixelSize: 12
                        }
                    }
                    TextButton {
                        id: clearScope
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.top: parent.top
                        anchors.topMargin: 12
                        label: "Clear"
                        onClicked: {
                            root.search = ""
                            root.project = ""
                            root.chat = ""
                        }
                    }
                }
            }

            // Headline numbers.
            Rectangle {
                width: parent.width
                height: 96
                radius: 12
                color: Theme.panelRaised
                border.width: 1
                border.color: Theme.hairline

                Row {
                    anchors.fill: parent
                    Repeater {
                        model: 4
                        delegate: Item {
                            required property int index
                            width: parent.width / 4
                            height: parent.height
                            Rectangle {
                                visible: index > 0
                                width: 1
                                height: parent.height - 32
                                anchors.verticalCenter: parent.verticalCenter
                                color: Theme.hairline
                            }
                        }
                    }
                }
                Row {
                    anchors.fill: parent
                    Stat {
                        width: parent.width / 4
                        label: "Tokens today"
                        value: Theme.tokens(root.tokensToday)
                        note: {
                            if (root.priorAverage <= 0) return "No earlier days to compare"
                            const d = (root.tokensToday - root.priorAverage) / root.priorAverage * 100
                            return (d >= 0 ? "▲ " : "▼ ") + Math.abs(Math.round(d)) + "% vs 6-day average"
                        }
                    }
                    Stat {
                        width: parent.width / 4
                        label: "Tokens · " + root.days + " days"
                        value: Theme.tokens(root.rangeTotal)
                        note: root.activeDays > 0
                              ? Theme.tokens(root.rangeTotal / root.activeDays) + " per active day · " + root.activeDays + " active"
                              : "No history in this range"
                    }
                    Stat {
                        width: parent.width / 4
                        label: "Estimated cost · " + root.days + " days"
                        value: Theme.usd(root.rangeCost)
                        note: root.costDays > 0
                              ? Theme.usd(root.rangeCost / root.costDays) + " per active day · today " + Theme.usd(root.costToday)
                              : "Nothing spent in this range"
                    }
                    Stat {
                        width: parent.width / 4
                        label: "Served from cache"
                        value: root.rangeTotal > 0
                               ? Math.round(100 * root.rangeKinds.cache_read / root.rangeTotal) + "%"
                               : "—"
                        note: root.rangeTotal > 0
                              ? "Cache reads, share of " + root.days + "-day tokens"
                              : "No tokens in this range"
                    }
                }
            }

            // What to change, from the engine's local rules over the sessions
            // in view. Each can narrow the page to its chat, or open it.
            DashCard {
                id: suggestionsCard
                width: parent.width
                heading: "Suggestions"
                caption: {
                    const saving = Engine.dashboardSuggestions.filter(s => root.matches(s.provider)).reduce((a, s) => a + (s.saving_usd || 0), 0)
                    return (saving > 0 ? "Up to " + Theme.usd(saving) + " less in the last " + root.days + " days · " : "")
                           + "from local rules over these sessions, nothing leaves your computer"
                }
                // The rules and Claude read Claude Code's sessions: with
                // another tool picked, there is nothing of its own to say.
                readonly property bool canAsk: root.matches("claude_code")
                readonly property var shownSuggestions: Engine.dashboardSuggestions.filter(s => root.matches(s.provider))
                trailing: Row {
                    visible: suggestionsCard.canAsk
                    spacing: 8
                    DashSegmented {
                        options: [{ value: "sonnet", label: "Sonnet" }, { value: "opus", label: "Opus" }]
                        value: root.analysisModel
                        onPicked: (v) => root.analysisModel = v
                    }
                    TextButton {
                        label: Engine.analysis.state === "running" ? "Asking Claude…" : "Ask Claude"
                        onClicked: if (Engine.analysis.state !== "running") Engine.analyzeUsage(root.analysisModel)
                    }
                }

                Column {
                    width: parent.width

                    Text {
                        visible: suggestionsCard.shownSuggestions.length === 0
                        width: parent.width
                        topPadding: 8
                        bottomPadding: 8
                        wrapMode: Text.WordWrap
                        text: suggestionsCard.canAsk ? "Nothing stands out in these sessions. Ask Claude for a closer look."
                                                     : "Suggestions read Claude Code's sessions. Pick All tools or Claude Code to see them."
                        color: Theme.textTertiary
                        font.pixelSize: 13
                    }

                    Repeater {
                        model: suggestionsCard.shownSuggestions
                        delegate: Item {
                            id: tip
                            required property var modelData
                            required property int index
                            readonly property string firstId: modelData.sessions && modelData.sessions.length > 0
                                                              ? modelData.sessions[0] : ""
                            readonly property bool showable: firstId.length > 0 && root.chat !== firstId
                                                             && Engine.dashboardSessions.some(s => s.id === tip.firstId)
                            readonly property var liveChat: Engine.chats.find(c => c.id === tip.firstId) || null
                            width: parent.width
                            height: tipText.implicitHeight + 24

                            Rectangle {
                                visible: tip.index > 0
                                width: parent.width
                                height: 1
                                color: Theme.hairline
                            }
                            Column {
                                id: tipText
                                y: 12
                                width: parent.width - (saving.visible ? saving.width + 16 : 0)
                                spacing: 4
                                Text {
                                    width: parent.width
                                    text: tip.modelData.title
                                    color: Theme.text
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: tip.modelData.detail
                                    color: Theme.textSecondary
                                    font.pixelSize: 12
                                    wrapMode: Text.WordWrap
                                }
                                Row {
                                    visible: tip.showable || tip.liveChat !== null
                                    topPadding: 4
                                    spacing: 8
                                    TextButton {
                                        visible: tip.showable
                                        label: tip.modelData.sessions.length > 1 ? "Show the dearest" : "Only this chat"
                                        onClicked: root.chat = tip.firstId
                                    }
                                    TextButton {
                                        visible: tip.liveChat !== null
                                        label: "Open chat"
                                        onClicked: Engine.openChat(tip.liveChat)
                                    }
                                }
                            }
                            Rectangle {
                                id: saving
                                visible: tip.modelData.saving_usd !== undefined && tip.modelData.saving_usd !== null
                                anchors.right: parent.right
                                y: 12
                                width: savingText.implicitWidth + 20
                                height: 26
                                radius: 13
                                color: Qt.rgba(0x3D / 255, 0xDC / 255, 0x97 / 255, 0.12)
                                Text {
                                    id: savingText
                                    anchors.centerIn: parent
                                    text: "≈ " + Theme.usd(tip.modelData.saving_usd || 0) + " less"
                                    color: Theme.ample
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }
                            }
                        }
                    }

                    // Claude's answer: a line while it thinks, then its
                    // Markdown, or why not.
                    Column {
                        visible: suggestionsCard.canAsk && Engine.analysis.state !== undefined
                        width: parent.width
                        topPadding: 12
                        bottomPadding: 12
                        spacing: 8
                        readonly property string name: Engine.analysis.model === "opus" ? "Opus" : "Sonnet"

                        Rectangle { width: parent.width; height: 1; color: Theme.hairline }
                        Text {
                            text: Engine.analysis.state === "running" ? "Claude (" + parent.name + ") is reading the numbers…"
                                : Engine.analysis.state === "failed" ? "Claude could not answer"
                                : "Claude (" + parent.name + ") suggests"
                            color: Theme.text
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                        }
                        TextEdit {
                            visible: (Engine.analysis.text || "").length > 0
                            width: parent.width
                            readOnly: true
                            selectByMouse: true
                            wrapMode: Text.WordWrap
                            textFormat: Engine.analysis.state === "failed" ? TextEdit.PlainText : TextEdit.MarkdownText
                            text: Engine.analysis.text || ""
                            color: Engine.analysis.state === "failed" ? Theme.critical : Theme.textSecondary
                            selectionColor: Theme.textTertiary
                            font.pixelSize: 13
                        }
                    }

                    Text {
                        visible: suggestionsCard.canAsk
                        width: parent.width
                        topPadding: 10
                        wrapMode: Text.WordWrap
                        text: "Ask Claude sends only totals, ratios and models, with sessions as S1, S2…: no titles, folders or chat text. It runs through your own claude command and subscription, with no tools."
                        color: Theme.textTertiary
                        font.pixelSize: 11
                    }
                }
            }

            // Limits.
            Column {
                width: parent.width
                spacing: 12

                SectionHeading {
                    text: "Limits"
                    caption: "Click a tool to refresh it"
                }

                Grid {
                    id: limitsGrid
                    width: parent.width
                    spacing: 16
                    columns: Math.max(1, Math.min(3, root.shownReadings.length, Math.floor((width + spacing) / 320)))
                    visible: root.shownReadings.length > 0

                    Repeater {
                        model: root.shownReadings
                        delegate: DashLimitCard {
                            required property var modelData
                            width: (limitsGrid.width - (limitsGrid.columns - 1) * limitsGrid.spacing) / limitsGrid.columns
                            reading: modelData
                            session: root.sessionFor(modelData.provider)
                            now: root.now
                            windowSlots: root.maxWindows
                        }
                    }
                }

                // No tool on: say so and point at Settings.
                Rectangle {
                    visible: root.shownReadings.length === 0
                    width: parent.width
                    height: 120
                    radius: 12
                    color: "transparent"
                    border.width: 1
                    border.color: Theme.cardStroke
                    Column {
                        anchors.centerIn: parent
                        spacing: 12
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: Engine.connected ? "No tools are switched on." : "Waiting for the engine…"
                            color: Theme.textSecondary
                            font.pixelSize: 13
                        }
                        TextButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: Engine.connected
                            label: "Open Settings"
                            onClicked: Engine.openSettings()
                        }
                    }
                }
            }

            // Spend over time.
            DashCard {
                width: parent.width
                heading: "Estimated cost"
                caption: "Per day at list prices · hover a day for the breakdown"
                trailing: DashSegmented {
                    options: [
                        { value: "model", label: "By model" },
                        { value: "tool", label: "By tool" }
                    ]
                    value: root.costBy
                    onPicked: (v) => root.costBy = v
                }

                Column {
                    width: parent.width
                    spacing: 16
                    DashUsageChart {
                        width: parent.width
                        height: 220
                        format: "usd"
                        days: root.costChart.days
                        series: root.costChart.series
                        today: root.today
                        emptyText: "No cost history yet — it fills in as you work."
                    }
                    Legend {
                        width: parent.width
                        series: root.costChart.series
                        money: true
                    }
                }
            }

            // Tokens over time.
            DashCard {
                width: parent.width
                heading: "Tokens"
                caption: "Per day · hover a day for the breakdown"
                trailing: DashSegmented {
                    options: [
                        { value: "tool", label: "By tool" },
                        { value: "model", label: "By model" },
                        { value: "kind", label: "By kind" }
                    ]
                    value: root.tokensBy
                    onPicked: (v) => root.tokensBy = v
                }

                Column {
                    width: parent.width
                    spacing: 16
                    DashUsageChart {
                        width: parent.width
                        height: 220
                        days: root.tokenChart.days
                        series: root.tokenChart.series
                        today: root.today
                    }
                    Legend {
                        width: parent.width
                        series: root.tokenChart.series
                    }
                }
            }

            // Models over the range, and today at a glance.
            Row {
                id: modelsRow
                width: parent.width
                spacing: 16
                readonly property real rowHeight: Math.max(modelsCard.implicitHeight, costCard.implicitHeight)

                DashCard {
                    id: modelsCard
                    width: parent.width - costCard.width - parent.spacing
                    height: modelsRow.rowHeight
                    heading: "Models"
                    caption: root.modelRows.length + (root.modelRows.length === 1 ? " model" : " models")
                             + " in the last " + root.days + " days · by estimated cost"

                    DashModelTable {
                        width: parent.width
                        models: root.modelRows
                        totalCost: root.rangeCost
                        shades: root.shades
                    }
                }

                DashCard {
                    id: costCard
                    width: Math.round((parent.width - parent.spacing) * 0.36)
                    height: modelsRow.rowHeight
                    heading: "Today"
                    caption: "Estimated cost and token mix"

                    DashCostBreakdown {
                        width: parent.width
                        costs: root.shownCosts
                        total: root.costToday
                        shades: root.shades
                        today: root.todayTotals
                    }
                }
            }

            // The range's dearest sessions.
            DashCard {
                id: sessionsCard
                width: parent.width
                heading: "Dearest sessions"
                caption: root.scoped
                         ? root.shownSessions.length + (root.shownSessions.length === 1 ? " session" : " sessions")
                           + " for " + root.scopeLabel + " in the last " + root.days + " days, by estimated cost"
                         : root.shownSessions.length === 0
                         ? "By estimated cost in the last " + root.days + " days"
                         : "Top " + root.shownSessions.length + " by estimated cost in the last " + root.days
                           + " days · click one for its models"
                trailing: TextButton {
                    visible: root.shownSessions.length > 8
                    label: root.showAllSessions ? "Show fewer" : "Show all " + root.shownSessions.length
                    onClicked: root.showAllSessions = !root.showAllSessions
                }

                Column {
                    id: sessionList
                    width: parent.width

                    // Column labels, aligned with DashSessionRow's cells.
                    Item {
                        width: parent.width
                        height: 20
                        visible: root.shownSessions.length > 0
                        Text {
                            x: 44
                            text: "Session"
                            color: Theme.textTertiary
                            font.pixelSize: 11
                            font.weight: Font.Medium
                        }
                        Row {
                            anchors.right: parent.right
                            Text { width: 112; horizontalAlignment: Text.AlignHCenter; text: "Models"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                            Text { width: 76; horizontalAlignment: Text.AlignRight; text: "Tokens"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                            Text { width: 84; horizontalAlignment: Text.AlignRight; text: "Est. cost"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                            Text { width: 64; horizontalAlignment: Text.AlignRight; text: "Share"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                            Text { width: 84; horizontalAlignment: Text.AlignRight; text: "Last day"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                        }
                    }

                    Repeater {
                        model: root.showAllSessions ? root.listedSessions : root.listedSessions.slice(0, 8)
                        delegate: DashSessionRow {
                            required property var modelData
                            required property int index
                            width: sessionList.width
                            session: modelData
                            today: root.today
                            first: index === 0
                            rangeCost: root.rangeCost
                            shades: root.modelShades
                            otherShade: root.shades[root.shades.length - 1]
                            expanded: root.openSession === modelData.id || Engine.dashboardSession.length > 0
                            focusable: Engine.dashboardSession.length === 0
                            onFocusRequested: root.chat = modelData.id
                            onToggled: root.openSession = expanded ? "" : modelData.id
                            onOpenRequested: Engine.openChat(modelData)
                        }
                    }

                    Text {
                        visible: root.shownSessions.length === 0
                        topPadding: 8
                        text: root.scoped ? "No session in this range matches."
                                                                : "No session history in this range yet."
                        color: Theme.textTertiary
                        font.pixelSize: 13
                    }
                }
            }

            // Recent chats.
            Item {
                width: parent.width
                height: chatsCard.implicitHeight

                DashCard {
                    id: chatsCard
                    width: parent.width
                    heading: "Recent chats"
                    caption: (!root.chatsNarrowed
                              ? root.foundChats.length + (root.foundChats.length === 1 ? " chat" : " chats")
                              : root.foundChats.length + " of " + root.shownChats.length
                                + (root.shownChats.length === 1 ? " chat matches" : " chats match"))
                             + (root.foundUnread > 0 ? " · " + root.foundUnread + " to read" : "") + " · click one to jump to it"
                    trailing: TextButton {
                        visible: root.foundChats.length > 8
                        label: root.showAllChats ? "Show fewer" : "Show all " + root.foundChats.length
                        onClicked: root.showAllChats = !root.showAllChats
                    }

                    Column {
                        id: chatList
                        width: parent.width

                        // Column labels, aligned with DashChatRow's cells.
                        Item {
                            width: parent.width
                            height: 20
                            visible: root.foundChats.length > 0
                            Text {
                                x: 44
                                text: "Chat"
                                color: Theme.textTertiary
                                font.pixelSize: 11
                                font.weight: Font.Medium
                            }
                            Row {
                                anchors.right: parent.right
                                Text { width: 84; horizontalAlignment: Text.AlignRight; text: "Tokens"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                                Text { visible: root.chatsHaveContext; width: 96; horizontalAlignment: Text.AlignRight; text: "Context"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                                Text { width: 76; horizontalAlignment: Text.AlignRight; text: "Last active"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                            }
                        }

                        Repeater {
                            model: root.showAllChats ? root.listedChats : root.listedChats.slice(0, 8)
                            delegate: DashChatRow {
                                required property var modelData
                                required property int index
                                width: chatList.width
                                chat: modelData
                                now: root.now
                                first: index === 0
                                showContext: root.chatsHaveContext
                            }
                        }

                        Text {
                            visible: root.foundChats.length === 0
                            topPadding: 8
                            text: root.chatsNarrowed ? "No recent chat matches." : "No recent chats found."
                            color: Theme.textTertiary
                            font.pixelSize: 13
                        }
                    }
                }
            }

            // Grok Bot's bots, busiest first. Grok Bot records no per-bot
            // counters, so tokens are read off the local transcripts.
            DashCard {
                id: botsCard
                width: parent.width
                visible: Engine.dashboardBots.length > 0
                heading: "Grok Bot bots"
                caption: "By estimated usage in the last " + root.days + " days · estimated from local transcripts, never measured"

                Column {
                    id: botList
                    width: parent.width

                    Item {
                        width: parent.width
                        height: 20
                        Text {
                            x: 0
                            text: "Bot"
                            color: Theme.textTertiary
                            font.pixelSize: 11
                            font.weight: Font.Medium
                        }
                        Row {
                            anchors.right: parent.right
                            Text { width: 76; horizontalAlignment: Text.AlignRight; text: "Messages"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                            Text { width: 84; horizontalAlignment: Text.AlignRight; text: "Est. tokens"; color: Theme.textTertiary; font.pixelSize: 11; font.weight: Font.Medium }
                        }
                    }

                    Repeater {
                        model: Engine.dashboardBots
                        delegate: Item {
                            id: botRow
                            required property var modelData
                            required property int index
                            width: botList.width
                            height: 44

                            HoverHandler {
                                id: rowHover
                                cursorShape: Qt.PointingHandCursor
                            }
                            TapHandler {
                                onTapped: Engine.openChat({ provider: "grok_bot", id: botRow.modelData.id, title: botRow.modelData.name })
                            }
                            Rectangle {
                                anchors.fill: parent
                                anchors.leftMargin: -8
                                anchors.rightMargin: -8
                                radius: 8
                                color: Theme.panelHover
                                opacity: rowHover.hovered ? 1 : 0
                            }
                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.hairline
                                visible: botRow.index > 0 && !rowHover.hovered
                            }

                            // Every ranked bot gets its drawn avatar — a plain
                            // disc when the roster never styled one — so the
                            // names line up.
                            BotAvatar {
                                id: botAvatar
                                x: 0
                                anchors.verticalCenter: parent.verticalCenter
                                width: 24
                                height: 24
                                shape: botRow.modelData.avatar_shape || ""
                                colorName: botRow.modelData.avatar_color || ""
                            }

                            Column {
                                anchors.left: botAvatar.right
                                anchors.leftMargin: 10
                                anchors.right: messagesCell.left
                                anchors.rightMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                Text {
                                    width: parent.width
                                    text: botRow.modelData.name
                                    color: Theme.text
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                                Text {
                                    width: parent.width
                                    visible: botRow.modelData.routines !== undefined
                                             && botRow.modelData.routines.length > 0
                                    text: botRow.modelData.routines.join(", ")
                                    color: Theme.textTertiary
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }
                            }
                            Text {
                                id: messagesCell
                                anchors.right: tokensCell.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: 76
                                horizontalAlignment: Text.AlignRight
                                text: botRow.modelData.messages
                                color: Theme.textSecondary
                                font.pixelSize: 12
                                font.features: { "tnum": 1 }
                            }
                            Text {
                                id: tokensCell
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: 84
                                horizontalAlignment: Text.AlignRight
                                text: "~" + Theme.tokens(botRow.modelData.tokens)
                                color: Theme.text
                                font.pixelSize: 12
                                font.features: { "tnum": 1 }
                            }
                        }
                    }
                }
            }
        }
    }
}
