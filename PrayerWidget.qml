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
        root.hijriText = Calc.formatHijri(
            Calc.hijriDate(now.getFullYear(), now.getMonth() + 1, now.getDate(), root.hijriOffset))
        root.lastComputed = Qt.formatDate(now, "yyyy-MM-dd")
        updateCountdown()

        // The arc is the one part of this that can be done without, so it goes
        // last and cannot take the rest down with it. A QML script imported with
        // .pragma library is cached engine-wide by URL, so after this file gains
        // a function the running shell keeps the older copy until it restarts --
        // and a throw here used to skip the date, the countdown and the handover
        // line, blanking most of the panel with nothing in the log to say why.
        try {
            root.sunSamples = sampleSun(noon)
            root.prayerAlt = samplePrayerAltitudes(noon)
        } catch (e) {
            root.sunSamples = []
            root.prayerAlt = ({})
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
                     Maghrib: "maghrib", Isha: "isha", "Islamic midnight": "midnight" }
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

    // Every event plotted on the curve. Each is by definition the instant the
    // sun reaches a given altitude, so the altitude is what places it -- the
    // point sits on the path rather than beside it.
    readonly property var arcMarks: {
        var t = root.todayTimes
        if (!t) return []
        var out = []
        var keys = [["Fajr", "fajr"], ["Sunrise", "sunrise"], ["Dhuhr", "dhuhr"],
                    ["Asr", "asr"], ["Maghrib", "maghrib"], ["Isha", "isha"],
                    ["Islamic midnight", "midnight"]]
        for (var i = 0; i < keys.length; i++) {
            var h = t[keys[i][1]]
            var a = root.prayerAlt[keys[i][0]]
            if (h === undefined || isNaN(h) || a === undefined) continue
            out.push({ name: keys[i][0], h: h % 24, alt: a })
        }
        return out
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
    // The arc the sun walks today, sampled from the same ephemeris the prayer
    // times are cut from. It answers one question -- where the sun is -- so it
    // carries no progress encoding; the span bar above owns that.
    //
    // Only the two horizon crossings are labelled. Everything else is a dot on
    // the curve in its own sky colour, matching its dot in the list below. Six
    // labels cannot coexist on a 24-hour axis where Fajr and sunrise are seventy
    // minutes apart -- fourteen pixels -- and the label is forty-six wide.
    component SunPath: Item {
        id: sky

        readonly property int padX: 10
        readonly property real horizonY: 58
        readonly property real nightDepth: 28

        function repaint() { skyCanvas.requestPaint() }

        Component.onCompleted: repaint()
        onWidthChanged: repaint()
        onVisibleChanged: if (visible) repaint()

        Connections {
            target: root
            function onSunSamplesChanged() { sky.repaint() }
            function onAltitudeNowChanged() { sky.repaint() }
        }

        function xFor(hr) {
            return sky.padX + (hr / 24) * (sky.width - 2 * sky.padX)
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

                var maxAlt = -90, minAlt = 90
                for (var i = 0; i < samples.length; i++) {
                    if (samples[i].alt > maxAlt) maxAlt = samples[i].alt
                    if (samples[i].alt < minAlt) minAlt = samples[i].alt
                }
                if (maxAlt <= 0) maxAlt = 1
                if (minAlt >= 0) minAlt = -1

                var hz = sky.horizonY
                function py(alt) {
                    return alt >= 0
                         ? hz - (alt / maxAlt) * (hz - 8)
                         : hz + (alt / minAlt) * sky.nightDepth
                }

                // Daylight, filled under the curve. The single strongest cue for
                // reading the shape at a glance: the lit part of the day has
                // substance, the night is bare.
                var grad = ctx.createLinearGradient(0, 8, 0, hz)
                grad.addColorStop(0, Qt.rgba(0.91, 0.70, 0.24, 0.22))
                grad.addColorStop(1, Qt.rgba(0.91, 0.70, 0.24, 0.02))
                ctx.fillStyle = grad
                ctx.beginPath()
                ctx.moveTo(sky.xFor(0), hz)
                for (var f = 0; f < samples.length; f++) {
                    var yf = py(samples[f].alt)
                    ctx.lineTo(sky.xFor(samples[f].h), Math.min(yf, hz))
                }
                ctx.lineTo(sky.xFor(24), hz)
                ctx.closePath()
                ctx.fill()

                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.20)
                ctx.lineWidth = 1
                ctx.beginPath()
                ctx.moveTo(0, hz + 0.5)
                ctx.lineTo(width, hz + 0.5)
                ctx.stroke()

                // The path itself.
                ctx.strokeStyle = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g,
                                          Theme.surfaceText.b, 0.34)
                ctx.lineWidth = 1.6
                ctx.lineJoin = "round"
                ctx.beginPath()
                for (var j = 0; j < samples.length; j++) {
                    var xj = sky.xFor(samples[j].h), yj = py(samples[j].alt)
                    if (j === 0) ctx.moveTo(xj, yj)
                    else ctx.lineTo(xj, yj)
                }
                ctx.stroke()

                // Every prayer as a point on the path, ringed in the panel's own
                // background so it reads clearly against the curve behind it.
                var marks = root.arcMarks
                for (var k = 0; k < marks.length; k++) {
                    var mk = marks[k]
                    var cx = sky.xFor(mk.h), cy = py(mk.alt)
                    ctx.beginPath()
                    ctx.arc(cx, cy, 4.2, 0, 2 * Math.PI)
                    ctx.fillStyle = Theme.surfaceContainerHigh
                    ctx.fill()
                    ctx.beginPath()
                    ctx.arc(cx, cy, 2.8, 0, 2 * Math.PI)
                    ctx.fillStyle = root.skyColor(mk.alt)
                    ctx.fill()
                }

                // Where the sun is now.
                var nowAlt = root.altitudeNow
                var sx = sky.xFor(root.nowHours()), sy = py(nowAlt)
                var c = root.skyColor(nowAlt)
                ctx.fillStyle = c
                ctx.strokeStyle = c
                ctx.globalAlpha = 0.25
                ctx.beginPath(); ctx.arc(sx, sy, 11, 0, 2 * Math.PI); ctx.fill()
                ctx.globalAlpha = 1
                if (nowAlt >= 0) {
                    ctx.beginPath(); ctx.arc(sx, sy, 5.5, 0, 2 * Math.PI); ctx.fill()
                } else {
                    ctx.lineWidth = 1.8
                    ctx.beginPath(); ctx.arc(sx, sy, 4.5, 0, 2 * Math.PI); ctx.stroke()
                }
            }
        }

        // The two horizon crossings, set inside the arc where nothing else is,
        // and thirteen hours apart so they cannot collide with each other.
        StyledText {
            x: Math.min(sky.width - width, sky.xFor(root.todayTimes ? root.todayTimes.sunrise : 6) + 6)
            y: sky.horizonY - 15
            text: root.todayTimes ? root.formatTime(root.hhmm(root.todayTimes.sunrise)) : ""
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            visible: root.todayTimes !== null
        }

        StyledText {
            x: Math.max(0, sky.xFor(root.todayTimes ? root.todayTimes.maghrib : 18) - width - 6)
            y: sky.horizonY - 15
            text: root.todayTimes ? root.formatTime(root.hhmm(root.todayTimes.maghrib)) : ""
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            visible: root.todayTimes !== null
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

                // --- Date ---
                Item {
                    width: content.width
                    height: Math.max(hijriLabel.implicitHeight, refreshPill.height)

                    StyledText {
                        id: hijriLabel
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.hijriText
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
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

                        // The window you are inside, stated as a sentence so it
                        // needs no decoding. It repeats no figure the line above
                        // already gives -- when the window closes exactly as the
                        // next prayer opens, it simply says so.
                        StyledText {
                            width: parent.width
                            text: {
                                var w = root.activeSpan
                                if (!w) return ""
                                if (w.gap) return "No prayer due yet"

                                var handsOver = Math.abs(w.end - root.nextAt) < 1 / 120
                                var line = handsOver
                                         ? (w.name + " is open until then")
                                         : (w.name + " is open — " + root.formatSplit(root.spanRemainingSec)
                                            + " left, until " + root.formatTime(root.hhmm(w.end)))

                                var cw = root.currentWindow
                                if (cw && cw.preferredEnd !== undefined) {
                                    line += root.preferredRemainingSec > 0
                                          ? (" · best prayed before " + root.formatTime(root.hhmm(cw.preferredEnd)))
                                          : " · past Islamic midnight"
                                }
                                return line
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: root.isUrgent ? Font.Medium : Font.Normal
                            color: root.isUrgent ? Theme.error
                                 : (root.preferredRemainingSec < 0 ? Theme.warning : Theme.surfaceVariantText)
                            wrapMode: Text.WordWrap

                            Behavior on color { ColorAnimation { duration: 400 } }
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

                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: {
                            var w = root.activeSpan
                            if (!w) return ""
                            var began = "began " + root.formatDuration(root.spanElapsedSec) + " ago"
                            return w.gap ? ("between prayers · " + began)
                                         : (w.name + " window · " + began)
                        }
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                        opacity: 0.8
                    }
                }

                // --- Where the sun is ---
                SunPath {
                    width: content.width
                    height: 92
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
                        { label: "Isha",             start: root.todayTimes.isha,     end: root.tomorrowTimes ? root.tomorrowTimes.fajr + 24 : null, marker: false },
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
                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: height / 2
                            color: parent.isNext
                                   ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.14)
                                   : (parent.isCurr
                                      ? Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.06)
                                      : "transparent")
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

                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: modelData.marker ? 30 : 28
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            font.pixelSize: modelData.marker ? Theme.fontSizeSmall : Theme.fontSizeMedium
                            font.weight: (parent.isNext || parent.isCurr) ? Font.Bold : Font.Normal
                            font.italic: modelData.marker
                            color: parent.isNext ? Theme.primary : Theme.surfaceText
                            opacity: modelData.marker ? 0.75 : 1
                        }

                        // Two right-aligned columns. The headers name them, so no
                        // arrow is needed in seven consecutive rows.
                        StyledText {
                            anchors.right: parent.right
                            anchors.rightMargin: 84
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.formatTime(root.hhmm(modelData.start))
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: (parent.isNext || parent.isCurr) ? Font.Bold : Font.Normal
                            color: parent.isNext ? Theme.primary : Theme.surfaceText
                            opacity: modelData.marker ? 0.75 : 1
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.end !== null
                                  ? root.formatTime(root.hhmm(modelData.end)) : "·"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: (parent.isNext || parent.isCurr) ? Font.Bold : Font.Normal
                            color: parent.isNext ? Theme.primary : Theme.surfaceText
                            opacity: modelData.end === null ? 0.35 : (modelData.marker ? 0.75 : 0.85)
                        }
                    }
                }
            }
        }
    }
}
