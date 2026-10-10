// SPDX-License-Identifier: GPL-2.0-only
// Explicit board transport setup. Startup never changes modem NV settings.
'use strict';

import * as uloop from 'uloop';
import * as atcmd from 'wwand.atcmd';
import * as boardmod from 'wwand.board';

export function install(self, o)
{
	let board = o.board;
	let p = board?.profile?.pcie;
	let fx = o.fx ?? boardmod.default_fx();
	let timer = null, started = false, busy = false, stopped = false;
	let cancel_mode = null;
	let reserved_port = null;
	let status = { supported: !!p, state: p ? 'pending' : 'unsupported',
		data_mode: !!p?.at_port && !!board?.profile?.manual_data_mode };
	let log = (msg) => o.log('notice', sprintf('board %s: uptime=%ss %s',
		board.id, split(fx.read('/proc/uptime') ?? '?', ' ')[0], msg));
	let devices = () => filter(fx.list('/sys/bus/pci/devices') ?? [],
		(d) => p && substr(d, 0, length(p.bus) + 1) == p.bus + ':');

	self.board_transport_status = () => ({ ...status, busy: busy, endpoints: devices() });
	self.board_at_reserved = (path) => path != null && path == reserved_port;
	self.pcie_rescan = function() {
		if (!p || stopped)
			return { error: 'no_pcie_board_profile' };
		if (busy || board.power_busy?.())
			return { error: 'board_transport_busy' };
		// Scan only. Never remove devices, reset GPIOs, or change data mode.
		if (!length(devices()) && !fx.write('/sys/bus/pci/rescan', '1'))
			return { error: 'pcie_rescan_failed' };
		let found = length(devices()) > 0;
		status.state = found ? 'loading_driver' : 'missing_endpoint';
		if (found) {
			// rmnet_nss needs running firmware, not just a loaded module.
			if (p.dependency == 'rmnet_nss' && !fx.nss_ready?.()) {
				status.state = 'waiting_nss';
				return { ok: true, found: true, state: status.state };
			}
			for (let module in [ p.dependency, p.module ])
				if (module && fx.run([ 'modprobe', module ]) != 0) {
					status.state = 'driver_failed';
					return { error: 'module_load_failed', module: module };
				}
			status.state = 'driver_loaded';
			// Device nodes can arrive later; their hotplug and WAITING_MODEM
			// checks remain responsible for protocol readiness.
			uloop.timer(0, () => { if (!stopped) o.recheck(); });
		}
		log(found ? 'PCIe endpoint present; driver loaded' : 'PCIe rescan: endpoint still missing');
		return { ok: true, found: found, state: status.state };
	};

	self.board_transport_start = function() {
		if (!p || started)
			return;
		started = true;
		let attempts = 0, nss_attempts = 0;
		let poll;
		poll = () => {
			if (stopped)
				return;
			let r = self.pcie_rescan();
			if (r.error)
				o.log('err', sprintf('board transport: %J', r));
			if (r.state == 'waiting_nss') {
				if (++nss_attempts == 1)
					log('waiting for NSS firmware before loading modem driver');
				if (nss_attempts >= 31) {
					status.state = 'nss_timeout';
					timer = null;
					log('NSS firmware wait timed out; modem driver remains unloaded');
					return;
				}
				timer = uloop.timer(o.poll_ms ?? 1000, poll);
				return;
			}
			if (r.found || r.error || ++attempts >= (p.boot_rescan_attempts ?? 1)) {
				timer = null;
				if (!r.found && !r.error)
					log('boot rescans finished; manual Rescan PCIe remains available');
				return;
			}
			timer = uloop.timer(o.poll_ms ?? p.boot_rescan_interval_ms ?? 5000, poll);
		};
		// procd and ubus stay available. NSS profiles wait without blocking.
		timer = uloop.timer(0, poll);
	};

	self.modem_data_mode = function(mode, cb) {
		if (!status.data_mode || stopped)
			return cb({ error: 'data_mode_unsupported' });
		if (mode != null && mode != 'usb' && mode != 'pcie')
			return cb({ error: 'invalid_data_mode' });
		if (busy || board.power_busy?.() || length(keys(self.modems)) > 1)
			return cb({ error: 'board_transport_busy' });
		let engine = null, owned = false;
		for (let name, entry in self.modems) {
			// Use the daemon's queue if it already owns this modem's AT port.
			if (entry.modem?.at && (entry.modem.at_tty == p.at_port ||
			    match(entry.modem.at_tty ?? '', /^\/dev\/(mhi_.*DUN.*|wwan[0-9]+at[0-9]+)$/)))
				engine = entry.modem.at;
			else if (entry.modem)
				return cb({ error: 'modem_at_not_ready' });
		}
		if (!engine) {
			engine = o.open_at(p.at_port);
			owned = true;
		}
		if (!engine)
			return cb({ error: 'no_at_port', port: p.at_port });
		busy = true;
		reserved_port = owned ? p.at_port : null;
		let finished = false, deadline, pending_cb;
		let finish = (err, result) => {
			if (finished)
				return;
			finished = true;
			deadline?.cancel();
			engine.cancel_queued?.(pending_cb);
			cancel_mode = null;
			if (owned)
				engine.close();
			// An owned native transport closes on the next uloop turn.
			uloop.timer(0, () => {
				busy = false;
				reserved_port = null;
				if (owned && !stopped)
					o.recheck();
			});
			cb(err, result);
		};
		cancel_mode = () => finish({ error: 'data_mode_cancelled' });
		deadline = uloop.timer(30000, () => finish({ error: 'data_mode_timeout',
			detail: 'Read the setting again before retrying.' }));
		let send = (command, next) => {
			if (finished || stopped)
				return;
			pending_cb = (err, result) => {
				if (finished || stopped)
					return;
				if (err)
					finish({ error: 'at_failed', command: command, detail: err });
				else
					next(result?.lines ?? []);
			};
			engine.send(command, pending_cb, { timeout: 5000 });
		};
		let parse = (lines) => {
			for (let line in (lines ?? [])) {
				let m = match(line, /^\+QCFG:\s*"data_interface",\s*([01]),\s*0\s*$/);
				if (m)
					return m[1] == '1' ? 'pcie' : 'usb';
			}
			return null;
		};
		send('AT+CGMI', (lines) => {
			if (!match(join(' ', lines ?? []), /quectel/i))
				return finish({ error: 'unsupported_modem_vendor' });
			send('AT+QCFG="data_interface"', (lines) => {
				let current = parse(lines);
				if (!current)
					return finish({ error: 'unsupported_data_interface' });
				if (mode == null || mode == current)
					return finish(null, { ok: true, mode: current, changed: false });
				send(sprintf('AT+QCFG="data_interface",%d,0', mode == 'pcie' ? 1 : 0), () => {
					send('AT+QCFG="data_interface"', (lines) => {
						if (parse(lines) != mode)
							return finish({ error: 'data_mode_readback_failed',
								detail: 'The write may have succeeded. Read the setting again before retrying.' });
						log('operator saved modem data mode: ' + mode);
						finish(null, { ok: true, mode: mode, changed: true, restart_required: true });
					});
				});
			});
		});
	};

	self.board_transport_stop = () => {
		stopped = true;
		timer?.cancel();
		cancel_mode?.();
	};
};

export function open_at(port)
{
	let tr = atcmd.open_transport(port, 115200);
	return tr ? atcmd.create(tr) : null;
};

export const open_transport = atcmd.open_transport;
