"""The alarm and timer app setup.sh installs (issue #63): its App Finder
launcher, built from the package's own file with search keywords added, and
the check that starts it when it isn't already running.

    python3 -m unittest discover -s tests
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

# The shape of the launcher alarm-clock-applet 0.4.1 ships: no Keywords line.
PACKAGE_LAUNCHER = """[Desktop Entry]
Name[de]=Wecker
Name=Alarm Clock
Comment=Wake up in the morning
Icon=alarm-clock
Exec=alarm-clock-applet
Terminal=false
Type=Application
Categories=GNOME;GTK;Utility;
"""

KEYWORDS = "Keywords=alarm;timer;countdown;reminder;clock;wake;"


def launcher(text):
    function = re.search(r"^alarm_clock_launcher\(\) \{\n.*?^\}\n", setup_extract.setup_text(),
                         re.S | re.M).group(0)
    directory = tempfile.mkdtemp()
    try:
        path = os.path.join(directory, "alarm-clock-applet.desktop")
        with open(path, "w") as f:
            f.write(text)
        return subprocess.run(["bash", "-c", function + 'alarm_clock_launcher "$1"', "-", path],
                              capture_output=True, text=True, check=True, timeout=30).stdout
    finally:
        shutil.rmtree(directory, ignore_errors=True)


class AlarmClockLauncher(unittest.TestCase):
    def test_keywords_make_timer_and_alarm_searchable(self):
        lines = launcher(PACKAGE_LAUNCHER).splitlines()
        self.assertIn(KEYWORDS, lines)
        terms = KEYWORDS.split("=", 1)[1].split(";")
        self.assertIn("timer", terms)
        self.assertIn("alarm", terms)

    def test_marked_as_managed_and_nothing_else_changes(self):
        lines = launcher(PACKAGE_LAUNCHER).splitlines()
        self.assertEqual(lines[0], "[Desktop Entry]")
        self.assertIn("debian-intel-macbook-post-install", lines[1])
        rest = [line for line in lines if line != KEYWORDS and "debian-intel" not in line]
        self.assertEqual(rest, PACKAGE_LAUNCHER.splitlines())

    def test_a_keywords_line_the_package_adds_later_is_replaced_not_doubled(self):
        text = PACKAGE_LAUNCHER.replace("Icon=", "Keywords=wake;\nIcon=")
        lines = launcher(text).splitlines()
        self.assertEqual([line for line in lines if line.startswith("Keywords=")], [KEYWORDS])

    def test_keywords_go_in_the_desktop_entry_group_only(self):
        text = PACKAGE_LAUNCHER + "\n[Desktop Action Stop]\nName=Stop\nExec=alarm-clock-applet --stop\n"
        out = launcher(text)
        entry, action = out.split("[Desktop Action Stop]")
        self.assertIn(KEYWORDS, entry)
        self.assertNotIn("Keywords", action)

    def test_result_is_a_valid_desktop_file(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        path = os.path.join(directory, "alarm-clock-applet.desktop")
        with open(path, "w") as f:
            f.write(launcher(PACKAGE_LAUNCHER))
        r = subprocess.run(["desktop-file-validate", path], capture_output=True, text=True, timeout=30)
        errors = [line for line in r.stdout.splitlines() if "error:" in line]
        self.assertEqual(errors, [])

    def test_the_installed_launcher(self):
        installed = "/usr/share/applications/alarm-clock-applet.desktop"
        if not os.path.exists(installed):
            self.skipTest("alarm-clock-applet is not installed here")
        with open(installed) as f:
            lines = launcher(f.read()).splitlines()
        self.assertEqual(sum(line.startswith("Keywords=") for line in lines), 1)


class AlarmClockSetup(unittest.TestCase):
    def test_installed_through_install_pkg(self):
        self.assertRegex(setup_extract.setup_text(), r'(?m)^install_pkg "alarm-clock-applet" ')

    def test_running_check_uses_the_kernel_process_name(self):
        # comm is cut to 15 characters, and pgrep -x compares against it
        names = re.findall(r'pgrep -u "\$USER" -x (\S+)', setup_extract.setup_text())
        self.assertIn("alarm-clock-applet"[:15], names)
        self.assertNotIn("alarm-clock-applet", names)


if __name__ == "__main__":
    unittest.main()
