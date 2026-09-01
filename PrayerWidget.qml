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
    property bool iconOnly: pluginData.iconOnly ?? false
    property bool showSeconds: pluginData.showSeconds ?? false
    property bool use12H: pluginData.use12H ?? false
    property string pillStyle: pluginData.pillStyle || "countdown"

    // === Computed state ===
    // Times are fractional hours in local civil time. Tomorrow is needed because
    // after Isha the next prayer is tomorrow's Fajr, and Isha's window runs until
    // tomorrow's dawn.
    property var yesterdayTimes: null
    property var todayTimes: null
    property var tomorrowTimes: null
    property string hijriText: ""
    property string lastComputed: ""

    property string currName: ""
    property string nextName: ""
    property real nextAt: 0            // fractional hours, may exceed 24 (tomorrow)
    property int nextTotalSeconds: 0

    // Urgent once there is under a quarter of an hour left to pray what is open.
    readonly property bool isUrgent: spanRemainingSec > 0 && spanRemainingSec <= 900
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
        return Calc.computeDay(date.getFullYear(), date.getMonth() + 1, date.getDate(),
                               optionsFor(date))
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

        // Yesterday is needed because the small hours before dawn still belong
        // to yesterday's Isha window; tomorrow, because that window ends at
        // tomorrow's dawn.
        root.yesterdayTimes = computeFor(new Date(noon.getTime() - 86400000))
        root.todayTimes = computeFor(noon)
        root.tomorrowTimes = computeFor(new Date(noon.getTime() + 86400000))
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

    // === Prayer windows ===
    // How long each prayer may be prayed for. Every window closes when the next
    // prayer opens, with two exceptions: Fajr closes at sunrise rather than
    // running on to Dhuhr, and Isha runs to the following dawn -- though the
    // majority hold that it should not be delayed past Islamic midnight, which
    // is tracked separately as a preferred limit rather than a hard one.
    //
    // Hours may fall outside [0,24) so that a window spanning midnight stays a
    // single contiguous interval.
    readonly property var windows: {
        if (!yesterdayTimes || !todayTimes || !tomorrowTimes) return []
        var y = yesterdayTimes, t = todayTimes, m = tomorrowTimes

        // Islamic midnight lands in the small hours, so place it on whichever
        // side of 00:00 keeps it inside its own night.
        function nightMidnight(times, base) {
            return times.midnight < 12 ? times.midnight + base : times.midnight + base - 24
        }

        return [
            { name: "Isha",    start: y.isha - 24, end: t.fajr,       endLabel: "dawn",
              preferredEnd: nightMidnight(y, 0),   preferredLabel: "Islamic midnight" },
            { name: "Fajr",    start: t.fajr,      end: t.sunrise,    endLabel: "sunrise" },
            { name: "Dhuhr",   start: t.dhuhr,     end: t.asr,        endLabel: "Asr" },
            { name: "Asr",     start: t.asr,       end: t.maghrib,    endLabel: "Maghrib" },
            { name: "Maghrib", start: t.maghrib,   end: t.isha,       endLabel: "Isha" },
            { name: "Isha",    start: t.isha,      end: m.fajr + 24,  endLabel: "dawn",
              preferredEnd: nightMidnight(t, 24),  preferredLabel: "Islamic midnight" }
        ]
    }

    // The window we are inside right now, or null between sunrise and Dhuhr,
    // when no prayer is due.
    readonly property var currentWindow: {
        var h = nowHours()
        var w = root.windows
        for (var i = 0; i < w.length; i++)
            if (h >= w[i].start && h < w[i].end) return w[i]
        return null
    }

    // The stretch the interface is currently describing. Between sunrise and
    // Dhuhr no prayer is open, so the gap itself becomes the span -- which keeps
    // one card, one bar and one countdown covering every moment of the day
    // instead of the panel emptying out for five hours each morning.
    readonly property var activeSpan: {
        if (currentWindow) return currentWindow
        if (!todayTimes) return null
        return { name: "", start: todayTimes.sunrise, end: todayTimes.dhuhr,
                 endLabel: "Dhuhr", gap: true }
    }

    readonly property int spanElapsedSec: {
        var w = activeSpan
        return w ? Math.max(0, Math.round((nowHours() - w.start) * 3600)) : 0
    }

    readonly property int spanRemainingSec: {
        var w = activeSpan
        return w ? Math.max(0, Math.round((w.end - nowHours()) * 3600)) : 0
    }

    readonly property real spanProgress: {
        var total = spanElapsedSec + spanRemainingSec
        return total > 0 ? spanElapsedSec / total : 0
    }

    // Seconds until Isha's preferred cut-off, negative once it has passed.
    readonly property int preferredRemainingSec: {
        var w = currentWindow
        if (!w || w.preferredEnd === undefined) return 0
        return Math.round((w.preferredEnd - nowHours()) * 3600)
    }

    // A single hue carried at different strengths across the day, brightest at
    // noon and dimmest at night. It ties each row in the list to its band on the
    // strip without introducing a second palette to fight the theme.
    function daypartColor(name) {
        var a = name === "Dhuhr"    ? 0.85
              : name === "Asr"      ? 0.65
              : name === "Sunrise"  ? 0.55
              : name === "Maghrib"  ? 0.45
              : name === "Fajr"     ? 0.32
              : name === "Isha"     ? 0.26
              : 0.18
        return Qt.rgba(accentColor.r, accentColor.g, accentColor.b, a)
    }

    // The day as a strip: each prayer window as a proportional band running from
    // today's dawn to tomorrow's. The sunrise-to-Dhuhr gap is deliberately left
    // as bare track, so the one stretch with no prayer due is visible as a hole.
    readonly property var dayBands: {
        if (!todayTimes || !tomorrowTimes) return []
        var t = todayTimes
        return [
            { name: "Fajr",    start: t.fajr,    end: t.sunrise },
            { name: "Dhuhr",   start: t.dhuhr,   end: t.asr },
            { name: "Asr",     start: t.asr,     end: t.maghrib },
            { name: "Maghrib", start: t.maghrib, end: t.isha },
            { name: "Isha",    start: t.isha,    end: tomorrowTimes.fajr + 24 }
        ]
    }

    readonly property real dayStart: todayTimes ? todayTimes.fajr : 0
    readonly property real daySpan: (todayTimes && tomorrowTimes)
                                  ? (tomorrowTimes.fajr + 24 - todayTimes.fajr) : 24

    // Position of "now" along that strip, clamped for the pre-dawn hours which
    // belong to the previous cycle.
    readonly property real dayProgress: {
        if (!todayTimes) return 0
        return Math.max(0, Math.min(1, (nowHours() - dayStart) / daySpan))
    }

    // How far through the gap between the last prayer and the next we are, for
    // the ring style of the bar pill.
    readonly property real progressToNext: {
        var s = root.schedule
        if (s.length === 0) return 0
        var h = nowHours()
        var prev = null, next = null
        for (var i = 0; i < s.length; i++)
            if (s[i].at > h) { next = s[i]; prev = i > 0 ? s[i - 1] : null; break }
        if (!next) return 0
        // Before today's Fajr the interval opened with yesterday's Isha.
        var start = prev ? prev.at
                  : (yesterdayTimes ? yesterdayTimes.isha - 24 : next.at - 1)
        var span = next.at - start
        if (span <= 0) return 0
        return Math.max(0, Math.min(1, (h - start) / span))
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

        root.currName = curr
        root.nextName = next.name
        root.nextAt = next.at

        var diff = Math.round((next.at - h) * 3600)
        if (diff < 0) diff += 86400
        root.nextTotalSeconds = diff

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

    function formatDuration(totalSeconds) {
        var s = Math.max(0, totalSeconds)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        if (h > 0) return h + "h " + m + "m"
        if (m > 0) return m + "m"
        return "under a minute"
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


    // === Lifecycle ===
    onPluginServiceChanged: if (pluginService) recompute()

    onLatChanged: debounceTimer.restart()
    onLonChanged: debounceTimer.restart()
    onMethodChanged: debounceTimer.restart()
    onSchoolChanged: debounceTimer.restart()
    onHighLatChanged: debounceTimer.restart()
    onHijriOffsetChanged: debounceTimer.restart()

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
    // With the prayer's name gone from the bar, the symbol is the only thing
    // identifying it, so all seven are visually distinct. Asr gets the shade
    // glyph because it is the one prayer defined by shadow length rather than
    // by the sun's altitude.
    property var prayerIcons: ({
        "Fajr":     "moon_stars",
        "Sunrise":  "clear_day",
        "Dhuhr":    "wb_sunny",
        "Asr":      "wb_iridescent",
        "Maghrib":  "wb_twilight",
        "Isha":     "bedtime",
        "Midnight": "dark_mode"
    })

    function getPrayerIcon(name) {
        return root.prayerIcons[name] || "mosque"
    }

    // Horizontal bar pill:
    // Two ways to render the same fact. "countdown" spells the time left out;
    // "arc" draws it as a ring filling between one prayer and the next, trading
    // the exact figure for a smaller, more glanceable pill.
    component PrayerRing: Item {
        id: ring
        property real fraction: root.progressToNext
        property color arcColor: root.isUrgent ? root.accentColor : Theme.surfaceText

        // Must sit inside the bar pill's own padding, so it is driven by the
        // bar's thickness rather than by the icon size.
        readonly property int diameter: Math.max(16, Math.min(Theme.iconSize + 2, root.widgetThickness - 8))
        implicitWidth: diameter
        implicitHeight: diameter

        onFractionChanged: arcCanvas.requestPaint()
        onArcColorChanged: arcCanvas.requestPaint()

        Canvas {
            id: arcCanvas
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var cx = width / 2, cy = height / 2, r = width / 2 - 1.5
                ctx.lineWidth = 2
                ctx.lineCap = "round"
                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.18)
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                ctx.stroke()

                if (ring.fraction > 0) {
                    ctx.strokeStyle = ring.arcColor
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, -Math.PI / 2,
                            -Math.PI / 2 + 2 * Math.PI * ring.fraction)
                    ctx.stroke()
                }
            }
        }

        DankIcon {
            anchors.centerIn: parent
            name: root.getPrayerIcon(root.nextName)
            size: ring.diameter - 5
            color: ring.arcColor
        }
    }

    // The pill carries only the symbol of the prayer being counted down to and
    // the time left. The prayer's name is legible from the symbol, and its clock
    // time is one click away in the popout -- both were spending bar width to
    // say what the countdown already says.
    horizontalBarPill: Component {
        Row {
            spacing: root.iconOnly ? 0 : Theme.spacingXS
            rightPadding: root.iconOnly ? 0 : Theme.spacingS

            PrayerRing {
                visible: root.pillStyle === "arc"
                width: visible ? implicitWidth : 0
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                visible: root.pillStyle !== "arc"
                width: visible ? implicitWidth : 0
                name: root.getPrayerIcon(root.nextName)
                size: Theme.iconSize - 6
                color: root.isUrgent ? root.accentColor : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter

                Behavior on color { ColorAnimation { duration: 400 } }
            }

            StyledText {
                visible: !root.iconOnly
                width: visible ? implicitWidth : 0
                text: root.schedule.length > 0
                      ? root.formatCountdown(root.nextTotalSeconds)
                      : "\u2026"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: root.isUrgent ? Font.Bold : Font.Normal
                color: root.isUrgent ? root.accentColor : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter

                Behavior on color { ColorAnimation { duration: 400 } }
            }
        }
    }

    // Vertical bar pill:
    verticalBarPill: Component {
        Column {
            spacing: 2

            PrayerRing {
                visible: root.pillStyle === "arc"
                height: visible ? implicitHeight : 0
                anchors.horizontalCenter: parent.horizontalCenter
            }

            DankIcon {
                visible: root.pillStyle !== "arc"
                height: visible ? implicitHeight : 0
                name: root.getPrayerIcon(root.nextName)
                size: Theme.iconSize - 6
                color: root.isUrgent ? root.accentColor : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter

                Behavior on color { ColorAnimation { duration: 400 } }
            }

            StyledText {
                visible: root.schedule.length > 0
                height: visible ? implicitHeight : 0
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
            width: 320
            implicitWidth: 320
            implicitHeight: content.implicitHeight + Theme.spacingM * 2

            Column {
                id: content
                spacing: Theme.spacingS
                anchors.fill: parent
                anchors.margins: Theme.spacingM

                // --- Hijri date and refresh ---
                Item {
                    width: content.width
                    height: Math.max(hijriLabel.implicitHeight, refreshPill.height)

                    StyledText {
                        id: hijriLabel
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.hijriText
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
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

                // --- One card for the present moment ---
                // The two cards this replaces asked the same question twice: for
                // four of the five prayers a window closes exactly as the next
                // one opens, so "Maghrib in 2h 34m" and "Asr, 2h 34m left" were
                // the same number stacked on itself. What is actually worth
                // knowing is the deadline you are up against, so that is the
                // headline, and the prayer it hands over to is a footnote.
                Rectangle {
                    width: content.width
                    height: stateCol.implicitHeight + Theme.spacingM * 2
                    radius: 10
                    color: root.accentBg
                    border.color: root.isUrgent ? Theme.error : root.accentColor
                    border.width: 1

                    Behavior on border.color { ColorAnimation { duration: 400 } }

                    Column {
                        id: stateCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingXS

                        readonly property var span: root.activeSpan
                        readonly property bool inGap: span !== null && span.gap === true

                        // What is open, and how long it has been.
                        Item {
                            width: parent.width
                            height: openRow.implicitHeight

                            Row {
                                id: openRow
                                anchors.left: parent.left
                                spacing: Theme.spacingXS

                                DankIcon {
                                    visible: !stateCol.inGap
                                    width: visible ? implicitWidth : 0
                                    name: stateCol.span ? root.getPrayerIcon(stateCol.span.name) : "mosque"
                                    size: Theme.iconSize - 6
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: stateCol.inGap ? "No prayer due"
                                        : (stateCol.span ? stateCol.span.name : "")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: openRow.verticalCenter
                                text: stateCol.inGap
                                      ? ("since sunrise, " + root.formatDuration(root.spanElapsedSec))
                                      : ("began " + root.formatDuration(root.spanElapsedSec) + " ago")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }

                        // The deadline.
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.activeSpan ? root.formatCountdown(root.spanRemainingSec) : "—"
                            font.pixelSize: Theme.fontSizeLarge + 6
                            font.weight: Font.Bold
                            color: root.isUrgent ? Theme.error : Theme.surfaceText

                            Behavior on color { ColorAnimation { duration: 400 } }
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: stateCol.inGap ? "until Dhuhr opens" : "left to pray"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        Item { width: 1; height: 2 }

                        // The span drawn end to end, with its bounds named.
                        Item {
                            width: parent.width
                            height: 14

                            StyledText {
                                id: spanFrom
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: stateCol.span ? root.formatTime(root.hhmm(stateCol.span.start)) : ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                id: spanTo
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: stateCol.span ? root.formatTime(root.hhmm(stateCol.span.end)) : ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                            }

                            Rectangle {
                                anchors.left: spanFrom.right
                                anchors.right: spanTo.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                height: 4
                                radius: 2
                                color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                               Theme.surfaceText.b, 0.12)

                                Rectangle {
                                    height: parent.height
                                    radius: parent.radius
                                    width: Math.min(1, root.spanProgress) * parent.width
                                    color: root.isUrgent ? Theme.error : root.accentColor

                                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                                    Behavior on color { ColorAnimation { duration: 400 } }
                                }
                            }
                        }

                        // Where the span hands over, and Isha's earlier preferred
                        // limit, which is the one case the two differ.
                        StyledText {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: {
                                if (root.schedule.length === 0) return ""
                                var handover = "then " + root.nextName
                                            + " at " + root.formatTime(root.hhmm(root.nextAt))
                                var w = root.currentWindow
                                if (w && w.preferredEnd !== undefined) {
                                    if (root.preferredRemainingSec <= 0)
                                        return handover + "  ·  past " + w.preferredLabel
                                    return handover + "  ·  best before "
                                         + root.formatTime(root.hhmm(w.preferredEnd))
                                }
                                return handover
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.preferredRemainingSec < 0 ? Theme.warning : Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // --- The day at a glance ---
                // Bands are proportional to real duration, so the long Isha
                // night and the short Maghrib window are immediately legible,
                // and the morning gap shows up as bare track.
                Item {
                    width: content.width
                    height: 14
                    visible: root.dayBands.length > 0

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: 8
                        radius: 4
                        color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.08)
                    }

                    Repeater {
                        model: root.dayBands

                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool isCurrent: root.currentWindow !== null
                                                              && root.currentWindow.name === modelData.name
                            x: (modelData.start - root.dayStart) / root.daySpan * parent.width
                            width: Math.max(2, (modelData.end - modelData.start) / root.daySpan * parent.width)
                            height: 8
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: isCurrent ? root.accentColor : root.daypartColor(modelData.name)
                        }
                    }

                    Rectangle {
                        x: root.dayProgress * parent.width - width / 2
                        width: 2
                        height: parent.height
                        radius: 1
                        color: Theme.surfaceText
                    }
                }

                // --- Column header ---
                Item {
                    width: content.width
                    height: openLbl.implicitHeight

                    StyledText {
                        id: openLbl
                        anchors.right: parent.right
                        anchors.rightMargin: 10 + 52 + 18
                        text: "opens"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.7
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        text: "closes"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.7
                    }
                }

                // --- The day in full ---
                Repeater {
                    model: root.todayTimes ? [
                        { label: "Fajr",     start: root.todayTimes.fajr,     end: root.todayTimes.sunrise, marker: false },
                        { label: "Sunrise",  start: root.todayTimes.sunrise,  end: null,                    marker: true  },
                        { label: "Dhuhr",    start: root.todayTimes.dhuhr,    end: root.todayTimes.asr,     marker: false },
                        { label: "Asr",      start: root.todayTimes.asr,      end: root.todayTimes.maghrib, marker: false },
                        { label: "Maghrib",  start: root.todayTimes.maghrib,  end: root.todayTimes.isha,    marker: false },
                        { label: "Isha",     start: root.todayTimes.isha,     end: root.tomorrowTimes ? root.tomorrowTimes.fajr + 24 : null, marker: false },
                        { label: "Midnight", start: root.todayTimes.midnight, end: null,                    marker: true  }
                    ] : []

                    delegate: Item {
                        required property var modelData
                        width: content.width
                        height: modelData.marker ? 22 : 30

                        readonly property bool isNext: !modelData.marker && modelData.label === root.nextName
                        readonly property bool isCurr: !modelData.marker
                                                       && root.currentWindow !== null
                                                       && modelData.label === root.currentWindow.name
                                                       && !isNext
                        readonly property color fg: isNext ? root.accentColor
                                                  : (isCurr ? Theme.surfaceText : Theme.surfaceVariantText)

                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: height / 2
                            color: parent.isNext ? root.accentBg
                                 : (parent.isCurr ? root.subtleBg : "transparent")
                        }

                        // Seven glyphs down the edge was decoration once the
                        // strip above carried the picture. A dot in the prayer's
                        // own daypart colour does the same anchoring work and
                        // matches it to its band.
                        Rectangle {
                            id: rowDot
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: modelData.marker ? 4 : 7
                            height: width
                            radius: width / 2
                            color: parent.isNext ? root.accentColor
                                                 : root.daypartColor(modelData.label)
                        }

                        // Markers are not prayers -- they bound them. Indented,
                        // smaller and unadorned so the eye skips them.
                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: modelData.marker ? 34 : 28
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            font.pixelSize: modelData.marker ? Theme.fontSizeSmall : Theme.fontSizeMedium
                            font.weight: (parent.isNext || parent.isCurr) ? Font.Bold : Font.Normal
                            font.italic: modelData.marker
                            color: parent.fg
                            opacity: modelData.marker ? 0.75 : 1
                        }

                        // Opens and closes are separate fixed columns, so a
                        // marker's single time can never be mistaken for a
                        // closing time.
                        StyledText {
                            anchors.right: parent.right
                            anchors.rightMargin: 10 + 52 + 18
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(root.hhmm(modelData.start))
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: (parent.isNext || parent.isCurr) ? Font.Bold : Font.Normal
                            color: parent.fg
                            opacity: modelData.marker ? 0.75 : 1
                        }

                        StyledText {
                            visible: modelData.end !== null
                            anchors.right: parent.right
                            anchors.rightMargin: 10 + 52 + 4
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\u2192"
                            font.pixelSize: Theme.fontSizeSmall
                            color: parent.fg
                            opacity: 0.45
                        }

                        StyledText {
                            visible: modelData.end !== null
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.end !== null ? root.formatTime(root.hhmm(modelData.end)) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: (parent.isNext || parent.isCurr) ? Font.Bold : Font.Normal
                            color: parent.fg
                            opacity: 0.8
                        }
                    }
                }
            }
        }
    }
}
