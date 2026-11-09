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

Both go through the NVS settings backend with `CONFIG_SETTINGS_NVS_NAME_CACHE` and `CONFIG_NVS_LOOKUP_CACHE` off. Every lookup then walks the NVS allocation table back from the newest entry, and every load reads every stored name. After the keyboard's Bluetooth pairings were cleared and redone, neither stock v25.11 nor stock v26.09 dropped any more, and a host-side probe saw no stall of 13 ms or more. The working explanation is that the stall length depends on how much is stored and where it sits in the NVS log. The debug build is there to measure that directly.

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
