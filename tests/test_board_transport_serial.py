#!/usr/bin/env python3
"""Native AT engine and serial transport through a host PTY."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class NativeSerialTest(unittest.TestCase):
    def test_explicit_mode_write(self):
        ucode = os.environ.get("WWAND_TEST_UCODE")
        modules = os.environ.get("WWAND_TEST_MODPATH")
        native = os.environ.get("WWAND_TEST_NATIVE")
        if not all((ucode, modules, native)):
            self.skipTest("set WWAND_TEST_UCODE, WWAND_TEST_MODPATH and WWAND_TEST_NATIVE")
        master, slave = pty.openpty()
        port = os.ttyname(slave)
        script = """
'use strict';
import * as uloop from 'uloop';
import * as transport from 'wwand.board_transport';
uloop.init();
let self = { modems: {} };
transport.install(self, {
 board: { id: 'test', profile: { manual_data_mode: true, pcie: {
  bus: '0001:01', module: 'pcie_mhi', at_port: %s
 } } },
 fx: { read: () => '0', list: () => [], run: () => die('unexpected host command'),
       write: () => die('unexpected sysfs write') },
 log: () => {}, recheck: () => {}, open_at: transport.open_at
});
self.modem_data_mode('pcie', (err, result) => {
 printf('%%J\\n', { error: err, result: result });
 self.board_transport_stop();
 uloop.timer(20, () => uloop.end());
});
uloop.run();
""" % json.dumps(port)
        with tempfile.TemporaryDirectory(prefix="wwand-at-") as temp:
            source = Path(temp) / "serial.uc"
            source.write_text(script)
            process = subprocess.Popen(
                [ucode, "-L", modules, "-L", native, "-L", str(ROOT / "tests/*.uc"), str(source)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            commands, pending, mode = [], b"", 0
            deadline = time.monotonic() + 8
            try:
                while process.poll() is None and time.monotonic() < deadline:
                    if not select.select([master], [], [], .1)[0]:
                        continue
                    pending += os.read(master, 4096)
                    while b"\r" in pending:
                        command, pending = pending.split(b"\r", 1)
                        command = command.strip().decode()
                        if not command:
                            continue
                        commands.append(command)
                        if command == "AT+CGMI":
                            body = "Quectel"
                        elif command == 'AT+QCFG="data_interface"':
                            body = f'+QCFG: "data_interface",{mode},0'
                        elif command == 'AT+QCFG="data_interface",1,0':
                            mode, body = 1, ""
                        else:
                            self.fail(f"unexpected command: {command}")
                        os.write(master, ("\r\n" + body + "\r\nOK\r\n").encode())
                self.assertIsNotNone(process.poll(), "native serial action timed out")
                stdout, stderr = process.communicate(timeout=2)
                self.assertEqual(process.returncode, 0, stderr)
                response = json.loads(stdout)
                self.assertIsNone(response["error"])
                self.assertEqual(response["result"]["mode"], "pcie")
                self.assertTrue(response["result"]["restart_required"])
                self.assertEqual(commands, ["AT+CGMI", 'AT+QCFG="data_interface"',
                                           'AT+QCFG="data_interface",1,0', 'AT+QCFG="data_interface"'])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                os.close(master)
                os.close(slave)

if __name__ == "__main__":
    unittest.main()
