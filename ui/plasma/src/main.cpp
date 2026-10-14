#include "engineclient.h"
#include "notifications.h"

#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QDebug>

int main(int argc, char *argv[])
{
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);
    app.setOrganizationName(QStringLiteral("OmegaNotch"));
    app.setApplicationName(QStringLiteral("omega-notch"));
    app.setApplicationVersion(QStringLiteral(OMEGA_NOTCH_VERSION));
    app.setDesktopFileName(QStringLiteral("omega-notch"));
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("omega-notch")));
    app.setQuitOnLastWindowClosed(true);

    EngineClient engineClient;
    Notifications notifications;

    QObject::connect(&engineClient, &EngineClient::sessionFinished, &notifications,
                     [&](const QString &provider, const QString &label) {
                         if (!engineClient.alertsEnabled()) {
                             return;
                         }
                         const QString body = label.isEmpty()
                             ? QStringLiteral("%1 finished").arg(provider)
                             : QStringLiteral("%1 · %2 finished").arg(provider, label);
                         const QString sound = engineClient.soundEnabled()
                             ? Notifications::finishedSound(engineClient.soundFinished())
                             : QString();
                         notifications.notify(QStringLiteral("Omega Notch"), body, sound);
                     });
    QObject::connect(&engineClient, &EngineClient::sessionWaiting, &notifications,
                     [&](const QString &provider, const QString &label) {
                         if (!engineClient.alertsEnabled()) {
                             return;
                         }
                         const QString body = label.isEmpty()
                             ? QStringLiteral("%1 is waiting on you").arg(provider)
                             : QStringLiteral("%1 · %2 is waiting on you").arg(provider, label);
                         const QString sound = engineClient.soundEnabled()
                             ? Notifications::waitingSound(engineClient.soundWaiting())
                             : QString();
                         notifications.notify(QStringLiteral("Omega Notch"), body, sound);
                     });

    QObject::connect(&engineClient, &EngineClient::limitReached, &notifications,
                     [&](const QString &message) {
                         if (!engineClient.alertsEnabled()) {
                             return;
                         }
                         const QString sound = engineClient.soundEnabled()
                             ? Notifications::waitingSound(engineClient.soundWaiting())
                             : QString();
                         notifications.notify(QStringLiteral("Omega Notch"), message, sound);
                     });

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("Engine"), &engineClient);
    engine.rootContext()->setContextProperty(QStringLiteral("Notify"), &notifications);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        []() {
            qCritical("Failed to create QML root object");
            QCoreApplication::exit(1);
        },
        Qt::QueuedConnection);

    QObject::connect(&engine, &QQmlApplicationEngine::warnings, [](const QList<QQmlError> &warnings) {
        for (const QQmlError &err : warnings) {
            qWarning().noquote() << err.toString();
        }
    });

    // Prefer the module entry; fall back to resource path variants.
    const QList<QUrl> candidates{
        QUrl(QStringLiteral("qrc:/qt/qml/OmegaNotch/qml/Main.qml")),
        QUrl(QStringLiteral("qrc:/OmegaNotch/qml/Main.qml")),
        QUrl(QStringLiteral("qrc:/qml/Main.qml")),
    };

    bool loaded = false;
    for (const QUrl &url : candidates) {
        engine.load(url);
        if (!engine.rootObjects().isEmpty()) {
            loaded = true;
            qInfo().noquote() << "Loaded" << url.toString();
            break;
        }
        engine.clearComponentCache();
    }

    if (!loaded) {
        qCritical("Could not load Main.qml from any known resource path");
        return 2;
    }

    return app.exec();
}
