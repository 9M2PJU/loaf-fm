import QtQuick
import app.loaf

// Loaded by the Loaf binary so the registered types and font resources match
// the application. The Python runner supplies an isolated settings directory.
Item {
    LoafCore { id: core }
    Theme { id: theme }

    Timer {
        interval: 0
        running: true
        onTriggered: {
            theme.lowPowerSetting = "off";
            var expected = Number(core.get_setting("testExpectedOpacity"));
            function check(condition, message) {
                if (!condition)
                    throw new Error(message);
            }
            try {
                check(Math.abs(theme.windowBackground.a - expected) < 0.01,
                      "Saved opacity was not loaded or sanitized");
                theme.backgroundOpacity = 0.78;
                check(Math.abs(theme.windowBackground.a - 0.78) < 0.01,
                      "Changing opacity did not update the background");
                check(theme.textMain.a === 1 && theme.primary.a === 1
                      && theme.surfaceContainer.a === 1,
                      "Foreground or popup colors became translucent");
                check(theme.backdropSurface(theme.surfaceContainerLow).a < 0.2,
                      "Inset backgrounds obscure the desktop");
                theme.lowPowerSetting = "on";
                check(theme.windowBackground.a === 1
                      && theme.backdropSurface(theme.surfaceContainerLow).a === 1,
                      "Low-power mode did not restore solid backgrounds");
                theme.lowPowerSetting = "off";
                check(Math.abs(theme.windowBackground.a - 0.78) < 0.01,
                      "Leaving low-power mode lost the preferred opacity");
                theme.backgroundOpacity = NaN;
                check(theme.windowBackground.a === 1, "Invalid opacity did not fall back to solid");
                theme.backgroundOpacity = 0.78;
                console.log("BACKGROUND_OPACITY_TEST_PASS");
                Qt.quit();
            } catch (error) {
                console.error("BACKGROUND_OPACITY_TEST_FAIL: " + error.message);
                Qt.quit();
            }
        }
    }
}
