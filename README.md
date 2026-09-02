# Prayer Times

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) widget showing Islamic
prayer times, computed locally from the sun's position.

![Screenshot](screenshot.png)

## What it does

- **No network.** Prayer times are a deterministic function of date, latitude and longitude, so
  they are calculated on this machine. Works offline, cannot be rate limited, and your
  coordinates are never sent anywhere.
- **Prayers as windows, not instants.** Each prayer shows when it opens, when it closes, and how
  much of it is left. Most close as the next one opens; two do not. Fajr closes at sunrise rather
  than running on to Dhuhr, and Isha closes at Islamic midnight — the middle of the night — rather
  than at the following dawn. Both leave a stretch with no prayer due, and the widget says so
  outright rather than going blank.
- **Hijri date**, with an adjustment for calendars set by local moonsighting.
- 22 calculation methods, both Asr schools, angle-based high-latitude handling, and a polar clamp.

## Accuracy

The calculation is cross-checked against the [Aladhan API](https://aladhan.com/prayer-times-api)
by the harness in `test/`: 2016 comparisons across 21 cities, six dates spanning both solstices
and equinoxes, and both Asr schools. Nineteen of the twenty-one cities agree to within one minute
on every prayer. `test/README.md` documents the remaining divergences — three of which are the API
applying undocumented defaults that contradict its own published parameters.

```bash
cd test
node fetchcache.mjs   # snapshot API responses
node compare.mjs      # compare local computation against them
```

## Requirements

DankMaterialShell ≥ 0.2.4 on Quickshell 0.2+. No external tools.

## Installation

```bash
git clone https://github.com/HenryPrzygocki/prayertimes.git \
  ~/.config/DankMaterialShell/plugins/prayerTimes
```

Then enable it in *DMS Settings → Plugins* and add the widget to a DankBar section.

## Configuration

Set your latitude and longitude, pick the calculation method your local mosque follows, and choose
the Asr school. Everything else is display preference.

Note that the calculation method is a *convention*, not a physical constant: methods differ only in
which angle below the horizon counts as dawn and nightfall. The Asr school is the one setting that
changes a geometric rule, and switching from Shafi to Hanafi moves Asr itself 45–70 minutes later.

## Credits

Forked from [muadzmo/prayertimes](https://github.com/muadzmo/prayertimes) by **muadz**, which
provided the original widget, its icon, and the plugin's overall shape.

This fork replaced the Aladhan HTTP client with a local implementation of the underlying solar
geometry, added the prayer-window model, and rebuilt the bar pill and popout.

> **Licensing:** the upstream repository does not carry a licence file, so no licence terms have
> been granted for its code. This fork is published on GitHub under the same conditions the
> original was, and adds no licence of its own, since that would not be ours to grant. If you
> intend to redistribute this outside GitHub, ask the original author to add a licence first.
