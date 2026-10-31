# Prayer Times

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) widget showing Islamic
prayer times, computed locally from the sun's position.

![Screenshot](screenshot.png)

## What it does

- **No network.** Prayer times are a deterministic function of date, latitude and longitude, so
  they are calculated on this machine. Works offline, cannot be rate limited, and your
  coordinates are never sent anywhere. The sole exception is the place search in settings, which
  asks a directory for a named town's coordinates when you search for one, and can name the
  coordinates you already have (which sends them to a reverse geocoder, and only when you press the
  button). If you set a second location, the widget asks open-meteo once which time zone it is
  in; the main location never leaves the machine. Both look up a place, never an IP, so they are unaffected by a
  VPN — unlike IP geolocation, which resolves to the provider's exchange (163 km out when tested
  here, enough to move every prayer by several minutes) and is not used.
- **Prayers as windows, not instants.** Each prayer shows when it opens, when it closes, and how
  much of it is left. Most close as the next one opens; two do not. Fajr closes at sunrise rather
  than running on to Dhuhr, and Isha closes at Islamic midnight — the middle of the night — rather
  than at the following dawn. Both leave a stretch with no prayer due, and the widget says so
  outright rather than going blank.
- **A second location**, on its own tab in the popout: somewhere else to keep an eye on, worked
  out exactly as the main one is, with every time on your system's clock, and each also shown,
  smaller, on the clock there. The widget asks open-meteo which zone the place is in, once; the
  offset comes from the system's own tzdata, so a change in the rules there arrives with the next
  tzdata update rather than whenever a web service catches up. The bar keeps following the main
  location.
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
node timeline.mjs     # windows and countdowns across DST changes and time zones (offline)
```

## Requirements

DankMaterialShell (Dux Shell) ≥ 2.0. Version 3 of this plugin uses the `qs.DCommon.Widgets` set
that 2.0 introduced; for an older shell, check out the `v2.1.0` tag.

The `process` permission is used only to read a second location's UTC offset from the system's
tzdata with `date(1)`. No other external tools.

## Installation

```bash
git clone https://github.com/HenryPrzygocki/prayertimes.git \
  ~/.config/DankMaterialShell/plugins/prayerTimes
```

Then enable it in *DMS Settings → Plugins* and add the widget to a DankBar section.

## Configuration

Set your latitude and longitude, pick the calculation method your local mosque follows, and choose
the Asr school. Everything else is display preference. A second location is optional; search for it
and its coordinates and time zone are filled in together.

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
