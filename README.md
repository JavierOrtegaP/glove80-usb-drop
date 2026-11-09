# glove80-usb-drop

Why a Glove80 on USB can suddenly disappear from the computer and stay dead until the cable is replugged, with measurements from a debug build of the left-half firmware.

## Summary

- MoErgo's firmware (every version checked, up to v26.09) turns on USB start-of-frame (SOF) events. Zephyr's nRF USB driver then queues an event every millisecond into a 32-slot pool. If another cooperative thread keeps the CPU for 32 ms, the pool overflows, and the driver switches USB off for good.
- What keeps the CPU is settings work: loading a Bluetooth host's settings when it connects, and ZMK's debounced saves. With the NVS backend these walk the settings log, so they get slower with every entry the log gains in normal use: about 0.14 ms per entry, crossing 32 ms at roughly 250 entries.
- On a keyboard whose log had about 700 entries, stock v26.09 dropped USB at startup and at a Bluetooth reconnect. The same keyboard with SOF disabled did not.
- Fix: remove `select USB_DEVICE_SOF` from `ZMK_USB_BOOT`, as upstream ZMK did in [zmkfirmware/zmk#3070](https://github.com/zmkfirmware/zmk/pull/3070).

## The drop

`glove80_lh_defconfig` sets `CONFIG_ZMK_USB_BOOT=y`, and in `app/Kconfig` that option does `select USB_DEVICE_SOF`. With SOF on, Zephyr's nRF USB driver (`drivers/usb/device/usb_dc_nrfx.c`, zmkfirmware/zephyr `v3.5.0+zmk-fixes`) queues one event per USB frame, 1,000 a second. The events go into a pool of `CONFIG_USB_NRFX_EVT_QUEUE_SIZE` = 32 slots, which the driver's own work queue drains. That work queue runs at the lowest cooperative priority, and cooperative threads are never preempted. So if any other cooperative thread keeps the CPU for about 32 ms:

1. `usbd_evt_alloc()` fails ("USBD event allocation failed!"), flushes the pool and queues `USBD_EVT_REINIT`.
2. `usbd_reinit()` disables the USB peripheral, which turns the pull-up off so the host sees an unplug. Then it reinitialises the driver but never enables or attaches the peripheral again, and never reports a disconnect to ZMK.
3. ZMK still thinks USB is configured and keeps sending reports there. Only a VBUS drop (replug or power cycle) brings USB back.

ZMK upstream removed the `select` in #3070 (merged 18 Dec 2025). Without SOF nothing is queued every millisecond, so a stall has nothing to overflow. moergo-sc/zmk PR #46 traces the same overflow on the Go60.

`tools/uf2_patch_sof.py` makes a one-byte change to a Layout Editor `.uf2` with the same runtime effect: `nrfx_usbd_start()` never enables the SOF interrupt.

## What stalls the CPU

On the affected keyboard, on 7 Nov 2026 with stock v25.11, drops lined up with two settings operations:

- **60 s after the output changes** (Magic+USB, or a Bluetooth profile key, whose macro also runs `&out OUT_BLE`), ZMK saves `endpoints/preferred` on the system work queue (`CONFIG_ZMK_SETTINGS_SAVE_DEBOUNCE`). Six of seven drops came 60 s after Magic+USB.
- **When a bonded Bluetooth host connects**, Zephyr loads that host's CCC settings in the BT RX thread (`bt_gatt_connected`). The seventh drop came 0.16 s after Windows reconnected over Bluetooth, and the Go60 log in PR #46 shows the overflow right before the Bluetooth "Connected" messages.

Both go through the NVS settings backend with `CONFIG_SETTINGS_NVS_NAME_CACHE` and `CONFIG_NVS_LOOKUP_CACHE` off. Every lookup walks the NVS allocation table back from the newest entry until it finds the id. Every load, including the per-host `bt/ccc/<addr>` load on connect, reads the name and value of every stored setting. So each operation costs time in proportion to how many log entries were written after the settings it touches. Saves only scan the names stored after the one being saved, so how slow a save is also depends on where that name sits. They run in cooperative threads (the system work queue, BT RX), so for that whole time the USB driver's work queue can't run.

The same keyboard with the no-SOF patch held USB for 40 hours with the same stored settings.

## Measured (debug build, 9 Nov 2026)

The settings store had 17 names, and its table was grown with the debug fill key. "Load" is the walk a host connect does, run on the system work queue. "USB waited" is how long the USB driver's queued events waited for its work queue during that load.

| NVS table entries | Load | ATE reads | USB waited |
| --- | --- | --- | --- |
| 60 | 5.0 ms | 1,065 | 5.2 ms |
| 120 | 13.7 ms | 3,031 | 13.9 ms |
| 171 | 20.9 ms | 4,661 | 22.3 ms |
| 222 | 27.9 ms | 6,293 | 29.5 ms |
| 273 | 35.0 ms | 7,925 | 37.0 ms: the stock driver would switch USB off |
| 530 | 77.7 ms | 17,781 | 81.8 ms: off |
| 684 | 99.3 ms | 22,760 | 105.4 ms: off |

That's about 0.14 ms per entry, and a single connect-style load crosses the 32-slot limit at roughly 250 entries. That morning the store held only 55 entries, which is why neither stock v25.11 nor stock v26.09 dropped in the first tests that day. With the store left at about 700 entries:

- **Stock v26.09 (Factory Default Layout, unpatched)** dropped USB 0.22 s after enumerating, during the startup connections. After a replug it dropped 93 ms after Windows reconnected over Bluetooth. A save of `endpoints/preferred` did not drop it, since on this store that name has few names after it.
- **The no-SOF build (v25.11 plus the one-byte patch)**, with the same store, survived the startup and the Bluetooth reconnect, though each blocks for about 100 ms.

So with SOF on, any keyboard whose settings log has a few hundred entries above its stored settings drops USB on every Bluetooth connect. In normal use the log grows with every saved change (profile and output switches, pairings, lighting) until garbage collection compacts it. That's why the drops come and go. MoErgo v26.09 is affected the same way as v25.11. Turning on the NVS caches would shorten these walks a lot, but a pool that fills every millisecond would still overflow on any other long cooperative work. Removing SOF removes the overflow itself.

## Results

- `results/2026-11-09-debug-build-log.txt`: the debug build's whole serial log for the table above (device addresses replaced).
- `results/2026-11-09-usb-recorder.txt`: the PC-side recorder for stock v26.09 versus the no-SOF build on the grown store.
- `results/2026-11-07-usb-recorder-stock-v25.11.txt`: the recorder for stock v25.11 drops on 7 Nov: 60 s after a switch to USB typing, and 0.16 s after a Bluetooth reconnect.

## The debug build

Three patches on top of MoErgo ZMK `v25.11`:

| Patch | Applies to | What it does |
| --- | --- | --- |
| `patches/zephyr-debug-timing.patch` | zephyr | Logs the duration, allocation-table reads and thread of every settings load and save, plus NVS garbage collections and sector erases. In the USB driver it logs how long queued events waited for the work queue. It also skips SOF events once the pool is nearly full, so a long stall gets measured instead of switching USB off. |
| `patches/zmk-debug-behavior.patch` | zmk | A `&dbg_nvs` behavior bound in the factory layout's Magic layer (see below). |
| `patches/zmk-west-allowlist.patch` | zmk | Fetches only the Zephyr modules a Glove80 needs. Build speed only. |

`config/debug.conf` sends the log over a USB serial port (the `zmk-usb-logging` snippet), keeps it to warnings, and saves settings 1 s after a change instead of 60 s.

GitHub Actions builds it on every push to `main` (`.github/workflows/build.yml`), and the artifact is `glove80_lh-debug.uf2`. Flash it to the **left half only**: the right half never touches USB, and nothing here changes how the halves talk. Stored settings (pairings, profiles) survive the flash.

The layout is MoErgo's factory default plus three keys on the Magic layer:

| Keys | Action |
| --- | --- |
| Magic + Z | Fill: 50 throwaway settings writes, like those months of use add |
| Magic + X | Measure: on the system work queue, load the store the way a host connection does, save a throwaway setting, print store statistics |
| Magic + C | Clean up: delete the throwaway settings |

Real saves and connects are logged too: press Magic + a Bluetooth profile key, then Magic + USB (the save follows 1 s later), or turn the computer's Bluetooth off and on.

### Reading the log

On Windows, `tools/read_log.ps1` finds the keyboard's serial port, reads it, and writes `logs/glove80-debug.log` with the PC's time on every line. Real lines from the run above:

```
<wrn> settings: dbg settings load bt/ccc/<pc>: 4241 us, 842 ATE reads, 0 full walks, thread BT RX
<wrn> settings: dbg settings load dbg: 35003 us, 7925 ATE reads, 0 full walks, thread sysworkq
<wrn> usb_nrfx: dbg usb: events waited 37048 us for the work queue, peak 28 of 32 slots, 10 SOF skipped -> stock driver would have switched USB off
<wrn> settings: dbg stats: last name id 32785, 17 names, 0 empty ids (0 full walks), 273 table entries, 27720 bytes free, ...
<wrn> fs_nvs: dbg nvs gc: 193969 us, 1 ATE reads, rc 0, thread dbg_nvs
```

## Tools

- `tools/usb_watch.ps1` (Windows): a 100 ms recorder of every USB root-hub port, the keyboard's device state, and key presses counted per path (USB or Bluetooth, never which keys).
- `tools/usb_stall_probe.ps1` (Windows): times a USB control request to the keyboard every 10 ms. A stalled work queue shows up as a slow reply.
- `tools/uf2_patch_sof.py`: the one-byte no-SOF patch for a Layout Editor `.uf2` (needs `capstone`).
- `tools/read_log.ps1` (Windows): the serial log reader for the debug build.

## License

MIT, see `LICENSE`. The patches change Zephyr (Apache-2.0) and ZMK (MIT) source files and follow those projects' licenses.
