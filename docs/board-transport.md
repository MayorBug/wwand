# Board transport integration

This local redesign moves PCIe startup policy from a shell helper into the daemon's board integration.
A board profile describes the board's modem hardware.
The board profile supplies hardware parameters. The daemon keeps ownership of modem and interface lifecycles.
This format follows issue #48, but upstream does not yet agree on its final interface.

## Responsibilities

`board.uc` detects the board, loads its profile, and controls board power, reset, and LEDs.
`board_transport.uc` installs discovery and explicit data-mode actions on the daemon, like `hwops.uc` and `netsel_ops.uc`.
`daemon.uc` owns modem objects, transport ownership, autosetup, and hotplug handling.
`ubus.uc` exposes actions through the existing reply helpers. LuCI calls these methods and applies its access permissions.

procd starts `/usr/sbin/wwand` directly. `deps.create()` does not read the network configuration to construct the board.
The daemon reads that configuration through its normal initialization path.
The board starts discovery once, after the daemon applies its first configuration.

## Profile source and format

The board package installs `/usr/share/wwand/boards.d/<model.id>.json`.
The model identifier comes from `/etc/board.json`.
A valid version-1 file overrides the built-in profile data.
The loader retains the built-in LED function because JSON cannot supply executable functions.
A missing or invalid file uses the built-in fallback. An unknown board without a valid profile keeps its existing no-op behavior.

The following fields control this integration:

| Field | Meaning |
| --- | --- |
| `version` | Must equal `1` |
| `manual_data_mode` | Enables explicit Quectel data-mode actions and suppresses automatic serial-only mode switching |
| `reset_gpio`, `reset_run`, `reset_assert_ms` | Named reset line, released value, and pulse duration |
| `power_gpio`, `power_gpio_active_low` | Optional named power line and its polarity |
| `power_driver` | Only `/sys/bus/platform/drivers/pci-pwrctrl-slot` is supported |
| `power_device`, `power_module` | Slot controller identifier and module that must unload before power-off |
| `power_off_ms`, `repower_uses_power` | Power-off duration and whether board repower uses power instead of reset |
| `pcie.bus` | Endpoint bus, such as `0001:01` |
| `pcie.module`, `pcie.dependency` | Driver and optional dependency module |
| `pcie.at_port` | Board USB AT port for explicit actions |
| `pcie.boot_rescan_attempts` | One through five scans, with one as the default |
| `pcie.boot_rescan_interval_ms` | Interval from 1000 through 10000 milliseconds, with 5000 as the default |

The loader restricts file identifiers, device identifiers, module names, ports, and timing ranges.
The board package owns the GPIO assignments. The manager does not supply P5 assignments.
See the firmware profile for measured P5 parameters. Do not copy those parameters to another board without hardware evidence.

## Discovery lifecycle

The first discovery timer runs immediately. The daemon does not wait for Wi-Fi PHYs.
If the configured endpoint bus is empty, the action writes `1` to `/sys/bus/pci/rescan`.
sysfs exposes kernel device controls as files.
Linux rescans all PCIe buses through this file. The action accepts discovery only on the profile's endpoint bus.
If an endpoint already exists there, the action skips the rescan.
The action loads the dependency before the driver.

The board repeats discovery within the profile's limit. It stops on endpoint discovery, an action error, or the attempt limit.
The timers do not block the daemon between attempts.
The sysfs rescan and module commands are synchronous. A slow kernel operation can delay the event loop during that operation.

After discovery, the action requests autosetup and replays hotplug handling.
This also lets a fresh installation discover a modem without a configured modem section.
Driver loading does not prove that the modem protocol is ready.
Normal hotplug and WAITING_MODEM, the existing absent-modem state, handle later device nodes and protocol initialization.

The manual action uses the same discovery function after the boot limit ends.
Neither action removes devices, resets the modem, or changes its saved data mode.
The daemon cancels the boot timer on stop. A configuration reload does not restart the boot scan sequence.

## Explicit data-mode actions

The mode action requires `manual_data_mode` and a profile USB AT port.
AT commands control the modem through its command port.
It supports Quectel `AT+QCFG="data_interface"` values `0,0` for USB and `1,0` for PCIe.
It reads `AT+CGMI` before it accepts the vendor command.
It does not change the separate `pcie/mode` parameter.

The action uses a recognized AT queue that the daemon already owns for this board modem.
If no modem object owns an AT queue, it opens and reserves the profile USB AT port.
The daemon refuses a new AT opener while that port is reserved.
The temporary engine closes after the action. The daemon's existing queue stays open.
The action refuses multiple configured modems and concurrent board actions.
The daemon also refuses admin reset and repower while the data-mode action is busy.
The board guard covers recovery GPIO pulses and power cycles, so those paths cannot bypass the exclusion.

A read sends no mode write. A request for the current mode also skips the write.
A changed mode triggers a write and a second read. Success returns `restart_required: true`, without a reset or reboot.
Each AT command has a five-second timeout. The whole action has a thirty-second limit.

On stop or timeout, the action removes its commands that are still queued.
It ignores late callbacks. It cannot undo a command that already reached the modem.
If the write result is uncertain, read the mode again before retrying.
The UI disables Apply until that read succeeds.

## Slot power recovery

Slot recovery remains part of the existing recovery ladder and explicit Repower action.
It does not run as part of PCIe startup discovery.
The board requires a daemon preparation callback before it accepts a slot cycle.
Acceptance means that the action is scheduled, not that power-off succeeded.

The board calls preparation on the next event-loop turn.
This lets the recovery callback finish before the daemon retires its modem object.
The daemon then cancels that object's retry timer and closes its modem, context, and GPS transports.
Otherwise, a late failure callback can restart a retired modem beside its replacement.
During slot recovery, the daemon retains its waiting entry even if hotplug or configuration reload sees the old device nodes.
It does not create another backend until the board finishes recovery.

The board requires MHI unload before endpoint removal and slot power-off.
It attempts unload five times, with fifty milliseconds between failed attempts.
If preparation or unload fails, power stays unchanged and the daemon logs the failure.
Removal affects only the profile's endpoint bus. It leaves other buses and the host root port alone.

After the off interval, the board binds the slot controller, rescans PCIe, and reloads MHI.
If binding fails, the daemon logs that the modem remains off.
On daemon stop, the board cancels pending preparation or attempts to restore a slot that it powered off.

## API and UI contract

| Method | Permission | Result |
| --- | --- | --- |
| `pcie_rescan` | Write | `found` and discovery `state`, or an error |
| `modem_get_data_mode` | Read | Saved `mode` and `changed: false`, or an error |
| `modem_set_data_mode` | Write | Requested `mode`, `changed`, and `restart_required` after a changed mode |

The setter accepts `mode: "usb"` or `mode: "pcie"`.
The methods use the existing `ok` and `error` response convention.
Unsupported boards return `no_pcie_board_profile` or `data_mode_unsupported`.
Busy operations return `board_transport_busy`.

`status.board.transport` reports support, data-mode capability, discovery state, active action status, and endpoint addresses.
`driver_loaded` means that module loading succeeded. It does not mean that MHI or the data connection works.
The status does not cache the saved data mode. The read method obtains it from the modem.

LuCI shows Board modem setup even when no modem row exists.
Selecting a mode does not save it. Apply requires explicit confirmation because the mode persists across reboots.
The UI reports that a reboot is needed after a change. Read-only users can read the mode but cannot rescan or save it.

## Tests and hardware limits

The following tests cover the new contracts:

- `test_board_transport.uc` covers profile loading, bounded discovery, mode actions, and AT ownership.
- `test_board_ops.uc` covers the daemon, autosetup replay, API replies, hotplug during unload retries, and reset refusal during an AT transaction.
- `test_board_recovery.uc` covers retry cancellation across deferred board preparation.
- `test_board.uc` covers unload limits, endpoint scope, slot restoration, and existing GPIO behavior.
- `test_board_transport_serial.py` uses the real native serial engine through a host pseudo-terminal.
- LuCI `tests/test_transport.js` covers user actions and access permissions with injected DOM and RPC functions.

These tests do not prove a working data connection or slot recovery on hardware.
The full daemon test also needs a working host ubusd and its required access permissions.
The P5 image keeps its separate early firmware reset unchanged. The reported RM520 freeze remains unresolved.
The old `startup_*` UCI parameters no longer control this integration.

## Startup endpoint lookup

The modem control node can appear before the network device.
Wwand retries missing endpoint values before QMI data negotiation.
It keeps explicit endpoint values unchanged.
The board controls declare their RPC methods within the UI component.
An older cached shared RPC module cannot remove those methods.
An already open browser tab still requires a fresh page load.

## NSS firmware readiness

Profiles with the `rmnet_nss` dependency wait for NSS core 0 before loading the modem driver. Other profiles do not wait.
The daemon polls once per second for up to 30 seconds. The timers keep ubus and the UI responsive.
The readiness test reads the kernel boot message through `dmesg`. The NSS driver emits this message after it initializes the core.
If the wait expires, the daemon leaves the modem driver unloaded and records `nss_timeout`. Manual Rescan PCIe can retry afterward.
This gate does not wait for Wi-Fi and does not change modem power or data mode.

After flashing, make sure that `nss core 0 booted successfully` precedes `NSS context created`.
Test IPv4 and IPv6 HTTPS from a Wi-Fi client with NSS acceleration enabled. Save the boot log if NSS times out or HTTPS fails.

The P5 flashed-build log confirms NSS boot at 31.67 seconds, MHI initialization at 32.86 seconds, and NSS context creation at 33.07 seconds.
The earlier Wi-Fi wait hides this dependency. Keep NSS readiness independent of Wi-Fi when changing startup behavior.
Loading `rmnet_nss` alone does not prove that its firmware is ready. The reader depends on the NSS core 0 boot message in `dmesg`.
