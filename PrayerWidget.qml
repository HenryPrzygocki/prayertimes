import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

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
    property real moonFraction: 0
    property string moonName: ""
    property var prayerAlt: ({})
    property string hijriText: ""
    property string lastComputed: ""

    property string currName: ""
    property string nextName: ""
    property real nextAt: 0            // fractional hours, may exceed 24 (tomorrow)
    property int nextTotalSeconds: 0

    // Urgent once there is under a quarter of an hour left to pray what is open.
    readonly property bool isUrgent: currentWindow !== null
                                     && spanRemainingSec > 0 && spanRemainingSec <= 900
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
        return computeDay(date.getFullYear(), date.getMonth() + 1, date.getDate(),
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
        root.hijriText = formatHijri(
            hijriDate(now.getFullYear(), now.getMonth() + 1, now.getDate(), root.hijriOffset))
        root.lastComputed = Qt.formatDate(now, "yyyy-MM-dd")
        updateCountdown()

        // The arc is the one part of this that can be done without, so it goes
        // last and cannot take the rest down with it. A QML script imported with
        // .pragma library is cached engine-wide by URL, so after this file gains
        // a function the running shell keeps the older copy until it restarts --
        // and a throw here used to skip the date, the countdown and the handover
        // line, blanking most of the panel with nothing in the log to say why.
        try {
            root.moonFraction = moonPhase(now.getFullYear(), now.getMonth() + 1, now.getDate())
            root.moonName = moonPhaseName(root.moonFraction)

            // A full turn of the sky. The ellipse closes, so the night needs no
            // cropping and the sun never leaves the frame.
            root.sunSamples = sampleSun(noon)
            root.prayerAlt = samplePrayerAltitudes(noon)
        } catch (e) {
            root.sunSamples = []
            root.prayerAlt = ({})
            root.moonName = ""
            console.warn("prayerTimes: sun path unavailable —", e)
        }
    }

    // The sun's altitude across the civil day, sampled once when the day rolls
    // over. The arc is then a fixed shape with only the sun moving along it,
    // which keeps the panel calm and lets the eye learn the silhouette.
    function sampleSun(noon) {
        var o = optionsFor(noon)
        var y = noon.getFullYear(), m = noon.getMonth() + 1, d = noon.getDate()
        var out = []
        for (var i = 0; i <= 240; i++) {
            var h = i * 24 / 240
            var pt = sunSkyPoint(y, m, d, h, o)
            out.push({ h: h, x: pt.x, z: pt.z, alt: pt.alt })
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
                     Maghrib: "maghrib", Isha: "isha", "Islamic midnight": "midnight" }
        for (var name in keys)
            out[name] = solarAltitude(y, m, d, t[keys[name]], o)
        return out
    }

    // Colour taken from where the sun actually is. Every prayer is defined by a
    // solar altitude, so this is not decoration mapped onto the data -- it is the
    // data. Fajr and Isha come out the same indigo because they sit at the same
    // depression below the horizon, and sunrise and Maghrib share a coral for
    // the same reason.
    function skyColor(alt) {
        if (alt >= 50)  return "#F2C14E"   // overhead
        if (alt >= 20)  return "#E08133"   // climbing or descending
        if (alt >= -1)  return "#CE5439"   // at the horizon
        if (alt >= -12) return "#7A5E9B"   // civil twilight
        return "#46578F"                   // night
    }

    function prayerColor(name) {
        var a = root.prayerAlt[name]
        return a === undefined ? Theme.surfaceVariantText : skyColor(a)
    }

    // Every event plotted on the curve. Each is by definition the instant the
    // sun reaches a given altitude, so the altitude is what places it -- the
    // point sits on the path rather than beside it.
    readonly property var arcMarks: {
        var t = root.todayTimes
        if (!t) return []
        var now = new Date()
        var noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)
        var o = optionsFor(noon)
        var out = []
        var keys = [["Fajr", "fajr"], ["Dhuhr", "dhuhr"], ["Asr", "asr"],
                    ["Maghrib", "maghrib"], ["Isha", "isha"],
                    ["Islamic midnight", "midnight"]]
        for (var i = 0; i < keys.length; i++) {
            var h = t[keys[i][1]]
            if (h === undefined || isNaN(h)) continue
            var pt = sunSkyPoint(noon.getFullYear(), noon.getMonth() + 1,
                                      noon.getDate(), h % 24, o)
            out.push({ name: keys[i][0], x: pt.x, z: pt.z, alt: pt.alt })
        }
        return out
    }




    // Where the sun is on that ellipse right now.
    readonly property var sunNow: {
        var d = clock.date
        if (!root.todayTimes) return null
        var noon = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 12)
        return sunSkyPoint(d.getFullYear(), d.getMonth() + 1, d.getDate(),
                                nowHours(), optionsFor(noon))
    }

    readonly property real altitudeNow: sunNow ? sunNow.alt : 0

    // Progress across the interval between one prayer and the next, which is
    // what the bar's rule sits under.
    readonly property real progressToNext: {
        var sc = root.schedule
        if (sc.length === 0) return 0
        var h = nowHours()
        var prev = null, next = null
        for (var i = 0; i < sc.length; i++)
            if (sc[i].at > h) { next = sc[i]; prev = i > 0 ? sc[i - 1] : null; break }
        if (!next) return 0
        var start = prev ? prev.at
                  : (yesterdayTimes ? yesterdayTimes.isha - 24 : next.at - 1)
        var span = next.at - start
        return span > 0 ? Math.max(0, Math.min(1, (h - start) / span)) : 0
    }

    // The bar reddens when the next prayer is nearly here; the panel reddens
    // when the open window is nearly over. Different facts, kept apart.
    readonly property bool nextImminent: nextTotalSeconds > 0 && nextTotalSeconds <= 900


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
    // How long each prayer may be prayed for. Most windows close when the next
    // prayer opens; two do not. Fajr closes at sunrise rather than running on to
    // Dhuhr, and Isha closes at Islamic midnight -- the middle of the night --
    // rather than at the following dawn. Isha may still be prayed after that out
    // of necessity, but its time has ended, so midnight is the limit shown.
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
            { name: "Isha",    start: y.isha - 24, end: nightMidnight(y, 0),  endLabel: "Islamic midnight" },
            { name: "Fajr",    start: t.fajr,      end: t.sunrise,            endLabel: "sunrise" },
            { name: "Dhuhr",   start: t.dhuhr,     end: t.asr,                endLabel: "Asr" },
            { name: "Asr",     start: t.asr,       end: t.maghrib,            endLabel: "Maghrib" },
            { name: "Maghrib", start: t.maghrib,   end: t.isha,               endLabel: "Isha" },
            { name: "Isha",    start: t.isha,      end: nightMidnight(t, 24), endLabel: "Islamic midnight" }
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
        var w = root.windows
        if (w.length === 0) return null
        var h = nowHours()
        // There are two stretches with nothing due: sunrise to Dhuhr, and now
        // Islamic midnight to dawn, since Isha's time ends at midnight.
        for (var i = 0; i < w.length - 1; i++)
            if (h >= w[i].end && h < w[i + 1].start)
                return { name: "", start: w[i].end, end: w[i + 1].start,
                         endLabel: w[i + 1].name, gap: true }
        return null
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
        return toHHMM(hours)
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
        "Islamic midnight": { name: "dark_mode", fill: 0.0 }
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
    // The moon as it actually looks tonight. Drawn rather than picked from a
    // set of glyphs, because the terminator is a smooth function of the phase
    // and a handful of fixed icons would quantise it. It sits beside the Hijri
    // date because that calendar counts exactly this.
    component MoonPhase: Item {
        id: moon
        implicitWidth: 15
        implicitHeight: 15

        Connections {
            target: root
            function onMoonFractionChanged() { moonCanvas.requestPaint() }
        }
        Component.onCompleted: moonCanvas.requestPaint()

        Canvas {
            id: moonCanvas
            anchors.fill: parent
            onAvailableChanged: if (available) requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var r = Math.min(width, height) / 2 - 0.5
                var cx = width / 2, cy = height / 2
                var p = root.moonFraction
                var k = Math.cos(2 * Math.PI * p)      // +1 new, -1 full
                var lit = (1 - k) / 2
                var waxing = p < 0.5

                var dark = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                   Theme.surfaceText.b, 0.16)
                var light = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                    Theme.surfaceText.b, 0.72)

                ctx.fillStyle = dark
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.fill()

                // The lit half, then the terminator ellipse over it: dark when a
                // crescent, light when gibbous.
                ctx.fillStyle = light
                ctx.beginPath()
                ctx.arc(cx, cy, r, -Math.PI / 2, Math.PI / 2, !waxing)
                ctx.closePath()
                ctx.fill()

                ctx.fillStyle = lit > 0.5 ? light : dark
                ctx.save()
                ctx.translate(cx, cy)
                ctx.scale(Math.max(0.001, Math.abs(k)), 1)
                ctx.beginPath(); ctx.arc(0, 0, r, 0, 2 * Math.PI); ctx.fill()
                ctx.restore()

                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.22)
                ctx.lineWidth = 0.75
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.stroke()
            }
        }
    }

    // The sun's path across the sky, drawn as the ellipse it actually is.
    //
    // Plotting altitude against clock time puts all the bend at noon and leaves
    // the flanks straight, which reads as a wedge rather than an orbit. The sun's
    // diurnal path is a circle on the celestial sphere, and a circle seen in
    // projection is an ellipse -- so projecting it is both the truer picture and
    // the one that looks right. It closes on itself, which also means the night
    // needs no cropping and the sun never leaves the frame.
    //
    // East is on the left, as it is for an observer facing the equator.
    component SunPath: Item {
        id: sky

        readonly property int padX: 12
        readonly property int padY: 7

        function repaint() { skyCanvas.requestPaint() }

        Component.onCompleted: repaint()
        onWidthChanged: repaint()
        onVisibleChanged: if (visible) repaint()

        Connections {
            target: root
            function onSunSamplesChanged() { sky.repaint() }
            function onSunNowChanged() { sky.repaint() }
        }

        Canvas {
            id: skyCanvas
            anchors.fill: parent
            onAvailableChanged: if (available) requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()

                var s = root.sunSamples
                if (!s || s.length === 0) return

                var x0 = 9, x1 = -9, z0 = 9, z1 = -9
                for (var i = 0; i < s.length; i++) {
                    if (s[i].x < x0) x0 = s[i].x
                    if (s[i].x > x1) x1 = s[i].x
                    if (s[i].z < z0) z0 = s[i].z
                    if (s[i].z > z1) z1 = s[i].z
                }
                if (x1 - x0 < 1e-6 || z1 - z0 < 1e-6) return

                var px = function (x) {
                    return sky.padX + (x - x0) / (x1 - x0) * (width - 2 * sky.padX)
                }
                var py = function (z) {
                    return sky.padY + (z1 - z) / (z1 - z0) * (height - 2 * sky.padY)
                }
                var hz = py(0)

                // Ground.
                ctx.fillStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                        Theme.surfaceText.b, 0.045)
                ctx.fillRect(0, hz, width, height - hz)

                // Daylight, filled between the arc and the horizon.
                var grad = ctx.createLinearGradient(0, sky.padY, 0, hz)
                grad.addColorStop(0, Qt.rgba(0.95, 0.76, 0.30, 0.26))
                grad.addColorStop(1, Qt.rgba(0.95, 0.76, 0.30, 0.03))
                ctx.fillStyle = grad
                ctx.beginPath()
                var started = false
                for (var d = 0; d < s.length; d++) {
                    if (s[d].z < 0) continue
                    if (!started) { ctx.moveTo(px(s[d].x), hz); started = true }
                    ctx.lineTo(px(s[d].x), py(s[d].z))
                }
                if (started) {
                    for (var e = s.length - 1; e >= 0; e--)
                        if (s[e].z >= 0) { ctx.lineTo(px(s[e].x), hz); break }
                    ctx.closePath()
                    ctx.fill()
                }

                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.20)
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(0, hz + 0.5)
                ctx.lineTo(width, hz + 0.5)
                ctx.stroke()

                // The whole ellipse faintly, then the daylight half over it, so
                // the part of the turn the sun is above ground stands out.
                ctx.lineJoin = "round"
                ctx.lineCap = "round"
                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.22)
                ctx.lineWidth = 1.4
                ctx.beginPath()
                for (var j = 0; j < s.length; j++) {
                    var xj = px(s[j].x), yj = py(s[j].z)
                    if (j === 0) ctx.moveTo(xj, yj)
                    else ctx.lineTo(xj, yj)
                }
                ctx.closePath()
                ctx.stroke()

                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.42)
                ctx.lineWidth = 1.8
                ctx.beginPath()
                var pen = false
                for (var k = 0; k < s.length; k++) {
                    if (s[k].z < 0) { pen = false; continue }
                    var xk = px(s[k].x), yk = py(s[k].z)
                    if (!pen) { ctx.moveTo(xk, yk); pen = true }
                    else ctx.lineTo(xk, yk)
                }
                ctx.stroke()

                // Each prayer as a point on the path, ringed in the panel's own
                // background so it reads against the curve behind it.
                var marks = root.arcMarks
                for (var n = 0; n < marks.length; n++) {
                    var cx = px(marks[n].x), cy = py(marks[n].z)
                    ctx.beginPath()
                    ctx.arc(cx, cy, 4.4, 0, 2 * Math.PI)
                    ctx.fillStyle = Theme.surfaceContainerHigh
                    ctx.fill()
                    ctx.beginPath()
                    ctx.arc(cx, cy, 2.9, 0, 2 * Math.PI)
                    ctx.fillStyle = root.skyColor(marks[n].alt)
                    ctx.fill()
                }

                // Where the sun is now: filled by day, hollow by night.
                var now = root.sunNow
                if (!now) return
                var sx = px(now.x), sy = py(now.z)
                var c = root.skyColor(now.alt)
                ctx.fillStyle = c
                ctx.strokeStyle = c
                ctx.globalAlpha = 0.25
                ctx.beginPath(); ctx.arc(sx, sy, 11, 0, 2 * Math.PI); ctx.fill()
                ctx.globalAlpha = 1
                if (now.alt >= 0) {
                    ctx.beginPath(); ctx.arc(sx, sy, 5.5, 0, 2 * Math.PI); ctx.fill()
                } else {
                    ctx.lineWidth = 1.8
                    ctx.beginPath(); ctx.arc(sx, sy, 4.5, 0, 2 * Math.PI); ctx.stroke()
                }
            }
        }

        // The horizon crossings, in the corners the ellipse leaves empty. Their
        // sides are not a convention: facing the equator, east really is on the
        // left, so sunrise belongs there.
        Column {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            spacing: -1

            StyledText {
                text: root.todayTimes ? root.formatTime(root.hhmm(root.todayTimes.sunrise)) : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
                opacity: 0.8
            }
            StyledText {
                text: "sunrise"
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
                opacity: 0.6
            }
        }

        Column {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: -1

            StyledText {
                anchors.right: parent.right
                text: root.todayTimes ? root.formatTime(root.hhmm(root.todayTimes.maghrib)) : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
                opacity: 0.8
            }
            StyledText {
                anchors.right: parent.right
                text: "sunset"
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
                opacity: 0.6
            }
        }
    }

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
                    name: root.getPrayerIcon(root.nextName)
                    fill: root.getPrayerFill(root.nextName)
                    size: Theme.iconSize - 6
                    color: root.nextImminent ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 400 } }
                }

                StyledText {
                    visible: !root.iconOnly
                    width: visible ? implicitWidth : 0
                    text: root.schedule.length > 0 ? root.formatSplit(root.nextTotalSeconds) : "\u2026"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: root.nextImminent ? Font.Bold : Font.Normal
                    color: root.nextImminent ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 400 } }
                }
            }

            // Inset from the content by the theme's own spacing, so it reads as
            // a deliberate margin rather than a rule that nearly reaches the
            // pill's edge and stops.
            Rectangle {
                visible: root.showPillProgress && root.schedule.length > 0
                width: Math.max(12, pillRow.width - Theme.spacingS * 2)
                height: 2
                radius: 1
                anchors.horizontalCenter: parent.horizontalCenter
                color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.15)

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: Math.min(1, root.progressToNext) * parent.width
                    color: root.nextImminent ? Theme.error : root.accentColor

                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: root.getPrayerIcon(root.nextName)
                fill: root.getPrayerFill(root.nextName)
                size: Theme.iconSize - 6
                color: root.nextImminent ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter

                Behavior on color { ColorAnimation { duration: 400 } }
            }

            StyledText {
                visible: root.schedule.length > 0
                text: root.formatSplit(root.nextTotalSeconds)
                font.pixelSize: Theme.fontSizeSmall - 2
                color: root.nextImminent ? Theme.error : Theme.surfaceText
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

                // --- Date ---
                Item {
                    width: content.width
                    height: Math.max(hijriLabel.height, refreshPill.height)

                    Row {
                        id: hijriLabel
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        MoonPhase {
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.hijriText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        anchors.left: hijriLabel.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.baseline: hijriLabel.top
                        anchors.baselineOffset: hijriLabel.height / 2 + 4
                        text: root.moonName
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.6
                        visible: width + hijriLabel.width + 40 < parent.width
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
                               : "transparent"

                        DankIcon {
                            name: "refresh"
                            size: Theme.iconSize - 4
                            color: Theme.surfaceVariantText
                            opacity: refreshArea.containsMouse ? 1.0 : 0.7
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

                // --- What is next ---
                // The panel's subject line. The first question anyone opens this
                // for is which prayer is coming and when, so it is answered first,
                // in the largest type, in a whole sentence.
                Rectangle {
                    width: content.width
                    height: nextCol.implicitHeight + Theme.spacingM * 2
                    radius: 12
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: nextCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: 6

                        Item {
                            width: parent.width
                            height: nameRow.implicitHeight

                            Row {
                                id: nameRow
                                anchors.left: parent.left
                                spacing: Theme.spacingXS

                                DankIcon {
                                    name: root.getPrayerIcon(root.nextName)
                                    fill: root.getPrayerFill(root.nextName)
                                    size: Theme.iconSize - 6
                                    color: root.prayerColor(root.nextName)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: root.nextName.toUpperCase()
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    font.letterSpacing: 0.6
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: nameRow.verticalCenter
                                text: root.schedule.length > 0
                                      ? root.formatTime(root.hhmm(root.nextAt)) : ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceVariantText
                            }
                        }

                        StyledText {
                            text: root.schedule.length > 0
                                  ? ("in " + root.formatSplit(root.nextTotalSeconds)) : "—"
                            font.pixelSize: Theme.fontSizeLarge + 8
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }

                    }
                }

                // --- How far through the current window ---
                // Linear, bounded and captioned. The caption is the whole point:
                // an unlabelled bar is a puzzle, a labelled one is an instrument.
                Column {
                    width: content.width
                    spacing: 4

                    Item {
                        width: parent.width
                        height: 12

                        StyledText {
                            id: spanFrom
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.activeSpan ? root.formatTime(root.hhmm(root.activeSpan.start)) : ""
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            id: spanTo
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.activeSpan ? root.formatTime(root.hhmm(root.activeSpan.end)) : ""
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }

                        Rectangle {
                            anchors.left: spanFrom.right
                            anchors.right: spanTo.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            height: 6
                            radius: 3
                            color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                           Theme.surfaceText.b, 0.10)

                            Rectangle {
                                height: parent.height
                                radius: parent.radius
                                width: Math.min(1, root.spanProgress) * parent.width
                                color: root.isUrgent ? Theme.error : Theme.primary

                                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 400 } }
                            }
                        }
                    }

                    // What is open and how much of it is left. How long ago it
                    // began is the one number here nobody acts on.
                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: {
                            var w = root.activeSpan
                            if (!w) return ""
                            if (w.gap) return "No prayer due"
                            return w.name + "  ·  " + root.formatSplit(root.spanRemainingSec) + " remaining"
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: root.isUrgent ? Font.Medium : Font.Normal
                        color: root.isUrgent ? Theme.error : Theme.surfaceVariantText

                        Behavior on color { ColorAnimation { duration: 400 } }
                    }
                }

                // --- Where the sun is ---
                SunPath {
                    width: content.width
                    height: 104
                    visible: root.sunSamples.length > 0
                }

                Rectangle {
                    width: content.width
                    height: 1
                    color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.08)
                }

                // --- Column header ---
                Item {
                    width: content.width
                    height: 16

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 84
                        anchors.verticalCenter: parent.verticalCenter
                        text: "opens"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.6
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: "closes"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.6
                    }
                }

                // --- The whole day ---
                Repeater {
                    model: root.todayTimes ? [
                        { label: "Fajr",             start: root.todayTimes.fajr,     end: root.todayTimes.sunrise, marker: false },
                        { label: "sunrise",          start: root.todayTimes.sunrise,  end: null,                    marker: true  },
                        { label: "Dhuhr",            start: root.todayTimes.dhuhr,    end: root.todayTimes.asr,     marker: false },
                        { label: "Asr",              start: root.todayTimes.asr,      end: root.todayTimes.maghrib, marker: false },
                        { label: "Maghrib",          start: root.todayTimes.maghrib,  end: root.todayTimes.isha,    marker: false },
                        { label: "Isha",             start: root.todayTimes.isha,     end: root.todayTimes.midnight, marker: false },
                        { label: "Islamic midnight", start: root.todayTimes.midnight, end: null,                    marker: true  }
                    ] : []

                    delegate: Item {
                        required property var modelData
                        width: content.width
                        height: modelData.marker ? 24 : 30

                        readonly property bool isNext: !modelData.marker && modelData.label === root.nextName
                        readonly property bool isCurr: !modelData.marker
                                                       && root.currentWindow !== null
                                                       && modelData.label === root.currentWindow.name
                                                       && !isNext

                        // State lives in the row's fill and weight; identity lives
                        // in the dot's colour. Two channels, never mixed.
                        // Only what is open gets a fill. What is next is said in
                        // words, so two rows are never lit at once.
                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: height / 2
                            color: parent.isCurr
                                   ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14)
                                   : "transparent"
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: modelData.marker ? 4 : 7
                            height: width
                            radius: width / 2
                            color: root.prayerColor(modelData.label)
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: modelData.marker ? 30 : 28
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 5

                            StyledText {
                                text: modelData.label
                                font.pixelSize: modelData.marker ? Theme.fontSizeSmall : Theme.fontSizeMedium
                                font.weight: isCurr ? Font.Bold : Font.Normal
                                font.italic: modelData.marker
                                color: Theme.surfaceText
                                opacity: modelData.marker ? 0.75 : 1
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                visible: isNext
                                text: "upcoming"
                                font.pixelSize: Theme.fontSizeSmall - 2
                                font.italic: true
                                color: Theme.surfaceVariantText
                                opacity: 0.8
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        // Two right-aligned columns. The headers name them, so no
                        // arrow is needed in seven consecutive rows.
                        StyledText {
                            visible: !modelData.marker
                            anchors.right: parent.right
                            anchors.rightMargin: 84
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(root.hhmm(modelData.start))
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: isCurr ? Font.Bold : Font.Normal
                            color: Theme.surfaceText
                        }

                        StyledText {
                            visible: !modelData.marker
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.end !== null
                                  ? root.formatTime(root.hhmm(modelData.end)) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: isCurr ? Font.Bold : Font.Normal
                            color: Theme.surfaceText
                            opacity: 0.85
                        }

                        // Sunrise and Islamic midnight open and close nothing, so
                        // their single time sits centred across both columns
                        // rather than pretending to be an opening time.
                        StyledText {
                            visible: modelData.marker
                            x: parent.width - 122 + (110 - width) / 2
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(root.hhmm(modelData.start))
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            opacity: 0.75
                        }
                    }
                }
            }
        }
    }

    // ===== BEGIN CALC =====
    // The calculation lives here rather than in an imported .js because
    // Quickshell caches an imported script by URL for the life of the
    // process: a plugin reload cache-busts the .qml but not the script, so
    // edits to the maths silently did not take until the shell was
    // restarted. Everything between these markers is plain function
    // declarations, which is what lets test/extract.mjs lift it back out
    // and run it under node unchanged.
    // Local prayer-time computation. Replaces the Aladhan HTTP API with the same
    // underlying algorithm (Zarrabi-Zadeh / PrayTimes), so no network is involved.
    //
    // Every prayer is the instant the sun reaches a defined altitude, found by
    // inverting the hour-angle equation
    //
    //     cos H = (sin a - sin(lat) sin(decl)) / (cos(lat) cos(decl))
    //
    // with `a` the sun's altitude. The calculation methods differ only in which
    // altitude counts as dawn (Fajr) and nightfall (Isha); Asr is the one prayer
    // defined by shadow length instead, and Maghrib/Sunrise sit at -0.833 deg to
    // account for refraction (34') plus the solar semidiameter (16').

    // === Degree-based trig ===
    function dsin(d) { return Math.sin(d * Math.PI / 180) }
    function dcos(d) { return Math.cos(d * Math.PI / 180) }
    function dtan(d) { return Math.tan(d * Math.PI / 180) }
    function dasin(x) { return Math.asin(x) * 180 / Math.PI }
    function dacos(x) { return Math.acos(x) * 180 / Math.PI }
    function datan2(y, x) { return Math.atan2(y, x) * 180 / Math.PI }
    function darccot(x) { return Math.atan(1 / x) * 180 / Math.PI }

    function fixAngle(a) { return fixRange(a, 360) }
    function fixHour(a) { return fixRange(a, 24) }
    function fixRange(a, range) {
        a = a - range * Math.floor(a / range)
        return a < 0 ? a + range : a
    }

    // === Solar ephemeris ===
    // Low-precision series from the Astronomical Almanac; ~0.01 deg, which is two
    // orders of magnitude finer than the minute-level resolution we display.
    function julianDay(year, month, day) {
        if (month <= 2) { year -= 1; month += 12 }
        var a = Math.floor(year / 100)
        var b = 2 - a + Math.floor(a / 4)
        return Math.floor(365.25 * (year + 4716)) + Math.floor(30.6001 * (month + 1))
             + day + b - 1524.5
    }

    // Returns { decl: solar declination (deg), eqt: equation of time (hours) }.
    function sunPosition(jd) {
        var D = jd - 2451545.0
        var g = fixAngle(357.529 + 0.98560028 * D)   // mean anomaly
        var q = fixAngle(280.459 + 0.98564736 * D)   // mean longitude
        var L = fixAngle(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g))  // apparent longitude
        var e = 23.439 - 0.00000036 * D              // obliquity of the ecliptic
        var RA = fixHour(datan2(dcos(e) * dsin(L), dcos(L)) / 15)    // right ascension (h)
        return { decl: dasin(dsin(e) * dsin(L)), eqt: q / 15 - RA }
    }

    // === Calculation methods ===
    // Parameters mirror aladhan.com/v1/methods so results stay comparable.
    // `isha` is a depression angle in degrees, or { minutes: n } for a fixed offset
    // after Maghrib. `maghrib` defaults to the sunset angle unless a method
    // (the Jafari ones) defines its own depression.
    function methodTable() {
        return {
            "0":  { name: "Shia Ithna-Ashari, Leva Institute, Qum", fajr: 16,   isha: 14,             maghribAngle: 4,   midnight: "jafari" },
            "1":  { name: "University of Islamic Sciences, Karachi", fajr: 18,  isha: 18 },
            "2":  { name: "Islamic Society of North America (ISNA)", fajr: 15,  isha: 15 },
            "3":  { name: "Muslim World League",                    fajr: 18,   isha: 17 },
            "4":  { name: "Umm Al-Qura University, Makkah",          fajr: 18.5, isha: { minutes: 90, ramadanMinutes: 120 } },
            "5":  { name: "Egyptian General Authority of Survey",    fajr: 19.5, isha: 17.5 },
            "7":  { name: "Institute of Geophysics, Tehran",         fajr: 17.7, isha: 14,             maghribAngle: 4.5, midnight: "jafari" },
            "8":  { name: "Gulf Region",                            fajr: 19.5, isha: { minutes: 90 } },
            "9":  { name: "Kuwait",                                 fajr: 18,   isha: 17.5 },
            "10": { name: "Qatar",                                  fajr: 18,   isha: { minutes: 90 } },
            "11": { name: "Majlis Ugama Islam Singapura",           fajr: 20,   isha: 18 },
            "12": { name: "Union Organization Islamic de France",   fajr: 12,   isha: 12 },
            "13": { name: "Diyanet İşleri Başkanlığı, Turkey",      fajr: 18,   isha: 17,
                    offsets: { sunrise: -7, dhuhr: 5, asr: 5, sunset: 7 } },
            "14": { name: "Spiritual Administration of Muslims of Russia", fajr: 16, isha: 15 },
            "16": { name: "Dubai (experimental)",                   fajr: 18.2, isha: 18.2,
                    offsets: { dhuhr: 3, asr: 1, sunset: 3 } },
            "17": { name: "Jabatan Kemajuan Islam Malaysia (JAKIM)", fajr: 20,  isha: 18 },
            "18": { name: "Tunisia",                                fajr: 18,   isha: 18 },
            "19": { name: "Algeria",                                fajr: 18,   isha: 17 },
            "20": { name: "Kementerian Agama Republik Indonesia",   fajr: 20,   isha: 18 },
            "21": { name: "Morocco",                                fajr: 19,   isha: 17,
                    maghribMinutes: 5, offsets: { dhuhr: 5 } },
            "22": { name: "Comunidade Islamica de Lisboa",          fajr: 18,   isha: { minutes: 77 },
                    maghribMinutes: 3, offsets: { dhuhr: 5 } },
            "23": { name: "Ministry of Awqaf, Jordan",              fajr: 18,   isha: 18,             maghribMinutes: 5 }
        }
    }

    function sunsetAngle() { return 0.833 }   // refraction + solar semidiameter

    // === Core ===
    // opts: { lat, lon, tzOffset (hours, DST-aware), method, asrFactor (1 Shafi | 2 Hanafi),
    //         highLat ("angle" | "nightmiddle" | "seventh" | "none") }
    // Returns times as fractional hours in local civil time, or null where the sun
    // never reaches the required altitude and no adjustment is requested.
    function computeDay(year, month, day, opts) {
        var lat = opts.lat
        var lon = opts.lon
        var tz = opts.tzOffset
        var mt = methodTable()
        var m = mt[String(opts.method)] || mt["3"]
        var asrFactor = opts.asrFactor || 1
        var jd = julianDay(year, month, day) - lon / (15 * 24)

        function midDay(t) {
            return fixHour(12 - sunPosition(jd + t).eqt)
        }

        // Time (in hours) at which the sun sits `angle` degrees below the horizon.
        // dir "ccw" picks the morning crossing, "cw" the evening one.
        function sunAngleTime(angle, t, dir) {
            var decl = sunPosition(jd + t).decl
            var noon = midDay(t)
            var arg = (-dsin(angle) - dsin(decl) * dsin(lat)) / (dcos(decl) * dcos(lat))
            if (arg > 1 || arg < -1) return NaN     // sun never reaches this altitude
            var v = dacos(arg) / 15
            return noon + (dir === "ccw" ? -v : v)
        }

        // Asr is defined by shadow length, not altitude: the shadow of a gnomon
        // equals its noon shadow plus `factor` times its height.
        function asrTime(factor, t) {
            var decl = sunPosition(jd + t).decl
            return sunAngleTime(-darccot(factor + dtan(Math.abs(lat - decl))), t, "cw")
        }

        // Seed with rough guesses, then iterate: each time depends on the solar
        // position at that time, so a couple of passes converge to well under a second.
        var t = { fajr: 5 / 24, sunrise: 6 / 24, dhuhr: 12 / 24, asr: 13 / 24,
                  sunset: 18 / 24, maghrib: 18 / 24, isha: 18 / 24 }
        var times = null

        for (var pass = 0; pass < 3; pass++) {
            times = {
                fajr:    sunAngleTime(m.fajr, t.fajr, "ccw"),
                sunrise: sunAngleTime(sunsetAngle(), t.sunrise, "ccw"),
                dhuhr:   midDay(t.dhuhr),
                asr:     asrTime(asrFactor, t.asr),
                sunset:  sunAngleTime(sunsetAngle(), t.sunset, "cw")
            }
            times.maghrib = (m.maghribAngle !== undefined)
                          ? sunAngleTime(m.maghribAngle, t.maghrib, "cw")
                          : times.sunset
            // A fixed-offset Isha is resolved once maghrib is final, below.
            times.isha = (typeof m.isha === "object")
                       ? NaN
                       : sunAngleTime(m.isha, t.isha, "cw")

            for (var k in times)
                if (!isNaN(times[k])) t[k] = times[k] / 24
        }

        // Shift from mean solar time at the meridian to local civil time.
        var offset = tz - lon / 15
        for (var key in times) times[key] += offset

        // Regional precaution offsets ("temkin"), applied before anything is derived
        // from sunset so that Maghrib and a fixed-offset Isha inherit them.
        if (m.offsets)
            for (var o in m.offsets)
                if (times[o] !== undefined) times[o] += m.offsets[o] / 60

        if (m.maghribMinutes) times.maghrib = times.sunset + m.maghribMinutes / 60
        else if (m.maghribAngle === undefined) times.maghrib = times.sunset

        if (typeof m.isha === "object") {
            // Umm Al-Qura and the Gulf methods stretch the interval from 90 to 120
            // minutes throughout Ramadan.
            var mins = m.isha.minutes
            if (m.isha.ramadanMinutes && hijriDate(year, month, day).month === 9)
                mins = m.isha.ramadanMinutes
            times.isha = times.maghrib + mins / 60
        }

        // Inside the polar circles the sun can fail to cross the horizon at all.
        // Collapse sunrise/sunset onto solar noon so downstream arithmetic stays
        // finite; the high-latitude rule below then still yields a usable night.
        if (isNaN(times.sunrise) || isNaN(times.sunset)) {
            if (isNaN(times.sunrise)) times.sunrise = times.dhuhr
            if (isNaN(times.sunset)) times.sunset = times.dhuhr
            if (isNaN(times.maghrib)) times.maghrib = times.sunset
        }

        adjustHighLatitudes(times, m, lat, opts.highLat || "angle")

        // Islamic midnight: the midpoint of the night. The majority (Sunni) rule
        // measures sunset -> next sunrise; the Jafari rule measures sunset -> next
        // dawn. It marks the preferred cut-off for praying Isha.
        var nightStart = times.sunset
        var nightEnd = (m.midnight === "jafari" ? times.fajr : times.sunrise) + 24
        times.midnight = fixHour(nightStart + (nightEnd - nightStart) / 2)

        return times
    }

    // Above roughly 48 deg the sun may never descend to the Fajr/Isha depression
    // angle in summer, leaving those times undefined. The angle-based rule (the
    // default Aladhan uses) then splits the night by the method's own angles.
    function adjustHighLatitudes(times, m, lat, mode) {
        if (mode === "none") return
        var night = (times.sunrise + 24) - times.sunset
        if (!isFinite(night)) return

        function portion(angle, fraction) {
            if (mode === "angle" && typeof angle === "number") return night / 60 * angle
            if (mode === "seventh") return night / 7
            return night / 2   // nightmiddle
        }

        if (isNaN(times.fajr)) times.fajr = times.sunrise - portion(m.fajr)
        if (isNaN(times.isha) && typeof m.isha === "number")
            times.isha = times.sunset + portion(m.isha)
    }

    // === Sun position through the day ===
    // The prayer times are all instants where the sun crosses a given altitude, so
    // the altitude curve itself is the thing they are cut from. Exposing it lets the
    // interface draw the actual arc the sun walks rather than a stylised one.
    //
    // `hourLocal` is local civil time. Returns degrees above the horizon, negative
    // when the sun is down.
    function solarAltitude(year, month, day, hourLocal, opts) {
        var lat = opts.lat
        var lon = opts.lon
        var jd = julianDay(year, month, day) - lon / (15 * 24)
        var sp = sunPosition(jd + hourLocal / 24)

        // Undo the same shift computeDay applies to get from the local meridian's
        // mean solar frame to civil time, then take the hour angle from solar noon.
        var meanSolar = hourLocal - opts.tzOffset + lon / 15
        var H = 15 * (meanSolar - (12 - sp.eqt))

        return dasin(dsin(lat) * dsin(sp.decl)
                   + dcos(lat) * dcos(sp.decl) * dcos(H))
    }

    // The sun's position projected onto the sky as an observer facing the equator
    // sees it: x runs east (negative, on the left) to west, z is height, and equals
    // the sine of the altitude.
    //
    //   x = cos(decl) sin(H)
    //   z = sin(decl) sin(lat) + cos(decl) cos(lat) cos(H)
    //
    // In the hour angle H these are the parametric equations of an ellipse, centred
    // at (0, sin decl sin lat) with semi-axes cos(decl) and cos(decl) cos(lat). That
    // is not a stylisation: the sun's diurnal path is a circle on the celestial
    // sphere, and a circle seen in projection is an ellipse. Plotting altitude
    // against clock time instead gives a curve whose bend is concentrated entirely
    // at noon, which is why it reads as a wedge rather than as an orbit.
    function sunSkyPoint(year, month, day, hourLocal, opts) {
        var lat = opts.lat
        var lon = opts.lon
        var jd = julianDay(year, month, day) - lon / (15 * 24)
        var sp = sunPosition(jd + hourLocal / 24)
        var H = 15 * ((hourLocal - opts.tzOffset + lon / 15) - (12 - sp.eqt))
        var z = dsin(sp.decl) * dsin(lat) + dcos(sp.decl) * dcos(lat) * dcos(H)
        return { x: dcos(sp.decl) * dsin(H), z: z, alt: dasin(Math.max(-1, Math.min(1, z))) }
    }

    // === Moon ===
    // Phase as a fraction of the synodic month: 0 new, 0.5 full. Measured from a
    // known new moon, which is accurate to a few hours over a century -- far finer
    // than the day-level resolution anything here displays. The Hijri calendar is
    // lunar, so this is the shape the date is counting.
    function moonPhase(gy, gm, gd) {
        var days = (julianDay(gy, gm, gd) + 0.5) - 2451550.1
        var p = (days / 29.530588853) % 1
        return p < 0 ? p + 1 : p
    }

    // Fraction of the disc lit, 0 to 1.
    function moonIllumination(phase) {
        return (1 - Math.cos(2 * Math.PI * phase)) / 2
    }

    function moonPhaseName(phase) {
        if (phase < 0.02 || phase > 0.98) return "New moon"
        if (phase < 0.23) return "Waxing crescent"
        if (phase < 0.27) return "First quarter"
        if (phase < 0.48) return "Waxing gibbous"
        if (phase < 0.52) return "Full moon"
        if (phase < 0.73) return "Waning gibbous"
        if (phase < 0.77) return "Last quarter"
        return "Waning crescent"
    }

    // === Hijri calendar ===
    // Tabular (arithmetical) Islamic calendar, the same civil reckoning Aladhan
    // serves by default. It is a fixed 30-year cycle of 11 leap years, so it can
    // differ by a day from a locally moonsighted calendar -- see `hijriOffset`.
    function hijriMonths() {
        return [
            "Muharram", "Safar", "Rabi' al-awwal", "Rabi' al-thani",
            "Jumada al-ula", "Jumada al-akhira", "Rajab", "Sha'ban",
            "Ramadan", "Shawwal", "Dhu al-Qi'dah", "Dhu al-Hijjah"
        ]
    }

    function hijriDate(gy, gm, gd, dayOffset) {
        // Epoch chosen as the best fit to the Umm al-Qura table Aladhan serves:
        // exact on 57% of sampled dates and never more than a day out. An
        // arithmetical calendar cannot do better against a moonsighted one, which
        // is what `dayOffset` is for.
        var jd = Math.floor(julianDay(gy, gm, gd) + 0.5) + (dayOffset || 0)
        var i = jd - 1948439 + 10632
        var n = Math.floor((i - 1) / 10631)
        i = i - 10631 * n + 354
        var j = Math.floor((10985 - i) / 5316) * Math.floor((50 * i) / 17719)
              + Math.floor(i / 5670) * Math.floor((43 * i) / 15238)
        i = i - Math.floor((30 - j) / 15) * Math.floor((17719 * j) / 50)
              - Math.floor(j / 16) * Math.floor((15238 * j) / 43) + 29
        var month = Math.floor((24 * i) / 709)
        var day = i - Math.floor((709 * month) / 24)
        var year = 30 * n + j - 30
        return { day: day, month: month, year: year, monthName: hijriMonths()[month - 1] }
    }

    function formatHijri(h) {
        return h.day + " " + h.monthName + " " + h.year + " AH"
    }

    // === Formatting / window helpers ===
    function toHHMM(hours) {
        if (hours === null || hours === undefined || isNaN(hours)) return ""
        var t = fixHour(hours + 0.5 / 60)     // round to nearest minute
        var h = Math.floor(t)
        var mn = Math.floor((t - h) * 60)
        return (h < 10 ? "0" : "") + h + ":" + (mn < 10 ? "0" : "") + mn
    }

    function toSeconds(hours) {
        return Math.round(fixHour(hours) * 3600)
    }
    // ===== END CALC =====
}
