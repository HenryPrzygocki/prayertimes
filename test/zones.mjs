// Checks the zone table the widget reads once from `zdump -i`: at instants
// across two years, and on either side of every change, the offset looked up
// from the table must equal what glibc's date(1) says for that instant.
import { execSync, execFileSync } from "node:child_process"
import { loadCalc } from "./extract.mjs"

const C = loadCalc()
const ZONES = ["Africa/Casablanca", "America/Chicago", "Europe/London", "Asia/Riyadh",
               "Asia/Kolkata", "Australia/Lord_Howe", "America/St_Johns", "Asia/Kathmandu"]
const Y = new Date().getFullYear()

let checks = 0, failures = 0
for (const z of ZONES) {
  const table = C.parseZoneTable(execFileSync("zdump", ["-i", "-c", `${Y},${Y + 2}`, z]).toString())
  if (!table) { console.log("FAIL no table for", z); failures++; continue }

  const start = Date.UTC(Y, 0, 1), end = Date.UTC(Y + 2, 0, 1)
  const probes = []
  for (let t = start; t < end; t += 5 * 86400000 + 3600000 * 7) probes.push(t)   // drifts through the hours
  for (const row of table) if (isFinite(row.from)) probes.push(row.from - 1000, row.from, row.from + 1000)

  // One date(1) call per zone, fed every probe.
  const out = execSync(`for t in ${probes.map(p => Math.floor(p / 1000)).join(" ")}; do TZ=${z} date -d @$t +%z; done`)
    .toString().trim().split("\n")
  probes.forEach((p, i) => {
    const o = out[i], want = (o[0] === "-" ? -1 : 1) * (+o.slice(1, 3) + +o.slice(3, 5) / 60)
    const got = C.zoneOffsetAt(table, Math.floor(p / 1000) * 1000)
    checks++
    if (Math.abs(got - want) > 1e-9) {
      failures++
      if (failures < 10) console.log(`FAIL ${z} @ ${new Date(p).toISOString()}: table ${got}, date ${want}`)
    }
  })
}
console.log(`${checks} checks, ${failures} failures`)
process.exit(failures ? 1 : 0)
