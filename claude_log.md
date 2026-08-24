# PingPong Paddle Tracker
Design & Progress Log — built with Claude

**App version v1.2 · Firmware version v1.0 · Updated 2026-08-23 (log started 2026-08-15)**

A wireless IMU attached to a table-tennis paddle streams motion to a phone app that detects ball hits and measures paddle-face speed. Logging is driven by hits: every detected hit is saved as its own log. This document captures what has been built, the key technical decisions, and — most importantly — the roadmap of future improvements, so work can resume from exactly where it left off.

> Format note: this `.md` supersedes the original `claude_log.pdf` (v1.1). Keep it updated as versions and roadmap features land.

---

## 0. How to resume

- Read **Section 6 (Future roadmap)** and **Section 7 (where we left off)** first — that is the live to-do list. **The next focus is a larger piece of work on speed measurement (see §7).**
- The flagship spin/brush decomposition (§6.1) **core is now implemented** in v1.2 (closing ⟂ vs brushing ∥ speeds via a face-up calibration).
- Sections 3–4 describe current firmware and app capabilities; Section 5 lists the tuned constants and empirical findings you will need.
- Section 8 is an explicit **changelog for v1.1 → v1.2** (this session).
- Key source files: **PingPongTrackerFirmware/src/main.cpp** (firmware); **ping_pong_tracker_app/lib/main.dart** (app + UI), **lib/motion_estimator.dart** (orientation, velocity, ω×r face speed + ⟂/∥ split), **lib/hit_detector.dart** (vibration hit detector).
- Reference data: **data_v1.0/{hit,spin,swing}** are current clean captures (one stroke each, still at both ends); **data_v0.0/** holds the older, messier sets.

---

## 1. Project overview & goal

A Seeed XIAO nRF52840 Sense board (LSM6DS3TR-C IMU) is mounted on a table-tennis paddle. It streams accelerometer and gyroscope data over BLE at a fixed 1660 Hz to a Flutter phone app. All detection and analysis run in the app; the firmware is a thin, high-rate streamer.

The original goal — compare the time of maximum paddle speed to the time of ball contact — is complete: they are effectively simultaneous (peak rotational speed coincides with the hit to within ~15 ms). The project has since moved into table-tennis-specific analytics (Section 6), and as of v1.2 the paddle-face speed is decomposed into **closing (into-the-ball)** and **brushing (spin-generating)** components.

---

## 2. Hardware & architecture

- **MCU/Radio:** Seeed XIAO nRF52840 Sense (Nordic nRF52840, SoftDevice S140), Adafruit Bluefruit BLE stack.
- **IMU:** LSM6DS3TR-C, internal I²C (Wire1). Accelerometer ±16 g, gyroscope 2000 °/s, both sampled at the shared max ODR of 1660 Hz.
- **Link:** BLE Nordic UART service; 2 Mbps PHY, 247-byte MTU, 7.5 ms connection interval, data-length extension — all to sustain the high sample rate.
- **App:** Flutter (Android, tested on a Pixel 3a XL); iOS-ready (Section 4.10) but needs a Mac to build. `flutter_blue_plus` for BLE.
- **Design split:** the board only streams; the app does windowing, logging, hit detection, orientation/speed estimation, storage, and visualization.

---

## 3. Firmware capabilities (v1.0)

File: **PingPongTrackerFirmware/src/main.cpp** (PlatformIO, env *xiaoblesense*; flash with `pio run -t upload`). **Unchanged this session.**

**Streaming**
- Advertises as **PaddleTrack**. On connect, negotiates 2 Mbps PHY, 247-byte MTU, data-length extension, and a 7.5 ms interval for throughput.
- Reads the IMU on each new accel sample (XLDA), bursting all 12 bytes (gyro + accel) in one I²C read at 400 kHz.
- Batches samples into notifications on the UART TX characteristic. Packet: byte 0 = sample count N, byte 1 = battery %, then N × 12 bytes of int16 LE ax, ay, az, gx, gy, gz (raw counts). Up to 20 samples/packet; flushes when full or after a 15 ms latency cap.
- Battery percentage sampled every 2 s from the on-board divider.

**Versioning**
- Firmware version exposed as a READ BLE characteristic (UUID …0004…). The app reads it on connect and shows "fw v1.0". Bump the `FW_VERSION` define and reflash when firmware changes.

> The firmware has intentionally stayed a pure streamer — no on-device detection or logging — so all logic can iterate in the app.

---

## 4. App capabilities (v1.2)

Files: **lib/main.dart** (UI, BLE, logging, storage), **lib/motion_estimator.dart** (orientation + speed + ⟂/∥ split), **lib/hit_detector.dart** (hit detection). Tabs: Connection, Logs, Settings.

### 4.1 Connection & live display
- Scan/connect to PaddleTrack; decodes packets and applies sensitivities (accel 0.488 mg/count, gyro 70 mdps/count).
- Live readouts: streaming status, sample rate, accel (g), gyro (°/s), orientation (roll/pitch/tilt), live **Face speed (ω×r)** in m/s, and — once calibrated — the live **⟂ closing / ∥ brushing** split.
- Horizontal battery gauge + percentage under the sample rate when connected; app/firmware versions top-right (app v1.2 / fw v1.0).

### 4.2 Calibration (face-up)
- The single "Calibrate" action now doubles as a **face-up calibration**: hold the paddle at rest with the **forehand face pointing straight up** while it averages ~1.5 s of samples.
- It sets the gyro bias and the gravity-aligned initial orientation (as before) **and** captures the **paddle-face normal** in the board frame — because with the face up, gravity points along that normal (see §4.5).
- A pose-sanity check (`faceNormalValid`) warns if the captured normal is too close to the handle axis (i.e. the handle was held up instead of the face), which would make the ⟂/∥ split degenerate.
- The captured normal is persisted as a mounting constant (`faceNormalX/Y/Z`).

### 4.3 Logging — two modes (Settings toggle)
- **Automatic (default) — one log per hit:** each detected ball hit is saved as its own log. A ring buffer supplies the "before" history and recording continues the same amount after the hit — so every log spans ±(window) around the hit (default 1 s → 2 s total). Further hits inside a window stay in that log and are marked, not split out.
- **Manual:** a Start/Stop button on the Connection tab records straight to a log, auto-stopping after a timeout (0.1–5.0 s).
- Both modes share the same capture, finalize, and numbering code.

### 4.4 Hit detection
- Runs live on every sample (both modes). A ball impact rings the wood at high frequency (~80–830 Hz); swing/hand motion is below ~80 Hz — cleanly separable.
- Algorithm (causal, real-time): 2-pole high-pass at 120 Hz on |accel| → 6 ms RMS envelope → threshold with hysteresis (0.4×) and a 50 ms refractory.
- Tuned threshold **0.5 g**: zero false positives on no-hit swings, catches every real hit. Threshold is a Settings slider (0.1–1.5 g).
- In automatic mode a detected hit is also the capture trigger (§4.3). Detected hit times attach to each log and are drawn as magenta vertical lines on all speed/IMU charts.

### 4.5 Paddle-face speed (ω×r) and its ⟂/∥ split
- **Total face speed** = |ω × r| — the gyro (a direct measurement) crossed with a constant board-frame lever-arm vector `r`. No integration, so no drift; reads ~0 at rest by construction.
- `r` points along the handle axis, confirmed **board Z** by a pure handle-twist capture (gz dominant). So ω×r excludes the handle-twist (spin) and keeps the swing → linear face-center speed.
- Lever-arm magnitude is a Settings slider (2–30 cm, default 12); sets only the m/s scale, not timing.
- **NEW (v1.2) — closing/brushing decomposition.** The tip velocity `v = ω×r` is projected onto the face normal `n̂`:
  - `perp` (⟂, **closing**, perpendicular to the face) = |v · n̂| → drives ball pace/drive.
  - `par` (∥, **brushing**, in the face plane) = √(|v|² − perp²) → drives spin.
  - so `faceSpeed² = perp² + par²`.
- **Orientation-independent:** both `v` and `n̂` live in the board frame, so the split is a pure body-frame projection — **no world-orientation tracking needed**. `n̂` comes from the face-up calibration (§4.2), captured directly from gravity, **not hardcoded to an axis** — so a diagonal or shifted mount is handled exactly.
- **Replay:** recorded logs don't start face-up, so `n̂` can't be recovered from a log. The persisted mounting normal is passed into `computeSpeedSeries(faceNormal:)` to split saved logs; recalibrating clears the speed cache so open/next logs re-split.
- **Caveat (rotation-only):** ω×r captures only the *rotational* tip speed (by design, to stay drift-free). A pure straight-forward push with no rotation reads ~0. It characterizes spin/brushing and wrist-driven strokes well; it underestimates closing speed for translation-dominated smashes.
- Outputs: `MotionEstimator.faceSpeedPerp / faceSpeedPar`; `SpeedSeries.facePerp / facePar / hasComponents`.

### 4.6 Logs — charts, markers, management
- Each log stores time + 6 axes (columnar), a name, and hit times, as a binary file in app storage; survives restart. Numbering persists and restarts at 1 only when no logs remain.
- **Detail view charts** (each with magenta hit markers and horizontal grid lines):
  - **Face speed (ω×r)** — in v1.2, when calibrated, this one chart overlays three traces: **total speed** (indigo), **⟂ speed** (deep orange), **∥ speed** (teal), with all three peak values in the corner. Uncalibrated, it shows total only plus a "calibrate face-up" note.
  - **Speed (accel — old)** — the drift-prone accel-integrated speed, kept as a comparison.
  - **Accelerometer** and **Gyroscope** — raw axes.
- Below the charts, the raw data as **color-coded, aligned CSV rows** (see §4.7).
- **Scroll behavior (fixed this session):** the logs list preserves its scroll position when you open a log and come back (`PageStorageKey`), while a log's detail always opens at the **top** (distinct scroll key). A floating **"Jump to top"** button appears in the detail once the charts scroll out of view.
- Management: Rename (with automatic "(1)/(2)" de-dup), Share single (CSV), Share all (zip), Delete, Delete-all (with confirmation). The per-log actions are a compact **⋮ dropdown** menu.

### 4.7 CSV table (color + alignment)
- On-screen CSV is color-coded **per column to match the charts**: time = grey; ax/ay/az = red/green/blue; gx/gy/gz = orange/purple/teal.
- Columns are fixed-width, right-aligned monospace, and the header uses the same widths so labels line up over their numbers (sized to fit the Pixel 3a XL width).
- The **exported** CSV/zip is unchanged (standard comma-separated, full precision).

### 4.8 Graph interaction — hover readout
- Drag horizontally across any chart (or press-and-hold) to scrub: a vertical **crosshair** snaps to the nearest sample, a colored **dot** sits on each trace, and a **readout box** shows `t = … s` plus each series' value (color-matched). Vertical drags pass through to the page scroll, so the detail view still scrolls normally.
- **Setting — "Persist graph hover"** (default **off**): off = readout shows only while touching (true hover); on = it stays after you lift, with an **× button** to dismiss (positioned so it never covers a value).
- **Setting — "Hover readout position":** **Follow** (default; box tracks the touched point, clamped on-screen), **Left**, **Right**, or **Adaptive** (opposite the finger).

### 4.9 Navigation — Android back button
- `PopScope` integrates the system back button: in a log detail → returns to the list; on the Logs/Settings tab → returns to the Connection tab; only exits the app from the Connection tab with no log open. Dialogs/menus close first as usual.

### 4.10 Platform — iOS readiness
- `ios/Runner/Info.plist` includes `NSBluetoothAlwaysUsageDescription` (required, or iOS crashes on first Bluetooth access). The rest of the app is cross-platform. Building for iPhone still requires a Mac/Xcode; with a free Apple ID the app is sideloaded (7-day expiry, re-sign to renew) — e.g. build IPA on a Mac VM, sign/install with Sideloadly.

### 4.11 Settings (all persisted)
Automatic-logging toggle; Hit threshold (g); Lever arm (cm); Auto-capture window (± around each hit, s) or Manual auto-stop timeout (s); "Always show logs list"; "Persist graph hover"; "Hover readout position"; plus the persisted **face normal** (from face-up calibration) and **log sequence number** (not user-facing).

---

## 5. Key findings & reference values

| Item | Value / finding |
|---|---|
| Sample rate (ODR) | 1660 Hz (fixed) |
| Accel / gyro scale | 0.488 mg/count (±16 g) · 70 mdps/count (2000 °/s) |
| Logging trigger | each detected ball hit → its own log, ±window (default 1 s) |
| Hit detector | 2-pole HP @ 120 Hz + 6 ms env; threshold 0.5 g; 50 ms refractory |
| Hit vs swing bands | impact ~80–830 Hz; motion below 80 Hz (~5× separation margin) |
| Handle axis | board Z (from pure-twist test: gz dominant ~528 °/s rms) |
| Face speed | v = |ω × r|, r along Z; drift-free; ~0 at rest |
| Face normal | captured from gravity at **face-up** calibration; body-frame unit vector; persisted |
| ⟂/∥ split | perp = |v·n̂|, par = √(|v|²−perp²); faceSpeed² = perp²+par²; orientation-independent |
| Lever arm default | 12 cm (sets m/s scale only; timing scale-independent) |
| Peak speed vs hit | coincident within ~0–40 ms across all v1.0 strokes |
| Old accel speed | drifts: peak often in follow-through, end 0.5–3.7 m/s even with pauses |
| Perf testing | **judge scroll/UI smoothness in `--profile`/`--release`, not debug** (debug jank is misleading) |

**Lever-arm calibration (how to set r):** (a) tape-measure from the IMU to the paddle-face center along the handle (~12–16 cm) for a good first value; (b) for a true m/s, film swings at 120–240 fps with a ruler in frame, measure peak face speed, and set r = v_peak / |ω_peak| (ω in rad/s); (c) timing and relative comparisons do not depend on r. The ω×r approximation is most accurate with the board mounted near the wrist/pivot.

---

## 6. Future roadmap — ways to keep improving (most important)

The peak-speed-vs-hit goal is done. Ordered roughly by value. **6.1's core decomposition is now DONE (v1.2)**; the remaining sub-items and the other tracks are still open.

### 6.1 Spin / brush estimation (flagship) — *core DONE (v1.2)*
- **Done:** decompose v_face (from ω×r) into a **normal component (⟂ closing → pace/drive)** and a **tangential component (∥ brushing → spin)** via a face-up calibration that captures the face normal. Live readout + per-log combined chart shipped.
- **Still open:** a single-number **spin index** (tangential/normal ratio) per stroke; using the excluded handle-twist (ω about Z) as an additional spin signal; validating ⟂/∥ against known drives vs loops on-device.

### 6.2 Mine the accelerometer at impact
- **Hit hardness / impulse:** peak accel and the integral of the impact spike as a "power" metric; a rough outgoing-ball-speed estimate via momentum.
- **Sweet-spot / mishit detection:** off-center hits induce a torque (coincident gyro spike) and a different vibration signature → a "clean contact" quality score.
- **Face angle at contact:** the orientation filter already knows the paddle tilt at the hit instant (open/closed face, angle of attack) — essentially free.
- **Vibration spectrum:** an FFT of the ~30 ms ring could separate clean vs edge hits and might fingerprint rubbers/blades.

### 6.3 Stroke classification
- Each auto-captured log is a clean single-stroke window — ideal labeled training data.
- From features (peak speed, peak ω, rotation axis, orientation change, pace/spin split, duration) build a rule-based or small ML classifier that auto-tags each log: forehand/backhand, drive, push, topspin loop, smash, serve.

### 6.4 Per-stroke & session analytics
- **Stroke report card:** speed, spin index, face angle, contact quality, contact timing, and stroke type — one summary per log.
- **Session dashboard:** stroke count, speed/spin distributions, stroke-type breakdown, consistency (variance of peak speed and of contact timing).
- **Contact-timing metric:** contact ≈ peak speed; per-stroke deviation (hitting before your fastest = decelerating into the ball) is a useful drill metric.

### 6.5 Real-time feedback & drills
- After each captured hit, flash a "speed-gun" result (e.g. "Forehand · 6.2 m/s · topspin").
- Target-based drills ("10 forehands over 5 m/s"), consistency challenges, with audio/haptic cues.

### 6.6 Infrastructure, robustness & exports
- **Weak/spin hit robustness:** add a complementary cue (a sudden gyro impulse from a glancing/brushy contact) to catch weak high-spin hits that may fall below the 0.5 g threshold.
- **Full-frame calibration:** *DONE (v1.2)* — the face-up calibration locks the paddle-face normal for the ⟂/∥ decomposition.
- **Export enrichment:** include computed metrics (peak face speed, ⟂/∥ split, hit time, spin index, face angle) in the CSV/zip exports, not just raw IMU.
- **On-device model:** as labeled captures accumulate, train a small classifier for stroke type / spin / quality.

---

## 7. Open items / where we left off

- **Next up — a larger piece of work on speed measurement.** (Scope to be detailed at the start of that session. Current speed metrics are the drift-free ω×r face speed and its ⟂/∥ split; the accel-integrated speed remains a drifting comparison only.)
- The flagship ⟂/∥ decomposition (§6.1) **core is done in v1.2**; remaining 6.1 work is a spin-index readout and on-device validation of the split.
- Face-up calibration must be done once (per mounting) before ⟂/∥ appears; logs recorded before any calibration show a "calibrate face-up" note until a normal is available, then re-split from the persisted normal.
- Deferred: weak high-spin hits may slip under the 0.5 g hit threshold — this also affects whether a log is captured (§6.6).
- Set the lever arm from a tape measure now; optionally do a one-time slow-mo video calibration for a true m/s (Section 5).
- A 3D-printed handle mount is planned (rigid coupling to preserve hit vibration; re-tune the hit threshold with the case on if amplitude drops).
- **Perf note:** always evaluate scroll/UI smoothness in `--profile`/`--release`. A "laggy logs list" chased this session turned out to be debug-mode overhead; profile mode was smooth with no further changes.

---

## 8. Changelog — v1.1 → v1.2 (this session, 2026-08-23)

**Flagship**
- **Closing/brushing (⟂/∥) speed decomposition** of ω×r via a **face-up calibration** (captures the face normal from gravity in the board frame; body-frame projection, orientation-independent; not axis-hardcoded so diagonal mounts work). Persisted mounting normal; used live and for log replay. New `faceSpeedPerp/Par`, `SpeedSeries.facePerp/facePar/hasComponents`; live readout + pose warning; combined **total + ⟂ + ∥** chart (legend "total speed" / "⟂ speed" / "∥ speed").

**Graphs**
- Added **horizontal grid lines** (with value labels) and an emphasized zero line.
- Added **touch hover readout** (crosshair + per-trace dots + value box) via horizontal-drag/long-press; vertical drags still scroll the page.
- New setting **"Persist graph hover"** (default off) with an **× dismiss** button on the pinned readout.
- New setting **"Hover readout position":** Follow (default) / Left / Right / Adaptive.
- Combined the three face-speed traces onto one chart (was, briefly, two separate charts).

**Logs / QOL**
- Fixed **scroll positions:** list keeps its place on back; detail always opens at top; added a **Jump-to-top** button in the detail.
- **Color-coded + aligned CSV** table (per-column colors matching charts; fixed-width monospace header alignment).
- Removed the sample count from the main list rows; fixed the automatic-logging Settings description to "Each hit is auto-detected and recorded."
- Logs list rebuilt as `ListView.builder` + fixed `itemExtent` + lightweight rows; per-row actions kept as a **compact ⋮ dropdown** (a bottom-sheet variant was tried and reverted).

**Performance**
- Gated the ~10 Hz repaint timer and the per-sample fusion math (`_motion.update`) to the **Connection tab only** (no needless full-screen rebuilds / CPU on other tabs).
- **Key finding:** the reported logs-list "lag" was **debug-mode** overhead — smooth in `--profile`. The above are still net wins.

**Platform / navigation**
- **Android back button** wired via `PopScope` (detail → list, tab → Connection, exit from Connection root).
- **iOS:** added `NSBluetoothAlwaysUsageDescription` to `ios/Runner/Info.plist` (required for BLE).

**Version**
- App bumped **v1.1 → v1.2**; firmware unchanged (v1.0).

---

*Generated as a design/handoff log so work can resume directly. Update the versions and roadmap as features land.*
