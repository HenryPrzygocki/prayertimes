import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "PrayerCalc.js" as Calc

PluginComponent {
    id: root
    pluginId: "prayerTimes"

    // === Settings, bound directly to pluginData ===
    // parseFloat tolerates the stray whitespace that creeps into hand-entered
    // coordinates; the old code interpolated them straight into a URL.
    property real lat: parseFloat(String(pluginData.lat || "-6.2088").trim())
    property real lon: parseFloat(String(pluginData.lon || "106.8456").trim())
    property string method: pluginData.method || "2"
    property string school: pluginData.school || "0"
    property string highLat: pluginData.highLat || "angle"
    property int hijriOffset: Number(pluginData.hijriOffset) || 0
    property int notifyThresholdSec: (Number(pluginData.notifyMinutes) || 15) * 60
    property bool iconOnly: pluginData.iconOnly ?? false
    property bool showSeconds: pluginData.showSeconds ?? false
    property bool use12H: pluginData.use12H ?? false

    // Per-prayer manual offsets in minutes, applied after computation.
    property var tuneOffsets: ({
        fajr:    Number(pluginData.tuneFajr)    || 0,
        sunrise: Number(pluginData.tuneSunrise) || 0,
        dhuhr:   Number(pluginData.tuneDhuhr)   || 0,
        asr:     Number(pluginData.tuneAsr)     || 0,
        maghrib: Number(pluginData.tuneMaghrib) || 0,
        isha:    Number(pluginData.tuneIsha)    || 0
    })

    // === Computed state ===
    // Times are fractional hours in local civil time. Tomorrow is needed because
    // after Isha the next prayer is tomorrow's Fajr, and Isha's window runs until
    // tomorrow's dawn.
    property var todayTimes: null
    property var tomorrowTimes: null
    property string hijriText: ""
    property string lastComputed: ""

    property string currName: ""
    property string nextName: ""
    property real nextAt: 0            // fractional hours, may exceed 24 (tomorrow)
    property int nextTotalSeconds: 0
    property bool _wasUrgent: false
    property bool _wasAtTime: false

    readonly property bool isUrgent: nextTotalSeconds > 0 && nextTotalSeconds <= notifyThresholdSec
    readonly property color accentColor: Theme.primary
    readonly property color accentBg: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.18)
    readonly property color subtleBg: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.05)

    // === Computation ===
    function optionsFor(date) {
        return {
            lat: root.lat,
            lon: root.lon,
            method: root.method,
            asrFactor: root.school === "1" ? 2 : 1,
            highLat: root.highLat,
            // Resolved per date so daylight-saving transitions are handled.
            tzOffset: -date.getTimezoneOffset() / 60
        }
    }

    function computeFor(date) {
        var t = Calc.computeDay(date.getFullYear(), date.getMonth() + 1, date.getDate(),
                                optionsFor(date))
        for (var k in root.tuneOffsets)
            if (t[k] !== undefined) t[k] += root.tuneOffsets[k] / 60
        return t
    }

    // Prayer times are a deterministic function of the date, so this only needs
    // to run when the date changes -- not on a polling interval.
    function recompute() {
        if (isNaN(root.lat) || isNaN(root.lon)) {
            root.todayTimes = null
            root.tomorrowTimes = null
            return
        }
        var now = new Date()
        var noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)
        var noonTomorrow = new Date(noon.getTime() + 86400000)

        root.todayTimes = computeFor(noon)
        root.tomorrowTimes = computeFor(noonTomorrow)
        root.hijriText = Calc.formatHijri(
            Calc.hijriDate(now.getFullYear(), now.getMonth() + 1, now.getDate(), root.hijriOffset))
        root.lastComputed = Qt.formatDate(now, "yyyy-MM-dd")
        updateCountdown()
    }

    // === Prayer periods ===
    // The ordered list of prayer starts spanning now, closing with tomorrow's
    // Fajr so the Isha -> Fajr countdown crosses midnight cleanly.
    readonly property var schedule: {
        if (!todayTimes || !tomorrowTimes) return []
        return [
            { name: "Fajr",    at: todayTimes.fajr },
            { name: "Dhuhr",   at: todayTimes.dhuhr },
            { name: "Asr",     at: todayTimes.asr },
            { name: "Maghrib", at: todayTimes.maghrib },
            { name: "Isha",    at: todayTimes.isha },
            { name: "Fajr",    at: tomorrowTimes.fajr + 24 }
        ]
    }

    function nowHours() {
        var d = clock.date
        return d.getHours() + d.getMinutes() / 60 + d.getSeconds() / 3600
    }

    function updateCountdown() {
        var sched = root.schedule
        if (sched.length === 0) return

        var h = nowHours()
        var idx = -1
        for (var i = 0; i < sched.length; i++)
            if (sched[i].at > h) { idx = i; break }

        // Before today's Fajr we are still inside last night's Isha.
        var curr = idx <= 0 ? "Isha" : sched[idx - 1].name
        var next = idx < 0 ? sched[sched.length - 1] : sched[idx]

        if (root.nextName !== next.name) {
            root._wasUrgent = false
            root._wasAtTime = false
        }
        root.currName = curr
        root.nextName = next.name
        root.nextAt = next.at

        var diff = Math.round((next.at - h) * 3600)
        if (diff < 0) diff += 86400
        root.nextTotalSeconds = diff

        var todayKey = Qt.formatDate(clock.date, "yyyy-MM-dd")
        var baseKey = todayKey + "|" + root.nextName + "|" + Math.round(next.at * 60)

        var urgent = diff > 0 && diff <= root.notifyThresholdSec
        if (urgent && !root._wasUrgent) {
            if (pluginService.loadPluginState("prayerTimes", "lastNotifiedThresholdKey", "") !== baseKey) {
                pluginService.savePluginState("prayerTimes", "lastNotifiedThresholdKey", baseKey)
                sendPrayerNotification()
            }
        }
        var atTime = diff <= 60 && diff > 0
        if (atTime && !root._wasAtTime) {
            if (pluginService.loadPluginState("prayerTimes", "lastNotifiedAtKey", "") !== baseKey) {
                pluginService.savePluginState("prayerTimes", "lastNotifiedAtKey", baseKey)
                sendPrayerTimeNotification()
            }
        }
        root._wasUrgent = urgent
        root._wasAtTime = atTime
    }

    // === Display helpers ===
    function hhmm(hours) {
        return Calc.toHHMM(hours)
    }

    function formatTime(time24h) {
        if (!time24h || time24h === "") return ""
        if (!root.use12H) return time24h
        var parts = time24h.split(":")
        if (parts.length < 2) return time24h
        var hours = parseInt(parts[0], 10)
        var ampm = hours >= 12 ? "PM" : "AM"
        hours = hours % 12
        if (hours === 0) hours = 12
        return (hours < 10 ? "0" : "") + hours + ":" + parts[1] + " " + ampm
    }

    function formatCountdown(totalSeconds) {
        if (totalSeconds <= 0) return root.showSeconds ? "00:00" : "0 min"
        var h  = Math.floor(totalSeconds / 3600)
        var m  = Math.floor((totalSeconds % 3600) / 60)
        var s  = totalSeconds % 60
        if (root.showSeconds) {
            var mm = (m < 10 ? "0" : "") + m
            var ss = (s < 10 ? "0" : "") + s
            if (h > 0) return (h < 10 ? "0" : "") + h + ":" + mm + ":" + ss
            return mm + ":" + ss
        }
        var mm2 = (m < 10 ? "0" : "") + m
        if (h > 0) return (h < 10 ? "0" : "") + h + ":" + mm2
        return m + " min"
    }

    readonly property string iconPath: {
        var fullUrl = Qt.resolvedUrl("icon.svg").toString()
        return fullUrl.replace("file://", "")
    }

    // === Notifications ===
    Process { id: prayerNotifyProc; running: false }
    Process { id: errorNotifyProc;  running: false }

    function sendPrayerNotification() {
        var mins = Math.ceil(root.nextTotalSeconds / 60)
        prayerNotifyProc.command = [
            "notify-send", "-a", "Prayer Widget", "-u", "critical", "-i", iconPath,
            root.nextName + " in " + mins + " min (at " + root.formatTime(root.hhmm(root.nextAt)) + ")"
        ]
        prayerNotifyProc.running = true
    }

    function sendPrayerTimeNotification() {
        prayerNotifyProc.command = [
            "notify-send", "-a", "Prayer Widget", "-u", "critical", "-i", iconPath,
            "Time for " + root.nextName
        ]
        prayerNotifyProc.running = true
    }

    // === Lifecycle ===
    onPluginServiceChanged: if (pluginService) recompute()

    onLatChanged: debounceTimer.restart()
    onLonChanged: debounceTimer.restart()
    onMethodChanged: debounceTimer.restart()
    onSchoolChanged: debounceTimer.restart()
    onHighLatChanged: debounceTimer.restart()
    onHijriOffsetChanged: debounceTimer.restart()
    onTuneOffsetsChanged: debounceTimer.restart()

    Timer {
        id: debounceTimer
        interval: 400
        repeat: false
        onTriggered: root.recompute()
    }

    SystemClock {
        id: clock
        precision: root.showSeconds ? SystemClock.Seconds : SystemClock.Minutes
        onDateChanged: {
            // Recompute only when the civil date rolls over. Prayer times are
            // indexed by the solar day, so this is the only moment they change.
            if (Qt.formatDate(clock.date, "yyyy-MM-dd") !== root.lastComputed)
                root.recompute()
            else
                root.updateCountdown()
        }
    }

    // === Prayer icons ===
    property var prayerIcons: ({
        "Fajr":     "bedtime",
        "Sunrise":  "wb_twilight",
        "Dhuhr":    "wb_sunny",
        "Asr":      "light_mode",
        "Maghrib":  "wb_twilight",
        "Isha":     "bedtime",
        "Midnight": "dark_mode"
    })

    function getPrayerIcon(name) {
        return root.prayerIcons[name] || "mosque"
    }

    // Horizontal bar pill:
    horizontalBarPill: Component {
        Row {
            spacing: root.iconOnly ? 0 : Theme.spacingXS
            rightPadding: root.iconOnly ? 0 : Theme.spacingS

            DankIcon {
                name: root.getPrayerIcon(root.currName)
                size: Theme.iconSize - 6
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: !root.iconOnly
                text: root.schedule.length > 0
                      ? (root.nextName + " " + root.formatTime(root.hhmm(root.nextAt)))
                      : "Loading…"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
                width: root.iconOnly ? 0 : implicitWidth
            }

            StyledText {
                visible: !root.iconOnly && root.schedule.length > 0
                text: "·"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                leftPadding: 2
                rightPadding: 2
                anchors.verticalCenter: parent.verticalCenter
                width: (!root.iconOnly && root.schedule.length > 0) ? implicitWidth : 0
            }

            StyledText {
                visible: !root.iconOnly && root.schedule.length > 0
                text: root.formatCountdown(root.nextTotalSeconds)
                font.pixelSize: Theme.fontSizeSmall
                font.weight: root.isUrgent ? Font.Bold : Font.Normal
                color: root.isUrgent ? root.accentColor : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
                width: (!root.iconOnly && root.schedule.length > 0) ? implicitWidth : 0
            }
        }
    }

    // Vertical bar pill:
    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: root.getPrayerIcon(root.currName)
                size: Theme.iconSize - 6
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.schedule.length > 0
                text: root.formatCountdown(root.nextTotalSeconds)
                font.pixelSize: Theme.fontSizeSmall - 2
                color: root.isUrgent ? root.accentColor : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // Popout panel:
    popoutContent: Component {
        Item {
            id: popoutRoot
            width: 260
            implicitWidth: 260
            implicitHeight: content.implicitHeight + Theme.spacingM * 2

            Column {
                id: content
                spacing: Theme.spacingS
                anchors.fill: parent
                anchors.margins: Theme.spacingM

                Item {
                    width: parent.width
                    height: Math.max(dateCol.implicitHeight, refreshPill.height)

                    Column {
                        id: dateCol
                        spacing: 2
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            text: root.hijriText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }
                    }

                    Rectangle {
                        id: refreshPill
                        width: 28
                        height: 28
                        radius: width / 2
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        color: refreshArea.containsMouse
                               ? Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.12)
                               : root.subtleBg

                        DankIcon {
                            name: "refresh"
                            size: Theme.iconSize - 4
                            color: Theme.surfaceVariantText
                            anchors.centerIn: parent
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.recompute()
                        }
                    }
                }

                // Countdown card. Themed with accent color
                Rectangle {
                    width: parent.width
                    height: cdCol.implicitHeight + Theme.spacingM * 2
                    radius: 8
                    color: root.accentBg
                    border.color: root.accentColor
                    border.width: 1

                    Column {
                        id: cdCol
                        anchors.centerIn: parent
                        spacing: 4

                        StyledText {
                            text: root.nextName !== "" ? (root.nextName + "  in") : "—"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        StyledText {
                            text: root.schedule.length > 0
                                  ? root.formatCountdown(root.nextTotalSeconds)
                                  : "—"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                            color: root.isUrgent ? root.accentColor : Theme.surfaceText
                            anchors.horizontalCenter: parent.horizontalCenter

                            Behavior on color { ColorAnimation { duration: 400 } }
                        }

                        StyledText {
                            text: root.schedule.length > 0
                                  ? ("at  " + root.formatTime(root.hhmm(root.nextAt))) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                // Prayer times list
                Repeater {
                    model: root.todayTimes ? [
                        { label: "Fajr",     time: root.hhmm(root.todayTimes.fajr),     icon: "bedtime" },
                        { label: "Sunrise",  time: root.hhmm(root.todayTimes.sunrise),  icon: "wb_twilight" },
                        { label: "Dhuhr",    time: root.hhmm(root.todayTimes.dhuhr),    icon: "wb_sunny" },
                        { label: "Asr",      time: root.hhmm(root.todayTimes.asr),      icon: "light_mode" },
                        { label: "Maghrib",  time: root.hhmm(root.todayTimes.maghrib),  icon: "wb_twilight" },
                        { label: "Isha",     time: root.hhmm(root.todayTimes.isha),     icon: "bedtime" },
                        { label: "Midnight", time: root.hhmm(root.todayTimes.midnight), icon: "dark_mode" }
                    ] : []

                    delegate: Item {
                        width: parent.width
                        height: 36

                        readonly property bool isNext: modelData.label === root.nextName
                        readonly property bool isCurr: modelData.label === root.currName

                        Rectangle {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            anchors.topMargin: 2
                            anchors.bottomMargin: 2
                            radius: height / 2
                            color: isNext ? root.accentBg : (isCurr ? root.subtleBg : "transparent")
                            border.color: isNext ? root.accentColor : "transparent"
                            border.width: isNext ? 1 : 0
                        }

                        Item {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12

                            Row {
                                spacing: Theme.spacingS
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter

                                DankIcon {
                                    name: modelData.icon
                                    size: Theme.iconSize
                                    color: isNext ? root.accentColor
                                                  : (isCurr ? Theme.surfaceText : Theme.surfaceVariantText)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: modelData.label
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: (isNext || isCurr) ? Font.Bold : Font.Normal
                                    color: isNext ? root.accentColor
                                                  : (isCurr ? Theme.surfaceText : Theme.surfaceVariantText)
                                    width: 64
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                text: root.formatTime(modelData.time)
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: (isNext || isCurr) ? Font.Bold : Font.Normal
                                color: isNext ? root.accentColor
                                              : (isCurr ? Theme.surfaceText : Theme.surfaceVariantText)
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                width: 70
                            }
                        }
                    }
                }
            }
        }
    }
}
