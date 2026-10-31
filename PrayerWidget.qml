import QtQuick
import Quickshell
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    pluginId: "prayerTimes"

    // === Settings, bound directly to pluginData ===
    // parseFloat tolerates the stray whitespace that creeps into hand-entered
    // coordinates; the old code interpolated them straight into a URL.
    property real lat: parseFloat(String(pluginData.lat || "").trim())
    property real lon: parseFloat(String(pluginData.lon || "").trim())

    // The name of the place the coordinates came from, shown only while it still
    // describes them. Editing latitude or longitude by hand would otherwise
    // leave the old name sitting under the new numbers, and a label that quietly
    // disagrees with what it labels is worse than no label at all.
    readonly property string placeLabel: labelFor(pluginData.placeLabel, pluginData.placeLat,
                                                  pluginData.placeLon, lat, lon)

    function labelFor(name, pLat, pLon, lat, lon) {
        if (!name || isNaN(lat) || isNaN(lon))
            return ""
        pLat = parseFloat(String(pLat || "").trim())
        pLon = parseFloat(String(pLon || "").trim())
        if (isNaN(pLat) || isNaN(pLon))
            return ""
        // A hundred metres of slack, well inside the rounding already applied.
        return (Math.abs(pLat - lat) < 0.001 && Math.abs(pLon - lon) < 0.001) ? name : ""
    }

    function coordText(lat, lon) {
        if (isNaN(lat) || isNaN(lon))
            return ""
        return Math.abs(lat).toFixed(2) + "°" + (lat >= 0 ? "N" : "S") + "   "
             + Math.abs(lon).toFixed(2) + "°" + (lon >= 0 ? "E" : "W")
    }

    property string method: pluginData.method || "2"
    property string school: pluginData.school || "0"
    property string highLat: pluginData.highLat || "angle"
    property int hijriOffset: Number(pluginData.hijriOffset) || 0
    property bool iconOnly: pluginData.iconOnly ?? false
    property bool showSeconds: pluginData.showSeconds ?? false
    property bool use12H: pluginData.use12H ?? false
    property bool showPillProgress: pluginData.showPillProgress ?? true

    // === Second location ===
    // Shown on its own tab in the popout, never on the bar. It is computed
    // exactly as the main one is, on the system's clock; the clock there is
    // only added beside that, in a lower register.
    property real secLat: parseFloat(String(pluginData.secLat || "").trim())
    property real secLon: parseFloat(String(pluginData.secLon || "").trim())
    readonly property string secMethod: pluginData.secMethod && pluginData.secMethod !== "same"
                                        ? pluginData.secMethod : method
    readonly property string secLabel: labelFor(pluginData.secLabel, pluginData.secPlaceLat,
                                                pluginData.secPlaceLon, secLat, secLon)

    // Which place the popout shows. It always opens on the main location: the
    // second is somewhere to glance at, not somewhere to stay.
    property int popoutTab: 0
    onInteractionActiveChanged: if (interactionActive) popoutTab = 0
    readonly property bool hasSecond: there.located
    popoutWidth: hasSecond ? 440 : 400

    readonly property color accentColor: Theme.primary

    // The conventions shared by every place: the Asr school is a juristic
    // choice of the person praying, not of the town.
    onSchoolChanged: { here.refresh(); there.refresh() }
    onHighLatChanged: { here.refresh(); there.refresh() }
    onHijriOffsetChanged: { here.refresh(); there.refresh() }

    SystemClock {
        id: clock
        precision: root.showSeconds ? SystemClock.Seconds : SystemClock.Minutes
    }

    readonly property real nowMs: clock.date.getTime()
    // The sun dot moves about a pixel a minute; redrawing the arc every second
    // when seconds are shown would repaint the canvas for nothing.
    readonly property real minuteMs: Math.floor(nowMs / 60000) * 60000

    // === A place ===
    // Everything derived from one set of coordinates: the three days of times
    // around today, the windows and countdowns built on them, the sky and the
    // moon. The bar reads the configured location through `here`.
    component Place: Item {
        id: place
        visible: false

        property real lat: NaN
        property real lon: NaN
        property string label: ""
        property string method: "2"

        // Every place is computed on the system's clock. A place may also show
        // the clock there, for which its zone's offsets are read once and
        // then looked up (see readZone).
        property bool showsOwnClock: false
        property string zoneName: ""
        property var zoneTable: null
        property real zoneValidUntil: 0
        property bool zoneLoading: false
        readonly property real zoneOffset: root.zoneOffsetAt(zoneTable, now)

        // Out of range is treated as unset: a latitude of 95 is a typo, and
        // computing from it produced NaN times under a panel that looked live.
        readonly property bool located: !isNaN(lat) && !isNaN(lon)
                                        && Math.abs(lat) <= 90 && Math.abs(lon) <= 180

        // Yesterday, today and tomorrow, each { y, m, d, tz, times, at }: times
        // in this place's wall-clock hours, `at` the same events as instants.
        // Yesterday because the small hours before dawn still belong to its
        // Isha window; tomorrow because the countdown after Isha runs to its
        // Fajr.
        property var days: []
        property string lastComputed: ""
        // The Islamic day begins at Maghrib, not at midnight, so the Hijri date
        // is that of the civil day after the last Maghrib to have happened
        // here. Each place has its own Maghribs, so a second location turns
        // its date at its own sunset, whatever our clock says.
        readonly property string hijriText: days.length === 3
            ? root.formatHijri(root.hijriAt(days, now, root.hijriOffset)) : ""
        property real moonFraction: 0
        property real moonLit: 0
        property bool moonWaxes: true
        property bool moonTurning: false
        property var sunSamples: []
        property var prayerAlt: ({})

        readonly property var today: days.length === 3 ? days[1] : null
        readonly property real now: root.nowMs

        // UTC offset in hours at an instant, and the civil date it falls on,
        // both on the system's clock.
        function offsetAt(ms) {
            return -new Date(ms).getTimezoneOffset() / 60
        }

        function civilDate(ms) {
            var d = new Date(ms)
            return [d.getFullYear(), d.getMonth() + 1, d.getDate()]
        }

        function dateKey(ymd) {
            return ymd[0] + "-" + ymd[1] + "-" + ymd[2]
        }

        function optionsFor(tz) {
            return {
                lat: place.lat,
                lon: place.lon,
                method: place.method,
                asrFactor: root.school === "1" ? 2 : 1,
                highLat: root.highLat,
                hijriOffset: root.hijriOffset,
                tzOffset: tz
            }
        }

        // Settings arrive one key at a time, so recomputing waits for them to
        // settle rather than running once per keystroke.
        function refresh() {
            debounce.restart()
        }

        // A new place's clock is unknown until asked, not the old one's.
        onLatChanged: { zoneName = ""; zoneTable = null; refresh() }
        onLonChanged: { zoneName = ""; zoneTable = null; refresh() }
        onMethodChanged: refresh()
        Component.onCompleted: refresh()

        // Prayer times are a deterministic function of the date, so they only
        // need recomputing when the civil date rolls over -- not on a polling
        // interval.
        onNowChanged: if (dateKey(civilDate(now)) !== lastComputed) recompute()

        Timer {
            id: debounce
            interval: 400
            onTriggered: place.recompute()
        }

        function clear() {
            // Clear everything derived. Leaving yesterday's times, the sampled
            // arc and the Hijri date behind drew a live sky for wherever the
            // coordinates used to point, under a card showing nothing.
            days = []
            lastComputed = ""
            sunSamples = []
            prayerAlt = ({})
        }

        function recompute() {
            if (!located) {
                clear()
                return
            }
            // The zone's offsets are read once per place and cover two years;
            // the daily recompute only re-reads them as that runs out.
            if (showsOwnClock && !zoneLoading && (!zoneTable || now > zoneValidUntil))
                readZone()
            var c = civilDate(now)
            var dates = [], offsets = []
            for (var k = -1; k <= 1; k++) {
                // Resolved at noon of each day, so daylight-saving changes,
                // which happen in the small hours, are never straddled.
                var noon = new Date(c[0], c[1] - 1, c[2] + k, 12)
                dates.push([noon.getFullYear(), noon.getMonth() + 1, noon.getDate()])
                offsets.push(-noon.getTimezoneOffset() / 60)
            }
            computeDays(dates, offsets)
        }

        // QML's Date knows only the system's zone, so the clock there takes two
        // steps, each answered by whatever is authoritative for it, and each
        // done once per place -- never when the popout opens.
        //
        // Which zone a point is in is geography, and is asked of open-meteo
        // ("timezone=auto" answers for bare coordinates).
        //
        // What that zone's offsets are is politics: Morocco left +01 for +00 in
        // September 2026, and open-meteo's server still said +01 a month on.
        // So offsets never come from the network. They are read from the
        // system's own tzdata, which the package manager keeps current, with
        // zdump: every change from the start of this year to two years on, so
        // daylight saving there is exact to the minute by lookup alone.
        function readZone() {
            if (!showsOwnClock || !located) {
                zoneTable = null
                return
            }
            if (zoneName === "") {
                findZoneName()
                return
            }
            var z = zoneName
            var y = new Date(now).getFullYear()
            zoneLoading = true
            // An argument list, not a shell line: the name never meets sh.
            Proc.runCommand("prayerTimes.zone", ["zdump", "-i", "-c", y + "," + (y + 2), z],
                            function (out, code) {
                zoneLoading = false
                if (z !== zoneName)
                    return   // the place moved while this ran
                var table = code === 0 ? root.parseZoneTable(out) : null
                if (!table) {
                    console.warn("prayerTimes: tzdata has no zone", z)
                    zoneName = ""
                    retry.restart()
                    return
                }
                zoneTable = table
                zoneValidUntil = Date.UTC(y + 2, 0, 1) - 30 * 86400000
            }, 0)
        }

        function findZoneName() {
            zoneLoading = true
            var key = lat.toFixed(4) + "," + lon.toFixed(4)
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== XMLHttpRequest.DONE)
                    return
                zoneLoading = false
                if (key !== lat.toFixed(4) + "," + lon.toFixed(4)) {
                    readZone()   // the place moved while this was out
                    return
                }
                var tz = ""
                try {
                    if (xhr.status === 200)
                        tz = String(JSON.parse(xhr.responseText).timezone || "")
                } catch (e) {}
                if (tz !== "" && tz !== "GMT") {
                    zoneName = tz
                    readZone()
                    return
                }
                console.warn("prayerTimes: no time zone found for", key, "- status", xhr.status)
                retry.restart()
            }
            xhr.open("GET", "https://api.open-meteo.com/v1/forecast?forecast_days=1&timezone=auto"
                          + "&latitude=" + lat.toFixed(4) + "&longitude=" + lon.toFixed(4))
            xhr.send()
        }

        // Offline at startup, say: try again in five minutes, not at midnight.
        Timer {
            id: retry
            interval: 300000
            onTriggered: place.readZone()
        }

        function computeDays(dates, offsets) {
            var out = []
            for (var i = 0; i < 3; i++) {
                var dt = dates[i]
                var times = root.computeDay(dt[0], dt[1], dt[2], optionsFor(offsets[i]))
                out.push({ y: dt[0], m: dt[1], d: dt[2], tz: offsets[i], times: times,
                           at: root.dayInstants(dt[0], dt[1], dt[2], times, offsets[i]) })
            }
            days = out
            var t = out[1]
            lastComputed = dateKey([t.y, t.m, t.d])

            // The arc and the moon are the parts that can be done without, so
            // they go last and behind a guard: whatever they may throw, the
            // times, the date and the countdown above are already set, and an
            // ornament cannot blank the panel.
            try {
                moonFraction = root.moonPhase(t.y, t.m, t.d)
                moonLit = root.moonIllumination(moonFraction)
                moonWaxes = root.moonWaxing(moonFraction)
                moonTurning = root.moonAtTurningPoint(moonFraction)
                sunSamples = sampleSun()
                prayerAlt = samplePrayerAltitudes()
            } catch (e) {
                sunSamples = []
                prayerAlt = ({})
                console.warn("prayerTimes: sun path unavailable —", e)
            }
        }

        // === The sky ===
        function sunPoint(hours) {
            var t = today
            return root.sunSkyPoint(t.y, t.m, t.d, hours, optionsFor(t.tz))
        }

        // The sun's altitude across the civil day, sampled once when the day
        // rolls over. The arc is then a fixed shape with only the sun moving
        // along it, which keeps the panel calm and lets the eye learn the
        // silhouette.
        function sampleSun() {
            var out = []
            for (var i = 0; i <= 240; i++) {
                var h = i * 24 / 240
                var pt = sunPoint(h)
                out.push({ h: h, x: pt.x, z: pt.z, alt: pt.alt })
            }
            return out
        }

        function samplePrayerAltitudes() {
            var out = {}
            var keys = { Fajr: "fajr", sunrise: "sunrise", Dhuhr: "dhuhr", Asr: "asr",
                         Maghrib: "maghrib", Isha: "isha", "Islamic midnight": "midnight" }
            for (var name in keys)
                out[name] = sunPoint(today.times[keys[name]]).alt
            return out
        }

        function prayerColor(name) {
            var a = prayerAlt[name]
            return a === undefined ? Theme.surfaceVariantText : root.skyColor(a)
        }

        // Every event plotted on the curve. Each is by definition the instant
        // the sun reaches a given altitude, so the altitude is what places it --
        // the point sits on the path rather than beside it.
        readonly property var arcMarks: {
            if (!today) return []
            var out = []
            var keys = [["Fajr", "fajr"], ["Dhuhr", "dhuhr"], ["Asr", "asr"],
                        ["Maghrib", "maghrib"], ["Isha", "isha"],
                        ["Islamic midnight", "midnight"]]
            for (var i = 0; i < keys.length; i++) {
                var h = today.times[keys[i][1]]
                if (h === undefined || isNaN(h)) continue
                var pt = sunPoint(h % 24)
                out.push({ name: keys[i][0], x: pt.x, z: pt.z, alt: pt.alt })
            }
            return out
        }

        // Where the sun is on that ellipse right now. Hours are counted from
        // this place's midnight in real time, so a DST change earlier in the
        // day does not move the sun an hour off its true position.
        readonly property var sunNow: {
            if (!today) return null
            return sunPoint((root.minuteMs - root.instantOf(today.y, today.m, today.d, 0, today.tz)) / 3600000)
        }

        // === The timeline ===
        readonly property var windows: days.length === 3 ? root.prayerWindows(days[0].at, days[1].at) : []
        readonly property var schedule: days.length === 3 ? root.prayerSchedule(days[1].at, days[2].at) : []
        readonly property int nextIdx: root.nextIndex(schedule, now)
        readonly property var next: nextIdx >= 0 ? schedule[nextIdx] : null
        readonly property string nextName: next ? next.name : ""
        readonly property int nextTotalSeconds: next ? Math.max(0, secondsUntil(next.at)) : 0

        // The stretch the interface is describing, and whether it is a prayer
        // window or the gap before one.
        readonly property var activeSpan: root.spanAt(windows, now)
        readonly property var currentWindow: activeSpan && !activeSpan.gap ? activeSpan : null

        readonly property int spanElapsedSec: activeSpan ? Math.max(0, -secondsUntil(activeSpan.start)) : 0
        readonly property int spanRemainingSec: activeSpan ? Math.max(0, secondsUntil(activeSpan.end)) : 0
        readonly property real spanProgress: {
            var total = spanElapsedSec + spanRemainingSec
            return total > 0 ? spanElapsedSec / total : 0
        }

        // Progress across the interval between one prayer and the next, which
        // is what the bar's rule sits under. Before dawn the interval began at
        // yesterday's Isha.
        readonly property real progressToNext: {
            if (!next) return 0
            var start = nextIdx > 0 ? schedule[nextIdx - 1].at : days[0].at.isha
            var span = next.at - start
            return span > 0 ? Math.max(0, Math.min(1, (now - start) / span)) : 0
        }

        // The bar reddens when the next prayer is nearly here; the panel
        // reddens when the open window is nearly over. Different facts, kept
        // apart.
        readonly property bool nextImminent: nextTotalSeconds > 0 && nextTotalSeconds <= 900
        readonly property bool isUrgent: currentWindow !== null
                                         && spanRemainingSec > 0 && spanRemainingSec <= 900

        // The row the panel is about: the window that is open, or, between
        // windows, the prayer that comes next. It carries the countdown, and
        // the bar when a window is open, so each is said once.
        readonly property real focusStart: currentWindow ? currentWindow.start : (next ? next.at : NaN)

        // The table shows the prayer day that holds that row, so it never
        // needs an extra one: until Islamic midnight, last night's Isha is
        // still open and yesterday is shown; after a midnight that falls
        // before 00:00, the next prayer is tomorrow's Fajr and tomorrow is.
        readonly property int focusDay: {
            if (days.length !== 3) return 1
            if (currentWindow && currentWindow.start === days[0].at.isha) return 0
            if (!currentWindow && next && next.at === days[2].at.fajr) return 2
            return 1
        }

        // The day as the table lists it. Sunrise and Islamic midnight open and
        // close nothing, so they are markers rather than windows.
        readonly property var rows: {
            if (days.length !== 3) return []
            var a = days[focusDay].at
            return [
                { label: "Fajr",             start: a.fajr,     end: a.sunrise,  marker: false },
                { label: "sunrise",          start: a.sunrise,  end: null,       marker: true  },
                { label: "Dhuhr",            start: a.dhuhr,    end: a.asr,      marker: false },
                { label: "Asr",              start: a.asr,      end: a.maghrib,  marker: false },
                { label: "Maghrib",          start: a.maghrib,  end: a.isha,     marker: false },
                { label: "Isha",             start: a.isha,     end: a.midnight, marker: false },
                { label: "Islamic midnight", start: a.midnight, end: null,       marker: true  }
            ]
        }

        function secondsUntil(ms) {
            return Math.round((ms - now) / 1000)
        }

        // An instant on the system's clock, in the user's 12/24-hour style.
        // With `marked`, a time falling on another day than today is tagged +1
        // or -1: read off our clock, a far place's day can begin last night.
        function clockText(ms, marked) {
            if (ms === null || ms === undefined || isNaN(ms)) return ""
            var text = root.formatTime(root.toHHMM(root.wallHours(ms, offsetAt(ms))))
            return marked ? text + dayMark(civilDate(ms), civilDate(now)) : text
        }

        // The same instant on the clock there, tagged against that clock's
        // today. Empty until the offset there is known.
        function zoneClock(ms) {
            if (ms === null || ms === undefined || isNaN(ms)) return ""
            var off = root.zoneOffsetAt(zoneTable, ms)
            if (isNaN(off)) return ""
            var shifted = function (t, o) {
                var w = new Date(t + o * 3600000)
                return [w.getUTCFullYear(), w.getUTCMonth() + 1, w.getUTCDate()]
            }
            return root.formatTime(root.toHHMM(root.wallHours(ms, off)))
                 + dayMark(shifted(ms, off), shifted(now, zoneOffset))
        }

        function dayMark(day, today) {
            var diff = Math.round((Date.UTC(day[0], day[1] - 1, day[2])
                                   - Date.UTC(today[0], today[1] - 1, today[2])) / 86400000)
            return diff === 0 ? "" : (diff > 0 ? " +" : " \u2212") + Math.abs(diff)
        }
    }

    Place {
        id: here
        lat: root.lat
        lon: root.lon
        method: root.method
        label: root.placeLabel
    }

    Place {
        id: there
        showsOwnClock: true
        lat: root.secLat
        lon: root.secLon
        method: root.secMethod
        label: root.secLabel
    }

    // How far a place's clock is from ours, in a few words.
    function offsetText(place) {
        var d = place.zoneOffset + new Date(nowMs).getTimezoneOffset() / 60
        if (Math.abs(d) < 1 / 120) return "same time"
        var h = Math.floor(Math.abs(d)), m = Math.round((Math.abs(d) - h) * 60)
        return (h > 0 ? h + "h" : "") + (h > 0 && m > 0 ? " " : "") + (m > 0 ? m + "m" : "")
             + (d > 0 ? " ahead" : " behind")
    }

    // === Display helpers ===
    function formatTime(time24h) {
        if (!time24h || time24h === "") return ""
        if (!root.use12H) return time24h
        var parts = time24h.split(":")
        if (parts.length < 2) return time24h
        var hours = parseInt(parts[0], 10)
        var ampm = hours >= 12 ? "PM" : "AM"
        hours = hours % 12
        if (hours === 0) hours = 12
        return hours + ":" + parts[1] + " " + ampm
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

    // The moon as it actually looks tonight. Drawn rather than picked from a
    // set of glyphs, because the terminator is a smooth function of the phase
    // and a handful of fixed icons would quantise it. It sits beside the Hijri
    // date because that calendar counts exactly this.
    component MoonPhase: Item {
        id: moon
        required property var place
        implicitWidth: 15
        implicitHeight: 15

        Connections {
            target: moon.place
            function onMoonFractionChanged() { moonCanvas.requestPaint() }
        }
        onPlaceChanged: moonCanvas.requestPaint()
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
                var p = moon.place.moonFraction
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
        required property var place

        readonly property int padX: 12
        readonly property int padY: 7

        function repaint() { skyCanvas.requestPaint() }

        Component.onCompleted: repaint()
        onWidthChanged: repaint()
        onVisibleChanged: if (visible) repaint()
        onPlaceChanged: repaint()

        Connections {
            target: sky.place
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

                var s = sky.place.sunSamples
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
                var marks = sky.place.arcMarks
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
                var now = sky.place.sunNow
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
                text: sky.place.today ? sky.place.clockText(sky.place.today.at.sunrise) : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
                opacity: 0.8
            }
            StyledText {
                text: "sunrise" + (sky.place.today && !isNaN(sky.place.zoneOffset) && sky.place.showsOwnClock
                                   ? "  \u00b7  " + sky.place.zoneClock(sky.place.today.at.sunrise) + " there" : "")
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
            }
        }

        Column {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: -1

            StyledText {
                anchors.right: parent.right
                text: sky.place.today ? sky.place.clockText(sky.place.today.at.maghrib) : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
                opacity: 0.8
            }
            StyledText {
                anchors.right: parent.right
                text: (sky.place.today && !isNaN(sky.place.zoneOffset) && sky.place.showsOwnClock
                       ? sky.place.zoneClock(sky.place.today.at.maghrib) + " there  \u00b7  " : "") + "sunset"
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
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

                DIcon {
                    name: here.located ? root.getPrayerIcon(here.nextName) : "location_off"
                    fill: here.located ? root.getPrayerFill(here.nextName) : 0.0
                    size: Theme.iconSize - 6
                    color: here.nextImminent ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 400 } }
                }

                StyledText {
                    visible: !root.iconOnly
                    width: visible ? implicitWidth : 0
                    text: here.next ? root.formatSplit(here.nextTotalSeconds) : "…"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: here.nextImminent ? Font.Bold : Font.Normal
                    color: here.nextImminent ? Theme.error : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 400 } }
                }
            }

            // Inset from the content by the theme's own spacing, so it reads as
            // a deliberate margin rather than a rule that nearly reaches the
            // pill's edge and stops.
            Rectangle {
                visible: root.showPillProgress && here.next !== null
                width: Math.max(12, pillRow.width - Theme.spacingS * 2)
                height: 2
                radius: 1
                anchors.horizontalCenter: parent.horizontalCenter
                color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.15)

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: Math.min(1, here.progressToNext) * parent.width
                    color: here.nextImminent ? Theme.error : root.accentColor

                    Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DIcon {
                name: here.located ? root.getPrayerIcon(here.nextName) : "location_off"
                fill: here.located ? root.getPrayerFill(here.nextName) : 0.0
                size: Theme.iconSize - 6
                color: here.nextImminent ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter

                Behavior on color { ColorAnimation { duration: 400 } }
            }

            StyledText {
                visible: here.next !== null
                text: root.formatSplit(here.nextTotalSeconds)
                font.pixelSize: Theme.fontSizeSmall - 2
                color: here.nextImminent ? Theme.error : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // Everything the popout says about one place, from the sky down to the
    // footer naming it.
    component PlaceView: Column {
        id: view
        required property var place
        spacing: Theme.spacingS

        // Every time here is on the system's clock. A second place with a
        // zone also shows its own clock, quieter, in a third column; the
        // other columns move left to make room for it.
        readonly property bool remote: place !== here
        readonly property bool showsZone: remote && !isNaN(place.zoneOffset)
        readonly property int colShift: showsZone ? 64 : 0

        // --- Nothing to compute from ---
        Rectangle {
            width: view.width
            height: emptyCol.implicitHeight + Theme.spacingL * 2
            radius: 12
            visible: !view.place.located
            color: Theme.surfaceContainerHigh

            Column {
                id: emptyCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingXS

                Row {
                    spacing: Theme.spacingS

                    DIcon {
                        name: "location_off"
                        size: Theme.iconSize - 4
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "No location set"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    width: parent.width
                    text: "Prayer times are computed from your coordinates. Set them in plugin settings, or search there for your town."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // --- The day ---
        // On a solid card: the popout's surface is translucent, and over a
        // light wallpaper secondary text washed out to nothing. The card keeps
        // it legible whatever is behind the shell, and gives the arc's markers
        // the background their rings are drawn to match.
        Rectangle {
            width: view.width
            height: dayCol.implicitHeight + Theme.spacingS * 2
            radius: 12
            visible: view.place.located
            color: Theme.surfaceContainerHigh

            Column {
                id: dayCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacingS
                spacing: Theme.spacingS

                // --- Where the sun is ---
                SunPath {
                    place: view.place
                    width: dayCol.width
                    height: 104
                    visible: view.place.sunSamples.length > 0
                }

                Rectangle {
                    width: dayCol.width
                    height: 1
                    visible: view.place.located
                    color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.08)
                }

                // --- Column header ---
                Item {
                    width: dayCol.width
                    height: 16
                    visible: view.place.located

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: view.place.focusDay === 0 ? "yesterday"
                              : view.place.focusDay === 2 ? "tomorrow" : ""
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.italic: true
                        color: Theme.primary
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 84 + view.colShift
                        anchors.verticalCenter: parent.verticalCenter
                        text: "opens"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 12 + view.colShift
                        anchors.verticalCenter: parent.verticalCenter
                        text: "closes"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: view.showsZone
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: "there"
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.italic: true
                        color: Theme.surfaceVariantText
                    }
                }

                // --- The whole day ---
                Repeater {
                    model: view.place.rows

                    delegate: Item {
                        id: row
                        required property var modelData
                        width: dayCol.width
                        height: line.height + (open ? 20 : 0)

                        // Already over. Every row is an instant, so Isha's close
                        // and Islamic midnight, which land after 00:00, need no
                        // special case.
                        readonly property bool isPast: (modelData.end !== null ? modelData.end : modelData.start)
                                                       <= view.place.now

                        // Matched by instant rather than by name: after Isha the
                        // next prayer is tomorrow's Fajr, and this morning's Fajr
                        // row must not claim it.
                        readonly property bool isNext: !modelData.marker && view.place.next !== null
                                                       && modelData.start === view.place.next.at
                        readonly property bool isFocus: !modelData.marker
                                                        && modelData.start === view.place.focusStart
                        readonly property bool open: isFocus && view.place.currentWindow !== null
                        readonly property bool urgent: open && view.place.isUrgent

                        // State lives in the row's fill and weight; identity lives
                        // in the dot's colour. Two channels, never mixed.
                        Rectangle {
                            anchors.fill: parent
                            anchors.topMargin: 1
                            anchors.bottomMargin: 1
                            radius: 14
                            color: row.isFocus
                                   ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, row.open ? 0.16 : 0.08)
                                   : "transparent"
                        }

                        Item {
                            id: line
                            width: parent.width
                            height: modelData.marker ? 24 : 30

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: modelData.marker ? 4 : 7
                                height: width
                                radius: width / 2
                                color: view.place.prayerColor(modelData.label)
                                opacity: row.isPast ? 0.4 : 1
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: modelData.marker ? 30 : 28
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6

                                StyledText {
                                    text: modelData.label
                                    font.pixelSize: modelData.marker ? Theme.fontSizeSmall : Theme.fontSizeMedium
                                    font.weight: row.isFocus ? Font.Bold : Font.Normal
                                    font.italic: modelData.marker
                                    color: Theme.surfaceText
                                    opacity: row.isPast ? 0.5 : (modelData.marker ? 0.8 : 1)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // The countdown, on the row it counts: how long is
                                // left of what is open, or how long until what is
                                // next. Elsewhere, a word marks the next prayer.
                                StyledText {
                                    visible: row.isFocus || row.isNext
                                    text: row.open ? root.formatSplit(view.place.spanRemainingSec) + " left"
                                          : row.isFocus ? "in " + root.formatSplit(view.place.nextTotalSeconds)
                                          : "next"
                                    font.pixelSize: row.isFocus ? Theme.fontSizeSmall : Theme.fontSizeSmall - 2
                                    font.weight: row.isFocus ? Font.DemiBold : Font.Normal
                                    font.italic: !row.isFocus
                                    color: row.urgent ? Theme.error : Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: 400 } }
                                }
                            }

                            // Right-aligned columns. The headers name them, so no
                            // arrow is needed in seven consecutive rows.
                            StyledText {
                                visible: !modelData.marker
                                anchors.right: parent.right
                                anchors.rightMargin: 84 + view.colShift
                                anchors.verticalCenter: parent.verticalCenter
                                text: view.place.clockText(modelData.start, view.remote)
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: row.isFocus ? Font.Bold : Font.Normal
                                color: Theme.surfaceText
                                opacity: row.isPast ? 0.5 : 1
                            }

                            StyledText {
                                visible: !modelData.marker
                                anchors.right: parent.right
                                anchors.rightMargin: 12 + view.colShift
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.end !== null ? view.place.clockText(modelData.end, view.remote) : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: row.isFocus ? Font.Bold : Font.Normal
                                color: Theme.surfaceText
                                opacity: row.isPast ? 0.45 : 0.85
                            }

                            // Sunrise and Islamic midnight open and close nothing,
                            // so their single time sits centred across both
                            // columns rather than pretending to be an opening.
                            StyledText {
                                visible: modelData.marker
                                x: parent.width - 122 - view.colShift + (110 - width) / 2
                                anchors.verticalCenter: parent.verticalCenter
                                text: view.place.clockText(modelData.start, view.remote)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                opacity: row.isPast ? 0.45 : 0.8
                            }

                            // The same opening on the clock there, smaller and
                            // quieter: the system's clock is what is acted on,
                            // this is for reference.
                            StyledText {
                                visible: view.showsZone
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: view.place.zoneClock(modelData.start)
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.italic: true
                                color: Theme.surfaceVariantText
                                opacity: row.isPast ? 0.6 : 1
                            }
                        }

                        // How far through the open window, under the times it
                        // spans. Only an open window gets one: under a prayer's
                        // opening and closing a bar reads as that prayer running
                        // out, so the wait before one is said in words instead.
                        Rectangle {
                            visible: row.open
                            anchors.top: line.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 28
                            anchors.rightMargin: 12
                            height: 4
                            radius: 2
                            color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.10)

                            Rectangle {
                                height: parent.height
                                radius: parent.radius
                                width: Math.min(1, view.place.spanProgress) * parent.width
                                color: row.urgent ? Theme.error : Theme.primary

                                Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 400 } }
                            }
                        }
                    }
                }

                // --- What all of this is computed for ---
                // A footer rather than a header: it is checked occasionally, not
                // watched, so it should not compete with the table.
                Item {
                    width: dayCol.width
                    height: 22
                    visible: view.place.located

                    DIcon {
                        id: placePin
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        name: "location_on"
                        size: Theme.fontSizeSmall + 3
                        color: Theme.surfaceVariantText
                        opacity: 0.7
                    }

                    // Anchored between the pin and the coordinates rather than laid out
                    // in a row, so a long name elides instead of running underneath the
                    // numbers on the right.
                    StyledText {
                        anchors.left: placePin.right
                        anchors.leftMargin: Theme.spacingXS
                        anchors.right: placeCoords.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: view.place.label !== "" ? view.place.label
                                                      : root.coordText(view.place.lat, view.place.lon)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }

                    // The numbers stay on show beside a name: the name is the readable
                    // label, the coordinates are what is actually used.
                    StyledText {
                        id: placeCoords
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: view.place.label !== ""
                        width: visible ? implicitWidth : 0
                        text: root.coordText(view.place.lat, view.place.lon)
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        opacity: 0.65
                    }
                }
            }
        }
    }

    // Popout panel:
    popoutContent: Component {
        Item {
            id: popoutRoot
            // The popout's loader sets the width, from root.popoutWidth.
            implicitHeight: content.implicitHeight + Theme.spacingM * 2

            readonly property var shown: root.hasSecond && root.popoutTab === 1 ? there : here

            // The town's own name, without the region and country the search
            // appends; a tab has room for "Mecca", not "Mecca, Makkah, Saudi Arabia".
            function shortName(place, fallback) {
                return place.label !== "" ? place.label.split(",")[0] : fallback
            }

            Column {
                id: content
                spacing: Theme.spacingS
                anchors.fill: parent
                anchors.margins: Theme.spacingM

                // --- Date, and which place ---
                // On a card like the rest: on the bare translucent surface the
                // moon's percentage and the unselected tab faded into a light
                // wallpaper.
                Rectangle {
                    width: content.width
                    height: headCol.implicitHeight + Theme.spacingS * 2
                    radius: 12
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: headCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingS
                        anchors.leftMargin: Theme.spacingM
                        spacing: Theme.spacingXS

                        // --- Date ---
                        Item {
                            width: headCol.width
                            height: 28

                            Row {
                                id: hijriLabel
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXS

                                MoonPhase {
                                    place: popoutRoot.shown
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: popoutRoot.shown.hijriText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            // How full, and which way it is going. No arrow at new or
                            // full: there the direction is turning over rather than
                            // pointing anywhere, so an arrow would assert something false.
                            StyledText {
                                anchors.left: hijriLabel.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.baseline: hijriLabel.top
                                anchors.baselineOffset: hijriLabel.height / 2 + 4
                                text: Math.round(popoutRoot.shown.moonLit * 100) + "%"
                                      + (popoutRoot.shown.moonTurning ? "" : (popoutRoot.shown.moonWaxes ? " ↑" : " ↓"))
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                visible: popoutRoot.shown.hijriText !== "" && width + hijriLabel.width + 40 < parent.width
                            }
                        }

                        // Which place, and the time at the other one. Shown
                        // the same on both tabs, so switching changes what
                        // the panel says and never how tall it is.
                        Item {
                            width: headCol.width
                            height: 26
                            visible: root.hasSecond

                            Rectangle {
                                id: switcher
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: segments.width + 4
                                height: parent.height
                                radius: height / 2
                                color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.07)

                                Row {
                                    id: segments
                                    anchors.centerIn: parent

                                    Repeater {
                                        model: [popoutRoot.shortName(here, "Here"),
                                                popoutRoot.shortName(there, "There")]

                                        delegate: Rectangle {
                                            required property var modelData
                                            required property int index
                                            readonly property bool active: root.popoutTab === index
                                            width: Math.min(110, segLabel.implicitWidth + Theme.spacingM * 2)
                                            height: switcher.height - 4
                                            radius: height / 2
                                            color: active ? Theme.primary : "transparent"

                                            Behavior on color { ColorAnimation { duration: 150 } }

                                            StyledText {
                                                id: segLabel
                                                anchors.centerIn: parent
                                                width: Math.min(implicitWidth, 110 - Theme.spacingM * 2)
                                                text: modelData
                                                elide: Text.ElideRight
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: active ? Font.DemiBold : Font.Normal
                                                color: active ? Theme.primaryText : Theme.surfaceText
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.popoutTab = index
                                            }
                                        }
                                    }
                                }
                            }

                            StyledText {
                                anchors.left: switcher.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                elide: Text.ElideLeft
                                textFormat: Text.StyledText
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                text: (there.label !== "" ? there.label.split(",")[0] + "  " : "")
                                      + (!isNaN(there.zoneOffset)
                                         ? "<b>" + there.zoneClock(there.now) + "</b>  \u00b7  " + root.offsetText(there)
                                         : (there.zoneLoading ? "checking the time\u2026" : "time unknown"))
                            }
                        }
                    }
                }

                PlaceView {
                    width: content.width
                    place: popoutRoot.shown
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
    //         highLat ("angle" | "nightmiddle" | "seventh" | "none"),
    //         hijriOffset (days; decides when Ramadan's longer Isha interval applies) }
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
            // Isha falls after Maghrib, when the next Hijri day has begun: the
            // eve of 1 Ramadan has the longer interval, the eve of Eid does not.
            if (m.isha.ramadanMinutes && hijriDate(year, month, day + 1, opts.hijriOffset).month === 9)
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

        function portion(angle) {
            if (mode === "angle" && typeof angle === "number") return night / 60 * angle
            if (mode === "seventh") return night / 7
            return night / 2   // nightmiddle
        }

        if (isNaN(times.fajr)) times.fajr = times.sunrise - portion(m.fajr)
        if (isNaN(times.isha) && typeof m.isha === "number")
            times.isha = times.sunset + portion(m.isha)
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

    // Fraction of the disc lit, 0 at new and 1 at full.
    function moonIllumination(phase) {
        return (1 - Math.cos(2 * Math.PI * phase)) / 2
    }

    // True while the lit fraction is growing. Meaningless at the two turning points,
    // where the direction is changing rather than pointing anywhere.
    function moonWaxing(phase) {
        return phase < 0.5
    }

    function moonAtTurningPoint(phase) {
        return phase < 0.02 || phase > 0.98 || (phase > 0.48 && phase < 0.52)
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

    // The Hijri date at an instant. The Islamic day begins at Maghrib, so it
    // is the date of the civil day after the last Maghrib to have happened.
    // `days` are consecutive civil days, each { y, m, d, at } with at.maghrib
    // an instant; julianDay is linear in the day, so d + 1 may run past the
    // month's end.
    function hijriAt(days, now, dayOffset) {
        var last = -1
        for (var i = 0; i < days.length; i++)
            if (days[i].at.maghrib <= now) last = i
        var d = days[Math.max(0, last)]
        return hijriDate(d.y, d.m, d.d + (last < 0 ? 0 : 1), dayOffset)
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

    // === Timeline ===
    // computeDay answers in wall-clock hours on one civil date at one UTC offset.
    // Hours from different days, from either side of a daylight-saving change,
    // or from two time zones cannot be compared by subtracting them -- a day
    // with a DST change is 23 or 25 hours long, which put the overnight
    // countdown an hour out on both transition days. So each event is pinned to
    // the instant it names, in milliseconds since the epoch, and every ordering
    // and duration is taken between instants.
    function instantOf(year, month, day, hours, tzOffset) {
        return Date.UTC(year, month - 1, day) + (hours - tzOffset) * 3600000
    }

    // A civil day's events as instants. Islamic midnight belongs to the night
    // that follows the day's sunset. On the place's own clock that usually
    // means after 00:00; read off a clock in another zone it can fall
    // anywhere, so it is placed after sunset rather than after noon.
    function dayInstants(year, month, day, times, tzOffset) {
        var out = {}
        for (var k in times)
            out[k] = instantOf(year, month, day, times[k], tzOffset)
        if (isFinite(out.midnight) && isFinite(out.sunset))
            while (out.midnight < out.sunset)
                out.midnight += 86400000
        return out
    }

    // An instant read off a wall clock at the given UTC offset, in hours [0, 24).
    function wallHours(ms, tzOffset) {
        return fixHour(ms / 3600000 + tzOffset)
    }

    // How long each prayer may be prayed for. Most windows close when the next
    // prayer opens; two do not. Fajr closes at sunrise rather than running on to
    // Dhuhr, and Isha closes at Islamic midnight -- the middle of the night --
    // rather than at the following dawn. Isha may still be prayed after that out
    // of necessity, but its time has ended, so midnight is the limit shown.
    //
    // y and t are yesterday's and today's dayInstants. Yesterday's Isha is
    // included because the small hours of today still belong to it.
    function prayerWindows(y, t) {
        return [
            { name: "Isha",    start: y.isha,    end: y.midnight, endLabel: "Islamic midnight" },
            { name: "Fajr",    start: t.fajr,    end: t.sunrise,  endLabel: "sunrise" },
            { name: "Dhuhr",   start: t.dhuhr,   end: t.asr,      endLabel: "Asr" },
            { name: "Asr",     start: t.asr,     end: t.maghrib,  endLabel: "Maghrib" },
            { name: "Maghrib", start: t.maghrib, end: t.isha,     endLabel: "Isha" },
            { name: "Isha",    start: t.isha,    end: t.midnight, endLabel: "Islamic midnight" }
        ]
    }

    // The prayer starts spanning today, closing with tomorrow's Fajr so the
    // Isha -> Fajr countdown crosses midnight cleanly.
    function prayerSchedule(t, m) {
        return [
            { name: "Fajr",    at: t.fajr },
            { name: "Dhuhr",   at: t.dhuhr },
            { name: "Asr",     at: t.asr },
            { name: "Maghrib", at: t.maghrib },
            { name: "Isha",    at: t.isha },
            { name: "Fajr",    at: m.fajr }
        ]
    }

    // The stretch containing `now`: the window that is open, or -- between
    // sunrise and Dhuhr, and between Islamic midnight and dawn -- the gap
    // before the next one, so one bar and one countdown cover every moment of
    // the day instead of the panel emptying out for hours at a time.
    function spanAt(windows, now) {
        for (var i = 0; i < windows.length; i++)
            if (now >= windows[i].start && now < windows[i].end)
                return windows[i]
        for (var j = 0; j < windows.length - 1; j++)
            if (now >= windows[j].end && now < windows[j + 1].start)
                return { name: "", start: windows[j].end, end: windows[j + 1].start,
                         endLabel: windows[j + 1].name, gap: true }
        return null
    }

    // Index of the first prayer still to come, or -1.
    function nextIndex(schedule, now) {
        for (var i = 0; i < schedule.length; i++)
            if (schedule[i].at > now)
                return i
        return -1
    }

    // === Another zone's clock ===
    // `zdump -i` lists a zone's offset changes over a range of years, one per
    // line, tab-separated: the local date and time just after the change,
    // then the new offset ("2026-11-01  01  -06  CST"). The first line, with
    // dashes for date and time, is the offset in force as the range opens. Read once, this
    // answers the offset at any instant in the range by lookup alone.
    //
    // Returns [{ from: ms, off: hours }] in order, or null if nothing usable.
    function parseZoneTable(text) {
        function hours(o) {
            var m = /^([+-])(\d\d):?(\d\d)?:?(\d\d)?$/.exec(o)
            if (!m) return NaN
            return (m[1] === "-" ? -1 : 1) * (Number(m[2]) + Number(m[3] || 0) / 60
                                               + Number(m[4] || 0) / 3600)
        }
        var out = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t")
            if (f.length < 3) continue
            var off = hours(f[2])
            if (isNaN(off)) continue
            if (f[0] === "-") {
                out.push({ from: -Infinity, off: off })
                continue
            }
            var d = /^(\d+)-(\d\d)-(\d\d)$/.exec(f[0])
            var t = /^(\d\d):?(\d\d)?:?(\d\d)?$/.exec(f[1])   // "01", "0130" or "01:30"
            if (!d || !t || out.length === 0) continue
            // Local time after the change, so it is undone with the new offset.
            var local = Date.UTC(Number(d[1]), Number(d[2]) - 1, Number(d[3]),
                                 Number(t[1]), Number(t[2] || 0), Number(t[3] || 0))
            out.push({ from: local - off * 3600000, off: off })
        }
        return out.length > 0 && out[0].from === -Infinity ? out : null
    }

    function zoneOffsetAt(table, ms) {
        if (!table || isNaN(ms)) return NaN
        var off = NaN
        for (var i = 0; i < table.length && table[i].from <= ms; i++)
            off = table[i].off
        return off
    }

    // ===== END CALC =====
}
