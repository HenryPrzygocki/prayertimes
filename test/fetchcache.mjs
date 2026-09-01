import fs from "node:fs"
const CITIES = JSON.parse(fs.readFileSync("cities.json","utf8"))
const DATES = [[2026,9,1],[2026,12,21],[2026,6,21],[2027,3,20],[2026,10,15],[2027,2,10]]
const out = {}
for (const c of CITIES) for (const [y,mo,d] of DATES) for (const school of [0,1]) {
  const ds = `${String(d).padStart(2,"0")}-${String(mo).padStart(2,"0")}-${y}`
  const key = `${c.name}|${ds}|${school}`
  const url = `https://api.aladhan.com/v1/timings/${ds}?latitude=${c.lat}&longitude=${c.lon}&method=${c.method}&school=${school}`
  let json=null
  for (let a=0;a<6;a++){ try{ const r=await fetch(url); json=await r.json(); if(json&&json.code===200) break }catch(e){json=null}
    await new Promise(r=>setTimeout(r,1500*(a+1))) }
  if(!json||json.code!==200){ console.log("MISS",key); continue }
  out[key]={timings:json.data.timings, tz:json.data.meta.timezone, method:json.data.meta.method}
  await new Promise(r=>setTimeout(r,100))
}
fs.writeFileSync("apicache.json", JSON.stringify(out))
console.log("cached", Object.keys(out).length, "responses")
