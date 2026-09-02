// Lifts the calculation out of PrayerWidget.qml so it can run under node.
//
// It lives in the .qml because Quickshell caches an imported script by URL for
// the life of the process, so edits to a separate .js file do not take effect on
// a plugin reload. The region between the CALC markers is plain function
// declarations and nothing else, so it needs no transformation to run here.
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))

export function loadCalc(qmlPath = path.join(here, "..", "PrayerWidget.qml")) {
  const src = fs.readFileSync(qmlPath, "utf8")
  const a = src.indexOf("// ===== BEGIN CALC =====")
  const b = src.indexOf("// ===== END CALC =====")
  if (a < 0 || b < 0) throw new Error("CALC markers not found in " + qmlPath)

  const body = src.slice(a, b)
    .split("\n").slice(1)                    // drop the marker line
    .map(l => l.startsWith("    ") ? l.slice(4) : l)
    .join("\n")

  const stray = body.split("\n").find(l =>
    /^\s*(property|readonly|signal|id:|anchors)/.test(l))
  if (stray) throw new Error("QML leaked into the calc region: " + stray.trim())

  const exports = {}
  const names = ["computeDay", "toHHMM", "toSeconds", "hijriDate", "formatHijri",
                 "solarAltitude", "sunSkyPoint", "moonPhase", "moonIllumination",
                 "moonPhaseName", "methodTable", "sunPosition", "julianDay"]
  new Function("e", body + "\n;Object.assign(e,{" + names.join(",") + "})")(exports)
  return exports
}
