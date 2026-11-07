import QtQuick
import Quickshell
import qs.services

ShellRoot {
    id: test
    property int phase: 0
    function check(value, message) {
        if (!value) { console.error("Glint service smoke:", message); Qt.exit(1); }
    }
    Component.onCompleted: Wallpapers.refresh()
    Timer {
        interval: 300
        running: true
        repeat: true
        onTriggered: {
            if (test.phase === 0) {
                test.check(Wallpapers.glintActive, "client not connected");
                test.check(Wallpapers.items.some(w => w.kind === "video" && w.source === "file"), "local videos missing");
                test.check(Wallpapers.items.find(w => w.id === "42").preview === "/tmp/absolute-preview.png", "absolute preview broken");
                test.check(Wallpapers.optionsFor("*").mixed.fps, "mixed display options not detected");
                Wallpapers.setDisplaySetting("DP-2", "fps", 120);
            } else if (test.phase === 1) {
                test.check(Wallpapers.glintStatus["DP-2"].options.fps === 120 && Wallpapers.glintStatus["HDMI-A-1"].options.fps === 120, "FPS not applied to both displays");
                test.check(Wallpapers.globalOptions().fps === 120, "global FPS missing");
                test.check(Wallpapers.glintStatus["DP-2"].path === "/test/42" && Wallpapers.glintStatus["HDMI-A-1"].path === "/other/video", "different wallpapers replaced");
                Wallpapers.refreshSceneSettings("*", "/test/42");
            } else if (test.phase === 2) {
                test.check(Wallpapers.propertiesFor("*", "/test/42").length === 5, "project settings missing");
                Wallpapers.setSceneSetting("*", "clock", false, "/test/42");
            } else if (test.phase === 3) {
                test.check(Wallpapers.propertiesFor("*", "/test/42")[0].value === false, "property not updated");
                Wallpapers.pauseGlint("locked");
            } else if (test.phase === 4) {
                test.check(Wallpapers.glintStatus["DP-2"].state === "paused", "lock pause failed");
                Wallpapers.resumeGlint("locked");
            } else if (test.phase === 5) {
                test.check(Wallpapers.glintStatus["DP-2"].state === "running", "unlock resume failed");
                Wallpapers.setDisplaySettings("DP-2", { volume: 0.7, mute: false });
            } else if (test.phase === 6) {
                test.check(Wallpapers.glintStatus["DP-2"].options.volume === 0.7 && Wallpapers.glintStatus["DP-2"].options.mute === false, "volume did not clear mute");
                test.check(Wallpapers.glintStatus["HDMI-A-1"].options.volume === 0.7, "volume not global");
                Wallpapers.apply("/test/local.mp4", "DP-2");
            } else if (test.phase === 7) {
                test.check(Wallpapers.glintStatus["DP-2"].options.fps === 120 && Wallpapers.glintStatus["DP-2"].options.volume === 0.7, "new wallpaper lost global options");
                test.check(Wallpapers.glintStatus["HDMI-A-1"].path === "/other/video", "global settings replaced another wallpaper");
                Wallpapers.glintReady = false;
                Wallpapers.apply("/test/42", "*");
                test.check(Wallpapers.glintError.includes("not connected"), "offline request fell back to old backend");
                console.log("Glint service smoke passed");
                Qt.quit();
            }
            test.phase++;
        }
    }
}
