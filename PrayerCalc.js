.pragma library

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
var METHODS = {
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

var SUNSET_ANGLE = 0.833   // refraction + solar semidiameter

// === Core ===
// opts: { lat, lon, tzOffset (hours, DST-aware), method, asrFactor (1 Shafi | 2 Hanafi),
//         highLat ("angle" | "nightmiddle" | "seventh" | "none") }
// Returns times as fractional hours in local civil time, or null where the sun
// never reaches the required altitude and no adjustment is requested.
function computeDay(year, month, day, opts) {
    var lat = opts.lat
    var lon = opts.lon
    var tz = opts.tzOffset
    var m = METHODS[String(opts.method)] || METHODS["3"]
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
            sunrise: sunAngleTime(SUNSET_ANGLE, t.sunrise, "ccw"),
            dhuhr:   midDay(t.dhuhr),
            asr:     asrTime(asrFactor, t.asr),
            sunset:  sunAngleTime(SUNSET_ANGLE, t.sunset, "cw")
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
var HIJRI_MONTHS = [
    "Muharram", "Safar", "Rabi' al-awwal", "Rabi' al-thani",
    "Jumada al-ula", "Jumada al-akhira", "Rajab", "Sha'ban",
    "Ramadan", "Shawwal", "Dhu al-Qi'dah", "Dhu al-Hijjah"
]

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
    return { day: day, month: month, year: year, monthName: HIJRI_MONTHS[month - 1] }
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

