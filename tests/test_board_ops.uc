'use strict';
import * as uloop from 'uloop';
import * as daemonmod from 'wwand.daemon';
import * as config from 'wwand.config';
import * as api from 'wwand.ubus';
import * as fakefx from './lib/fakefx.uc';
import * as boardmod from 'wwand.board';
import * as atcmd from 'wwand.atcmd';
import { eq, ok, done } from './lib/check.uc';

uloop.init();
let endpoints = [], present = [], discovered = [], actions = [], methods;
let fx = {
	nss_ready: () => true,
	read: () => '21.00', list: () => endpoints,
	write: (path, value) => { push(actions, path); endpoints = ['0001:01:00.0']; return true; },
	run: (argv) => {
		push(actions, join(' ', argv));
		if (argv[1] == 'pcie_mhi')
			present = [{ kind: 'qmi', device: '/dev/mhi_QMI0' }];
		return 0;
	},
};
let native_queue = { send: (cmd, cb) => cb(null, { lines: cmd == 'AT+CGMI'
	? ['Quectel'] : ['+QCFG: "data_interface",1,0'] }), close: () => null };
let daemon = daemonmod.create({ deps: {
	board: { id: 'cudy,p5', profile: { manual_data_mode: true, pcie: {
		bus: '0001:01', module: 'pcie_mhi', dependency: 'rmnet_nss', at_port: '/dev/ttyUSB2',
	} }, init: () => {}, leds: () => {}, bars: () => 0 },
	board_fx: fx, board_open_at: () => native_queue,
	datapath_fx: fakefx.create(), log: () => {},
	list_present: () => present,
	autosetup_create: (dev) => { push(discovered, dev); return false; },
} });
daemon.apply_config(config.parse({network: {}}));
ok(api.publish({ publish: (name, object) => { methods = object; return {}; } }, daemon, () => {}),
	'publish: new methods register through the existing API');
eq(length(actions), 0, 'startup: daemon config applies before deferred board scan');
uloop.timer(20, () => uloop.end()); uloop.run();
eq(actions, ['/sys/bus/pci/rescan', 'modprobe rmnet_nss', 'modprobe pcie_mhi'],
	'startup: board discovers and loads MHI without a configured modem');
ok(index(discovered, 'mhi_QMI0') >= 0, 'first install: replay actual device through autosetup');
eq(daemon.status().board.transport.endpoints, ['0001:01:00.0'], 'status exposes board transport');

let replies = [];
let req = { args: {}, defer: () => {}, reply: (result) => push(replies, result) };
methods.modem_get_data_mode.call(req);
eq(replies[0].mode, 'pcie', 'read method reaches board AT action without a modem row');
eq(replies[0].ok, true, 'read response uses standard ubus shape');
uloop.timer(5, () => uloop.end()); uloop.run();
replies = []; req.args = { mode: 'invalid' };
methods.modem_set_data_mode.call(req);
eq(replies[0].ok, false, 'invalid mode is an API error');
eq(replies[0].error, 'invalid_data_mode', 'invalid mode has a useful error');
let res = methods.pcie_rescan.call({ args: {} });
ok(res.ok && res.found, 'manual rescan responds even with no configured modem');
eq(length(filter(actions, (a) => a == '/sys/bus/pci/rescan')), 1,
	'existing endpoint does not get rescanned unnecessarily');
daemon.stop_local(); daemon.shutdown();
uloop.timer(5, () => uloop.end()); uloop.run();
// A hotplug event must not reopen MHI between failed unload attempts.
let created = 0, starts = 0, unloads = 0, slotwrites = [], backend_resets = 0;
let slotfx = {
	read: (p) => p == '/proc/modules' ? 'pcie_mhi 100 1' : '0',
	list: () => [], write: (p, v) => { push(slotwrites, p); return true; },
	run: (args) => args[0] == 'rmmod' ? (++unloads == 1 ? 1 : 0) : 0,
};
let slot = boardmod.create({ id: 'cudy,p5', fx: slotfx, log: () => {}, profile: {
	manual_data_mode: true, repower_uses_power: true,
	reset_gpio: 'modem-reset', reset_run: 0, reset_assert_ms: 1,
	power_driver: '/sys/bus/platform/drivers/pci-pwrctrl-slot',
	power_device: 'test-slot', power_module: 'pcie_mhi', power_off_ms: 20,
	pcie: { bus: '0001:01', module: 'pcie_mhi', at_port: '/dev/ttyUSB2' },
} });
let rd = daemonmod.create({ deps: {
	board: slot, board_fx: slotfx, log: () => {}, datapath_fx: fakefx.create(),
	resolve_control: () => ({ protocol: 'qmi', device: '/dev/mhi_QMI0' }),
	load_qmi: () => ({ modem: { create: () => {
		created++;
		let queue = atcmd.create({ write: (s) => length(s), on_data: () => {},
			drain: () => {}, close: () => {} }, { log: () => {} });
		return { state: 'READY', start: () => { starts++; }, stop: () => queue.close(),
			at: queue, at_tty: '/dev/mhi_DUN',
			reset: (cb) => { backend_resets++; cb(null, { resetting: true }); } };
	} } }),
} });
rd.apply_config(config.parse({ network: {
	m0: { '.type': 'wwand_modem', device: '/dev/mhi_QMI0', mux: 'none' },
} }));
eq(created, 1, 'slot: initial backend exists');
rd.repower_modem('m0');
uloop.timer(20, () => { rd.hotplug('add', 'unrelated-netdev'); uloop.end(); }); uloop.run();
eq(unloads, 1, 'slot: the first unload fails before the hotplug event');
eq(created, 1, 'slot: hotplug cannot recreate a backend during unload retry');
ok(rd.modems.m0.modem == null, 'slot: the existing waiting entry remains detached');
uloop.timer(90, () => uloop.end()); uloop.run();
rd.hotplug('add', 'mhi_QMI0');
eq(created, 2, 'slot: normal hotplug recreates the backend after power returns');
eq(starts, 2, 'slot: exactly one backend starts after recovery');

// Use the real AT queue with a pending command. Both admin and recovery GPIO
// entry points must refuse concurrent board actions, without a backend fallback.
slotwrites = [];
rd.modem_data_mode('pcie', () => {});
ok(rd.board_transport_status().busy, 'mode: real AT queue has a pending transaction');
rd.modem_reset('m0', (err) => eq(err?.error, 'board_transport_busy', 'mode: admin reset refuses the pending transaction'));
rd.modems.m0.cfg.reset_gpio = 'modem-reset';
eq(rd.repower_modem('m0').error, 'board_transport_busy', 'mode: admin repower refuses the pending transaction');
ok(!slot.reset_pulse('modem-reset'), 'mode: recovery GPIO primitive also refuses overlap');
ok(!slot.power_cycle(), 'mode: slot power primitive also refuses overlap');
eq(slotwrites, [], 'mode: no GPIO or slot writes during the transaction');
eq(backend_resets, 0, 'mode: no soft reset fallback during the transaction');
rd.stop_local(); rd.shutdown();
uloop.timer(5, () => uloop.end()); uloop.run();
done('test_board_ops');
