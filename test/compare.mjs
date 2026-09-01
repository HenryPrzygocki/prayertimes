import fs from "node:fs"
import { execSync } from "node:child_process"
const src = fs.readFileSync("/home/henry/.config/DankMaterialShell/plugins/prayerTimes/PrayerCalc.js","utf8").replace(".pragma library","")
const Calc = {}
new Function("exports", src + "\n;Object.assign(exports,{computeDay,toHHMM,METHODS})")(Calc)
const cache = JSON.parse(fs.readFileSync("apicache.json","utf8"))
const CITIES = Object.fromEntries(JSON.parse(fs.readFileSync("cities.json","utf8")).map(c=>[c.name,c]))

// Use glibc's tzdata (what Qt sees) rather than node's bundled ICU copy.
const tzCache = {}
function tzOffset(zone, date) {
  const key = zone + date.toISOString().slice(0,10)
  if (tzCache[key] !== undefined) return tzCache[key]
  const out = execSync(`TZ=${zone} date -d @${Math.floor(date.getTime()/1000)} +%z`).toString().trim()
  const sign = out[0]==="-"?-1:1
  return tzCache[key] = sign*(+out.slice(1,3) + (+out.slice(3,5))/60)
}
const KEYS={Fajr:"fajr",Sunrise:"sunrise",Dhuhr:"dhuhr",Asr:"asr",Sunset:"sunset",Maghrib:"maghrib",Isha:"isha",Midnight:"midnight"}
const mins=t=>{const[h,m]=t.split(":").map(Number);return h*60+m}
const delta=(a,b)=>{let d=mins(a)-mins(b); if(d>720)d-=1440; if(d<-720)d+=1440; return d}

const byCity={}, all=[]
for (const [key,rec] of Object.entries(cache)) {
  const [name,ds,school]=key.split("|")
  const c=CITIES[name]; const [d,mo,y]=ds.split("-").map(Number)
  const off=tzOffset(rec.tz,new Date(Date.UTC(y,mo-1,d,12)))
  const loc=Calc.computeDay(y,mo,d,{lat:c.lat,lon:c.lon,tzOffset:off,method:c.method,
    asrFactor:school==="1"?2:1,highLat:"angle"})
  for (const [K,k] of Object.entries(KEYS)) {
    const a=rec.timings[K].split(" ")[0], b=Calc.toHHMM(loc[k])
    const dv=b?delta(b,a):NaN
    ;(byCity[name] ||= []).push(dv)
    all.push({name,ds,school,K,a,b,dv})
  }
}
console.log("city                  n   max|Δ|  distribution")
for (const [n,ds] of Object.entries(byCity)) {
  const fin=ds.filter(x=>!isNaN(x))
  const max=Math.max(...fin.map(Math.abs))
  const hist={}; for(const d of ds) hist[isNaN(d)?"NaN":d]=(hist[isNaN(d)?"NaN":d]||0)+1
  console.log(n.padEnd(20), String(ds.length).padStart(3), String(max).padStart(6), "  ",
    Object.entries(hist).sort((x,y)=>Math.abs(x[0])-Math.abs(y[0])).map(([k,v])=>`${k}min×${v}`).join(" "))
}
const bad=all.filter(x=>!(Math.abs(x.dv)<=1))
console.log(`\n${all.length} comparisons; ${bad.length} outside ±1 min`)
const groups={}
for(const b of bad) (groups[`${b.name} ${b.K}`] ||= []).push(`${b.ds}s${b.school} api=${b.a} loc=${b.b} Δ=${b.dv}`)
for(const [g,v] of Object.entries(groups)) console.log(` ${g.padEnd(30)} ${v.length}×  e.g. ${v[0]}`)
