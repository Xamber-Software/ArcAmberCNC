#include <QtQuickTest/quicktest.h>
#include <QQuickStyle>

class Setup : public QObject {
    Q_OBJECT
public slots:
    void applicationWillBeAvailable() { QCoreApplication::setAttribute(Qt::AA_DontUseNativeMenuBar); }
    void applicationAvailable() { QQuickStyle::setStyle(QStringLiteral("Basic")); }
};

QUICK_TEST_MAIN_WITH_SETUP(betterlinuxcnc, Setup)
#include "main.moc"
