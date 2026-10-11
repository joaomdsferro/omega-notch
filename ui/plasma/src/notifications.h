#pragma once

#include <QObject>
#include <QString>

class Notifications : public QObject
{
    Q_OBJECT
public:
    explicit Notifications(QObject *parent = nullptr);

    Q_INVOKABLE void notify(const QString &title, const QString &body, bool withSound);
};
