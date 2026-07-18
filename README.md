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

## Drives, not blade movements

Field testing surfaced a second capability beyond low-rate accuracy: **StrongRow
distinguishes true drive strokes from corrective strokes**, which the native
Garmin activity cannot. On open water you take small steering taps to keep the
boat tracking in wind and chop; the native detector registers every blade
movement, while StrongRow's period lock counts only the periodic drive cycle.

In a 5 × 4:00 session in wind and chop (tidal Potomac), StrongRow counted
**66–68 drives on every rep** while native cadence counted 89–109 blade
movements. Scored per drive stroke, distance per stroke was stable to **3.7 %**
across the five reps, against **22 %** per blade movement — the drive count is
the stable, physically meaningful unit for stroke-length and durability
analysis, exactly in the low-rate sessions where rate discipline is the point.
The difference between the two counts is itself useful: it measures
boat-handling workload on a rough day. StrongRow logs it live as a
`corrective_rate` developer field (native blade-movement cadence minus drive
rate, clamped at zero), plus a session-level `total_corrective_strokes`.

(Native cadence also resets at every lap boundary and reads near zero for the
first several seconds of each rep; StrongRow's rate carries straight through
laps.)

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
  hysteresis; stroke rate = 60 ÷ the **median** of the last five stroke periods
  → a stable, tenths-resolution readout with no artificial low-rate floor
  (caps at 40 spm), robust to any single missed or spurious peak.
- Output cleaning: the first 5 s after launch are quiet while the filters
  settle; readings above 30 spm are only reported when the autocorrelation
  lock confirms them (so rhythmic non-rowing hand motion — docking, handling
  the boat — reads as 0 instead of a phantom 35–40 spm burst); and a locked
  reading that disagrees with the lock by more than 30 % snaps to it.
- **GPS is on for the whole session**, so the FIT file carries position, speed
  and distance; the display shows the live **/500 m split** and **metres per
  stroke**.
- **R-R / HRV is logged explicitly**, without depending on the watch's
  "Log HRV" device setting: raw beat-to-beat intervals from the active
  heart-rate source (strap or wrist OHR) are captured every second, and a
  rolling **rMSSD** (last ~90 artifact-filtered beat pairs, 30 % jump
  rejection) is computed on the watch. An **RR indicator** next to the GPS
  status turns green while intervals are streaming.
- FIT developer fields written for offline analysis: `row_stroke_rate` (spm),
  `dist_per_stroke` (m), `corrective_rate` (spm of blade movements that are
  not drives), `rr_interval` (up to 4 raw ms values per record) and `rmssd`
  (ms) per record, plus session-level `avg_rmssd` (ms) and
  `total_corrective_strokes`.

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
