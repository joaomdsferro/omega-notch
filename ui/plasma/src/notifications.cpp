#include "notifications.h"

#include <QProcess>

Notifications::Notifications(QObject *parent)
    : QObject(parent)
{
}

void Notifications::notify(const QString &title, const QString &body, bool withSound)
{
    QStringList args{
        QStringLiteral("--app-name=Omega Notch"),
        QStringLiteral("--icon=omega-notch"),
        QStringLiteral("--urgency=normal"),
        title,
        body,
    };
    if (withSound) {
        args << QStringLiteral("--hint=string:sound-name:message-new-instant");
    }
    QProcess::startDetached(QStringLiteral("notify-send"), args);
}
