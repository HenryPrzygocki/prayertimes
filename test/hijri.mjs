import fs from "node:fs"
const src=fs.readFileSync("/home/henry/.config/DankMaterialShell/plugins/prayerTimes/PrayerCalc.js","utf8").replace(".pragma library","")
const C={}; new Function("e",src+"\n;Object.assign(e,{hijriDate,julianDay})")(C)

// sample the 1st, 10th and 20th of each Gregorian month over 2 years
const samples=[]
for (let y=2026;y<=2027;y++) for(let m=1;m<=12;m++) for(const d of [1,14,26]) samples.push([y,m,d])
const res=[]
for (const [y,m,d] of samples){
  const ds=`${String(d).padStart(2,"0")}-${String(m).padStart(2,"0")}-${y}`
  let j=null
  for(let a=0;a<5;a++){ try{ const r=await fetch(`https://api.aladhan.com/v1/gToH/${ds}`); j=await r.json(); if(j&&j.code===200)break }catch(e){}
    await new Promise(r=>setTimeout(r,1200*(a+1))) }
  if(!j||j.code!==200){ continue }
  const h=j.data.hijri
  res.push({y,m,d,ay:+h.year,am:+h.month.number,ad:+h.day})
  await new Promise(r=>setTimeout(r,80))
}
fs.writeFileSync("hijri_ref.json",JSON.stringify(res))

// score a day-offset applied to the tabular calendar
function score(off){
  let exact=0, off1=0, worse=0
  for(const r of res){
    const t=C.hijriDate(r.y,r.m,r.d,off)
    // convert both to an absolute day count for comparison
    const dv=(t.year-r.ay)*354.367+(t.month-r.am)*29.53+(t.day-r.ad)
    if(Math.abs(dv)<0.5) exact++; else if(Math.abs(dv)<1.5) off1++; else worse++
  }
  return {off,exact,off1,worse}
}
console.log(`${res.length} reference dates from Aladhan`)
for(let o=-2;o<=2;o++){ const s=score(o); console.log(` offset ${String(o).padStart(2)}: exact ${String(s.exact).padStart(3)}  ±1day ${String(s.off1).padStart(3)}  worse ${s.worse}`) }
