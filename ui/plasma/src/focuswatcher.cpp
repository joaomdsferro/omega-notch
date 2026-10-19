#include "focuswatcher.h"
#include "engineclient.h"

#include <KIdleTime>

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QStandardPaths>

namespace {

constexpr auto kPlugin = "omega-notch-focus";
constexpr auto kPath = "/FocusWatcher";
// Input more recent than this means someone is looking at the screen.
constexpr int kPresenceMs = 10000;

// Reports the active window, and its caption as it changes (a terminal tab
// switch or a new title only changes the caption).
QString scriptSource(const QString &service)
{
    return QStringLiteral(R"JS(
const service = "%1";
let current = null;
function send() {
    // No active window clears the last one, so it is not taken as in front.
    callDBus(service, "%2", "org.omeganotch.FocusWatcher", "windowFocused",
             current ? String(current.pid) : "0", current ? current.caption || "" : "");
}
function watch(window) {
    if (current) {
        try { current.captionChanged.disconnect(send); } catch (e) {}
    }
    current = window;
    if (current) current.captionChanged.connect(send);
    send();
}
workspace.windowActivated.connect(watch);
watch(workspace.activeWindow);
)JS")
        .arg(service, QLatin1String(kPath));
}

QDBusInterface scripting()
{
    return QDBusInterface(QStringLiteral("org.kde.KWin"), QStringLiteral("/Scripting"),
                          QStringLiteral("org.kde.kwin.Scripting"));
}

} // namespace

FocusWatcher::FocusWatcher(EngineClient *client, QObject *parent)
    : QObject(parent)
    , m_client(client)
{
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerObject(QLatin1String(kPath), this, QDBusConnection::ExportScriptableSlots)) {
        qWarning() << "focus watcher: could not register on the session bus";
        return;
    }

    auto *idle = KIdleTime::instance();
    m_idleId = idle->addIdleTimeout(kPresenceMs);
    connect(idle, &KIdleTime::timeoutReached, this, [this](int id, int) {
        if (id != m_idleId) {
            return;
        }
        m_present = false;
        KIdleTime::instance()->catchNextResumeEvent();
    });
    connect(idle, &KIdleTime::resumingFromIdle, this, [this] {
        m_present = true;
        check();
    });

    // A report made while the engine was away was dropped: send it again.
    connect(m_client, &EngineClient::connectedChanged, this, [this] {
        m_sentPid = 0;
        m_sentCaption.clear();
        m_sentUnread.clear();
        check();
    });

    connect(&m_timer, &QTimer::timeout, this, &FocusWatcher::check);
    m_timer.start(2000);

    loadScript();
}

FocusWatcher::~FocusWatcher()
{
    unloadScript();
}

void FocusWatcher::loadScript()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation)
                        + QStringLiteral("/omega-notch");
    QDir().mkpath(dir);
    const QString path = dir + QStringLiteral("/%1.js").arg(QLatin1String(kPlugin));
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "focus watcher: could not write the KWin script";
        return;
    }
    file.write(scriptSource(QDBusConnection::sessionBus().baseService()).toUtf8());
    file.close();

    auto kwin = scripting();
    if (!kwin.isValid()) {
        return; // Not on KWin: chats are marked read only when opened.
    }
    // One left over from a run that did not exit cleanly holds the name.
    kwin.call(QStringLiteral("unloadScript"), QLatin1String(kPlugin));
    const QDBusReply<int> id = kwin.call(QStringLiteral("loadScript"), path, QLatin1String(kPlugin));
    if (!id.isValid() || id.value() < 0) {
        qWarning() << "focus watcher: KWin refused the script";
        return;
    }
    QDBusInterface script(QStringLiteral("org.kde.KWin"),
                          QStringLiteral("/Scripting/Script%1").arg(id.value()),
                          QStringLiteral("org.kde.kwin.Script"));
    script.call(QStringLiteral("run"));
    m_loaded = true;
}

void FocusWatcher::unloadScript()
{
    if (!m_loaded) {
        return;
    }
    scripting().call(QStringLiteral("unloadScript"), QLatin1String(kPlugin));
    m_loaded = false;
}

void FocusWatcher::windowFocused(const QString &pid, const QString &caption)
{
    m_pid = pid.toLongLong();
    m_caption = caption;
    check();
}

void FocusWatcher::check()
{
    const QStringList unread = m_client->unreadLiveChats();
    if (!m_client->connected() || unread.isEmpty() || !m_present || m_pid <= 0
        || m_pid == QCoreApplication::applicationPid()) {
        return;
    }
    if (m_pid == m_sentPid && m_caption == m_sentCaption && unread == m_sentUnread) {
        return;
    }
    m_sentPid = m_pid;
    m_sentCaption = m_caption;
    m_sentUnread = unread;
    m_client->windowFocused(m_pid, m_caption);
}
