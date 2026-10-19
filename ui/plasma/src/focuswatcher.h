#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>

class EngineClient;

// Tells the engine which window is in front while a finished chat waits to
// be read, so looking at it marks it read (Ghostty tab, VS Code window…).
// KWin reports the active window and its caption through a small script;
// only while you are at the computer: a reply that lands in a window left in
// front while you were away stays unread until you come back to it.
class FocusWatcher : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.omeganotch.FocusWatcher")

public:
    explicit FocusWatcher(EngineClient *client, QObject *parent = nullptr);
    ~FocusWatcher() override;

public slots:
    // Called by the KWin script, on activation and on caption changes.
    Q_SCRIPTABLE void windowFocused(const QString &pid, const QString &caption);

private:
    void loadScript();
    void unloadScript();
    void check();

    EngineClient *m_client;
    QTimer m_timer;
    int m_idleId = -1;
    bool m_present = true;
    qint64 m_pid = 0;
    QString m_caption;
    // Only news is sent: the same window over the same unread chats was
    // already looked at.
    qint64 m_sentPid = 0;
    QString m_sentCaption;
    QStringList m_sentUnread;
    bool m_loaded = false;
};
