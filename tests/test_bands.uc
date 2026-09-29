// wwand tests — per-modem band lists in the daemon: a band edit on a modem
// that does not keep it (settings `persistent: false`, Fibocom +GTACT) is
// kept in uci, a reload never restarts a modem for a band change, a changed
// list is applied by the running modem, and a list nothing applies is said
// in status. The codec itself is tested in test_ncm_fibocom, the bring-up
// ordering in test_ncm (s9x..s9z).

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as config from 'wwand/config.uc';
import * as daemon_mod from 'wwand/daemon.uc';

uloop.init();

let recorded = [];

let d = daemon_mod.create({
	deps: {
		log: (level, msg) => null,
		// no control device yet: the modem entry waits, nothing is opened
		resolve_control: (cfg) => null,
		record_bands: (section, lists) => {
			push(recorded, [ section, lists ]);
			return section == 'm0';
		},
	},
});

let net = (bands) => config.parse({ network: {
	m0: { '.type': 'wwand_modem', usb_path: '3-1', ...(bands ?? {}) },
} });

d.apply_config(net());

let entry = d.modems.m0;

ok(entry != null, 'modem entry exists');

// what the daemon sees of a running FM350: the settings passthrough and the
// bring-up apply, both recorded
let applied = 0;
let answer = { applied: [ 'lte' ], verified: true, persistent: false };
let fake = {
	info: { model: 'FM350-GL' },
	config: entry.cfg,
	settings_set: (s, cb) => cb(null, answer),
	apply_config_bands: (cb) => { applied++; cb(null, {}); },
	bands_applicable: () => true,
	stop: () => null,
};

entry.modem = fake;

let err, res;

d.modem_set_settings('m0', { lte_bands: [ 3, 1 ], nr5g_sa_bands: [ 78 ], nr5g_nsa_bands: [ 78 ] },
	(e, r) => { err = e; res = r; });

eq(err, null, 'set: accepted');
eq(recorded, [ [ 'm0', { band_lte: [ '3', '1' ], band_nr: [ '78' ] } ] ],
	'set: a not-NV band edit is kept in uci (one NR list, as strings)');
eq([ entry.cfg.band_lte, entry.cfg.band_nr ], [ [ '3', '1' ], [ '78' ] ],
	'set: the running config follows');

// the reload that follows the commit: same lists -> nothing restarted,
// nothing applied again
d.apply_config(net({ band_lte: [ '3', '1' ], band_nr: [ '78' ] }));
ok(d.modems.m0 === entry, 'reload with the recorded lists: the modem is not restarted');
eq(applied, 0, 'reload with the recorded lists: nothing to apply');

// a hand edit of a running modem's lists: applied live, still no restart
d.apply_config(net({ band_lte: [ '20' ], band_nr: [ '78' ] }));
ok(d.modems.m0 === entry, 'band edit by hand: the modem is not restarted');
eq(applied, 1, 'band edit by hand: the running modem applies it');
eq(fake.config.band_lte, [ '20' ], 'band edit by hand: the modem sees the new list');

// "no band ticked" = all bands: the option goes away
recorded = [];
d.modem_set_settings('m0', { lte_bands: [] }, (e, r) => { err = e; });
eq(recorded, [ [ 'm0', { band_lte: [] } ] ], 'set: an empty list removes the option (all bands)');

// an NV-keeping modem (QMI) is not recorded
recorded = [];
answer = { applied: [ 'lte' ] };
d.modem_set_settings('m0', { lte_bands: [ 3 ] }, (e, r) => { err = e; });
eq(recorded, [], 'set: a modem that keeps its bands itself writes nothing to uci');

// status: a configured list nothing applies is a warning ...
fake.bands_applicable = () => false;

let w = filter(d.status().modems.m0.config_warnings ?? [], (x) => x.check == 'band_lists');

eq(length(w), 1, 'status: a band list on a modem without a band command warns');
ok(index(w[0]?.message ?? '', 'FM350-GL') >= 0 && index(w[0]?.message ?? '', 'keeps its bands itself') < 0,
	'status: ...naming the model, not claiming an NCM modem keeps bands in NV');

// not identified yet (the FM350 refuses CGMM after a slot switch, #32): no
// verdict at all rather than a wrong one (#45)
fake.bands_applicable = () => null;
w = filter(d.status().modems.m0.config_warnings ?? [], (x) => x.check == 'band_lists');
eq(length(w), 0, 'status: a modem that has not said what it is gets no band verdict (#45)');

// a QMI/MBIM modem has no band command wwand drives: it keeps bands in NV
let keep = fake.bands_applicable;
delete fake.bands_applicable;
w = filter(d.status().modems.m0.config_warnings ?? [], (x) => x.check == 'band_lists');
ok(length(w) == 1 && index(w[0].message, 'keeps its bands itself') >= 0,
	'status: a QMI/MBIM modem is told to set its bands in Modem Tools');
fake.bands_applicable = keep;

// ... and so is a failed apply
fake.bands_applicable = () => true;
fake.band_apply_error = { error: 'unsupported_tuple', detail: 'tuple 17' };
w = filter(d.status().modems.m0.config_warnings ?? [], (x) => x.check == 'band_lists');
ok(length(w) == 1 && index(w[0].message, 'tuple 17') >= 0, 'status: a failed apply says why');

fake.band_apply_error = null;
w = filter(d.status().modems.m0.config_warnings ?? [], (x) => x.check == 'band_lists');
eq(length(w), 0, 'status: an applied list is not a warning');

// a modem other options change IS still restarted (the exclusion is bands only)
d.apply_config(net({ band_lte: [ '20' ], band_nr: [ '78' ], stats_interval: '30' }));
ok(d.modems.m0 !== entry, 'a non-band edit still rebuilds the modem');

done('test_bands');
