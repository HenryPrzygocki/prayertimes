// Checks the instant-based timeline the widget builds on top of computeDay:
// that it round-trips to the same wall-clock times, stays ordered across both
// daylight-saving transitions, covers every minute of the day, and gives the
// same instants whichever zone the place is viewed from.
//
// Needs no network and no API snapshot. Offsets come from glibc, as in
// compare.mjs, because that is what Qt reads.
import fs from "node:fs"
import { execSync } from "node:child_process"
import { loadCalc } from "./extract.mjs"

const C = loadCalc()
const cities = JSON.parse(fs.readFileSync(new URL("cities.json", import.meta.url), "utf8"))

function tzOffset(zone, y, m, d) {
  const out = execSync(`TZ=${zone} date -d "${y}-${m}-${d} 12:00" +%z`).toString().trim()
  return (out[0] === "-" ? -1 : 1) * (+out.slice(1, 3) + +out.slice(3, 5) / 60)
}

function day(c, y, m, d) {
  const tz = tzOffset(c.tz, y, m, d)
  const times = C.computeDay(y, m, d, { lat: c.lat, lon: c.lon, tzOffset: tz,
                                        method: c.method, asrFactor: 1, highLat: "angle" })
  return { tz, times, at: C.dayInstants(y, m, d, times, tz) }
}

function shift(y, m, d, k) {
  const t = new Date(Date.UTC(y, m - 1, d + k))
  return [t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()]
}

let failures = 0, checks = 0
function check(ok, msg) { checks++; if (!ok) { failures++; console.log("FAIL", msg) } }

// Both US transitions, both EU ones, and ordinary days either side of them.
const DATES = [[2026, 3, 8], [2026, 3, 29], [2026, 6, 21], [2026, 10, 25],
               [2026, 11, 1], [2026, 12, 21]]

for (const c of cities) {
  for (const [y, m, d] of DATES) {
    const tag = `${c.name} ${y}-${m}-${d}`
    const Y = day(c, ...shift(y, m, d, -1)), T = day(c, y, m, d), M = day(c, ...shift(y, m, d, 1))

    // Round trip: an instant read back off the same clock is the time computed.
    for (const k of ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha", "midnight"])
      if (isFinite(T.times[k]))
        check(C.toHHMM(C.wallHours(T.at[k], T.tz)) === C.toHHMM(T.times[k]),
              `${tag} ${k} round trip`)

    // Inside the polar circles computeDay collapses a missing sunrise or sunset
    // onto solar noon, which keeps the arithmetic finite but leaves Maghrib
    // before Asr. That is a known limit (README), not something to test here.
    const polar = T.times.sunrise === T.times.dhuhr || T.times.sunset === T.times.dhuhr
    const w = C.prayerWindows(Y.at, T.at)
    if (polar || w.some(x => !isFinite(x.start) || !isFinite(x.end))) continue

    // Each window opens before it closes, and none overlaps the next.
    for (let i = 0; i < w.length; i++) {
      check(w[i].start < w[i].end, `${tag} ${w[i].name} window inverted`)
      if (i + 1 < w.length) check(w[i].end <= w[i + 1].start, `${tag} ${w[i].name} overlaps ${w[i + 1].name}`)
    }

    // Every minute from yesterday's Isha to tonight's midnight is either inside a
    // window or inside a gap the panel can describe.
    for (let t = w[0].start; t < w[w.length - 1].end; t += 60000)
      if (!C.spanAt(w, t)) { check(false, `${tag} no span at ${new Date(t).toISOString()}`); break }

    // After Isha the next prayer is tomorrow's Fajr, not this morning's -- the
    // case that used to mark today's long-gone Fajr row as upcoming.
    const s = C.prayerSchedule(T.at, M.at)
    const i = C.nextIndex(s, T.at.isha + 60000)
    check(i === 5 && s[i].at === M.at.fajr, `${tag} next after Isha is tomorrow's Fajr`)

    // Viewing the same place from another zone -- which is how the second
    // location is computed, on the system's clock -- moves the clock, not the
    // event: the instants must agree, give or take the solar day the date
    // picks out. Islamic midnight included: it must still land in the night
    // after its own sunset, wherever that falls on the viewer's clock.
    for (const shiftH of [7, -9, 12, -13]) {
      const tzv = T.tz + shiftH
      const far = C.dayInstants(y, m, d,
        C.computeDay(y, m, d, { lat: c.lat, lon: c.lon, tzOffset: tzv, method: c.method,
                                asrFactor: 1, highLat: "angle" }), tzv)
      for (const k of ["fajr", "dhuhr", "asr", "maghrib", "isha", "midnight"])
        check(Math.abs(far[k] - T.at[k]) < 1000 || Math.abs(Math.abs(far[k] - T.at[k]) - 86400000) < 600000,
              `${tag} ${k} instant depends on viewing zone (${shiftH > 0 ? "+" : ""}${shiftH}h)`)
      check(far.midnight > far.sunset && far.midnight < far.sunrise + 86400000,
            `${tag} midnight outside its night viewed at ${shiftH}h`)
    }
  }
}

console.log(`${checks} checks, ${failures} failures`)
process.exit(failures ? 1 : 0)
