# glove80-usb-drop

Why a Glove80 on USB can suddenly disappear from the computer and stay dead until the cable is replugged, plus a debug build of the left-half firmware that measures the cause.

## The drop

MoErgo's firmware (every version checked, up to v26.09) has `CONFIG_ZMK_USB_BOOT=y`, and in `app/Kconfig` that option does `select USB_DEVICE_SOF`. With SOF on, Zephyr's nRF USB driver (`drivers/usb/device/usb_dc_nrfx.c`, zmkfirmware/zephyr `v3.5.0+zmk-fixes`) queues one event per USB frame, 1,000 a second. The events go into a pool of `CONFIG_USB_NRFX_EVT_QUEUE_SIZE` = 32 slots, which the driver's own work queue drains. That work queue runs at the lowest cooperative priority, and cooperative threads are never preempted. So if any other cooperative thread keeps the CPU for about 32 ms:

1. `usbd_evt_alloc()` fails ("USBD event allocation failed!"), flushes the pool and queues `USBD_EVT_REINIT`.
2. `usbd_reinit()` disables the USB peripheral, which turns the pull-up off so the host sees an unplug. Then it reinitialises the driver but never enables or attaches the peripheral again, and never reports a disconnect to ZMK.
3. ZMK still thinks USB is configured and keeps sending reports there. Only a VBUS drop (replug or power cycle) brings USB back.

ZMK upstream removed the `select` in [zmkfirmware/zmk#3070](https://github.com/zmkfirmware/zmk/pull/3070) (merged 18 Dec 2025). Without SOF nothing is queued every millisecond, so a stall has nothing to overflow. moergo-sc/zmk PR #46 traces the same overflow on the Go60.

`tools/uf2_patch_sof.py` makes a one-byte change to a Layout Editor `.uf2` that has the same runtime effect: `nrfx_usbd_start()` never enables the SOF interrupt. On the keyboard this was found on, the patched build held USB for 40 hours, with the same stored settings that made the stock build drop five times out of five.

## What stalls the CPU

On the affected keyboard, drops lined up with two settings operations:

- **60 s after the output changes** (Magic+USB, or a Bluetooth profile key, whose macro also runs `&out OUT_BLE`), ZMK saves `endpoints/preferred` on the system work queue (`CONFIG_ZMK_SETTINGS_SAVE_DEBOUNCE`). Five drops came exactly 60 s after Magic+USB.
- **When a bonded Bluetooth host connects**, Zephyr loads that host's CCC settings in the BT RX thread (`bt_gatt_connected`). One drop came 0.16 s after Windows reconnected over Bluetooth, and the Go60 log in PR #46 shows the overflow right before the Bluetooth "Connected" messages.

Both go through the NVS settings backend with `CONFIG_SETTINGS_NVS_NAME_CACHE` and `CONFIG_NVS_LOOKUP_CACHE` off. Every lookup walks the NVS allocation table back from the newest entry until it finds the id, and every load (including the per-host `bt/ccc/<addr>` load on connect) reads the name and value of every stored setting. So each operation costs time in proportion to how many log entries were written after the settings it touches. They run in cooperative threads (the system work queue, BT RX), so for that whole time the USB driver's work queue can't run.

## Measured (debug build, 9 Nov 2026)

Settings store with 17 names. The table entries were grown with the debug fill key. "Load" is the same walk a host connect does, run on the system work queue. "USB waited" is how long the USB driver's queued events waited for its work queue during that load.

| NVS table entries | Load | ATE reads | USB waited |
| --- | --- | --- | --- |
| 60 | 5.0 ms | 1,065 | 5.2 ms |
| 120 | 13.7 ms | 3,031 | 13.9 ms |
| 171 | 20.9 ms | 4,661 | 22.3 ms |
| 222 | 27.9 ms | 6,293 | 29.5 ms |
| 273 | 35.0 ms | 7,925 | 37.0 ms: the stock driver would switch USB off |
| 530 | 77.7 ms | 17,781 | 81.8 ms: off |
| 684 | 99.3 ms | 22,760 | 105.4 ms: off |

About 0.14 ms per entry. A single connect-style load crosses the 32-slot limit at roughly 250 entries. The keyboard's store held only 55 entries that morning, which is why nothing reproduced earlier that day. With the store left at about 700 entries:

- **Stock v26.09 (Factory Default Layout, unpatched)** dropped USB 0.22 s after enumerating, during the startup connections. After a replug it dropped 93 ms after Windows reconnected over Bluetooth. A save of `endpoints/preferred` did not drop it: a save only scans the names stored after the one being saved, so it depends on where that name sits in the list.
- **The no-SOF build (v25.11 plus the one-byte patch)**, with the same store, survived the startup and the Bluetooth reconnect, which block for about 100 ms.

So any keyboard whose settings log has a few hundred entries above its stored settings will drop USB on every Bluetooth connect, and in normal use the log grows with every saved change. MoErgo v26.09 is affected the same way as v25.11. Removing `select USB_DEVICE_SOF` (#3070) removes the overflow. Enabling the NVS caches would shorten the stalls, but that only moves the threshold.

## The debug build

Three patches on top of MoErgo ZMK `v25.11`:

| Patch | Applies to | What it does |
| --- | --- | --- |
| `patches/zephyr-debug-timing.patch` | zephyr | Logs the duration, allocation-table reads and thread of every settings load and save, NVS garbage collections and sector erases. In the USB driver it logs how long queued events waited for the work queue, and skips SOF events once the pool is nearly full, so a long stall is measured instead of switching USB off. |
| `patches/zmk-debug-behavior.patch` | zmk | A `&dbg_nvs` behavior bound in the factory layout's Magic layer (see below). |
| `patches/zmk-west-allowlist.patch` | zmk | Fetches only the Zephyr modules a Glove80 needs. Build speed only. |

`config/debug.conf` sends the log over a USB serial port (the `zmk-usb-logging` snippet), keeps it to warnings, and saves settings 1 s after a change instead of 60 s.

GitHub Actions builds it on every push to `main` (`.github/workflows/build.yml`). The artifact is `glove80_lh-debug.uf2`. Flash it to the **left half only**: the right half never touches USB, and the change doesn't affect how the halves talk. Stored settings (pairings, profiles) survive the flash.

The layout is MoErgo's factory default plus three keys on the Magic layer:

| Keys | Action |
| --- | --- |
| Magic + Z | Fill: 50 throwaway settings writes, as months of use would add |
| Magic + X | Measure: on the system work queue, load the store the way a host connection does, save a throwaway setting, print store statistics |
| Magic + C | Clean up: delete the throwaway settings |

Real saves and connects are logged too: press Magic + a Bluetooth profile key, then Magic + USB (the save follows 1 s later), or turn the computer's Bluetooth off and on.

### Reading the log

`tools/read_log.ps1` finds the keyboard's serial port, reads it and writes `logs/glove80-debug.log` with the PC's time on every line. Lines to look for:

```
dbg settings save endpoints/preferred: 41230 us, 9120 ATE reads, 0 full walks, thread sysworkq
dbg settings load bt/ccc/...: ...
dbg usb: events waited 38000 us for the work queue, peak 28 of 32 slots, 10 SOF skipped -> stock driver would have switched USB off
dbg stats: last name id 40, 22 names, 18 empty ids (36 full walks), 1210 table entries, 9800 bytes free, ...
dbg nvs gc: ... / dbg nvs erase: ...
```

(The numbers above are made up.)

## Tools

- `tools/usb_watch.ps1`: a 100 ms recorder of every USB root-hub port, the keyboard's device state, and key presses counted per path (USB or Bluetooth, never which keys).
- `tools/usb_stall_probe.ps1`: times a USB control request to the keyboard every 10 ms. A stalled work queue shows up as a slow reply.
- `tools/uf2_patch_sof.py`: the one-byte no-SOF patch for a Layout Editor `.uf2` (needs `capstone`).
- `tools/read_log.ps1`: the serial log reader for the debug build.
