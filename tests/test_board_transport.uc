'use strict';
import * as uloop from 'uloop';
import * as transport from 'wwand.board_transport';
import * as board from 'wwand.board';
import { eq, ok, done } from './lib/check.uc';

uloop.init();
let profile = { version: 1, manual_data_mode: true,
	pcie: { bus: '0001:01', module: 'pcie_mhi', dependency: 'rmnet_nss',
		at_port: '/dev/ttyUSB2', boot_rescan_attempts: 5, boot_rescan_interval_ms: 5000 } };
let nss_ready = true;
let actions, devs, found_after, commands, saved, vendor, readback, send_error, closed, rechecks;
let fx = {
	nss_ready: () => nss_ready,
	read: (p) => p == '/proc/uptime' ? '21.00 12.00' : null,
	list: (p) => p == '/sys/bus/pci/devices' ? devs : [],
	write: (p, v) => {
		push(actions, p);
		if (length(actions) == found_after)
			push(devs, '0001:01:00.0');
		return true;
	},
	run: (args) => { push(actions, join(' ', args)); return 0; },
};
let engine = {
	send: (cmd, cb) => {
		push(commands, cmd);
		if (send_error)
			return cb('timeout');
		if (cmd == 'AT+CGMI')
			return cb(null, { lines: [vendor] });
		if (cmd == 'AT+QCFG="data_interface"')
			return cb(null, { lines: [sprintf('+QCFG: "data_interface",%d,0', readback ?? saved)] });
		saved = index(cmd, ',1,0') >= 0 ? 1 : 0;
		cb(null, { lines: [] });
	},
	close: () => { closed++; },
};
function fresh() {
	actions = []; devs = []; found_after = 100; commands = [];
	saved = 0; vendor = 'Quectel'; readback = null; send_error = false; closed = 0; rechecks = 0;
	let self = { modems: {} };
	transport.install(self, { board: { id: 'cudy,p5', profile: profile }, fx: fx,
		log: () => {}, poll_ms: 1, open_at: () => engine, recheck: () => { rechecks++; } });
	return self;
};
function drain() { uloop.timer(20, () => uloop.end()); uloop.run(); };

let self = fresh();
self.board_transport_start();
eq(length(actions), 0, 'start: daemon is not blocked on a scan');
drain();
eq(actions, ['/sys/bus/pci/rescan', '/sys/bus/pci/rescan', '/sys/bus/pci/rescan',
	'/sys/bus/pci/rescan', '/sys/bus/pci/rescan'], 'start: five bounded scans, no Wi-Fi wait or reset');
eq(commands, [], 'start: no modem NV queries or writes');
self.pcie_rescan();
eq(length(actions), 6, 'manual scan remains available after boot retries end');
self.board_transport_start(); drain();
eq(length(actions), 6, 'start is idempotent');
self.board_transport_stop();

self = fresh(); found_after = 2;
self.board_transport_start(); drain();
eq(actions, ['/sys/bus/pci/rescan', '/sys/bus/pci/rescan', 'modprobe rmnet_nss', 'modprobe pcie_mhi'],
	'endpoint: stop scanning and load dependency before MHI');
ok(rechecks > 0, 'endpoint: trigger daemon discovery');
self.board_transport_stop();

self = fresh(); devs = ['0000:01:00.0'];
eq(self.pcie_rescan().found, false, 'another PCIe bus does not identify the board modem');
self.board_transport_stop();
self = fresh(); devs = ['0001:01:00.0'];
self.pcie_rescan();
eq(actions, ['modprobe rmnet_nss', 'modprobe pcie_mhi'], 'existing endpoint: load MHI without rescan');
self.board_transport_stop();

self = fresh(); devs = ['0001:01:00.0']; nss_ready = false;
eq(self.pcie_rescan().state, 'waiting_nss', 'manual scan respects NSS readiness');
self.board_transport_start();
eq(actions, [], 'NSS not ready: no modem module loads');
eq(self.board_transport_status().state, 'waiting_nss', 'NSS wait keeps daemon responsive');
nss_ready = true; drain();
eq(actions, ['modprobe rmnet_nss', 'modprobe pcie_mhi'], 'NSS ready: load driver without Wi-Fi wait');
self.board_transport_stop();
self = fresh(); devs = ['0001:01:00.0']; nss_ready = false;
self.board_transport_start(); drain(); drain(); drain();
eq(self.board_transport_status().state, 'nss_timeout', 'NSS wait has a bounded timeout');
eq(actions, [], 'NSS timeout never loads driver prematurely');
self.board_transport_stop();
let saved_dependency = profile.pcie.dependency;
profile.pcie.dependency = null;
self = fresh(); devs = ['0001:01:00.0'];
self.pcie_rescan();
eq(actions, ['modprobe pcie_mhi'], 'non-NSS profile loads immediately despite NSS not ready');
self.board_transport_stop();
profile.pcie.dependency = saved_dependency; nss_ready = true;

self = fresh();
self.modem_data_mode(null, (err, result) => {
	eq(err, null, 'mode read: success'); eq(result.mode, 'usb', 'mode read: USB detected');
});
eq(commands, ['AT+CGMI', 'AT+QCFG="data_interface"'], 'mode read never writes');
ok(self.board_at_reserved('/dev/ttyUSB2'), 'mode read: reserve owned AT port through deferred close');
eq(self.pcie_rescan().error, 'board_transport_busy', 'no rescan while an AT action is closing');
drain(); eq(closed, 1, 'mode read: close temporary native engine');
ok(!self.board_at_reserved('/dev/ttyUSB2'), 'mode read: release AT reservation');

commands = [];
self.modem_data_mode('pcie', (err, result) => {
	eq(err, null, 'mode set: success'); ok(result.restart_required, 'mode set: reports required reboot');
}); drain();
eq(commands, ['AT+CGMI', 'AT+QCFG="data_interface"', 'AT+QCFG="data_interface",1,0',
	'AT+QCFG="data_interface"'], 'mode set: vendor check, query, write, readback; no reset');
commands = [];
self.modem_data_mode('pcie', (err, result) => ok(!result.changed, 'same mode is unchanged')); drain();
eq(length(commands), 2, 'same mode: avoid NV write');

vendor = 'Other'; commands = [];
self.modem_data_mode('usb', (err) => eq(err.error, 'unsupported_modem_vendor', 'vendor guard')); drain();
eq(commands, ['AT+CGMI'], 'unsupported vendor: no setting write');
vendor = 'Quectel'; readback = 0; commands = [];
self.modem_data_mode('pcie', (err) => eq(err.error, 'data_mode_readback_failed', 'failed readback is reported')); drain();
send_error = true;
self.modem_data_mode(null, (err) => eq(err.error, 'at_failed', 'AT error is reported')); drain();
self.modem_data_mode('invalid', (err) => eq(err.error, 'invalid_data_mode', 'mode allowlist'));
self.modems = { a: {}, b: {} };
self.modem_data_mode('usb', (err) => eq(err.error, 'board_transport_busy', 'multiple modems are refused'));
self.board_transport_stop();

self = fresh();
self.modems = { builtin: { modem: { at: engine, at_tty: '/dev/mhi_DUN' } } };
self.modem_data_mode(null, () => {}); drain();
eq(closed, 0, 'daemon-owned engine is reused and never closed by the action');
self.board_transport_stop();

// JSON profiles override built-ins without constructing dependencies from UCI.
let pfx = { read: (path) => path == '/usr/share/wwand/boards.d/cudy,p5.json' ? sprintf('%J', profile) : null };
eq(board.load_profile('cudy,p5', pfx, () => {}).pcie.bus, '0001:01', 'board JSON: loads board-owned PCIe scope');
eq(board.load_profile('../escape', pfx, () => {}), null, 'board JSON: rejects unsafe model id');
for (let bad in [ { version: 2 }, { ...profile, power_gpio: '../escape' },
	{ ...profile, pcie: { ...profile.pcie, module: '../bad' } },
	{ ...profile, pcie: { ...profile.pcie, boot_rescan_attempts: 100 } } ]) {
	pfx.read = () => sprintf('%J', bad);
	eq(board.load_profile('cudy,p5', pfx, () => {}), null, 'board JSON: rejects invalid profile');
}
done('test_board_transport');
