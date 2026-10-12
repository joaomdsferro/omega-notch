#include "notifications.h"

#include <QFileInfo>
#include <QProcess>
#include <QStandardPaths>
#include <QVariantMap>

namespace {

struct Sound {
    const char *name;
    const char *label;
    // The closest sound in the bare freedesktop theme, for systems without
    // Plasma's Ocean theme.
    const char *fallback;
};

constexpr Sound kSounds[] = {
    {"completion-success", "Success", "complete"},
    {"outcome-success", "Fanfare", "complete"},
    {"message-new-instant", "Message", "message-new-instant"},
    {"message-attention", "Attention", "window-attention"},
    {"message-highlight", "Highlight", "message"},
    {"dialog-question", "Question", "window-question"},
    {"dialog-information", "Information", "dialog-information"},
    {"bell", "Bell", "bell"},
    {"alarm-clock-elapsed", "Alarm", "alarm-clock-elapsed"},
};

const Sound *findSound(const QString &name)
{
    for (const Sound &s : kSounds) {
        if (name == QLatin1String(s.name)) {
            return &s;
        }
    }
    return nullptr;
}

QString soundFile(const QString &name)
{
    const Sound *sound = findSound(name);
    if (!sound) {
        return {};
    }
    const QStringList dirs = QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation);
    const QList<QPair<QString, QString>> candidates{
        {QStringLiteral("ocean"), QLatin1String(sound->name)},
        {QStringLiteral("freedesktop"), QLatin1String(sound->name)},
        {QStringLiteral("freedesktop"), QLatin1String(sound->fallback)},
    };
    for (const auto &[theme, file] : candidates) {
        for (const QString &dir : dirs) {
            for (const char *ext : {".oga", ".ogg", ".wav"}) {
                const QString path = dir + QStringLiteral("/sounds/") + theme + QStringLiteral("/stereo/") + file
                    + QLatin1String(ext);
                if (QFileInfo::exists(path)) {
                    return path;
                }
            }
        }
    }
    return {};
}

} // namespace

Notifications::Notifications(QObject *parent)
    : QObject(parent)
{
}

QVariantList Notifications::sounds() const
{
    QVariantList list;
    for (const Sound &s : kSounds) {
        list << QVariantMap{
            {QStringLiteral("name"), QLatin1String(s.name)},
            {QStringLiteral("label"), QLatin1String(s.label)},
        };
    }
    return list;
}

QString Notifications::finishedSound(const QString &configured)
{
    return findSound(configured) ? configured : QStringLiteral("completion-success");
}

QString Notifications::waitingSound(const QString &configured)
{
    return findSound(configured) ? configured : QStringLiteral("message-attention");
}

void Notifications::notify(const QString &title, const QString &body, const QString &soundName)
{
    QStringList args{
        QStringLiteral("--app-name=Omega Notch"),
        QStringLiteral("--icon=omega-notch"),
        QStringLiteral("--urgency=normal"),
        title,
        body,
    };
    if (!soundName.isEmpty()) {
        args << QStringLiteral("--hint=string:sound-name:") + soundName;
        const QString file = soundFile(soundName);
        if (!file.isEmpty()) {
            args << QStringLiteral("--hint=string:sound-file:") + file;
        }
    }
    QProcess::startDetached(QStringLiteral("notify-send"), args);
}

void Notifications::playSound(const QString &soundName)
{
    const QString file = soundFile(soundName);
    if (file.isEmpty()) {
        return;
    }
    for (const QString &player : {QStringLiteral("pw-play"), QStringLiteral("paplay")}) {
        if (!QStandardPaths::findExecutable(player).isEmpty()) {
            QProcess::startDetached(player, {file});
            return;
        }
    }
}
