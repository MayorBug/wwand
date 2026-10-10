'use strict';
import * as uloop from 'uloop';
import * as board from 'wwand.board';
import * as common from 'wwand.modem_common';
import { eq, ok, done } from './lib/check.uc';

uloop.init();
let writes = [], calls = [], starts = 0, retired = false, retry;
let fx = {
	read: () => '', list: () => [], run: () => 0,
	write: (p, v) => { push(writes, p); return true; },
};
let b = board.create({ fx: fx, log: () => {}, profile: {
	power_driver: '/sys/bus/platform/drivers/pci-pwrctrl-slot',
	power_device: 'test-slot', power_module: 'pcie_mhi', power_off_ms: 5,
} });
let m = { counters: { attempts: 24 }, _teardown_depth: 0 };
m.teardown = () => {
	m._teardown_depth++;
	retry?.cancel(); retry = null;
	m._teardown_depth--;
};
m.stop = () => { m.teardown(); retired = true; push(calls, 'stop'); };
m.start = () => { starts++; };
m.set_state = () => {};
b.set_power_prepare(() => { m.stop(); return true; });
common.note_connect_failure_light(m, {
	on_attempt: () => 'usb_repower', usb_repower: () => b.power_cycle(),
});
let fail = common.make_fail(m, { log: () => {}, emit: () => {},
	timing: { backoff_min: 10, backoff_max: 10 },
	set_retry_timer: (t) => { retry = t; push(calls, 'retry'); },
});
fail('register', { error: 'timeout' });
ok(b.power_busy(), 'slot recovery owns the pending preparation timer');
uloop.timer(30, () => uloop.end()); uloop.run();
eq(calls, ['retry', 'stop'], 'recovery continuation completes before the daemon retires its modem');
ok(retired, 'daemon retires the old modem before slot power-off');
eq(starts, 0, 'retired modem cannot restart beside its hotplug replacement');
ok(index(writes, '/sys/bus/platform/drivers/pci-pwrctrl-slot/unbind') >= 0,
	'recovery still reaches the slot power action');

// Stopping before the next turn must cancel preparation, not detach a live modem.
writes = []; calls = [];
b.power_cycle(); b.finish_power();
uloop.timer(10, () => uloop.end()); uloop.run();
eq(calls, [], 'daemon stop cancels pending preparation');
eq(writes, [], 'cancelled preparation does not touch slot power');

b.set_power_prepare(() => false);
ok(b.power_cycle(), 'slot action reports scheduling, not completed power-off');
uloop.timer(10, () => uloop.end()); uloop.run();
eq(writes, [], 'refused preparation leaves power unchanged');
ok(!b.power_busy(), 'refused preparation releases its timer');
done('test_board_recovery');
