# StrongRow

![StrongRow — low-rate rowing, measured to a tenth](store/hero.png)

A Garmin Connect IQ watch app for **strength-focused, low-stroke-rate rowing**. It
computes stroke rate from the watch's raw accelerometer — tuned for the slow,
deliberate strokes used in strength/durability work — and displays it to a
**tenth of a stroke per minute**, with a configurable interval workout built in.

## Why it exists

Garmin's native rowing cadence is integer-only and its stroke counter becomes
unreliable below ~18–20 spm (on a real row, laps showed a cadence value but
**zero** counted strokes). StrongRow ignores the native cadence and detects each
catch/drive surge directly, so slow strokes are resolved with sub-1 spm precision.

## How it works

- Reads the wrist accelerometer at ~25 Hz.
- Band-passes the acceleration magnitude (removes gravity drift and hand jitter),
  then detects each stroke with an adaptive-envelope threshold plus hysteresis and
  a refractory window (rejects the recovery sub-peak, caps at 50 spm).
- Stroke rate = 60 ÷ the average of the last few stroke periods → a stable,
  tenths-resolution readout with no artificial low-rate floor.
- The computed rate is also written to the FIT file as a developer field
  (`row_stroke_rate`) for offline analysis.

### Why a watch app, not a data field

Connect IQ forbids raw high-frequency accelerometer access from data fields
(`Sensor.registerSensorDataListener` crashes there). A watch app can read the
25 Hz accelerometer, so StrongRow records its own rowing session. It uses the
**watch** accelerometer only — Connect IQ cannot access an external chest strap's
accelerometer (e.g. HRM 600), which broadcasts heart rate only.

## Interval workout

By default: **5 × 4:00 at 16–18 spm, 2:00 rest, and a press-START gate after each
rest** so the next interval only begins when you're ready. During work intervals
the big stroke-rate number turns **green when you're in the target band** and
**orange when you're outside it**. Each work/rest step is its own lap in the FIT,
and every transition vibrates and beeps.

### Controls

- **START/STOP** — begin the workout · pause/resume · continue past a rest gate.
- **BACK** — save the row and exit.

### Settings (Garmin Connect → app settings, no rebuild needed)

| Setting | Default |
|---|---|
| Enable interval workout (off = free row) | on |
| Number of intervals | 5 |
| Work length (minutes) | 4 |
| Rest length (minutes) | 2 |
| Target low / high (spm) | 16 / 18 |
| Press START after rest (gate) | on |

Turning the workout off gives a plain free row: live stroke rate with START to
record and BACK to save.

## Build & install

Built from the command line with the Connect IQ SDK:

```
monkeyc -o bin/StrongRow-<device>.prg -f monkey.jungle -y <developer_key> -d <device>
```

Supported devices: Forerunner 970/965, fēnix 8 (43/47 mm) / 8 Pro, fēnix 7 / 7 Pro,
epix Pro (47 mm), and fēnix 6 / 6 Pro / 6S Pro / 6X Pro.

To install: copy the matching `.prg` into `GARMIN\Apps` on the watch, reboot, then
launch **StrongRow** from the app list.

## Store assets

The `store/` directory holds the Connect IQ Store listing material:
`description.txt` (store description, under the 4,000-character limit),
`icon.png` / `icon.svg` (512 × 512 app icon), and `hero.png` / `hero.svg`
(1440 × 720 hero image). All artwork — including the 80 × 80 launcher icon in
`resources/drawables/` — is generated from `store/generate.py` (requires
`cairosvg`), so it can be tweaked and regenerated at any size.

## Author & license

Created by **Stephen Cieply, PhD**, developed with assistance from Claude.
Released under the [MIT License](LICENSE).
