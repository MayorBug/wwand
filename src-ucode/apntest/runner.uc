// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-apntest — the runner: one sweep over a parsed plan (apntest/plan.uc).
//
// Synchronous by design. A sweep is a strict sequence — select a SIM, dial,
// check, hang up, next — run from cron on a box that does nothing else, so an
// event loop would add states without adding concurrency. Every side effect
// goes through `ops`, which is what makes the whole sweep testable on a host:
//
//   ops.ubus(object, method, args)   -> reply object or null
//   ops.uci_get_all(config)          -> { section: { ... } }
//   ops.uci_set(config, section, option, value)   (value null = delete)
//   ops.uci_revert(config, section)  -> drop the uncommitted changes
//   ops.exec(argv)                   -> { code, out }
//   ops.pipe(argv, input)            -> exit code (input on stdin)
//   ops.mark_dirty(iface), ops.clear_dirty()  -> a test's uci changes are
//                                    pending (the CLI's crash recovery)
//   ops.sleep(ms), ops.now() (seconds), ops.log(level, msg)
//
// HOW A TEST DIALS. The test's APN and credentials are written to the test
// interface as UNCOMMITTED uci changes, the interface is brought up through
// netifd, and the changes are reverted afterwards. The daemon re-reads an
// interface's connection options on every up, through a uci cursor that sees
// uncommitted changes (ctx_settings.uc refresh_context_cfg, main.uc
// load_config), and netifd does the addressing as in production — so a test
// exercises the same path a customer's box does, without one flash write per
// run. A `wwand_sim` entry for the card under test overrides the interface's
// APN (context_common conn_cfg: per-SIM wins); the runner refuses such a test
// rather than report on an APN it did not dial.

'use strict';

// Icinga/NSCA states
export const OK = 0, WARNING = 1, CRITICAL = 2, UNKNOWN = 3;
const STATE_NAMES = [ 'OK', 'WARNING', 'CRITICAL', 'UNKNOWN' ];

// The thresholds of the tool this replaces (/usr/sbin/apntester): 5 priming
// pings, then 10; more than 50 % loss is critical, more than 20 % a warning.
const PING_PRIME = 5, PING_COUNT = 10;
const LOSS_CRITICAL = 50, LOSS_WARNING = 20;

// registration wait: the old tool's 120 s
const REG_WAIT_S = 120;
// a slot switch ends in a modem reset and a re-enumeration
const SLOT_WAIT_S = 180;
// the ping check at most: -w 5 priming, then -w 20
const PING_MAX_S = 30;
// netifd tears down asynchronously; the next test must not dial into it
const DOWN_WAIT_S = 30;

// `ping` output (busybox or iputils) -> { loss, rta } (rta in ms, null if no
// reply came back). null when the output carries no statistics at all.
export function parse_ping(out)
{
	let loss = match(out ?? '', /([0-9.]+)% packet loss/);

	if (!loss)
		return null;

	let rta = match(out, /min\/avg\/max[^=]*= *[0-9.]+\/([0-9.]+)\//);

	return { loss: +loss[1], rta: rta ? +rta[1] : null };
};

// The schedule goes into ROOT'S crontab (apntest_cli.uc cron-sync), so it is
// checked first: five fields of cron characters and nothing else — a value
// carrying a newline would add a command of its own.
const CRON_FIELD = /^[0-9A-Za-z*\/,-]+$/;

export function cron_ok(sched)
{
	if (type(sched) != 'string' || match(sched, /[\r\n]/))
		return false;

	let f = split(trim(sched), /[ \t]+/);

	return length(f) == 5 && length(filter(f, (x) => match(x, CRON_FIELD))) == 5;
};

// one NSCA line: host<TAB>service<TAB>code<TAB>message|perfdata
export function nsca_line(host, service, code, msg, perf)
{
	let text = replace(msg ?? '', /[\t\n]/g, ' ');

	if (length(perf ?? ''))
		text = sprintf('%s|%s', text, perf);

	return sprintf('%s\t%s\t%d\t%s\n', host, service, code, text);
};

// a configured regex against a value; a pattern that does not compile is a
// failed check with its reason, never an exception that ends the sweep
function rx_match(pattern, value)
{
	let re;

	try {
		re = regexp(pattern);
	}
	catch (e) {
		return { error: sprintf('invalid regex %J', pattern) };
	}

	return { hit: match(value ?? '', re) != null };
}

function perf_text(p)
{
	let parts = [];

	for (let k in sort(keys(p ?? {})))
		if (p[k] != null)
			push(parts, sprintf('%s=%s', k, '' + p[k]));

	return join(', ', parts);
}

// the interface a test dials: the configured one, else the only `proto wwand`
// interface bound to the plan's modem. cb-free, returns { name } or { error }.
export function resolve_interface(globals, network)
{
	if (globals?.interface)
		return network?.[globals.interface] ? { name: globals.interface }
			: { error: sprintf('interface %J is not in /etc/config/network', globals.interface) };

	let found = [];

	for (let name, s in (network ?? {}))
		if (s['.type'] == 'interface' && s.proto == 'wwand' && s.modem == globals?.modem)
			push(found, name);

	if (length(found) == 1)
		return { name: found[0] };

	return { error: length(found)
		? sprintf('modem %J has %d wwand interfaces (%s) — set `option interface` in globals',
			globals?.modem, length(found), join(', ', found))
		: sprintf('no `proto wwand` interface is bound to modem %J', globals?.modem) };
};

// a wwand_sim entry for this card that would override the test's connection
// options; null when there is none
function sim_override(network, iccid, imsi)
{
	for (let name, s in (network ?? {})) {
		if (s['.type'] != 'wwand_sim')
			continue;

		let hit = (iccid != null && s.iccid != null && index(iccid, s.iccid) == 0) ||
		          (imsi != null && s.imsi != null && s.imsi == imsi);

		// every field a wwand_sim may override on a connection
		// (context_common.uc SIM_OVERRIDABLE)
		if (hit && (s.apn != null || s.auth != null || s.username != null ||
		            s.password != null || s.pdp_type != null))
			return name;
	}

	return null;
}

export function create(plan, ops)
{
	let g = plan.globals ?? {};
	let log = ops.log;
	let verdicts = [];
	let started = ops.now();

	let modem_of = () => ops.ubus('wwand', 'status', {})?.modems?.[g.modem];
	let left = (deadline) => {
		let l = deadline - ops.now();
		return (l > 0) ? l : 0;
	};
	let at_most = (a, b) => (a < b) ? a : b;
	let netif = (iface) => sprintf('network.interface.%s', iface);

	// wait until the modem is registered (READY), at most `secs`
	let wait_ready = (secs) => {
		let until = ops.now() + secs;

		for (;;) {
			let m = modem_of();

			if (m?.state == 'READY')
				return m;

			if (ops.now() >= until)
				return null;

			ops.sleep(2000);
		}
	};

	let verdict = (test, service, state, msg, perf) => {
		let v = { test: test, service: service, state: state,
		          state_text: STATE_NAMES[state], message: msg,
		          perfdata: perf ?? null, time: ops.now() };

		push(verdicts, v);
		log(state == OK ? 'info' : 'warn', sprintf('%s: %s - %s', service, STATE_NAMES[state], msg));
		return v;
	};

	// the test failed before its checks: the first check reports the reason
	// under the test's service, the others say they did not run
	let fail_test = (t, state, msg, perf) => {
		verdict(t.name, t.service, state, sprintf('%s - %s', STATE_NAMES[state], msg), perf);

		for (let i = 1; i < length(t.checks); i++)
			verdict(t.name, t.checks[i].service, UNKNOWN,
				sprintf('UNKNOWN - not run: %s', msg), null);
	};

	let check_ping = (t, c, ctx) => {
		let host = c.arg;

		if (!length(host ?? ''))
			return [ UNKNOWN, 'UNKNOWN - ping needs a host (ping:<host>)', null ];

		ops.exec([ 'ping', '-c', '' + PING_PRIME, '-w', '' + PING_PRIME, '-I', ctx.dev, host ]);

		let r = ops.exec([ 'ping', '-c', '' + PING_COUNT, '-W', '10', '-w', '20', '-I', ctx.dev, host ]);
		let p = parse_ping(r?.out);

		if (!p)
			return [ CRITICAL, sprintf('CRITICAL - IP:%s, DNS:%s, Ping: %s, no statistics from ping',
				ctx.ip, ctx.dns, host), null ];

		let perf = { percent_packet_loss: p.loss, rta: p.rta, duration: ctx.duration, tries: 1 };
		let rta = (p.rta != null) ? sprintf('%s', '' + p.rta) : '-';

		if (p.loss > LOSS_CRITICAL)
			return [ CRITICAL, sprintf('CRITICAL - IP:%s, DNS:%s, Ping: %s, Packet loss too high: %s%%, RTA %sms',
				ctx.ip, ctx.dns, host, '' + p.loss, rta), perf ];

		if (p.loss > LOSS_WARNING)
			return [ WARNING, sprintf('WARNING - IP:%s, DNS:%s, Ping: %s, Packet loss high: %s%%, RTA %sms',
				ctx.ip, ctx.dns, host, '' + p.loss, rta), perf ];

		return [ OK, sprintf('OK - IP: %s, DNS: %s, Ping: %s, Loss: %s%%, RTA %sms',
			ctx.ip, ctx.dns, host, '' + p.loss, rta), perf ];
	};

	// the checks of this phase; anything else answers UNKNOWN — a check that
	// cannot run must never look like one that passed
	let CHECKS = { ping: check_ping };

	let run_checks = (t, ctx, deadline) => {
		for (let c in t.checks) {
			let fn = CHECKS[c.name];

			// the sweep's budget bounds the checks too
			if (fn && left(deadline) < PING_MAX_S) {
				verdict(t.name, c.service, UNKNOWN, 'UNKNOWN - run budget exhausted before this check', null);
				continue;
			}

			if (!fn) {
				verdict(t.name, c.service, UNKNOWN,
					sprintf('UNKNOWN - check %s is not available in this version', c.name), null);
				continue;
			}

			let r = fn(t, c, ctx);

			verdict(t.name, c.service, r[0], r[1], r[2]);
		}
	};

	let apply_params = (iface, t) => {
		ops.uci_set('network', iface, 'apn', t.apn);
		ops.uci_set('network', iface, 'auth', t.auth);
		ops.uci_set('network', iface, 'username', t.username);
		ops.uci_set('network', iface, 'password', t.password);
		ops.uci_set('network', iface, 'pdp_type', t.pdp_type);
	};

	// the interface's IPv4 address, DNS and L3 device once up, or null
	let wait_up = (iface, secs) => {
		let until = ops.now() + secs;

		for (;;) {
			let st = ops.ubus(sprintf('network.interface.%s', iface), 'status', {});
			let a = st?.['ipv4-address']?.[0]?.address;

			let dev = st?.l3_device ?? st?.device;

			if (st?.up && a && dev)
				return { ip: a, dns: join(' ', st['dns-server'] ?? []), dev: dev, status: st };

			if (ops.now() >= until)
				return { error: st?.errors?.[0]?.code ?? (st?.up ? 'no IPv4 address' : 'interface did not come up') };

			ops.sleep(2000);
		}
	};

	// settled down: netifd reports neither up nor pending
	let wait_down = (iface, secs) => {
		let until = ops.now() + secs;

		for (;;) {
			let st = ops.ubus(netif(iface), 'status', {});

			if (st != null && !st.up && !st.pending)
				return true;

			if (ops.now() >= until)
				return false;

			ops.sleep(1000);
		}
	};

	// the dial and its checks, after the parameters are in place; anything
	// that throws in here is the test's UNKNOWN, never the sweep's end
	let dial_and_check = (t, iface, t0, deadline) => {
		ops.ubus(netif(iface), 'up', {});

		let budget = t.budget;

		if (deadline - ops.now() < budget)
			budget = deadline - ops.now();

		let up = wait_up(iface, (budget > 0) ? budget : 1);
		let ctx = null;

		let ipm = (!up.error && t.ip_regex != null) ? rx_match(t.ip_regex, up.ip) : { hit: true };
		let dnm = (!up.error && t.dns_regex != null) ? rx_match(t.dns_regex, up.dns) : { hit: true };
		let pf = () => perf_text({ duration: ops.now() - t0, tries: 1 });

		if (up.error)
			fail_test(t, CRITICAL, sprintf('Connection to APN %s failed with message: %s', t.apn, up.error), pf());
		else if (ipm.error || dnm.error)
			fail_test(t, UNKNOWN, sprintf('ip_regex/dns_regex: %s', ipm.error ?? dnm.error), pf());
		else if (!ipm.hit)
			fail_test(t, CRITICAL, sprintf('Received wrong IP: %s', up.ip), pf());
		else if (!length(up.dns))
			fail_test(t, CRITICAL, 'Could not get DNS Servers', pf());
		else if (!dnm.hit)
			fail_test(t, CRITICAL, sprintf('Received wrong DNS Servers: %s', up.dns), pf());
		else
			ctx = { ip: up.ip, dns: up.dns, dev: up.dev, duration: ops.now() - t0 };

		if (ctx) {
			let before = length(verdicts);

			run_checks(t, ctx, deadline);

			for (let i = before; i < length(verdicts); i++)
				if (type(verdicts[i].perfdata) == 'object')
					verdicts[i].perfdata = perf_text(verdicts[i].perfdata);
		}
	};

	// returns false when the interface did not come down: the sweep stops
	// then, rather than dial the next APN into a teardown in progress
	let run_test = (t, iface, network, deadline) => {
		let t0 = ops.now();
		let m = wait_ready(at_most(REG_WAIT_S, left(deadline)));

		if (!m) {
			fail_test(t, WARNING, sprintf('Networkregistration took too long (%ds max)',
				at_most(REG_WAIT_S, ops.now() - t0)));
			return true;
		}

		let ov = sim_override(network, m.iccid, m.imsi);

		if (ov) {
			fail_test(t, UNKNOWN, sprintf('wwand_sim %s overrides the connection of this card — the test APN would not be dialled', ov));
			return true;
		}

		// THE TEST APN MUST NOT OUTLIVE THE TEST. It sits in the uci delta
		// directory, where the next ordinary ifup would dial it. So: mark the
		// interface before writing (a killed run is cleaned up by the next one
		// and by the init script — apntest_cli.uc recover), and clean up after whatever
		// happened in between.
		if (!ops.mark_dirty(iface)) {
			fail_test(t, UNKNOWN, 'cannot record the pending test parameters — not dialling');
			return true;
		}

		try {
			apply_params(iface, t);
			dial_and_check(t, iface, t0, deadline);
		}
		catch (e) {
			let before = length(filter(verdicts, (v) => v.test == t.name));

			if (!before)
				fail_test(t, UNKNOWN, sprintf('runner error: %s', e));
			else
				log('err', sprintf('%s: runner error after its verdicts: %s', t.name, e));
		}

		// each cleanup step guarded on its own: a failed down must not keep
		// the revert from running, and the marker only goes once the revert
		// did (ucode has no `finally`)
		let down = false;

		try {
			ops.ubus(netif(iface), 'down', {});
			down = wait_down(iface, DOWN_WAIT_S);
		}
		catch (e) {
			log('err', sprintf('%s: teardown failed: %s', iface, e));
		}

		try {
			ops.uci_revert('network', iface);
			ops.clear_dirty();
		}
		catch (e) {
			log('err', sprintf('%s: reverting the test parameters failed: %s — left for `wwand-apntest recover`', iface, e));
			down = false;
		}

		if (!down)
			log('err', sprintf('%s did not come down cleanly — the sweep stops here', iface));

		// low power, then online: the IMSI leaves the network between tests
		// (old imsi_detach + imsi_reattach)
		if (t.detach_after)
			ops.ubus('wwand', 'modem_reattach', { modem: g.modem });

		return down;
	};

	let select_sim = (sim, deadline) => {
		if (sim.profile != null)
			return 'eSIM profile selection is not available in this version';

		let slots = ops.ubus('wwand', 'modem_sim_slots', { modem: g.modem });
		let active = null;

		for (let s in (slots?.slots ?? []))
			if (s.active)
				active = s.physical;

		if (active == sim.slot || (active == null && sim.slot == 1))
			return null;

		log('notice', sprintf('switching %s to SIM slot %d', g.modem, sim.slot));

		let r = ops.ubus('wwand', 'modem_sim_switch_slot', { modem: g.modem, slot: sim.slot });

		if (r == null || r.error)
			return sprintf('switching to SIM slot %d failed: %s', sim.slot, r?.error ?? 'no answer');

		let w = at_most(SLOT_WAIT_S, left(deadline));

		return wait_ready(w) ? null
			: sprintf('no registration within %d s after switching to SIM slot %d', w, sim.slot);
	};

	let self = { verdicts: verdicts };

	// run the sweep, or one test (`only`); returns the verdicts
	self.run = function(only) {
		let network = ops.uci_get_all('network');
		let ifr = resolve_interface(g, network);
		let deadline = started + (g.run_budget ?? 1800);

		if (g.modem == null || ifr.error) {
			for (let grp in plan.groups)
				for (let t in grp.tests)
					if (!only || t.name == only)
						fail_test(t, UNKNOWN, g.modem == null ? 'no modem in globals' : ifr.error);
			return verdicts;
		}

		let slots0 = ops.ubus('wwand', 'modem_sim_slots', { modem: g.modem });
		let first_slot = null;

		for (let s in (slots0?.slots ?? []))
			if (s.active)
				first_slot = s.physical;

		let switched = false;
		let stuck = null;

		// the groups in a guard of their own: an exception must not keep the
		// box on a foreign card (restore_sim below)
		try {
			for (let grp in plan.groups) {
				let tests = filter(grp.tests, (t) => !only || t.name == only);

				if (!length(tests))
					continue;

				if (stuck || ops.now() >= deadline) {
					for (let t in tests)
						fail_test(t, UNKNOWN, stuck ?? 'run budget exhausted before this test');
					continue;
				}

				// set BEFORE the switch: one that succeeds and is followed by an
				// exception must still be undone below
				if (grp.sim.slot != null && grp.sim.slot != first_slot)
					switched = true;

				let err = select_sim(grp.sim, deadline);

				if (err) {
					for (let t in tests)
						fail_test(t, UNKNOWN, err);
					continue;
				}

				for (let t in tests) {
					if (stuck || ops.now() >= deadline) {
						fail_test(t, UNKNOWN, stuck ?? 'run budget exhausted before this test');
						continue;
					}

					if (!run_test(t, ifr.name, network, deadline))
						stuck = sprintf('not run: %s did not come down after the previous test', ifr.name);
				}
			}
		}
		catch (e) {
			log('err', sprintf('sweep aborted: %s', e));
		}

		// put the box back on the card it started with. Outside the budget on
		// purpose: leaving a test box on a foreign card costs more than the
		// minutes this takes.
		if (switched && g.restore_sim && first_slot != null)
			ops.ubus('wwand', 'modem_sim_switch_slot', { modem: g.modem, slot: first_slot });

		return verdicts;
	};

	// send every verdict to the NSCA monitor; returns the number not delivered
	self.report = function() {
		if (!g.monitor)
			return 0;

		let failed = 0;

		for (let v in verdicts) {
			let t = null;

			for (let grp in plan.groups)
				for (let x in grp.tests)
					if (x.name == v.test)
						t = x;

			let argv = [ 'send_nsca', '-H', g.monitor, '-c', g.nsca_cfg ?? '/etc/send_nsca.cfg' ];

			if (t?.nsca_port != null)
				push(argv, '-p', sprintf('%d', t.nsca_port));

			let code = ops.pipe(argv, nsca_line(g.nsca_host ?? 'localhost', v.service, v.state,
				v.message, v.perfdata));

			if (code != 0) {
				failed++;
				log('err', sprintf('send_nsca for %s failed (%d)', v.service, code));
			}
		}

		return failed;
	};

	return self;
};
