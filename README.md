# Mobile Intrusion Detection — Simulink / Android & iOS

One Simulink app, deployed identically to **both** phones. A Button widget on
each phone picks its role at runtime:

* **released** → **Security Node** (sensors, siren, camera-LED flash)
* **pressed**  → **Monitoring Console** (alert playback, breach log, remote commands)

Because both phones run the same model (req. 4), there is nothing to keep in
sync between "Phone A" and "Phone B" logic — swapping roles is one tap.

---

## 1. Files

| File | What it is |
|---|---|
| `ids_params.m` | Every tunable constant (thresholds, UDP port, timing). Edit this, not the logic files. |
| `node_init.m` / `node_step.m` | Security Node state machine: ARM exit-delay, baseline learning, light/tilt/motion detection, command handling, siren + LED strobe timing, status-packet packing. |
| `console_init.m` / `console_step.m` | Monitoring Console: link supervision, alert latch/ack, breach log, ARM/DISARM/SIREN command toggling with retry-safe sequence numbers. |
| `audio_init.m` / `audio_step.m` | Software audio engine: swept siren tone (no audio file needed) and looped playback of the recorded alert message. |
| `packet_ok.m`, `wrap180.m` | Small helpers (packet validation, angle wrap-around for azimuth). |
| `epoch_to_civil.m`, `wall_clock.m`, `host_epoch.m` | Timestamp conversion (pure integer arithmetic, generates clean C) and the phone/host clock read. |
| `build_security_core.m` | Builds the **SecurityCore** subsystem (hardware-independent) containing the Controller and AudioEngine MATLAB Function blocks. Used by *both* the deployable app and the desktop test harness — what is tested is what ships. |
| `build_android_model.m` | Builds the deployable app `ids_android_app.slx` from Android Devices blocks (Light Sensor, Orientation, Gyroscope, Location Sensor, UDP Send/Receive, Audio Playback, Button ×4, Data Display ×5, ToApp for the LED). |
| `patch_android_torch.m` | One-time patch to the generated Android Java project that adds real camera-LED (torch) control, since the support package has no flashlight block. Builds + installs the APK via Gradle. |
| `make_alert_audio.m` | Converts `alert_message.wav` → `alert_message.mat` (embedded into the app at build time). A synthesized chime is already generated as `alert_message.wav` if you don't record your own. |
| `ids_scenario.m`, `build_sim_harness.m`, `run_harness_test.m` | Desktop test rig: two `SecurityCore` instances, scripted sensors/taps, a lossy simulated Wi-Fi link (20% datagram loss), and 13 automated checks against every requirement. |
| `test_logic_units.m` | 37 fast unit tests of the state machines, clock math and audio engine (no model build needed). |

## 2. How it was verified (already run for you)

```
test_logic_units      37 / 37 PASS   (state machines, clock, audio, in isolation)
run_harness_test      13 / 13 PASS   (two full SecurityCore instances, 20% packet loss)
```

`run_harness_test` also writes `harness_timeline.png` — node state, light level,
console alert, siren/LED, and audio activity for both phones over a 130 s
scripted scenario that exercises every requirement, including the mid-run role
swap at t = 90 s. Re-run either any time with:

```matlab
test_logic_units
run_harness_test
```

## 3. Deploy to your phones

### One-time setup (per computer)
1. **Install the support package** for each OS you're targeting:
   MATLAB → **Home → Add-Ons → Get Hardware Support Packages** → search
   "Android" (or "Apple iOS") → Install. This needs your MathWorks account
   sign-in in a browser once — it can't be scripted headlessly. Confirm with:
   ```matlab
   matlabshared.supportpkg.getInstalled
   ```
2. Android: enable Developer Options + USB debugging on the phone, connect by
   USB, run `androidhwsetup` once. iOS: run `ioshwsetup` and provision the
   device with Xcode (support for this package is deprecated after R2023a —
   Android is the actively supported path; steps below assume Android).
3. Both phones must be on the same Wi-Fi network.
4. Optional: record your own alert message as `alert_message.wav` in this
   folder (any format `audioread` supports) and run `make_alert_audio` —
   otherwise a synthesized chime is used.

### Build
```matlab
cd 'C:\Users\prana\Documents\MobileIntrusionDetection'
build_android_model                       % -> ids_android_app.slx
```
If two phones share a hotspot where broadcast is unreliable, target one
phone's IP directly on each side instead of the default broadcast address:
```matlab
build_android_model('PeerIP', '192.168.43.42')   % IP of the *other* phone
```
(For a first test on one phone with no Android hardware attached, pass
`build_android_model('AllowStubs', true)` to build a placeholder copy you can
inspect in Simulink — it is **not** deployable.)

### Add the camera-LED flash (one-time per phone/rebuild)
The Android support package has no flashlight block, so the LED is driven
through a `ToApp` hook patched into the generated Java project:
1. Open `ids_android_app.slx` → **Hardware** tab → **Build** drop-down →
   **Build** (not "Build, Deploy & Start" — Gradle needs to touch the Java
   first).
2. In MATLAB:
   ```matlab
   patch_android_torch('ids_android_app')     % patches, builds APK, installs, launches
   ```
   Requires the Android SDK/Gradle that ships with Android Studio (used only
   for this LED patch; every other block works with plain
   Build-Deploy-&-Start). If Gradle isn't set up, run
   `patch_android_torch('ids_android_app', false)` to patch only, then open
   `ids_android_app_ert_rtw\ids_android_app` in Android Studio and press Run.
3. **Re-run `patch_android_torch` after every rebuild** — Simulink
   regenerates the Java file each time.

If you don't need the LED deterrent, skip the patch entirely:
```matlab
build_android_model('EnableTorch', false)
```
then just **Hardware → Build, Deploy & Start** normally — siren, sensors,
GPS, commands and logging all work without any Java patch.

### Repeat on the second phone
Same `.slx`, same build — install it on Phone B too. Nothing role-specific
to change; the Button decides the role at runtime.

## 4. Using the app

| Control (on-screen) | Effect |
|---|---|
| **Console mode** button | released = Security Node, pressed = Monitoring Console |
| **Arm or Disarm node** (console) | Remotely ARM (5 s exit delay + auto-baseline) or DISARM the other phone |
| **Siren on or off** (console) | Remotely trigger the siren + strobing camera LED on the node, or stop it |
| **Acknowledge alert** (console) | Silences the audible alert locally (breach stays logged) |

Data Displays show: node state/breach count/cause/siren/lux/tilt; console
link status/alert; last breach number+date+time+cause+GPS; node's live
GPS/lux/seconds-since-heard; and the last 5 breach times.

## 5. Protocol summary (`ids_params.m`)

* UDP, port 25000, 16-`double` (128-byte) datagrams, `MAGIC`+`PAIR_ID` guard
  so it ignores its own broadcasts and other groups on the same Wi-Fi.
* Node → Console (`TYPE_STATUS`): state, breach seq/time/cause/GPS, live
  GPS/lux, siren state, last confirmed command seq. Sent every 0.5 s
  (heartbeat) and immediately on any state change.
* Console → Node (`TYPE_CMD`): sequence number + command code
  (ARM/DISARM/SIREN_ON/SIREN_OFF). Re-sent every heartbeat until the node's
  status packet confirms that sequence, so a lost datagram just delays
  delivery by up to 0.5 s — verified up to 20% loss in the test harness.
* Node states: `DISARMED → ARMING (5 s exit delay, baseline learnt) → ARMED
  → ALARM` (latched until DISARM or re-ARM). Breach causes are a bit mask:
  light=1, tilt/orientation=2, motion/gyro=4 (console also raises
  link-lost=8 if an armed node goes silent for 5 s).

## 6. Tuning

Everything is in `ids_params.m`: light threshold (absolute + relative to
learnt baseline), tilt/azimuth thresholds, gyro threshold, debounce counts,
exit delay, heartbeat/timeout periods, siren tone range, LED strobe rate,
timezone offset for displayed timestamps, and the `PAIR_ID` (change this if
multiple teams test on the same Wi-Fi simultaneously).
