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
    property bool showPillProgress: pluginData.showPillProgress ?? true

    // === Computed state ===
    // Times are fractional hours in local civil time. Tomorrow is needed because
    // after Isha the next prayer is tomorrow's Fajr, and Isha's window runs until
    // tomorrow's dawn.
    property var yesterdayTimes: null
    property var todayTimes: null
    property var tomorrowTimes: null
    property var sunSamples: []
    property var prayerAlt: ({})
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
        root.sunSamples = sampleSun(noon)
        root.prayerAlt = samplePrayerAltitudes(noon)
        root.hijriText = Calc.formatHijri(
            Calc.hijriDate(now.getFullYear(), now.getMonth() + 1, now.getDate(), root.hijriOffset))
        root.lastComputed = Qt.formatDate(now, "yyyy-MM-dd")
        updateCountdown()
    }

    // The sun's altitude across the civil day, sampled once when the day rolls
    // over. The arc is then a fixed shape with only the sun moving along it,
    // which keeps the panel calm and lets the eye learn the silhouette.
    function sampleSun(noon) {
        var o = optionsFor(noon)
        var y = noon.getFullYear(), m = noon.getMonth() + 1, d = noon.getDate()
        var out = []
        for (var i = 0; i <= 144; i++) {
            var h = i * 24 / 144
            out.push({ h: h, alt: Calc.solarAltitude(y, m, d, h, o) })
        }
        return out
    }

    function samplePrayerAltitudes(noon) {
        var t = root.todayTimes
        if (!t) return ({})
        var o = optionsFor(noon)
        var y = noon.getFullYear(), m = noon.getMonth() + 1, d = noon.getDate()
        var out = {}
        var keys = { Fajr: "fajr", Sunrise: "sunrise", Dhuhr: "dhuhr", Asr: "asr",
                     Maghrib: "maghrib", Isha: "isha", Midnight: "midnight" }
        for (var name in keys)
            out[name] = Calc.solarAltitude(y, m, d, t[keys[name]], o)
        return out
    }

    // Colour taken from where the sun actually is. Every prayer is defined by a
    // solar altitude, so this is not decoration mapped onto the data -- it is the
    // data. Fajr and Isha come out the same indigo because they sit at the same
    // depression below the horizon, and sunrise and Maghrib share a coral for
    // the same reason.
    function skyColor(alt) {
        if (alt >= 45)  return "#E8B33C"   // high sun
        if (alt >= 15)  return "#E8993C"   // climbing or descending
        if (alt >= -1)  return "#D9603F"   // at the horizon
        if (alt >= -12) return "#7A5E9B"   // civil twilight
        return "#46578F"                   // night
    }

    function prayerColor(name) {
        var a = root.prayerAlt[name]
        return a === undefined ? Theme.surfaceVariantText : skyColor(a)
    }

    // Prayer instants paired with the altitude that defines them, for plotting.
    readonly property var dayMarks: {
        var t = root.todayTimes
        if (!t) return []
        var out = []
        var keys = [["Fajr", "fajr"], ["Sunrise", "sunrise"], ["Dhuhr", "dhuhr"],
                    ["Asr", "asr"], ["Maghrib", "maghrib"], ["Isha", "isha"]]
        for (var i = 0; i < keys.length; i++) {
            var h = t[keys[i][1]]
            if (h === undefined || isNaN(h)) continue
            out.push({ name: keys[i][0], h: h % 24, alt: root.prayerAlt[keys[i][0]] })
        }
        return out
    }

    readonly property real longestWindow: {
        var w = root.windows
        var m = 0
        for (var i = 0; i < w.length; i++) m = Math.max(m, w[i].end - w[i].start)
        return m > 0 ? m : 1
    }

    function windowLength(name) {
        var w = root.windows
        for (var i = 0; i < w.length; i++)
            if (w[i].name === name) return w[i].end - w[i].start
        return 0
    }

    readonly property real altitudeNow: {
        var s = root.sunSamples
        if (!s || s.length === 0) return 0
        var h = nowHours()
        var i = Math.max(0, Math.min(s.length - 1, Math.round(h / 24 * (s.length - 1))))
        return s[i].alt
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

    readonly property string spanSymbol: {
        var w = activeSpan
        if (!w) return nextName
        return (w.gap || w.name === "") ? nextName : w.name
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

    // "02:01" reads as a clock time, which is exactly what it is not. Units
    // remove the ambiguity at a glance and cost two characters.
    function formatSplit(totalSeconds) {
        var s = Math.max(0, totalSeconds)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
        if (root.showSeconds) return m + "m " + ((s % 60) < 10 ? "0" : "") + (s % 60) + "s"
        return m + "m"
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
    // identifying it. Rather than hunt for six unrelated glyphs, the pairs are
    // separated on the font's FILL axis: the same sun solid at noon and hollow
    // in the afternoon, the same horizon hollow at sunrise and solid at sunset.
    // One symbol, two strengths -- which is the actual difference between them.
    property var prayerIcons: ({
        "Fajr":     { name: "moon_stars",  fill: 0.0 },
        "Sunrise":  { name: "wb_twilight", fill: 0.0 },
        "Dhuhr":    { name: "wb_sunny",    fill: 1.0 },
        "Asr":      { name: "wb_sunny",    fill: 0.0 },
        "Maghrib":  { name: "wb_twilight", fill: 1.0 },
        "Isha":     { name: "bedtime",     fill: 1.0 },
        "Midnight": { name: "dark_mode",   fill: 0.0 }
    })

    function getPrayerIcon(name) {
        var i = root.prayerIcons[name]
        return i ? i.name : "mosque"
    }

    function getPrayerFill(name) {
        var i = root.prayerIcons[name]
        return i ? i.fill : 0.0
    }

    // Horizontal bar pill:
    // The arc the sun actually walks today, sampled from the same ephemeris the
    // prayer times are cut from. The prayers are drawn as points on it, because
    // that is literally what they are: the instants the sun crosses a given
    // altitude. Sunrise and Maghrib are where the curve meets the horizon, so
    // the scale explains itself without a legend.
    component SunPath: Item {
        id: sky

        readonly property real horizonFrac: 0.66   // where 0 degrees sits vertically
        readonly property int padX: 10

        function repaint() { skyCanvas.requestPaint() }

        Component.onCompleted: repaint()
        onWidthChanged: repaint()
        onHeightChanged: repaint()
        onVisibleChanged: if (visible) repaint()

        Connections {
            target: root
            function onSunSamplesChanged() { sky.repaint() }
            function onSpanProgressChanged() { sky.repaint() }
        }

        Canvas {
            id: skyCanvas
            anchors.fill: parent
            onAvailableChanged: if (available) requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()

                var samples = root.sunSamples
                if (!samples || samples.length === 0) return

                var w = width, h = height
                var x0 = sky.padX, x1 = w - sky.padX
                var horizonY = h * sky.horizonFrac

                var maxAlt = -90, minAlt = 90
                for (var i = 0; i < samples.length; i++) {
                    if (samples[i].alt > maxAlt) maxAlt = samples[i].alt
                    if (samples[i].alt < minAlt) minAlt = samples[i].alt
                }
                if (maxAlt <= 0) maxAlt = 1
                if (minAlt >= 0) minAlt = -1

                function px(hr) { return x0 + (hr / 24) * (x1 - x0) }
                function py(alt) {
                    return alt >= 0
                         ? horizonY - (alt / maxAlt) * (horizonY - 8)
                         : horizonY + (alt / minAlt) * (h - 10 - horizonY)
                }

                // Ground: everything below the horizon, so night reads as night.
                ctx.fillStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                        Theme.surfaceText.b, 0.05)
                ctx.fillRect(0, horizonY, w, h - horizonY)

                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.22)
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(0, horizonY + 0.5)
                ctx.lineTo(w, horizonY + 0.5)
                ctx.stroke()

                // The curve, coloured by where the sun is as it goes.
                ctx.lineWidth = 2
                ctx.lineCap = "round"
                for (var j = 1; j < samples.length; j++) {
                    ctx.strokeStyle = root.skyColor((samples[j].alt + samples[j - 1].alt) / 2)
                    ctx.globalAlpha = samples[j].h <= root.nowHours() ? 1.0 : 0.30
                    ctx.beginPath()
                    ctx.moveTo(px(samples[j - 1].h), py(samples[j - 1].alt))
                    ctx.lineTo(px(samples[j].h), py(samples[j].alt))
                    ctx.stroke()
                }
                ctx.globalAlpha = 1.0

                // Islamic midnight, the one marker with no visible counterpart
                // on the curve, as a hairline down to the baseline.
                var t = root.todayTimes
                if (t) {
                    var mx = px(t.midnight < 12 ? t.midnight : t.midnight - 24)
                    ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                              Theme.surfaceText.b, 0.30)
                    ctx.lineWidth = 1
                    ctx.setLineDash([2, 2])
                    ctx.beginPath()
                    ctx.moveTo(mx, horizonY)
                    ctx.lineTo(mx, h - 2)
                    ctx.stroke()
                    ctx.setLineDash([])
                }

                // Each prayer as a point on the path.
                var marks = root.dayMarks
                for (var k = 0; k < marks.length; k++) {
                    var mk = marks[k]
                    var cx = px(mk.h), cy = py(mk.alt)
                    ctx.fillStyle = root.skyColor(mk.alt)
                    ctx.beginPath()
                    ctx.arc(cx, cy, 2.6, 0, 2 * Math.PI)
                    ctx.fill()
                }

                // Where the sun is now: a filled disc above the horizon, a ring
                // below it, so day and night are distinguishable at a glance.
                var nowH = root.nowHours()
                var nowAlt = root.altitudeNow
                var sx = px(nowH), sy = py(nowAlt)
                ctx.fillStyle = root.skyColor(nowAlt)
                ctx.strokeStyle = root.skyColor(nowAlt)
                ctx.lineWidth = 2
                if (nowAlt >= 0) {
                    ctx.globalAlpha = 0.22
                    ctx.beginPath(); ctx.arc(sx, sy, 9, 0, 2 * Math.PI); ctx.fill()
                    ctx.globalAlpha = 1
                    ctx.beginPath(); ctx.arc(sx, sy, 4.5, 0, 2 * Math.PI); ctx.fill()
                } else {
                    ctx.globalAlpha = 0.18
                    ctx.beginPath(); ctx.arc(sx, sy, 9, 0, 2 * Math.PI); ctx.fill()
                    ctx.globalAlpha = 1
                    ctx.beginPath(); ctx.arc(sx, sy, 4, 0, 2 * Math.PI); ctx.stroke()
                }
                ctx.globalAlpha = 1
            }
        }

        // Horizon crossings carry their own labels, which is all the scale the
        // arc needs to be read.
        StyledText {
            x: sky.padX + (root.todayTimes ? root.todayTimes.sunrise / 24 : 0) * (sky.width - 2 * sky.padX) - width / 2
            y: sky.height * sky.horizonFrac + 3
            text: root.todayTimes ? root.formatTime(root.hhmm(root.todayTimes.sunrise)) : ""
            font.pixelSize: Theme.fontSizeSmall - 2
            color: Theme.surfaceVariantText
        }

        StyledText {
            x: sky.padX + (root.todayTimes ? root.todayTimes.maghrib / 24 : 0) * (sky.width - 2 * sky.padX) - width / 2
            y: sky.height * sky.horizonFrac + 3
            text: root.todayTimes ? root.formatTime(root.hhmm(root.todayTimes.maghrib)) : ""
            font.pixelSize: Theme.fontSizeSmall - 2
            color: Theme.surfaceVariantText
        }
    }


    // The pill carries only the symbol of the prayer being counted down to and
    // the time left. The prayer's name is legible from the symbol, and its clock
    // time is one click away in the popout -- both were spending bar width to
    // say what the countdown already says.
    // A ring around a square glyph never sat right -- circular geometry wrapped
    // around a symbol that is not circular. Progress reads better as a rule
    // beneath the whole pill: it belongs to the pill rather than fighting the
    // icon, and it is legible at two pixels where an arc was not.
    horizontalBarPill: Component {
        Column {
            spacing: 2

            Row {
                id: pillRow
                spacing: root.iconOnly ? 0 : Theme.spacingXS
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: root.getPrayerIcon(root.spanSymbol)
                    fill: root.getPrayerFill(root.spanSymbol)
                    size: Theme.iconSize - 6
                    color: root.isUrgent ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 400 } }
                }

                StyledText {
                    visible: !root.iconOnly
                    width: visible ? implicitWidth : 0
                    text: root.schedule.length > 0 ? root.formatSplit(root.spanRemainingSec) : "\u2026"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: root.isUrgent ? Font.Bold : Font.Normal
                    color: root.isUrgent ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 400 } }
                }
            }

            Rectangle {
                visible: root.showPillProgress && root.schedule.length > 0
                width: pillRow.width
                height: 2
                radius: 1
                anchors.horizontalCenter: parent.horizontalCenter
                color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.15)

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: Math.min(1, root.spanProgress) * parent.width
                    color: root.isUrgent ? Theme.error : root.accentColor

                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: root.getPrayerIcon(root.spanSymbol)
                fill: root.getPrayerFill(root.spanSymbol)
                size: Theme.iconSize - 6
                color: root.isUrgent ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter

                Behavior on color { ColorAnimation { duration: 400 } }
            }

            StyledText {
                visible: root.schedule.length > 0
                text: root.formatSplit(root.spanRemainingSec)
                font.pixelSize: Theme.fontSizeSmall - 2
                color: root.isUrgent ? Theme.error : Theme.surfaceText
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
                                    fill: stateCol.span ? root.getPrayerFill(stateCol.span.name) : 0.0
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

                        Item { width: 1; height: 4 }

                        SunPath {
                            width: parent.width
                            height: 84
                        }

                        Item { width: 1; height: 2 }

                        // The deadline.
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.spacingXS

                            StyledText {
                                text: root.activeSpan ? root.formatSplit(root.spanRemainingSec) : "—"
                                font.pixelSize: Theme.fontSizeLarge + 4
                                font.weight: Font.Bold
                                color: root.isUrgent ? Theme.error : Theme.surfaceText
                                anchors.baseline: parent.baseline

                                Behavior on color { ColorAnimation { duration: 400 } }
                            }

                            StyledText {
                                text: stateCol.inGap ? "until Dhuhr" : "left to pray"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.baseline: parent.baseline
                            }
                        }

                        // Where the span hands over, and Isha's earlier preferred
                        // limit, which is the one case the two differ.
                        StyledText {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: {
                                if (root.schedule.length === 0) return ""
                                // The span's right-hand label already carries
                                // this instant whenever the window hands straight
                                // over, which is four prayers in five.
                                var span = root.activeSpan
                                var alreadyShown = span && Math.abs(span.end - root.nextAt) < 1 / 120
                                var handover = alreadyShown
                                             ? ("then " + root.nextName)
                                             : ("then " + root.nextName + " at "
                                                + root.formatTime(root.hhmm(root.nextAt)))
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

                        // The dot carries the sky colour of the moment the
                        // prayer is defined by, so it matches the point on the
                        // arc above without needing a legend between them.
                        Rectangle {
                            id: rowDot
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: modelData.marker ? 4 : 7
                            height: width
                            radius: width / 2
                            color: root.prayerColor(modelData.label)
                        }

                        // How long the window runs, against the longest of the
                        // day. Isha's stretch and Maghrib's brevity are the sort
                        // of thing two columns of digits will never convey.
                        Rectangle {
                            visible: !modelData.marker && modelData.end !== null
                            anchors.left: parent.left
                            anchors.leftMargin: 92
                            anchors.verticalCenter: parent.verticalCenter
                            width: 46
                            height: 3
                            radius: 1.5
                            color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                           Theme.surfaceText.b, 0.10)

                            Rectangle {
                                height: parent.height
                                radius: parent.radius
                                width: Math.max(2, parent.width
                                       * root.windowLength(modelData.label) / root.longestWindow)
                                color: root.prayerColor(modelData.label)
                                opacity: 0.85
                            }
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
