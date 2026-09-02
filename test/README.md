# Verification harness

Cross-checks the calculation against the Aladhan API, which is what this plugin
used to call at runtime.

The maths lives inside `PrayerWidget.qml`, between the `BEGIN CALC` / `END CALC`
markers, because Quickshell caches a script imported from a separate file by URL
for the life of the process — so edits to it did not take effect on a plugin
reload, only on a shell restart. The region is plain function declarations and
nothing else, and `extract.mjs` lifts it out unchanged to run here.

```bash
node fetchcache.mjs   # snapshot API responses to apicache.json (slow, rate-limited)
node compare.mjs      # compare local computation against the snapshot
node hijri.mjs        # score the tabular Hijri calendar against Aladhan's
```

`compare.mjs` sources UTC offsets from glibc (`TZ=... date`) rather than node's
bundled ICU copy, because Qt reads the system tzdata and the two disagree for
Morocco.

## Expected result

19 of 21 cities agree to within one minute on every prayer, across solstices,
equinoxes, both Asr schools, and six dates. The known divergences are:

| Divergence | Cause |
|---|---|
| Tromsø (69°N), polar day/night | Aladhan collapses every time onto solar noon; we keep a self-consistent night split. |
| Qum midnight, −43 min | Aladhan ignores its own method's `Midnight: JAFARI` param unless `midnightMode=1` is passed; with it, Aladhan matches us exactly. |
| Paris Fajr/Isha at solstice, ±9 min | Aladhan's no-parameter default is an undocumented rule; with `latitudeAdjustmentMethod=3` (ANGLE_BASED) it matches us exactly. |
| Asr ±2 min at low sun elevation | Small residual in Aladhan's Asr near the horizon. Our iteration is fully converged at 3 passes (verified against 8). |
