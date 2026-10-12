#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

class Notifications : public QObject
{
    Q_OBJECT
    // [{ name, label }]: the sounds offered for an alert, from the
    // freedesktop sound theme.
    Q_PROPERTY(QVariantList sounds READ sounds CONSTANT)

public:
    explicit Notifications(QObject *parent = nullptr);

    QVariantList sounds() const;

    // The sound an alert plays: the configured one when it is offered here,
    // the default for that kind of alert otherwise (an empty or macOS name).
    static QString finishedSound(const QString &configured);
    static QString waitingSound(const QString &configured);

    // soundName empty: a silent notification.
    Q_INVOKABLE void notify(const QString &title, const QString &body, const QString &soundName);
    // Plays a sound now, for trying one out in Settings.
    Q_INVOKABLE void playSound(const QString &soundName);
};
