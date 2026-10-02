// wwand tests — apntest runner: one sweep against faked ubus/uci/exec.
//
// What is under test is the SEQUENCE the old tool ran by hand — register,
// dial the test APN, check address and resolver against the pool, ping,
// hang up, detach — and the rule that a check that cannot run never reports
// OK. The faked netifd answers from what the test wrote to uci, so a runner
// that dials the wrong APN fails here exactly as it would on the box.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as plan_mod from 'wwand/apntest/plan.uc';
import * as runner from 'wwand/apntest/runner.uc';

const PING_OK = `PING 8.8.8.8 (8.8.8.8): 56 data bytes
--- 8.8.8.8 ping statistics ---
10 packets transmitted, 10 packets received, 0% packet loss
round-trip min/avg/max = 40.1/52.3/80.9 ms
`;
const PING_LOSSY = `--- 8.8.8.8 ping statistics ---
10 packets transmitted, 7 packets received, 30% packet loss
round-trip min/avg/max = 40.1/61.0/80.9 ms
`;

// a box: one modem, one wwand interface, a netifd that hands out what the
// operator of `apn` would
function fake(o)
{
	o ??= {};

	let clock = 1000;
	let calls = [], execs = [], piped = [], logs = [];
	let uci_net = {
		wan: { '.type': 'interface', proto: 'wwand', modem: 'wwmodem0', apn: 'base.apn' },
		...(o.network ?? {}),
	};
	let delta = {};
	let iface_up = false;
	let active_slot = o.slot ?? 1;
	let modem_state = o.modem_state ?? 'READY';

	let effective = (opt) => (opt in delta) ? delta[opt] : uci_net.wan[opt];

	let dirty = null;
	let down_at = null;
	let ops = {
		mark_dirty: (i) => { dirty = i; return !o.no_marker; },
		clear_dirty: () => { dirty = null; },
		now: () => clock,
		sleep: (ms) => { clock += ms / 1000; },
		log: (l, m) => push(logs, sprintf('%s %s', l, m)),
		uci_get_all: (c) => uci_net,
		uci_set: (c, s, opt, v) => {
			if (o.throw_set && opt == 'username')
				die('uci set failed');
			delta[opt] = v;
		},
		uci_revert: (c, s) => { delta = {}; },
		exec: (argv) => {
			if (o.throw_exec)
				die('exec exploded');
			push(execs, join(' ', argv));
			return { code: 0, out: (index(argv, '10') >= 0) ? (o.ping ?? PING_OK) : '' };
		},
		pipe: (argv, input) => { push(piped, { argv: argv, input: input }); return 0; },
		ubus: (obj, method, args) => {
			push(calls, sprintf('%s.%s', obj, method));

			if (obj == 'wwand' && method == 'status' && o.throw_status) {
				o.throw_status = false;
				die('status exploded');
			}

			if (obj == 'wwand' && method == 'status')
				return { modems: { wwmodem0: { state: modem_state,
					iccid: o.iccid ?? '8988228000019215531', imsi: '901288003920645' } } };

			if (obj == 'wwand' && method == 'modem_sim_slots')
				return { slots: [ { physical: 1, active: active_slot == 1 },
				                  { physical: 2, active: active_slot == 2 } ] };

			if (obj == 'wwand' && method == 'modem_sim_switch_slot') {
				active_slot = args.slot;
				if (o.throw_after_switch)
					o.throw_status = true;
				return { ok: true };
			}

			if (obj == 'wwand' && method == 'modem_reattach')
				return { ok: true };

			if (obj == 'network.interface.wan' && method == 'up') {
				iface_up = true;
				o.seen_apn = effective('apn');
				return {};
			}

			if (obj == 'network.interface.wan' && method == 'down') {
				iface_up = false;
				down_at = clock;
				return {};
			}

			if (obj == 'network.interface.wan' && method == 'status') {
				// a teardown that never settles: still pending
				if (!iface_up && o.stuck_down && down_at != null)
					return { up: false, pending: true };

				if (!iface_up || o.never_up)
					return { up: false, errors: o.never_up ? [ { code: 'CALL_FAILED' } ] : null };

				return { up: true, l3_device: o.no_dev ? null : 'wwand0',
				         'ipv4-address': [ { address: o.ip ?? '172.20.1.5', mask: 32 } ],
				         'dns-server': o.dns ?? [ '217.14.160.130', '217.14.164.35' ] };
			}

			return null;
		},
	};

	return { ops: ops, calls: calls, execs: execs, piped: piped, logs: logs,
	         delta: () => delta, slot: () => active_slot, clock: () => clock, o: o,
	         dirty: () => dirty };
}

function plan_of(extra)
{
	let raw = {
		globals: { '.type': 'apntest', modem: 'wwmodem0', monitor: 'monitor1.marcant.net',
		           nsca_host: 'MarcanT_mccp-apn', run_budget: '900' },
		gdsp: { '.type': 'apntest_sim', slot: '1' },
		gdsp_cda: { '.type': 'apntest', sim: 'gdsp', apn: 'nbiot.global-m2m.net',
		            auth: 'both', username: 'mccp', password: 'mccp',
		            ip_regex: '^172\\.', dns_regex: '217\\.14\\.1', detach_after: '1',
		            service: 'apn-gdsp-lte-m', nsca_port: '5668',
		            check: [ 'ping:8.8.8.8' ] },
		...(extra ?? {}),
	};
	let p = plan_mod.parse(raw);

	eq(p.errors, [], 'plan: the fixture parses');
	return p;
}

let by_service = (vs) => {
	let m = {};
	for (let v in vs)
		m[v.service] = v;
	return m;
};

// --- the old tool's run, end to end ------------------------------------------
{
	let f = fake();
	let r = runner.create(plan_of(), f.ops);
	let vs = r.run();
	let v = by_service(vs)['apn-gdsp-lte-m'];

	eq(f.o.seen_apn, 'nbiot.global-m2m.net', 'run: the TEST apn was dialled, not the interface\'s');
	eq(v?.state, runner.OK, 'run: OK on a good dial and ping');
	ok(index(v.message, 'IP: 172.20.1.5') >= 0 && index(v.message, 'Loss: 0%') >= 0,
		'run: the message names IP and loss, as the old tool did');
	ok(index(v.perfdata, 'percent_packet_loss=0') >= 0 && index(v.perfdata, 'rta=52.3') >= 0,
		'run: perfdata for the monitor');
	ok(index(join('|', f.execs), '-I wwand0 8.8.8.8') >= 0, 'run: ping through the interface\'s L3 device');
	eq(f.delta(), {}, 'run: the uncommitted apn change is reverted afterwards');
	ok(index(f.calls, 'network.interface.wan.down') >= 0, 'run: the interface is brought down again');
	ok(index(f.calls, 'wwand.modem_reattach') >= 0, 'run: detach_after detaches the IMSI');

	eq(r.report(), 0, 'report: delivered');
	eq(length(f.piped), 1, 'report: one NSCA line per verdict');
	ok(index(join(' ', f.piped[0].argv), '-H monitor1.marcant.net') >= 0 &&
	   index(join(' ', f.piped[0].argv), '-p 5668') >= 0, 'report: to the monitor, on the test\'s port');
	ok(match(f.piped[0].input, /^MarcanT_mccp-apn\tapn-gdsp-lte-m\t0\tOK - /),
		'report: host, service, code, message — the send_nsca line format');
}

// --- the pool checks that never ran on the field box -------------------------
{
	let f = fake({ ip: '10.1.2.3' });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.CRITICAL, 'ip_regex: an address outside the pool is critical');
	ok(index(v.message, 'Received wrong IP: 10.1.2.3') >= 0, 'ip_regex: and says which');
	eq(f.delta(), {}, 'ip_regex: reverted on failure too');
}
{
	let f = fake({ dns: [ '8.8.8.8' ] });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.CRITICAL, 'dns_regex: a foreign resolver is critical');
}

// --- loss thresholds of the old tool -----------------------------------------
{
	let f = fake({ ping: PING_LOSSY });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.WARNING, 'ping: 30% loss is a warning (old threshold > 20%)');
}

// --- a dial that never comes up -----------------------------------------------
{
	let f = fake({ never_up: true });
	let p = plan_of({ gdsp_cda: { '.type': 'apntest', sim: 'gdsp', apn: 'nbiot.global-m2m.net',
		service: 'apn-gdsp-lte-m', budget: '20', check: [ 'ping:8.8.8.8', 'ping:1.1.1.1#second' ] } });
	let vs = by_service(runner.create(p, f.ops).run());

	eq(vs['apn-gdsp-lte-m']?.state, runner.CRITICAL, 'dial: a failed connection is critical');
	ok(index(vs['apn-gdsp-lte-m'].message, 'CALL_FAILED') >= 0, 'dial: with netifd\'s error code');
	eq(vs['apn-gdsp-lte-m_second']?.state, runner.UNKNOWN, 'dial: the other checks say they did not run');
	ok(f.clock() - 1000 < 40, 'dial: the wait ends with the test budget');
}

// --- a check that cannot run is never OK --------------------------------------
{
	let f = fake();
	let p = plan_of({
		mccp: { '.type': 'apntest_account', type: 'mccp', base_url: 'https://api-ng.m-ccp.de' },
		gdsp_cda: { '.type': 'apntest', sim: 'gdsp', apn: 'nbiot.global-m2m.net',
			service: 'apn-gdsp-lte-m', account: 'mccp', sim_id: '901288003920645',
			sim_type: 'globalsim', check: [ 'ping:8.8.8.8', 'accounting' ] } });
	let vs = by_service(runner.create(p, f.ops).run());

	eq(vs['apn-gdsp-lte-m']?.state, runner.OK, 'checks: the ping still reports');
	eq(vs['apn-gdsp-lte-m_accounting']?.state, runner.UNKNOWN, 'checks: accounting (not in this phase) is UNKNOWN, not OK');
}

// --- a card whose wwand_sim would override the test apn -----------------------
{
	let f = fake({ network: { card: { '.type': 'wwand_sim', iccid: '8988228000019215531', apn: 'other' } } });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.UNKNOWN, 'override: a wwand_sim apn for the card makes the test UNKNOWN');
	eq(f.o.seen_apn, null, 'override: and nothing is dialled');
}

// --- SIM groups: switch once, restore afterwards ------------------------------
{
	let f = fake({ slot: 1 });
	let p = plan_of({
		cda2: { '.type': 'apntest_sim', slot: '2' },
		t2: { '.type': 'apntest', sim: 'cda2', apn: 'internet.t-mobile', check: [ 'ping:8.8.8.8' ] },
	});

	runner.create(p, f.ops).run();
	eq(length(filter(f.calls, (c) => c == 'wwand.modem_sim_switch_slot')), 2, 'slots: one switch there, one back');
	eq(f.slot(), 1, 'slots: restore_sim puts the box back on its card');
}

// --- no registration -----------------------------------------------------------
{
	let f = fake({ modem_state: 'REGISTERING' });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.WARNING, 'registration: a modem that does not register is a warning (as before)');
	eq(f.o.seen_apn, null, 'registration: nothing is dialled');
}

// --- run budget -----------------------------------------------------------------
{
	let f = fake({ modem_state: 'REGISTERING' });
	let p = plan_of({ globals: { '.type': 'apntest', modem: 'wwmodem0', run_budget: '100' },
		t2: { '.type': 'apntest', sim: 'gdsp', apn: 'x', check: [ 'ping:8.8.8.8' ] } });
	let vs = by_service(runner.create(p, f.ops).run());

	ok(index(vs.t2?.message ?? '', 'run budget exhausted') >= 0,
		'budget: a test past the run budget says so instead of running');
}

// --- the test apn never outlives the test ---------------------------------------
{
	let f = fake({ throw_exec: true });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.UNKNOWN, 'exception: a check that throws is the test\'s UNKNOWN');
	eq(f.delta(), {}, 'exception: the test apn is reverted anyway');
	ok(index(f.calls, 'network.interface.wan.down') >= 0, 'exception: and the interface brought down');
	eq(f.dirty(), null, 'exception: the crash marker is cleared');
}

// --- a set that fails halfway is still cleaned up --------------------------------
{
	let f = fake({ throw_set: true });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.UNKNOWN, 'partial set: the test is UNKNOWN');
	eq(f.delta(), {}, 'partial set: what was set is reverted');
	eq(f.dirty(), null, 'partial set: marker cleared after the revert');
}

// --- no marker, no dial ---------------------------------------------------------
{
	let f = fake({ no_marker: true });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.UNKNOWN, 'marker: without a crash marker nothing is dialled');
	eq(f.o.seen_apn, null, 'marker: ...really nothing');
}

// --- a switch that succeeded is undone even after an exception ------------------
{
	let f = fake({ slot: 1, throw_after_switch: true });
	let p = plan_of({
		cda2: { '.type': 'apntest_sim', slot: '2' },
		t2: { '.type': 'apntest', sim: 'cda2', apn: 'internet.t-mobile', check: [ 'ping:8.8.8.8' ] },
	});

	runner.create(p, f.ops).run();
	eq(f.slot(), 1, 'restore: the box is back on its card after an exception mid-group');
}

// --- a teardown that does not finish stops the sweep ----------------------------
{
	let f = fake({ stuck_down: true });
	let p = plan_of({ t2: { '.type': 'apntest', sim: 'gdsp', apn: 'second.apn', check: [ 'ping:8.8.8.8' ] } });
	let vs = by_service(runner.create(p, f.ops).run());

	eq(vs['apn-gdsp-lte-m']?.state, runner.OK, 'teardown: the first test still reports');
	eq(vs.t2?.state, runner.UNKNOWN, 'teardown: the next one is not dialled into it');
	ok(index(vs.t2.message, 'did not come down') >= 0, 'teardown: and says why');
}

// --- the budget bounds the registration wait too --------------------------------
{
	let f = fake({ modem_state: 'REGISTERING' });
	let p = plan_of({ globals: { '.type': 'apntest', modem: 'wwmodem0', run_budget: '10' } });

	runner.create(p, f.ops).run();
	ok(f.clock() - 1000 <= 14, 'budget: a 10 s sweep does not wait the full 120 s registration');
}

// --- every overridable field counts, password included --------------------------
{
	let f = fake({ network: { card: { '.type': 'wwand_sim', iccid: '89882280000192', password: 'x' } } });
	let v = by_service(runner.create(plan_of(), f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.UNKNOWN, 'override: a password-only wwand_sim (ICCID prefix) also blocks the test');
}

// --- no l3 device, no ping -------------------------------------------------------
{
	let f = fake({ no_dev: true });
	let p = plan_of({ gdsp_cda: { '.type': 'apntest', sim: 'gdsp', apn: 'nbiot.global-m2m.net',
		service: 'apn-gdsp-lte-m', budget: '10', check: [ 'ping:8.8.8.8' ] } });
	let v = by_service(runner.create(p, f.ops).run())['apn-gdsp-lte-m'];

	eq(v?.state, runner.CRITICAL, 'l3: an up without a device is a failed dial, not a ping on ""');
	eq(length(filter(f.execs, (e) => index(e, 'ping') == 0)), 0, 'l3: and nothing is pinged');
}

// --- the interface is resolved, or the run says why it cannot -------------------
eq(runner.resolve_interface({ modem: 'm' }, { a: { '.type': 'interface', proto: 'wwand', modem: 'm' } }),
	{ name: 'a' }, 'iface: the only wwand interface of the modem');
ok(runner.resolve_interface({ modem: 'm' }, {
	a: { '.type': 'interface', proto: 'wwand', modem: 'm' },
	b: { '.type': 'interface', proto: 'wwand', modem: 'm' } }).error != null,
	'iface: two candidates need `option interface`');

// --- the parsers ----------------------------------------------------------------
eq(runner.parse_ping(PING_OK), { loss: 0, rta: 52.3 }, 'parse_ping: busybox statistics');
eq(runner.parse_ping('10 packets transmitted, 0 received, 100% packet loss, time 9012ms\n'),
	{ loss: 100, rta: null }, 'parse_ping: total loss has no rta');
eq(runner.parse_ping('ping: sendto: Network unreachable\n'), null, 'parse_ping: no statistics');
ok(runner.cron_ok('*/10 * * * *') && runner.cron_ok('0 2 * * mon'), 'cron: ordinary schedules');
ok(!runner.cron_ok('*/10 * * *') && !runner.cron_ok('*/10 * * * * extra'), 'cron: five fields, no more, no less');
ok(!runner.cron_ok('*/10 * * * *\n* * * * * rm -rf /'), 'cron: a newline cannot add a command to root\'s crontab');
ok(!runner.cron_ok('*/10 * * * $(id)'), 'cron: no shell characters');
eq(runner.nsca_line('h', 's', 2, 'a\tb', 'x=1'), 'h\ts\t2\ta b|x=1\n', 'nsca_line: tabs in the message cannot split fields');

done('test_apntest_runner');
