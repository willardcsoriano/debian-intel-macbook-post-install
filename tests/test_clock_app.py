"""The clock app setup.sh installs (GNOME Clocks), and the removal of Alarm
Clock, which v1.14.0 installed in its place: only where that version's managed
launcher shows the script set it up.

    python3 -m unittest discover -s tests -p test_clock_app.py
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

MARKER = "# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it."


def retire_function():
    match = re.search(r"^retire_alarm_clock\(\) \{\n.*?^\}\n", setup_extract.setup_text(),
                      re.MULTILINE | re.DOTALL)
    assert match, "retire_alarm_clock() not found in setup.sh"
    return match.group(0)


class RetireAlarmClock(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.launcher = os.path.join(self.dir, "alarm-clock-applet.desktop")
        self.calls = os.path.join(self.dir, "sudo-calls")

    def write_launcher(self, text):
        with open(self.launcher, "w") as f:
            f.write(text)

    def retire(self, sudo_status=0):
        # sudo is stubbed: it records its arguments and exits with sudo_status,
        # standing in for apt-get succeeding or failing.
        stub = 'sudo() { echo "$*" >> "$CALLS"; return %d; }\n' % sudo_status
        script = stub + retire_function() + 'retire_alarm_clock "$1"'
        env = dict(os.environ, CALLS=self.calls, LOG_FILE=os.path.join(self.dir, "log"))
        r = subprocess.run(["bash", "-c", script, "-", self.launcher],
                           env=env, capture_output=True, text=True, timeout=30)
        return r.returncode

    def sudo_calls(self):
        if not os.path.exists(self.calls):
            return []
        with open(self.calls) as f:
            return f.read().splitlines()

    def test_removes_the_package_and_launcher_this_script_set_up(self):
        self.write_launcher("[Desktop Entry]\n" + MARKER + "\nName=Alarm Clock\n")
        self.assertEqual(self.retire(), 0)
        self.assertEqual(self.sudo_calls(), ["apt-get purge -y alarm-clock-applet"])
        self.assertFalse(os.path.exists(self.launcher))

    def test_leaves_a_launcher_the_user_wrote_and_the_package_alone(self):
        self.write_launcher("[Desktop Entry]\nName=My Alarm Clock\n")
        self.assertEqual(self.retire(), 1)
        self.assertEqual(self.sudo_calls(), [])
        self.assertTrue(os.path.exists(self.launcher))

    def test_nothing_to_do_without_a_launcher(self):
        self.assertEqual(self.retire(), 1)
        self.assertEqual(self.sudo_calls(), [])

    def test_failed_removal_keeps_the_launcher_so_the_next_run_retries(self):
        self.write_launcher("[Desktop Entry]\n" + MARKER + "\n")
        self.assertEqual(self.retire(sudo_status=100), 2)
        self.assertTrue(os.path.exists(self.launcher))
        self.assertEqual(self.retire(), 0)
        self.assertFalse(os.path.exists(self.launcher))

    def test_called_on_the_path_managed_launcher_wrote_in_v1_14_0(self):
        self.assertIn('retire_alarm_clock "$ACTUAL_HOME/.local/share/applications/'
                      'alarm-clock-applet.desktop"', setup_extract.setup_text())


class ClockAppSetup(unittest.TestCase):
    def test_gnome_clocks_installed_through_install_pkg(self):
        self.assertRegex(setup_extract.setup_text(), r'(?m)^install_pkg "gnome-clocks" ')

    def test_alarm_clock_no_longer_installed_or_started(self):
        text = setup_extract.setup_text()
        self.assertNotRegex(text, r'(?m)^\s*install_pkg "alarm-clock-applet"')
        self.assertNotIn("alarm-clock-applet --hidden", text)
        self.assertNotIn("alarm_clock_launcher", text)

    def test_the_installed_launcher_is_searchable_as_is(self):
        # setup.sh writes no keyword copy for GNOME Clocks because the package
        # already lists these; this checks that claim against the real file.
        installed = "/usr/share/applications/org.gnome.clocks.desktop"
        if not os.path.exists(installed):
            self.skipTest("gnome-clocks is not installed here")
        with open(installed) as f:
            keywords = re.search(r"(?m)^Keywords=(.*)$", f.read())
        self.assertIsNotNone(keywords)
        terms = keywords.group(1).split(";")
        for term in ("alarm", "timer", "stopwatch"):
            self.assertIn(term, terms)


if __name__ == "__main__":
    unittest.main()
