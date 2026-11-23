"""fix-wifi and wifi-watchdog, the wifi recovery tools setup.sh installs
(docs/wifi-recovery.md): the scripts as setup.sh writes them, the watchdog's
poll-loop scenarios (tests/wifi_watchdog_scenarios.sh), fix-wifi against a
fake nmcli, and the user service.

    python3 -m unittest discover -s tests -p test_wifi_recovery.py
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import setup_extract  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
BASH = shutil.which("bash")


def content(variable, terminator):
    return setup_extract.heredoc(rf"^{variable}=\$\(cat << '{terminator}'$", terminator)


FIX_WIFI = content("FIX_WIFI_CONTENT", "FIXWIFI")
WATCHDOG = content("WIFI_WATCHDOG_CONTENT", "WIFIWATCHDOG")
UNIT = content("WIFI_WATCHDOG_UNIT_CONTENT", "WIFIWATCHDOGUNIT")


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return f.read().splitlines()


def write(directory, name, text, mode=0o755):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)
    return path


class SetupWritesTheScripts(unittest.TestCase):
    def test_bash_reads_each_heredoc_as_extracted(self):
        # The bodies sit inside $( ), where a parsing slip would change what
        # setup.sh writes without any error: let bash itself evaluate them.
        text = setup_extract.setup_text()
        for variable, terminator, expected in (("FIX_WIFI_CONTENT", "FIXWIFI", FIX_WIFI),
                                               ("WIFI_WATCHDOG_CONTENT", "WIFIWATCHDOG", WATCHDOG),
                                               ("WIFI_WATCHDOG_UNIT_CONTENT", "WIFIWATCHDOGUNIT", UNIT)):
            with self.subTest(variable=variable):
                block = re.search(rf"(?ms)^{variable}=\$\(cat << '{terminator}'\n.*?^{terminator}\n\)\n", text)
                self.assertIsNotNone(block)
                r = subprocess.run(["bash", "-c", block.group(0) + f'printf "%s\\n" "${variable}"'],
                                   capture_output=True, text=True, timeout=30)
                self.assertEqual(r.stdout, expected)

    def test_scripts_parse_and_are_marked_managed(self):
        for name, body in (("fix-wifi", FIX_WIFI), ("wifi-watchdog", WATCHDOG)):
            with self.subTest(name=name):
                self.assertTrue(body.startswith("#!/usr/bin/env bash\n# Managed by debian-intel-macbook-post-install"))
                r = subprocess.run(["bash", "-n"], input=body, capture_output=True, text=True, timeout=30)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_installed_through_ensure_file_executable_and_enabled_for_all_users(self):
        text = setup_extract.setup_text()
        self.assertIn('FIX_WIFI_BIN="/usr/local/bin/fix-wifi"', text)
        self.assertIn('WIFI_WATCHDOG_BIN="/usr/local/bin/wifi-watchdog"', text)
        self.assertIn('WIFI_WATCHDOG_UNIT="/etc/systemd/user/wifi-watchdog.service"', text)
        for path, body in (("$FIX_WIFI_BIN", "$FIX_WIFI_CONTENT"), ("$WIFI_WATCHDOG_BIN", "$WIFI_WATCHDOG_CONTENT"),
                           ("$WIFI_WATCHDOG_UNIT", "$WIFI_WATCHDOG_UNIT_CONTENT")):
            self.assertIn(f'ensure_file "{path}" "{body}" ', text)
        self.assertIn('sudo chmod 755 "$FIX_WIFI_BIN" "$WIFI_WATCHDOG_BIN"', text)
        self.assertIn("sudo systemctl --global enable wifi-watchdog.service", text)



class SetupStartsTheService(unittest.TestCase):
    """The install-and-start block of setup.sh, run in bash with ensure_file,
    sudo and systemctl stubbed: what it asks systemd to do in each state."""

    STUBS = r'''
FAILED=()
print_ok() { echo "ok: $1"; }
print_skip() { echo "skip: $1"; }
print_fail() { echo "fail: $1"; }
print_warning() { echo "warning: $1"; }
print_info() { echo "info: $1"; }
ensure_file() { echo "$1" >> "$CALLS.files"; [ -n "$CHANGED" ] && return 0; return 1; }
sudo() { echo "sudo $*" >> "$CALLS"; [ "$1" = systemctl ] && [ -n "$GLOBAL_FAILS" ] && return 1; return 0; }
systemctl() {
    echo "systemctl $*" >> "$CALLS"
    case "$*" in
        "--user is-enabled wifi-watchdog.service") echo "$ENABLED" ;;
        "--user is-active --quiet wifi-watchdog.service") [ -n "$ACTIVE" ] ;;
        "--user restart wifi-watchdog.service"|"--user start wifi-watchdog.service") [ -z "$START_FAILS" ] ;;
        *) return 0 ;;
    esac
}
'''

    def block(self):
        text = setup_extract.setup_text()
        start = text.index("wifi_tools_changed=false\n")
        end = text.index('    print_info "wifi-watchdog starts at your next login"\nfi\n', start)
        return text[start:end] + '    print_info "wifi-watchdog starts at your next login"\nfi\necho "failed=${#FAILED[@]}"\n'

    def run_block(self, **env):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        calls = os.path.join(directory, "calls")
        environment = dict(os.environ, CALLS=calls, LOG_FILE=os.path.join(directory, "log"), DISPLAY=":0",
                           CHANGED="", ACTIVE="", ENABLED="enabled", START_FAILS="", GLOBAL_FAILS="",
                           FIX_WIFI_BIN="/b/fix-wifi", WIFI_WATCHDOG_BIN="/b/wifi-watchdog")
        environment.update(env)
        r = subprocess.run([BASH, "-c", self.STUBS + self.block()], env=environment,
                           capture_output=True, text=True, timeout=30)
        made = read_lines(calls)
        return r.stdout, [c for c in made if "restart" in c or " start " in c + " "]

    def test_a_change_restarts_the_running_copy(self):
        out, starts = self.run_block(CHANGED="1", ACTIVE="1")
        self.assertEqual(starts, ["systemctl --user restart wifi-watchdog.service"])
        self.assertIn("ok: wifi-watchdog running", out)

    def test_no_change_and_not_running_starts_it(self):
        _, starts = self.run_block()
        self.assertEqual(starts, ["systemctl --user start wifi-watchdog.service"])

    def test_no_change_and_running_leaves_it_alone(self):
        out, starts = self.run_block(ACTIVE="1")
        self.assertEqual(starts, [])
        self.assertIn("ok: wifi-watchdog running", out)

    def test_masked_by_the_user_stays_off_even_after_a_change(self):
        out, starts = self.run_block(CHANGED="1", ENABLED="masked")
        self.assertEqual(starts, [])
        self.assertIn("skip: wifi-watchdog (masked for this account)", out)

    def test_failing_to_start_warns(self):
        out, _ = self.run_block(START_FAILS="1")
        self.assertIn("warning: wifi-watchdog didn't start", out)

    def test_no_display_leaves_it_to_the_next_login(self):
        out, starts = self.run_block(DISPLAY="", CHANGED="1")
        self.assertEqual(starts, [])
        self.assertIn("info: wifi-watchdog starts at your next login", out)

    def test_global_enable_failure_is_reported(self):
        out, _ = self.run_block(GLOBAL_FAILS="1", ACTIVE="1")
        self.assertIn("fail: wifi-watchdog login start", out)
        self.assertIn("failed=1", out)


class WatchdogUnit(unittest.TestCase):
    def setting(self, key):
        return re.findall(rf"(?m)^{key}=(.*)$", UNIT)

    def test_runs_the_installed_watchdog_for_real_users_only(self):
        self.assertEqual(self.setting("ExecStart"), ["/usr/local/bin/wifi-watchdog"])
        self.assertEqual(self.setting("ConditionUser"), ["!@system"])
        self.assertEqual(self.setting("WantedBy"), ["default.target"])
        self.assertEqual(self.setting("Restart"), ["on-failure"])

    def test_documentation_link_points_at_a_file_in_this_repo(self):
        link = self.setting("Documentation")[0]
        relative = link.split("/blob/master/", 1)[1]
        self.assertTrue(os.path.isfile(os.path.join(HERE, "..", relative)), relative)

    def test_systemd_accepts_it(self):
        if not shutil.which("systemd-analyze"):
            self.skipTest("systemd-analyze is not installed here")
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        unit = write(directory, "wifi-watchdog.service", UNIT, 0o644)
        r = subprocess.run(["systemd-analyze", "--user", "verify", unit], capture_output=True, text=True, timeout=60)
        # ExecStart names /usr/local/bin/wifi-watchdog, which a test machine
        # need not have; every other complaint is a real one.
        problems = [line for line in r.stderr.splitlines()
                    if line.strip() and "/usr/local/bin/wifi-watchdog" not in line]
        self.assertEqual(problems, [])


class WatchdogScenarios(unittest.TestCase):
    def test_poll_loop_scenarios(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        watchdog = write(directory, "wifi-watchdog", WATCHDOG)
        r = subprocess.run(["bash", os.path.join(HERE, "wifi_watchdog_scenarios.sh")],
                           env=dict(os.environ, WATCHDOG=watchdog),
                           capture_output=True, text=True, timeout=120)
        failures = [line for line in r.stdout.splitlines() if line.startswith("FAIL")]
        self.assertEqual(failures, [], r.stdout + r.stderr)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("all tests passed", r.stdout)
        # Guard against a scenario file that silently stopped running checks.
        self.assertGreaterEqual(sum(line.startswith("ok ") for line in r.stdout.splitlines()), 30)


class FixWifi(unittest.TestCase):
    """fix-wifi against a fake nmcli and bluetoothctl. sleep is stubbed so the
    retries take no time; RADIO_ON_AFTER is how many "radio wifi on" calls it
    takes before the radio reads enabled (0: never)."""

    NMCLI = r'''#!/bin/bash
echo "nmcli $*" >> "$CALLS"
case "$*" in
  "-t -f DEVICE,TYPE device status") [ -n "$NO_WIFI" ] || echo "wlp3s0:wifi"; echo "lo:loopback" ;;
  "radio wifi on")
    n=$(( $(cat "$ONS" 2>/dev/null || echo 0) + 1 )); echo $n > "$ONS"
    [ -z "$REFUSE_ON" ] || { echo "Error: not authorized" >&2; exit 1; } ;;
  "radio wifi")
    n=$(cat "$ONS" 2>/dev/null || echo 0)
    if [ "$RADIO_ON_AFTER" -gt 0 ] && [ "$n" -ge "$RADIO_ON_AFTER" ]; then echo enabled; else echo disabled; fi ;;
esac
exit 0
'''

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.bin = os.path.join(self.dir, "bin")
        os.mkdir(self.bin)
        write(self.bin, "nmcli", self.NMCLI)
        write(self.bin, "sleep", "#!/bin/sh\nexit 0\n")
        write(self.bin, "bluetoothctl", '#!/bin/sh\necho "bluetoothctl $*" >> "$CALLS"\n')
        self.script = write(self.dir, "fix-wifi", FIX_WIFI)
        self.calls = os.path.join(self.dir, "calls")

    def run_fix(self, *args, **env):
        environment = dict(os.environ, PATH=self.bin + ":/usr/bin:/bin", CALLS=self.calls,
                           ONS=os.path.join(self.dir, "ons"), RADIO_ON_AFTER="1", NO_WIFI="", REFUSE_ON="")
        environment.update(env)
        r = subprocess.run([BASH, self.script, *args], env=environment, capture_output=True, text=True, timeout=30)
        calls = read_lines(self.calls)
        return r.returncode, calls, r.stderr

    def test_plain_reconnects_the_wifi_device(self):
        rc, calls, _ = self.run_fix()
        self.assertEqual(rc, 0)
        self.assertIn("nmcli device disconnect wlp3s0", calls)
        self.assertEqual(calls[-1], "nmcli device connect wlp3s0")

    def test_no_wifi_device_is_an_error(self):
        rc, calls, err = self.run_fix(NO_WIFI="1")
        self.assertEqual(rc, 1)
        self.assertIn("No wifi device", err)
        self.assertFalse(any("disconnect" in c for c in calls))

    def test_radio_off_then_on(self):
        rc, calls, _ = self.run_fix("--radio")
        self.assertEqual(rc, 0)
        self.assertLess(calls.index("nmcli radio wifi off"), calls.index("nmcli radio wifi on"))

    def test_radio_retries_until_it_reads_enabled(self):
        rc, calls, _ = self.run_fix("--radio", RADIO_ON_AFTER="3")
        self.assertEqual(rc, 0)
        self.assertEqual(calls.count("nmcli radio wifi on"), 3)

    def test_radio_refused_every_time_fails_loudly_after_three_tries(self):
        rc, calls, err = self.run_fix("--radio", RADIO_ON_AFTER="0", REFUSE_ON="1")
        self.assertEqual(rc, 1)
        self.assertEqual(calls.count("nmcli radio wifi on"), 3)
        self.assertIn("nmcli radio wifi on", err)

    def test_bluetooth_power_cycles(self):
        rc, calls, _ = self.run_fix("--bluetooth")
        self.assertEqual(rc, 0)
        self.assertEqual(calls, ["bluetoothctl power off", "bluetoothctl power on"])

    def test_bluetooth_without_bluetoothctl_says_so(self):
        os.remove(os.path.join(self.bin, "bluetoothctl"))
        # PATH without /usr/bin, so a real bluetoothctl can't be found either.
        rc, calls, err = self.run_fix("--bluetooth", PATH=self.bin)
        self.assertEqual(rc, 1)
        self.assertIn("bluez", err)

    def test_unknown_option_is_refused_not_treated_as_a_reconnect(self):
        rc, calls, err = self.run_fix("--raido")
        self.assertEqual(rc, 2)
        self.assertIn("Usage", err)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
