#include "loaf/thumbnails.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QImage>
#include <QImageReader>
#include <QMimeDatabase>
#include <QMutex>
#include <QProcess>
#include <QQuickImageResponse>
#include <QRunnable>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QUrl>

#include <QThread>

#include <atomic>

namespace loaf {
namespace {

QString cacheRoot()
{
    QString base = qEnvironmentVariable("XDG_CACHE_HOME");
    if (base.isEmpty())
        base = QDir::homePath() + QStringLiteral("/.cache");
    return base + QStringLiteral("/thumbnails");
}

struct Flavor {
    const char *dir;
    int size;
};

Flavor flavorFor(int wanted)
{
    if (wanted <= 128)
        return {"normal", 128};
    if (wanted <= 256)
        return {"large", 256};
    if (wanted <= 512)
        return {"x-large", 512};
    return {"xx-large", 1024};
}

// One parsed $XDG_DATA_DIRS/thumbnailers/*.thumbnailer entry.
struct Thumbnailer {
    QString exec;
    QStringList mimes;
};

QList<Thumbnailer> loadThumbnailers()
{
    QList<Thumbnailer> out;
    QStringList dirs = QStandardPaths::locateAll(QStandardPaths::GenericDataLocation, QStringLiteral("thumbnailers"),
                                                 QStandardPaths::LocateDirectory);
    QSet<QString> seen;
    for (const QString &dir : dirs) {
        const QFileInfoList files = QDir(dir).entryInfoList({QStringLiteral("*.thumbnailer")}, QDir::Files);
        for (const QFileInfo &fi : files) {
            if (seen.contains(fi.fileName()))
                continue;
            seen.insert(fi.fileName());
            QFile f(fi.absoluteFilePath());
            if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
                continue;
            Thumbnailer t;
            QString tryExec;
            bool inGroup = false;
            while (!f.atEnd()) {
                const QString line = QString::fromUtf8(f.readLine()).trimmed();
                if (line.startsWith(QLatin1Char('['))) {
                    inGroup = line == QLatin1String("[Thumbnailer Entry]");
                    continue;
                }
                if (!inGroup)
                    continue;
                const int eq = line.indexOf(QLatin1Char('='));
                if (eq < 0)
                    continue;
                const QString key = line.left(eq).trimmed();
                const QString value = line.mid(eq + 1).trimmed();
                if (key == QLatin1String("Exec"))
                    t.exec = value;
                else if (key == QLatin1String("TryExec"))
                    tryExec = value;
                else if (key == QLatin1String("MimeType"))
                    t.mimes = value.split(QLatin1Char(';'), Qt::SkipEmptyParts);
            }
            if (!tryExec.isEmpty() && QStandardPaths::findExecutable(tryExec).isEmpty() && !QFileInfo(tryExec).isExecutable())
                continue;
            if (!t.exec.isEmpty() && !t.mimes.isEmpty())
                out.append(t);
        }
    }
    return out;
}

const QList<Thumbnailer> &thumbnailers()
{
    static const QList<Thumbnailer> list = loadThumbnailers();
    return list;
}

const Thumbnailer *thumbnailerFor(const QMimeType &mime)
{
    for (const Thumbnailer &t : thumbnailers()) {
        for (const QString &m : t.mimes) {
            if (mime.inherits(m))
                return &t;
        }
    }
    return nullptr;
}

// Splits an Exec line, honouring quotes, and substitutes %i %u %o %s.
QStringList expandExec(const QString &exec, const QString &input, const QString &uri, const QString &output, int size)
{
    QStringList args;
    QString cur;
    bool inQuote = false;
    bool has = false;
    for (int i = 0; i < exec.size(); ++i) {
        const QChar c = exec.at(i);
        if (c == QLatin1Char('"')) {
            inQuote = !inQuote;
            has = true;
        } else if (c.isSpace() && !inQuote) {
            if (has || !cur.isEmpty())
                args << cur;
            cur.clear();
            has = false;
        } else if (c == QLatin1Char('%') && i + 1 < exec.size()) {
            const QChar code = exec.at(++i);
            switch (code.toLatin1()) {
            case 'i': cur += input; break;
            case 'u': cur += uri; break;
            case 'o': cur += output; break;
            case 's': cur += QString::number(size); break;
            case '%': cur += QLatin1Char('%'); break;
            default: break;
            }
            has = true;
        } else {
            cur += c;
        }
    }
    if (has || !cur.isEmpty())
        args << cur;
    return args;
}

// Avoid launching several heavy thumbnailers for the same file at once.
QMutex g_inflightMutex;
QSet<QString> g_inflight;

class ThumbResponse : public QQuickImageResponse
{
public:
    explicit ThumbResponse(std::shared_ptr<std::atomic<bool>> cancelled)
        : m_cancelled(std::move(cancelled)) {}

    QQuickTextureFactory *textureFactory() const override
    {
        return QQuickTextureFactory::textureFactoryForImage(m_image);
    }
    QString errorString() const override { return m_error; }
    void cancel() override { m_cancelled->store(true); }

    void handleDone(const QImage &image, const QString &error)
    {
        m_image = image;
        m_error = image.isNull() && error.isEmpty() ? QStringLiteral("no thumbnail") : error;
        emit finished();
    }

private:
    std::shared_ptr<std::atomic<bool>> m_cancelled;
    QImage m_image;
    QString m_error;
};

// The actual work, kept out of the QObject so it is easy to follow.
class ThumbWork
{
public:
    ThumbWork(const QString &path, const QSize &requested, const std::atomic<bool> &cancelled)
        : m_path(path), m_requested(requested), m_cancelled(cancelled) {}

    QImage m_image;
    QString m_error;

    void produce()
    {
        const QFileInfo fi(m_path);
        if (!fi.isFile() || !fi.isReadable()) {
            m_error = QStringLiteral("not a readable file");
            return;
        }
        const QString root = cacheRoot();
        // Never thumbnail the thumbnail cache itself (spec).
        if (fi.absoluteFilePath().startsWith(root + QLatin1Char('/')))
            return loadPlain(fi);

        const int wanted = qMax(m_requested.width(), m_requested.height()) > 0
            ? qMax(m_requested.width(), m_requested.height()) : 128;
        const Flavor flavor = flavorFor(wanted);
        const QByteArray uri = QUrl::fromLocalFile(fi.absoluteFilePath()).toEncoded();
        const QString md5 = QString::fromLatin1(QCryptographicHash::hash(uri, QCryptographicHash::Md5).toHex());
        const QString mtime = QString::number(fi.lastModified().toSecsSinceEpoch());
        const QString cached = root + QLatin1Char('/') + QLatin1String(flavor.dir) + QLatin1Char('/') + md5 + QStringLiteral(".png");
        const QString failMarker = root + QStringLiteral("/fail/loaf-1.0/") + md5 + QStringLiteral(".png");

        // 1. Valid cached thumbnail?
        {
            QImageReader r(cached);
            if (r.canRead() && r.text(QStringLiteral("Thumb::MTime")) == mtime) {
                QImage img = r.read();
                if (!img.isNull())
                    return finish(img);
            }
        }
        // 2. Known failure for this version of the file?
        {
            QImageReader r(failMarker);
            if (r.canRead() && r.text(QStringLiteral("Thumb::MTime")) == mtime) {
                m_error = QStringLiteral("thumbnailing failed before");
                return;
            }
        }
        if (m_cancelled.load())
            return;

        // Only one job generates a given file at a time.
        {
            QMutexLocker lock(&g_inflightMutex);
            if (g_inflight.contains(cached)) {
                m_error = QStringLiteral("busy");
                return;
            }
            g_inflight.insert(cached);
        }
        QImage img = generate(fi, flavor.size, uri);
        {
            QMutexLocker lock(&g_inflightMutex);
            g_inflight.remove(cached);
        }
        if (m_cancelled.load())
            return; // not a real failure: don't write a fail marker

        if (img.isNull()) {
            QImage marker(1, 1, QImage::Format_ARGB32);
            marker.fill(Qt::transparent);
            store(marker, failMarker, uri, mtime);
            m_error = QStringLiteral("no thumbnailer could handle this file");
            return;
        }
        if (img.width() > flavor.size || img.height() > flavor.size)
            img = img.scaled(flavor.size, flavor.size, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        store(img, cached, uri, mtime);
        finish(img);
    }

    QImage generate(const QFileInfo &fi, int size, const QByteArray &uri)
    {
        static QMimeDatabase db;
        const QMimeType mime = db.mimeTypeForFile(fi);

        // Qt can decode it: scale while reading (JPEG decodes at 1/2..1/8).
        QImageReader reader(fi.absoluteFilePath());
        reader.setAutoTransform(true);
        if (reader.canRead()) {
            QSize full = reader.size();
            if (full.isValid() && (full.width() > size || full.height() > size))
                reader.setScaledSize(full.scaled(size, size, Qt::KeepAspectRatio));
            QImage img = reader.read();
            if (!img.isNull())
                return img;
        }
        if (m_cancelled.load())
            return {};

        // A system thumbnailer (ffmpegthumbnailer, evince, gdk-pixbuf, ...).
        const Thumbnailer *t = thumbnailerFor(mime);
        if (!t)
            return {};
        QTemporaryDir tmp;
        if (!tmp.isValid())
            return {};
        const QString out = tmp.filePath(QStringLiteral("thumb.png"));
        QStringList args = expandExec(t->exec, fi.absoluteFilePath(), QString::fromLatin1(uri), out, size);
        if (args.isEmpty())
            return {};
        QProcess proc;
        proc.setProgram(args.takeFirst());
        proc.setArguments(args);
        proc.setProcessChannelMode(QProcess::MergedChannels);
        proc.start();
        if (!proc.waitForStarted(3000))
            return {};
        // Poll so a cancelled request (e.g. scrolled away) stops the tool.
        for (int waited = 0; waited < 15000; waited += 100) {
            if (proc.waitForFinished(100))
                break;
            if (m_cancelled.load()) {
                proc.kill();
                proc.waitForFinished(1000);
                return {};
            }
        }
        if (proc.state() != QProcess::NotRunning) {
            proc.kill();
            proc.waitForFinished(1000);
            return {};
        }
        QImage img(out);
        return img;
    }

    static void store(const QImage &src, const QString &file, const QByteArray &uri, const QString &mtime)
    {
        QImage img = src;
        img.setText(QStringLiteral("Thumb::URI"), QString::fromLatin1(uri));
        img.setText(QStringLiteral("Thumb::MTime"), mtime);
        img.setText(QStringLiteral("Software"), QStringLiteral("Loaf"));
        QDir().mkpath(QFileInfo(file).absolutePath());
        QFile::setPermissions(QFileInfo(file).absolutePath(),
                              QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
        QSaveFile out(file);
        if (!out.open(QIODevice::WriteOnly))
            return;
        out.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        if (img.save(&out, "PNG"))
            out.commit();
        else
            out.cancelWriting();
    }

    void loadPlain(const QFileInfo &fi)
    {
        QImageReader r(fi.absoluteFilePath());
        finish(r.read());
    }

    void finish(const QImage &img)
    {
        if (img.isNull())
            return;
        if (m_requested.isValid() && !m_requested.isEmpty()
            && (img.width() > m_requested.width() || img.height() > m_requested.height()))
            m_image = img.scaled(m_requested, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        else
            m_image = img;
    }

    QString m_path;
    QSize m_requested;
    const std::atomic<bool> &m_cancelled;
};

} // namespace

ThumbnailProvider::ThumbnailProvider()
{
    // Thumbnailing is I/O and CPU heavy: two workers keep scrolling smooth
    // on low-end machines without starving the UI.
    m_pool.setMaxThreadCount(qBound(1, QThread::idealThreadCount() / 2, 2));
    m_pool.setExpiryTimeout(30000);
}

ThumbRunnable::ThumbRunnable(const QString &path, const QSize &requested, std::shared_ptr<std::atomic<bool>> cancelled)
    : m_path(path), m_requested(requested), m_cancelled(std::move(cancelled))
{
    setAutoDelete(true);
}

void ThumbRunnable::run()
{
    ThumbWork work(m_path, m_requested, *m_cancelled);
    if (!m_cancelled->load())
        work.produce();
    Q_EMIT done(work.m_image, work.m_error);
}

// id = hex(UTF-8/raw path bytes) "-" mtime; hex keeps any byte sequence
// (spaces, '%', '#', non-UTF-8) unambiguous inside an image URL.
static QString pathFromId(const QString &id)
{
    const int dash = id.indexOf(QLatin1Char('-'));
    const QByteArray hex = (dash >= 0 ? id.left(dash) : id).toLatin1();
    return QFile::decodeName(QByteArray::fromHex(hex));
}

QQuickImageResponse *ThumbnailProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    auto cancelled = std::make_shared<std::atomic<bool>>(false);
    auto *response = new ThumbResponse(cancelled);
    auto *runnable = new ThumbRunnable(pathFromId(id), requestedSize, cancelled);
    QObject::connect(runnable, &ThumbRunnable::done, response, &ThumbResponse::handleDone, Qt::QueuedConnection);
    m_pool.start(runnable);
    return response;
}

} // namespace loaf
