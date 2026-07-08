# StrongRow

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
- Band-passes each axis separately (removes gravity drift and hand jitter) and
  tracks which axis carries the stroke motion; detection runs on that axis's
  **signed** signal, where the drive and the recovery produce opposite-going
  lobes — unlike the rectified magnitude, where they look alike. (v1 used the
  magnitude and counted both surges, reading ~2× the true rate.)
- An **autocorrelation of the signal locks onto the true stroke-cycle period**
  (with a subharmonic check so it can't settle on a multiple of it), and that
  period gates the peak detector: a surge arriving mid-cycle is the recovery of
  the *same* stroke and is never counted. Verified in simulation from 14 to
  30 spm, including recovery surges as strong as the drive.
- Each stroke is then time-stamped by an adaptive-envelope threshold with
  hysteresis; stroke rate = 60 ÷ the average of the last few stroke periods → a
  stable, tenths-resolution readout with no artificial low-rate floor (caps at
  40 spm).
- **GPS is on for the whole session**, so the FIT file carries position, speed
  and distance; the display shows the live **/500 m split** and **metres per
  stroke**.
- **R-R / HRV is logged explicitly**, without depending on the watch's
  "Log HRV" device setting: raw beat-to-beat intervals from the active
  heart-rate source (strap or wrist OHR) are captured every second, and a
  rolling **rMSSD** (last ~90 artifact-filtered beat pairs, 30 % jump
  rejection) is computed on the watch. An **RR indicator** next to the GPS
  status turns green while intervals are streaming.
- FIT developer fields written for offline analysis: `row_stroke_rate` (spm)
  and `dist_per_stroke` (m), `rr_interval` (up to 4 raw ms values per record)
  and `rmssd` (ms) per record, plus a session-level `avg_rmssd` (ms).

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

The workout is wrapped in an untimed **WARM UP** and **COOL DOWN**: pressing
START begins recording immediately in the warmup (so launching is captured),
and the first interval only starts on the next START press. After the last
interval the cooldown records until you press START again at the dock, then
BACK saves. Both are their own laps, so they're easy to trim in analysis.

### Controls

- **START/STOP** — begin the workout · end warmup / cooldown · continue past a
  rest gate · pause/resume during intervals.
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
| Warmup and cooldown steps | on |

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

## Author & license

Created by **Stephen Cieply, PhD**, developed with assistance from Claude.
Released under the [MIT License](LICENSE).
