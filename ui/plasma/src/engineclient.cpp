#include "engineclient.h"

#include <QRegularExpression>

#include <QCoreApplication>
#include <QDir>
#include <QJsonDocument>
#include <QStandardPaths>
#include <QDebug>
#include <QRegion>
#include <QGuiApplication>
#include <QScreen>
#include <QClipboard>
#include <QDesktopServices>
#include <QUrl>
#include <QDateTime>
#include <QLocale>

#include <LayerShellQt/Window>

// "81% of Current session used", for the provider's card, which already
// names it.
static QString limitBanner(const QJsonObject &limit)
{
    const QString label = limit.value(QStringLiteral("label")).toString();
    const int pct = static_cast<int>(limit.value(QStringLiteral("used_pct")).toDouble());
    return limit.value(QStringLiteral("threshold")).toInt() >= 100
        ? QStringLiteral("%1 limit reached").arg(label)
        : QStringLiteral("%1% of %2 used").arg(pct).arg(label);
}

// "Claude Code: 81% of Current session used. Resets in 2h 10m", the same
// text as the macOS shell's, with the reset worded as Theme.resetsIn words it.
static QString limitMessage(const QJsonObject &limit, const QDateTime &now)
{
    const QString name = limit.value(QStringLiteral("display_name")).toString();
    QString text = QStringLiteral("%1: %2").arg(name, limitBanner(limit));

    // chrono may write up to nine digits of a second; minutes are enough.
    static const QRegularExpression fraction(QStringLiteral("\\.\\d+"));
    QString raw = limit.value(QStringLiteral("resets_at")).toString();
    raw.remove(fraction);
    const QDateTime resets = QDateTime::fromString(raw, Qt::ISODate);
    if (!resets.isValid()) {
        return text;
    }
    const qint64 mins = qRound64(now.secsTo(resets) / 60.0);
    if (mins <= 0) {
        text += QStringLiteral(". Resets now");
    } else if (mins < 60) {
        text += QStringLiteral(". Resets in %1 min").arg(mins);
    } else if (mins < 24 * 60) {
        text += QStringLiteral(". Resets in %1h %2m").arg(mins / 60).arg(mins % 60);
    } else {
        const QString pattern = mins < 6 * 24 * 60 ? QStringLiteral("ddd HH:mm") : QStringLiteral("d MMM");
        text += QStringLiteral(". Resets %1").arg(QLocale().toString(resets.toLocalTime(), pattern));
    }
    return text;
}

static bool isHexColor(const QString &color)
{
    static const QRegularExpression hex(QStringLiteral("^#[0-9A-Fa-f]{6}$"));
    return hex.match(color).hasMatch();
}

EngineClient::EngineClient(QObject *parent)
    : QObject(parent)
{
    connect(&m_socket, &QLocalSocket::connected, this, &EngineClient::onConnected);
    connect(&m_socket, &QLocalSocket::disconnected, this, &EngineClient::onDisconnected);
    connect(&m_socket, &QLocalSocket::readyRead, this, &EngineClient::onReadyRead);
    connect(&m_socket, &QLocalSocket::errorOccurred, this, &EngineClient::onError);

    m_reconnect.setInterval(1500);
    connect(&m_reconnect, &QTimer::timeout, this, &EngineClient::tryConnect);

    m_peekTimer.setSingleShot(true);
    connect(&m_peekTimer, &QTimer::timeout, this, [this]() {
        if (m_peekOpen) {
            m_peekOpen = false;
            emit peekOpenChanged();
        }
    });

    connect(qGuiApp, &QGuiApplication::screenAdded, this, &EngineClient::screensChanged);
    connect(qGuiApp, &QGuiApplication::screenRemoved, this, &EngineClient::screensChanged);
    connect(qGuiApp, &QGuiApplication::primaryScreenChanged, this, &EngineClient::screensChanged);

    tryConnect();
    m_reconnect.start();
}

QString EngineClient::socketPath() const
{
    const QByteArray override = qgetenv("OMEGA_NOTCH_SOCKET");
    if (!override.isEmpty()) {
        return QString::fromUtf8(override);
    }
    const QByteArray runtime = qgetenv("XDG_RUNTIME_DIR");
    if (!runtime.isEmpty()) {
        return QString::fromUtf8(runtime) + QStringLiteral("/omega-notch.sock");
    }
    return QDir::temp().filePath(QStringLiteral("omega-notch.sock"));
}

void EngineClient::tryConnect()
{
    if (m_socket.state() == QLocalSocket::ConnectedState
        || m_socket.state() == QLocalSocket::ConnectingState) {
        return;
    }
    m_socket.connectToServer(socketPath());
}

void EngineClient::onConnected()
{
    m_connected = true;
    emit connectedChanged();
    sendJson(QJsonObject{
        {QStringLiteral("type"), QStringLiteral("hello")},
        {QStringLiteral("client"), QStringLiteral("plasma")},
        {QStringLiteral("version"), 1},
    });
    sendJson(QJsonObject{{QStringLiteral("type"), QStringLiteral("subscribe")}});
}

void EngineClient::onDisconnected()
{
    if (m_connected) {
        m_connected = false;
        emit connectedChanged();
    }
}

void EngineClient::onError(QLocalSocket::LocalSocketError)
{
    // reconnect timer handles retry
}

void EngineClient::onReadyRead()
{
    m_buffer.append(m_socket.readAll());
    while (true) {
        const int nl = m_buffer.indexOf('\n');
        if (nl < 0) {
            break;
        }
        const QByteArray line = m_buffer.left(nl);
        m_buffer.remove(0, nl + 1);
        if (line.trimmed().isEmpty()) {
            continue;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(line);
        if (!doc.isObject()) {
            continue;
        }
        handleServerMessage(doc.object());
    }
}

void EngineClient::sendJson(const QJsonObject &obj)
{
    if (m_socket.state() != QLocalSocket::ConnectedState) {
        return;
    }
    QByteArray payload = QJsonDocument(obj).toJson(QJsonDocument::Compact);
    payload.append('\n');
    m_socket.write(payload);
}

void EngineClient::handleServerMessage(const QJsonObject &obj)
{
    const QString type = obj.value(QStringLiteral("type")).toString();
    if (type == QLatin1String("snapshot")) {
        applySnapshot(obj);
    } else if (type == QLatin1String("usage_updated")) {
        applyReading(obj.value(QStringLiteral("reading")).toObject());
    } else if (type == QLatin1String("session_updated")) {
        applySession(obj.value(QStringLiteral("session")).toObject());
    } else if (type == QLatin1String("session_finished")
               || type == QLatin1String("session_waiting")) {
        // The provider's own state arrives as `session_updated`; this event is
        // about one session and must not overwrite it.
        const QJsonObject session = obj.value(QStringLiteral("session")).toObject();
        const QString provider = session.value(QStringLiteral("provider")).toString();
        const QString label = session.value(QStringLiteral("label")).toString();
        if (type == QLatin1String("session_finished")) {
            triggerPeek(provider, label, QStringLiteral("finished"));
            emit sessionFinished(displayName(provider), label);
        } else {
            triggerPeek(provider, label, QStringLiteral("waiting_you"));
            emit sessionWaiting(displayName(provider), label);
        }
    } else if (type == QLatin1String("limit_reached")) {
        const QJsonObject limit = obj.value(QStringLiteral("limit")).toObject();
        triggerPeek(limit.value(QStringLiteral("provider")).toString(), limitBanner(limit),
                    limit.value(QStringLiteral("threshold")).toInt() >= 100 ? QStringLiteral("limit_reached")
                                                                            : QStringLiteral("limit"));
        emit limitReached(limitMessage(limit, QDateTime::currentDateTimeUtc()));
    } else if (type == QLatin1String("activity_updated")) {
        applyActivity(obj);
    } else if (type == QLatin1String("dashboard")) {
        applyDashboard(obj);
    } else if (type == QLatin1String("config_updated")) {
        applyConfig(obj.value(QStringLiteral("config")).toObject());
    } else if (type == QLatin1String("copilot_login")) {
        m_copilotLogin = obj.value(QStringLiteral("login")).toObject().toVariantMap();
        if (m_copilotLogin.value(QStringLiteral("state")) == QLatin1String("pending")) {
            copyCopilotCode();
            openCopilotVerification();
        }
        emit copilotLoginChanged();
    }
}

void EngineClient::applySnapshot(const QJsonObject &obj)
{
    m_readings.clear();
    const QJsonArray readings = obj.value(QStringLiteral("readings")).toArray();
    for (const QJsonValue &v : readings) {
        m_readings.push_back(v.toObject().toVariantMap());
    }
    emit readingsChanged();

    m_sessions.clear();
    const QJsonArray sessions = obj.value(QStringLiteral("sessions")).toArray();
    for (const QJsonValue &v : sessions) {
        m_sessions.push_back(v.toObject().toVariantMap());
    }
    emit sessionsChanged();

    applyActivity(obj);
    applyConfig(obj.value(QStringLiteral("config")).toObject());
}

void EngineClient::applyActivity(const QJsonObject &obj)
{
    m_chats = obj.value(QStringLiteral("chats")).toArray().toVariantList();
    m_tokens = obj.value(QStringLiteral("tokens")).toArray().toVariantList();
    emit activityChanged();
}

void EngineClient::applyDashboard(const QJsonObject &obj)
{
    m_dashboardPoints = obj.value(QStringLiteral("points")).toArray().toVariantList();
    m_dashboardCosts = obj.value(QStringLiteral("costs")).toArray().toVariantList();
    m_dashboardModels = obj.value(QStringLiteral("models")).toArray().toVariantList();
    m_dashboardSessions = obj.value(QStringLiteral("sessions")).toArray().toVariantList();
    m_dashboardAnswered = obj.value(QStringLiteral("search")).toString();
    m_dashboardTotalUsd = obj.value(QStringLiteral("total_usd")).toDouble(0.0);
    emit dashboardChanged();
}

void EngineClient::applyReading(const QJsonObject &reading)
{
    const QString provider = reading.value(QStringLiteral("provider")).toString();
    bool replaced = false;
    for (int i = 0; i < m_readings.size(); ++i) {
        const QVariantMap map = m_readings[i].toMap();
        if (map.value(QStringLiteral("provider")).toString() == provider) {
            m_readings[i] = reading.toVariantMap();
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        m_readings.push_back(reading.toVariantMap());
    }
    emit readingsChanged();
}

void EngineClient::applySession(const QJsonObject &session)
{
    const QString provider = session.value(QStringLiteral("provider")).toString();
    bool replaced = false;
    for (int i = 0; i < m_sessions.size(); ++i) {
        const QVariantMap map = m_sessions[i].toMap();
        if (map.value(QStringLiteral("provider")).toString() == provider) {
            m_sessions[i] = session.toVariantMap();
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        m_sessions.push_back(session.toVariantMap());
    }
    emit sessionsChanged();
}

void EngineClient::applyConfig(const QJsonObject &config)
{
    if (config.isEmpty()) {
        return;
    }
    m_rawConfig = config;
    m_edge = config.value(QStringLiteral("edge")).toString(QStringLiteral("right"));
    m_edgePosition = config.value(QStringLiteral("edge_position")).toDouble(0.5);
    m_sizePreset = config.value(QStringLiteral("size")).toString(QStringLiteral("medium"));
    m_peekSeconds = config.value(QStringLiteral("peek_seconds")).toInt(5);
    m_autoHide = config.value(QStringLiteral("auto_hide")).toBool(true);
    m_maxProviders = qBound(1, config.value(QStringLiteral("max_providers")).toInt(1), 5);
    m_idleSize = qBound(1.0, config.value(QStringLiteral("idle_size")).toDouble(1.0), 3.0);
    m_idleColor = config.value(QStringLiteral("idle_color")).toString(QStringLiteral("#000000"));
    m_nubWorking = config.value(QStringLiteral("nub_working")).toString(QStringLiteral("shiver"));
    m_nubWaiting = config.value(QStringLiteral("nub_waiting")).toString(QStringLiteral("pulse"));
    m_notchColor = config.value(QStringLiteral("notch_color")).toString(QStringLiteral("#000000"));
    m_screenName = config.value(QStringLiteral("screen")).toString();
    m_dashboardPalette = config.value(QStringLiteral("dashboard_palette")).toString(QStringLiteral("mono"));
    m_dashboardColors.clear();
    for (const QJsonValue &color : config.value(QStringLiteral("dashboard_colors")).toArray()) {
        const QString hex = color.toString();
        m_dashboardColors.append(isHexColor(hex) ? hex.toUpper() : QString());
    }

    const QJsonObject providers = config.value(QStringLiteral("providers")).toObject();
    m_providerCursor = providers.value(QStringLiteral("cursor")).toBool(true);
    m_providerClaudeCode = providers.value(QStringLiteral("claude_code")).toBool(true);
    m_providerClaudeDesktop = providers.value(QStringLiteral("claude_desktop")).toBool(true);
    m_providerCopilot = providers.value(QStringLiteral("copilot")).toBool(true);
    m_providerGrokBot = providers.value(QStringLiteral("grok_bot")).toBool(true);
    m_providerCodex = providers.value(QStringLiteral("codex")).toBool(true);

    const QJsonObject alerts = config.value(QStringLiteral("alerts")).toObject();
    m_alertsEnabled = alerts.value(QStringLiteral("enabled")).toBool(true);
    m_soundEnabled = alerts.value(QStringLiteral("sound")).toBool(true);
    m_systemNotifications = alerts.value(QStringLiteral("system_notifications")).toBool(false);
    m_openNotchOnAlert = alerts.value(QStringLiteral("open_notch")).toBool(true);
    m_openNotchSplit = alerts.value(QStringLiteral("open_notch_split")).toBool(false);
    m_openNotchFinished = alerts.value(QStringLiteral("open_notch_finished")).toBool(true);
    m_openNotchWaiting = alerts.value(QStringLiteral("open_notch_waiting")).toBool(true);
    m_openNotchLimits = alerts.value(QStringLiteral("open_notch_limits")).toBool(true);
    m_limitAlerts = alerts.value(QStringLiteral("limits")).toBool(true);
    m_soundFinished = alerts.value(QStringLiteral("sound_finished")).toString();
    m_soundWaiting = alerts.value(QStringLiteral("sound_waiting")).toString();

    emit configChanged();
}

void EngineClient::copilotSignIn()
{
    m_copilotLogin = QVariantMap{{QStringLiteral("state"), QStringLiteral("starting")}};
    emit copilotLoginChanged();
    sendJson(QJsonObject{{QStringLiteral("type"), QStringLiteral("copilot_sign_in")}});
}

void EngineClient::openCopilotVerification()
{
    const QString uri = m_copilotLogin.value(QStringLiteral("verification_uri")).toString();
    if (!uri.isEmpty()) {
        QDesktopServices::openUrl(QUrl(uri));
    }
}

void EngineClient::copyCopilotCode()
{
    const QString code = m_copilotLogin.value(QStringLiteral("user_code")).toString();
    if (!code.isEmpty()) {
        QGuiApplication::clipboard()->setText(code);
    }
}

void EngineClient::refresh(const QString &provider)
{
    QJsonObject obj{{QStringLiteral("type"), QStringLiteral("refresh")}};
    if (!provider.isEmpty()) {
        obj.insert(QStringLiteral("provider"), provider);
    }
    sendJson(obj);
}

void EngineClient::requestDashboard(int days)
{
    m_dashboardDays = qBound(7, days, 90);
    QJsonObject obj{
        {QStringLiteral("type"), QStringLiteral("get_dashboard")},
        {QStringLiteral("days"), m_dashboardDays},
    };
    if (!m_dashboardSearch.isEmpty()) {
        obj.insert(QStringLiteral("search"), m_dashboardSearch);
    }
    sendJson(obj);
}

void EngineClient::searchDashboard(const QString &search)
{
    // As the engine reads it: at most 8 words from 200 characters.
    const QStringList words = search.left(200).toLower().split(QRegularExpression(QStringLiteral("\\s+")),
                                                            Qt::SkipEmptyParts);
    const QString normal = words.mid(0, 8).join(QLatin1Char(' '));
    if (normal == m_dashboardSearch) {
        return;
    }
    m_dashboardSearch = normal;
    requestDashboard(m_dashboardDays);
}

void EngineClient::openChat(const QVariantMap &chat)
{
    QJsonObject obj{{QStringLiteral("type"), QStringLiteral("open_chat")}};
    for (const char *key : {"provider", "id", "cwd", "title", "surface"}) {
        const QString value = chat.value(QLatin1String(key)).toString();
        if (!value.isEmpty()) {
            obj.insert(QLatin1String(key), value);
        }
    }
    sendJson(obj);
}

void EngineClient::pushConfig()
{
    if (m_rawConfig.isEmpty()) {
        m_rawConfig = QJsonObject{
            {QStringLiteral("edge"), m_edge},
            {QStringLiteral("edge_position"), m_edgePosition},
            {QStringLiteral("size"), m_sizePreset},
            {QStringLiteral("accent"), QStringLiteral("plasma")},
            {QStringLiteral("peek_seconds"), m_peekSeconds},
            {QStringLiteral("auto_hide"), m_autoHide},
            {QStringLiteral("max_providers"), m_maxProviders},
            {QStringLiteral("idle_size"), m_idleSize},
            {QStringLiteral("idle_color"), m_idleColor},
            {QStringLiteral("nub_working"), m_nubWorking},
            {QStringLiteral("nub_waiting"), m_nubWaiting},
            {QStringLiteral("notch_color"), m_notchColor},
            {QStringLiteral("screen"), m_screenName},
            {QStringLiteral("dashboard_palette"), m_dashboardPalette},
            {QStringLiteral("dashboard_colors"), QJsonArray::fromStringList(m_dashboardColors)},
            {QStringLiteral("providers"),
             QJsonObject{
                 {QStringLiteral("cursor"), m_providerCursor},
                 {QStringLiteral("claude_code"), m_providerClaudeCode},
                 {QStringLiteral("claude_desktop"), m_providerClaudeDesktop},
                 {QStringLiteral("copilot"), m_providerCopilot},
                 {QStringLiteral("grok_bot"), m_providerGrokBot},
                 {QStringLiteral("codex"), m_providerCodex},
             }},
            {QStringLiteral("alerts"),
             QJsonObject{
                 {QStringLiteral("enabled"), m_alertsEnabled},
                 {QStringLiteral("sound"), m_soundEnabled},
                 {QStringLiteral("sound_finished"), m_soundFinished},
                 {QStringLiteral("sound_waiting"), m_soundWaiting},
                 {QStringLiteral("system_notifications"), m_systemNotifications},
                 {QStringLiteral("open_notch"), m_openNotchOnAlert},
                 {QStringLiteral("open_notch_split"), m_openNotchSplit},
                 {QStringLiteral("open_notch_finished"), m_openNotchFinished},
                 {QStringLiteral("open_notch_waiting"), m_openNotchWaiting},
                 {QStringLiteral("open_notch_limits"), m_openNotchLimits},
                 {QStringLiteral("limits"), m_limitAlerts},
                 {QStringLiteral("mute_cursor"), false},
                 {QStringLiteral("mute_claude_code"), false},
                 {QStringLiteral("mute_claude_desktop"), false},
                 {QStringLiteral("mute_copilot"), false},
                 {QStringLiteral("mute_grok_bot"), false},
                 {QStringLiteral("mute_codex"), false},
             }},
        };
    } else {
        m_rawConfig.insert(QStringLiteral("edge"), m_edge);
        m_rawConfig.insert(QStringLiteral("edge_position"), m_edgePosition);
        m_rawConfig.insert(QStringLiteral("size"), m_sizePreset);
        m_rawConfig.insert(QStringLiteral("peek_seconds"), m_peekSeconds);
        m_rawConfig.insert(QStringLiteral("auto_hide"), m_autoHide);
        m_rawConfig.insert(QStringLiteral("max_providers"), m_maxProviders);
        m_rawConfig.insert(QStringLiteral("idle_size"), m_idleSize);
        m_rawConfig.insert(QStringLiteral("idle_color"), m_idleColor);
        m_rawConfig.insert(QStringLiteral("nub_working"), m_nubWorking);
        m_rawConfig.insert(QStringLiteral("nub_waiting"), m_nubWaiting);
        m_rawConfig.insert(QStringLiteral("notch_color"), m_notchColor);
        m_rawConfig.insert(QStringLiteral("screen"), m_screenName);
        m_rawConfig.insert(QStringLiteral("dashboard_palette"), m_dashboardPalette);
        m_rawConfig.insert(QStringLiteral("dashboard_colors"), QJsonArray::fromStringList(m_dashboardColors));
        QJsonObject providers = m_rawConfig.value(QStringLiteral("providers")).toObject();
        providers.insert(QStringLiteral("cursor"), m_providerCursor);
        providers.insert(QStringLiteral("claude_code"), m_providerClaudeCode);
        providers.insert(QStringLiteral("claude_desktop"), m_providerClaudeDesktop);
        providers.insert(QStringLiteral("copilot"), m_providerCopilot);
        providers.insert(QStringLiteral("grok_bot"), m_providerGrokBot);
        providers.insert(QStringLiteral("codex"), m_providerCodex);
        m_rawConfig.insert(QStringLiteral("providers"), providers);
        QJsonObject alerts = m_rawConfig.value(QStringLiteral("alerts")).toObject();
        alerts.insert(QStringLiteral("enabled"), m_alertsEnabled);
        alerts.insert(QStringLiteral("sound"), m_soundEnabled);
        alerts.insert(QStringLiteral("sound_finished"), m_soundFinished);
        alerts.insert(QStringLiteral("sound_waiting"), m_soundWaiting);
        alerts.insert(QStringLiteral("system_notifications"), m_systemNotifications);
        alerts.insert(QStringLiteral("open_notch"), m_openNotchOnAlert);
        alerts.insert(QStringLiteral("open_notch_split"), m_openNotchSplit);
        alerts.insert(QStringLiteral("open_notch_finished"), m_openNotchFinished);
        alerts.insert(QStringLiteral("open_notch_waiting"), m_openNotchWaiting);
        alerts.insert(QStringLiteral("open_notch_limits"), m_openNotchLimits);
        alerts.insert(QStringLiteral("limits"), m_limitAlerts);
        m_rawConfig.insert(QStringLiteral("alerts"), alerts);
    }

    // Ensure accent is a valid externally-tagged enum for serde.
    if (!m_rawConfig.value(QStringLiteral("accent")).isObject()
        && m_rawConfig.value(QStringLiteral("accent")).toString() == QLatin1String("plasma")) {
        m_rawConfig.insert(QStringLiteral("accent"), QStringLiteral("plasma"));
    }

    sendJson(QJsonObject{
        {QStringLiteral("type"), QStringLiteral("set_config")},
        {QStringLiteral("config"), m_rawConfig},
    });
}

void EngineClient::setEdge(const QString &edge)
{
    m_edge = edge;
    emit configChanged();
    pushConfig();
}

void EngineClient::setEdgePosition(double pos)
{
    m_edgePosition = qBound(0.0, pos, 1.0);
    emit configChanged();
    pushConfig();
}

void EngineClient::setSizePreset(const QString &size)
{
    m_sizePreset = size;
    emit configChanged();
    pushConfig();
}

void EngineClient::setAutoHide(bool hide)
{
    m_autoHide = hide;
    emit configChanged();
    pushConfig();
}

void EngineClient::setMaxProviders(int count)
{
    m_maxProviders = qBound(1, count, 5);
    emit configChanged();
    pushConfig();
}

void EngineClient::setIdleSize(double size)
{
    m_idleSize = qBound(1.0, size, 3.0);
    emit configChanged();
    pushConfig();
}

void EngineClient::setNubWorking(const QString &motion)
{
    m_nubWorking = motion;
    emit configChanged();
    pushConfig();
}

void EngineClient::setNubWaiting(const QString &motion)
{
    m_nubWaiting = motion;
    emit configChanged();
    pushConfig();
}

void EngineClient::setIdleColor(const QString &color)
{
    if (!isHexColor(color)) {
        return;
    }
    m_idleColor = color.toUpper();
    emit configChanged();
    pushConfig();
}

void EngineClient::setNotchColor(const QString &color)
{
    if (!isHexColor(color)) {
        return;
    }
    m_notchColor = color.toUpper();
    emit configChanged();
    pushConfig();
}

void EngineClient::setDashboardPalette(const QString &name)
{
    static const QStringList known = {QStringLiteral("mono"), QStringLiteral("vivid"),
                                      QStringLiteral("colorblind")};
    if (!known.contains(name)) {
        return;
    }
    m_dashboardPalette = name;
    emit configChanged();
    pushConfig();
}

void EngineClient::setDashboardColor(int index, const QString &color)
{
    // As many series as the engine keeps (`DASHBOARD_SERIES`).
    if (index < 0 || index >= 6 || (!color.isEmpty() && !isHexColor(color))) {
        return;
    }
    while (m_dashboardColors.size() <= index) {
        m_dashboardColors.append(QString());
    }
    m_dashboardColors[index] = color.toUpper();
    while (!m_dashboardColors.isEmpty() && m_dashboardColors.last().isEmpty()) {
        m_dashboardColors.removeLast();
    }
    emit configChanged();
    pushConfig();
}

void EngineClient::setScreenName(const QString &name)
{
    m_screenName = name;
    emit configChanged();
    pushConfig();
}

QVariantList EngineClient::screens() const
{
    QVariantList out;
    const QScreen *primary = QGuiApplication::primaryScreen();
    for (const QScreen *screen : QGuiApplication::screens()) {
        const QString model = screen->model().isEmpty()
            ? screen->manufacturer()
            : screen->manufacturer().isEmpty() || screen->model().startsWith(screen->manufacturer())
                ? screen->model()
                : screen->manufacturer() + QLatin1Char(' ') + screen->model();
        out.push_back(QVariantMap{
            {QStringLiteral("name"), screen->name()},
            {QStringLiteral("model"), model.trimmed()},
            {QStringLiteral("width"), screen->size().width()},
            {QStringLiteral("height"), screen->size().height()},
            {QStringLiteral("primary"), screen == primary},
        });
    }
    return out;
}

void EngineClient::placeOnScreen(QWindow *window)
{
    if (!window) {
        return;
    }
    QScreen *target = nullptr;
    for (QScreen *screen : QGuiApplication::screens()) {
        if (screen->name() == m_screenName) {
            target = screen;
            break;
        }
    }
    if (!target) {
        target = QGuiApplication::primaryScreen();
    }
    LayerShellQt::Window *layer = LayerShellQt::Window::get(window);
    if (!layer) {
        return;
    }
    // Unplugging the output dismisses the surface; keep the window so it can
    // be mapped again on the primary screen instead of quitting the app.
    layer->setCloseOnDismissed(false);
    if (!target || (layer->screen() == target && window->screen() == target)) {
        return;
    }
    // The output is fixed when the layer surface is created, so the surface
    // has to be torn down and mapped again on the new one.
    const bool shown = window->isVisible();
    if (shown) {
        window->hide();
    }
    window->setScreen(target);
    layer->setScreen(target);
    if (shown) {
        window->show();
    }
}

void EngineClient::setProviderEnabled(const QString &id, bool enabled)
{
    if (id == QLatin1String("cursor")) {
        m_providerCursor = enabled;
    } else if (id == QLatin1String("claude_code")) {
        m_providerClaudeCode = enabled;
    } else if (id == QLatin1String("claude_desktop")) {
        m_providerClaudeDesktop = enabled;
    } else if (id == QLatin1String("copilot")) {
        m_providerCopilot = enabled;
    } else if (id == QLatin1String("grok_bot")) {
        m_providerGrokBot = enabled;
    } else if (id == QLatin1String("codex")) {
        m_providerCodex = enabled;
    }
    emit configChanged();
    pushConfig();
}

void EngineClient::setAlertsEnabled(bool enabled)
{
    m_alertsEnabled = enabled;
    emit configChanged();
    pushConfig();
}

void EngineClient::setSoundEnabled(bool enabled)
{
    m_soundEnabled = enabled;
    emit configChanged();
    pushConfig();
}

void EngineClient::setSystemNotifications(bool enabled)
{
    m_systemNotifications = enabled;
    emit configChanged();
    pushConfig();
}

void EngineClient::setOpenNotchOnAlert(bool open)
{
    m_openNotchOnAlert = open;
    emit configChanged();
    pushConfig();
}

void EngineClient::setOpenNotchSplit(bool split)
{
    // Start from what the single switch said, so nothing changes yet.
    if (split) {
        m_openNotchFinished = m_openNotchOnAlert;
        m_openNotchWaiting = m_openNotchOnAlert;
        m_openNotchLimits = m_openNotchOnAlert;
    }
    m_openNotchSplit = split;
    emit configChanged();
    pushConfig();
}

void EngineClient::setOpenNotchFinished(bool open)
{
    m_openNotchFinished = open;
    emit configChanged();
    pushConfig();
}

void EngineClient::setOpenNotchWaiting(bool open)
{
    m_openNotchWaiting = open;
    emit configChanged();
    pushConfig();
}

void EngineClient::setOpenNotchLimits(bool open)
{
    m_openNotchLimits = open;
    emit configChanged();
    pushConfig();
}

void EngineClient::setLimitAlerts(bool enabled)
{
    m_limitAlerts = enabled;
    emit configChanged();
    pushConfig();
}

void EngineClient::setSoundFinished(const QString &name)
{
    m_soundFinished = name;
    emit configChanged();
    pushConfig();
}

void EngineClient::setSoundWaiting(const QString &name)
{
    m_soundWaiting = name;
    emit configChanged();
    pushConfig();
}

QString EngineClient::displayName(const QString &provider) const
{
    for (const QVariant &item : m_readings) {
        const QVariantMap map = item.toMap();
        if (map.value(QStringLiteral("provider")).toString() == provider) {
            return map.value(QStringLiteral("display_name")).toString();
        }
    }
    return provider;
}

// On Wayland a window mask is the surface's input region: everything outside
// these rectangles lets the pointer through to whatever is underneath.
void EngineClient::setInputRegion(QWindow *window, const QVariantList &rects)
{
    if (!window) {
        return;
    }
    QRegion region;
    for (const QVariant &item : rects) {
        const QRect rect = item.toRectF().toAlignedRect();
        if (!rect.isEmpty()) {
            region += rect;
        }
    }
    // An empty mask means "no mask", which would swallow the whole surface.
    if (region.isEmpty()) {
        region = QRegion(0, 0, 1, 1);
    }
    window->setMask(region);
}

void EngineClient::openSettings()
{
    emit openSettingsRequested();
}

void EngineClient::openDashboard()
{
    emit openDashboardRequested();
}

void EngineClient::triggerPeek(const QString &provider, const QString &label, const QString &kind)
{
    bool open = m_openNotchOnAlert;
    if (m_openNotchSplit) {
        if (kind == QLatin1String("finished")) {
            open = m_openNotchFinished;
        } else if (kind.startsWith(QLatin1String("limit"))) {
            open = m_openNotchLimits;
        } else {
            open = m_openNotchWaiting;
        }
    }
    if (!m_alertsEnabled || !open) {
        return;
    }
    m_peekProvider = provider;
    m_peekLabel = label;
    m_peekKind = kind;
    m_peekOpen = true;
    emit peekOpenChanged();
    m_peekTimer.start(m_peekSeconds * 1000);
}
