#pragma once

#include <QObject>
#include <QLocalSocket>
#include <QJsonObject>
#include <QJsonArray>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QWindow>

class EngineClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QVariantList readings READ readings NOTIFY readingsChanged)
    Q_PROPERTY(QVariantList sessions READ sessions NOTIFY sessionsChanged)
    Q_PROPERTY(QVariantList chats READ chats NOTIFY activityChanged)
    Q_PROPERTY(QVariantList tokens READ tokens NOTIFY activityChanged)
    Q_PROPERTY(QVariantList dashboardPoints READ dashboardPoints NOTIFY dashboardChanged)
    Q_PROPERTY(QVariantList dashboardCosts READ dashboardCosts NOTIFY dashboardChanged)
    Q_PROPERTY(QVariantList dashboardModels READ dashboardModels NOTIFY dashboardChanged)
    Q_PROPERTY(QVariantList dashboardSessions READ dashboardSessions NOTIFY dashboardChanged)
    // The search dashboardSessions answers, as the engine read it.
    Q_PROPERTY(QString dashboardSearch READ dashboardSearch NOTIFY dashboardChanged)
    // The project it answers, and every project in the range to narrow to.
    Q_PROPERTY(QString dashboardProject READ dashboardProject NOTIFY dashboardChanged)
    Q_PROPERTY(QString dashboardSession READ dashboardSession NOTIFY dashboardChanged)
    Q_PROPERTY(QVariantList dashboardProjects READ dashboardProjects NOTIFY dashboardChanged)
    // What to change, from the engine's local rules; likeliest saving first.
    Q_PROPERTY(QVariantList dashboardSuggestions READ dashboardSuggestions NOTIFY dashboardChanged)
    Q_PROPERTY(double dashboardTotalUsd READ dashboardTotalUsd NOTIFY dashboardChanged)
    Q_PROPERTY(QString edge READ edge NOTIFY configChanged)
    Q_PROPERTY(double edgePosition READ edgePosition NOTIFY configChanged)
    Q_PROPERTY(QString sizePreset READ sizePreset NOTIFY configChanged)
    Q_PROPERTY(int peekSeconds READ peekSeconds NOTIFY configChanged)
    Q_PROPERTY(bool autoHide READ autoHide NOTIFY configChanged)
    Q_PROPERTY(int maxProviders READ maxProviders NOTIFY configChanged)
    Q_PROPERTY(double idleSize READ idleSize NOTIFY configChanged)
    // How the nub moves while a session works, and while one waits for you.
    Q_PROPERTY(QString nubWorking READ nubWorking NOTIFY configChanged)
    Q_PROPERTY(QString nubWaiting READ nubWaiting NOTIFY configChanged)
    Q_PROPERTY(QString idleColor READ idleColor NOTIFY configChanged)
    Q_PROPERTY(QString notchColor READ notchColor NOTIFY configChanged)
    // The dashboard's palette by name, and colours set over it per series
    // (an empty one keeps the palette's).
    Q_PROPERTY(QString dashboardPalette READ dashboardPalette NOTIFY configChanged)
    Q_PROPERTY(QStringList dashboardColors READ dashboardColors NOTIFY configChanged)
    Q_PROPERTY(QString screenName READ screenName NOTIFY configChanged)
    Q_PROPERTY(QVariantList screens READ screens NOTIFY screensChanged)
    Q_PROPERTY(bool alertsEnabled READ alertsEnabled NOTIFY configChanged)
    Q_PROPERTY(bool soundEnabled READ soundEnabled NOTIFY configChanged)
    Q_PROPERTY(bool systemNotifications READ systemNotifications NOTIFY configChanged)
    Q_PROPERTY(bool openNotchOnAlert READ openNotchOnAlert NOTIFY configChanged)
    Q_PROPERTY(bool openNotchSplit READ openNotchSplit NOTIFY configChanged)
    Q_PROPERTY(bool openNotchFinished READ openNotchFinished NOTIFY configChanged)
    Q_PROPERTY(bool openNotchWaiting READ openNotchWaiting NOTIFY configChanged)
    Q_PROPERTY(bool openNotchLimits READ openNotchLimits NOTIFY configChanged)
    Q_PROPERTY(bool limitAlerts READ limitAlerts NOTIFY configChanged)
    // Sound names as saved; empty means the default for that alert.
    Q_PROPERTY(QString soundFinished READ soundFinished NOTIFY configChanged)
    Q_PROPERTY(QString soundWaiting READ soundWaiting NOTIFY configChanged)
    Q_PROPERTY(bool providerCursor READ providerCursor NOTIFY configChanged)
    Q_PROPERTY(bool providerClaudeCode READ providerClaudeCode NOTIFY configChanged)
    Q_PROPERTY(bool providerClaudeDesktop READ providerClaudeDesktop NOTIFY configChanged)
    Q_PROPERTY(bool providerCopilot READ providerCopilot NOTIFY configChanged)
    Q_PROPERTY(bool providerGrokBot READ providerGrokBot NOTIFY configChanged)
    Q_PROPERTY(bool providerCodex READ providerCodex NOTIFY configChanged)
    // {state: ""|starting|pending|signed_in|failed, user_code, verification_uri, message}
    Q_PROPERTY(QVariantMap copilotLogin READ copilotLogin NOTIFY copilotLoginChanged)
    Q_PROPERTY(bool peekOpen READ peekOpen NOTIFY peekOpenChanged)
    Q_PROPERTY(QString peekProvider READ peekProvider NOTIFY peekOpenChanged)
    Q_PROPERTY(QString peekKind READ peekKind NOTIFY peekOpenChanged)
    Q_PROPERTY(QString peekLabel READ peekLabel NOTIFY peekOpenChanged)
    Q_PROPERTY(QString previewProvider READ previewProvider CONSTANT)

public:
    explicit EngineClient(QObject *parent = nullptr);

    bool connected() const { return m_connected; }
    QVariantList readings() const { return m_readings; }
    QVariantList sessions() const { return m_sessions; }
    QVariantList chats() const { return m_chats; }
    QVariantList tokens() const { return m_tokens; }
    QVariantList dashboardPoints() const { return m_dashboardPoints; }
    QVariantList dashboardCosts() const { return m_dashboardCosts; }
    QVariantList dashboardModels() const { return m_dashboardModels; }
    QVariantList dashboardSessions() const { return m_dashboardSessions; }
    QString dashboardSearch() const { return m_dashboardAnswered; }
    QString dashboardProject() const { return m_dashboardProjectAnswered; }
    QString dashboardSession() const { return m_dashboardSessionAnswered; }
    QVariantList dashboardProjects() const { return m_dashboardProjects; }
    QVariantList dashboardSuggestions() const { return m_dashboardSuggestions; }
    double dashboardTotalUsd() const { return m_dashboardTotalUsd; }
    QString edge() const { return m_edge; }
    double edgePosition() const { return m_edgePosition; }
    QString sizePreset() const { return m_sizePreset; }
    int peekSeconds() const { return m_peekSeconds; }
    bool autoHide() const { return m_autoHide; }
    int maxProviders() const { return m_maxProviders; }
    double idleSize() const { return m_idleSize; }
    QString nubWorking() const { return m_nubWorking; }
    QString nubWaiting() const { return m_nubWaiting; }
    QString idleColor() const { return m_idleColor; }
    QString notchColor() const { return m_notchColor; }
    QString dashboardPalette() const { return m_dashboardPalette; }
    QStringList dashboardColors() const { return m_dashboardColors; }
    QString screenName() const { return m_screenName; }
    QVariantList screens() const;
    bool alertsEnabled() const { return m_alertsEnabled; }
    bool soundEnabled() const { return m_soundEnabled; }
    bool systemNotifications() const { return m_systemNotifications; }
    bool openNotchOnAlert() const { return m_openNotchOnAlert; }
    bool openNotchSplit() const { return m_openNotchSplit; }
    bool openNotchFinished() const { return m_openNotchFinished; }
    bool openNotchWaiting() const { return m_openNotchWaiting; }
    bool openNotchLimits() const { return m_openNotchLimits; }
    bool limitAlerts() const { return m_limitAlerts; }
    QString soundFinished() const { return m_soundFinished; }
    QString soundWaiting() const { return m_soundWaiting; }
    bool providerCursor() const { return m_providerCursor; }
    bool providerClaudeCode() const { return m_providerClaudeCode; }
    bool providerClaudeDesktop() const { return m_providerClaudeDesktop; }
    bool providerCopilot() const { return m_providerCopilot; }
    bool providerGrokBot() const { return m_providerGrokBot; }
    bool providerCodex() const { return m_providerCodex; }
    QVariantMap copilotLogin() const { return m_copilotLogin; }
    bool peekOpen() const { return m_peekOpen; }
    QString peekProvider() const { return m_peekProvider; }
    QString peekKind() const { return m_peekKind; }
    QString peekLabel() const { return m_peekLabel; }
    // OMEGA_NOTCH_PREVIEW=<provider id> pins that provider's card open, and
    // OMEGA_NOTCH_PREVIEW=settings opens Settings at launch, for working on
    // either without driving the pointer.
    QString previewProvider() const { return qEnvironmentVariable("OMEGA_NOTCH_PREVIEW"); }

    Q_INVOKABLE void refresh(const QString &provider = QString());
    Q_INVOKABLE void requestDashboard(int days = 30);
    // Searches the dashboard's sessions; later requests keep the search
    // until it changes.
    Q_INVOKABLE void searchDashboard(const QString &search);
    // Narrows the whole dashboard to one project's sessions; empty for all.
    Q_INVOKABLE void setDashboardProject(const QString &project);
    // Narrows the dashboard's numbers to one session, by id; empty for all.
    Q_INVOKABLE void setDashboardSession(const QString &session);
    Q_INVOKABLE void setEdge(const QString &edge);
    Q_INVOKABLE void setEdgePosition(double pos);
    Q_INVOKABLE void setSizePreset(const QString &size);
    Q_INVOKABLE void setAutoHide(bool hide);
    Q_INVOKABLE void setMaxProviders(int count);
    Q_INVOKABLE void setIdleSize(double size);
    Q_INVOKABLE void setNubWorking(const QString &motion);
    Q_INVOKABLE void setNubWaiting(const QString &motion);
    Q_INVOKABLE void setIdleColor(const QString &color);
    Q_INVOKABLE void setNotchColor(const QString &color);
    Q_INVOKABLE void setDashboardPalette(const QString &name);
    // An empty colour gives the series the palette's back.
    Q_INVOKABLE void setDashboardColor(int index, const QString &color);
    Q_INVOKABLE void setScreenName(const QString &name);
    // Moves the layer surface onto the chosen output (the primary one when
    // that output is unplugged or none is chosen).
    Q_INVOKABLE void placeOnScreen(QWindow *window);
    Q_INVOKABLE void setProviderEnabled(const QString &id, bool enabled);
    Q_INVOKABLE void setAlertsEnabled(bool enabled);
    Q_INVOKABLE void setSoundEnabled(bool enabled);
    Q_INVOKABLE void setSystemNotifications(bool enabled);
    Q_INVOKABLE void setOpenNotchOnAlert(bool open);
    Q_INVOKABLE void setOpenNotchSplit(bool split);
    Q_INVOKABLE void setOpenNotchFinished(bool open);
    Q_INVOKABLE void setOpenNotchWaiting(bool open);
    Q_INVOKABLE void setOpenNotchLimits(bool open);
    Q_INVOKABLE void setLimitAlerts(bool enabled);
    Q_INVOKABLE void setSoundFinished(const QString &name);
    Q_INVOKABLE void setSoundWaiting(const QString &name);
    // Starts GitHub's device flow; once the code arrives it is copied and the
    // GitHub page opened, so all that is left is pasting it.
    Q_INVOKABLE void copilotSignIn();
    Q_INVOKABLE void openCopilotVerification();
    Q_INVOKABLE void copyCopilotCode();
    Q_INVOKABLE QString displayName(const QString &provider) const;
    Q_INVOKABLE void openSettings();
    Q_INVOKABLE void openDashboard();
    // Raises the window running this chat, or resumes it in a new one.
    Q_INVOKABLE void openChat(const QVariantMap &chat);
    Q_INVOKABLE void setInputRegion(QWindow *window, const QVariantList &rects);

signals:
    void connectedChanged();
    void readingsChanged();
    void sessionsChanged();
    void activityChanged();
    void dashboardChanged();
    void configChanged();
    void screensChanged();
    void peekOpenChanged();
    void copilotLoginChanged();
    void sessionFinished(const QString &provider, const QString &label);
    void sessionWaiting(const QString &provider, const QString &label);
    /// A usage threshold passed; `message` is ready to show.
    void limitReached(const QString &message);
    void openSettingsRequested();
    void openDashboardRequested();

private slots:
    void tryConnect();
    void onConnected();
    void onDisconnected();
    void onReadyRead();
    void onError(QLocalSocket::LocalSocketError error);

private:
    void sendJson(const QJsonObject &obj);
    void handleServerMessage(const QJsonObject &obj);
    void applySnapshot(const QJsonObject &obj);
    void applyReading(const QJsonObject &reading);
    void applySession(const QJsonObject &session);
    void applyActivity(const QJsonObject &obj);
    void applyDashboard(const QJsonObject &obj);
    void applyConfig(const QJsonObject &config);
    void pushConfig();
    void triggerPeek(const QString &provider, const QString &label, const QString &kind);
    QString socketPath() const;

    QLocalSocket m_socket;
    QByteArray m_buffer;
    QTimer m_reconnect;
    QTimer m_peekTimer;
    bool m_connected = false;
    bool m_peekOpen = false;
    QVariantList m_readings;
    QVariantList m_sessions;
    QVariantList m_chats;
    QVariantList m_tokens;
    QVariantList m_dashboardPoints;
    QVariantList m_dashboardCosts;
    QVariantList m_dashboardModels;
    QVariantList m_dashboardSessions;
    int m_dashboardDays = 30;
    QString m_dashboardSearch;
    QString m_dashboardAnswered;
    QString m_dashboardProject;
    QString m_dashboardProjectAnswered;
    QString m_dashboardSession;
    QString m_dashboardSessionAnswered;
    QVariantList m_dashboardProjects;
    QVariantList m_dashboardSuggestions;
    double m_dashboardTotalUsd = 0.0;
    QString m_peekProvider;
    QString m_peekKind;
    QString m_peekLabel;
    QString m_edge = QStringLiteral("right");
    double m_edgePosition = 0.5;
    QString m_sizePreset = QStringLiteral("medium");
    int m_peekSeconds = 5;
    bool m_autoHide = true;
    int m_maxProviders = 1;
    double m_idleSize = 1.0;
    QString m_nubWorking = QStringLiteral("shiver");
    QString m_nubWaiting = QStringLiteral("pulse");
    QString m_idleColor = QStringLiteral("#000000");
    QString m_notchColor = QStringLiteral("#000000");
    QString m_dashboardPalette = QStringLiteral("mono");
    QStringList m_dashboardColors;
    QString m_screenName;
    bool m_alertsEnabled = true;
    bool m_soundEnabled = true;
    bool m_systemNotifications = false;
    bool m_openNotchOnAlert = true;
    bool m_openNotchSplit = false;
    bool m_openNotchFinished = true;
    bool m_openNotchWaiting = true;
    bool m_openNotchLimits = true;
    bool m_limitAlerts = true;
    QString m_soundFinished;
    QString m_soundWaiting;
    bool m_providerCursor = true;
    bool m_providerClaudeCode = true;
    bool m_providerClaudeDesktop = true;
    bool m_providerCopilot = true;
    bool m_providerGrokBot = true;
    bool m_providerCodex = true;
    QVariantMap m_copilotLogin;
    QJsonObject m_rawConfig;
};
