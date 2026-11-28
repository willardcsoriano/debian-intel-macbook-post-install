"""fix_desktop_launchers: the per-user launcher copies without the %F/%U
placeholder that the App Finder needs. Run in bash against temporary
launcher directories.

    python3 -m unittest discover -s tests -p test_launcher_fix.py
"""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import setup_extract  # noqa: E402

TEXT = setup_extract.setup_text()
MARKER_LINE = re.search(r"(?m)^LAUNCHER_FIX_MARKER=.*$", TEXT).group(0)
MARKER = re.search(r'^LAUNCHER_FIX_MARKER="(.*)"$', MARKER_LINE).group(1)
FUNCTION = re.search(r"(?ms)^fix_desktop_launchers\(\) \{\n.*?^\}\n", TEXT).group(0)
PRELUDE = r'''
FAILED=()
print_ok() { echo "ok: $1"; }
print_skip() { echo "skip: $1"; }
print_fail() { echo "fail: $1"; }
print_info() { echo "info: $1"; }
update-desktop-database() { :; }
'''

VIEWER = "[Desktop Entry]\nName=Viewer\nExec=viewer %F\nType=Application\n"
VIEWER_FIXED = "[Desktop Entry]\n" + MARKER + "\nName=Viewer\nExec=viewer\nType=Application\n"
PLAIN = "[Desktop Entry]\nName=Plain\nExec=plain\nType=Application\n"


class FixDesktopLaunchers(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(self.cleanup)
        self.system = os.path.join(self.dir, "usr")
        self.local = os.path.join(self.dir, "home", "applications")
        os.makedirs(self.system)

    def cleanup(self):
        for root, dirs, _ in os.walk(self.dir):
            for d in dirs:
                os.chmod(os.path.join(root, d), 0o755)
        shutil.rmtree(self.dir, ignore_errors=True)

    def put(self, directory, name, text):
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, name), "w") as f:
            f.write(text)

    def read(self, name):
        with open(os.path.join(self.local, name)) as f:
            return f.read()

    def fix(self):
        script = PRELUDE + MARKER_LINE + "\n" + FUNCTION + \
            'fix_desktop_launchers "$1" "$2"; echo "failed=${#FAILED[@]}"'
        r = subprocess.run(["bash", "-c", script, "_", self.system, self.local],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.stderr, "", "nothing may reach the terminal unformatted")
        return r.stdout

    def test_writes_a_marked_copy_without_the_placeholder(self):
        self.put(self.system, "viewer.desktop", VIEWER)
        self.put(self.system, "plain.desktop", PLAIN)
        out = self.fix()
        self.assertIn("ok: Fixed 1 app launcher(s)", out)
        self.assertEqual(self.read("viewer.desktop"), VIEWER_FIXED)
        self.assertFalse(os.path.exists(os.path.join(self.local, "plain.desktop")))

    def test_second_run_changes_nothing(self):
        self.put(self.system, "viewer.desktop", VIEWER)
        self.fix()
        out = self.fix()
        self.assertIn("skip: App launcher fix (1 launcher(s) already fixed)", out)
        self.assertNotIn("ok:", out)

    def test_follows_a_package_update(self):
        self.put(self.system, "viewer.desktop", VIEWER)
        self.fix()
        self.put(self.system, "viewer.desktop", VIEWER.replace("Name=Viewer", "Name=Viewer 2"))
        self.assertIn("ok: Fixed 1", self.fix())
        self.assertIn("Name=Viewer 2", self.read("viewer.desktop"))

    def test_adopts_the_unmarked_copy_earlier_versions_wrote(self):
        self.put(self.system, "viewer.desktop", VIEWER)
        self.put(self.local, "viewer.desktop", VIEWER.replace(" %F", ""))
        self.assertIn("ok: Fixed 1", self.fix())
        self.assertEqual(self.read("viewer.desktop"), VIEWER_FIXED)

    def test_leaves_a_launcher_it_did_not_write(self):
        mine = VIEWER.replace("Name=Viewer", "Name=My Viewer")
        self.put(self.system, "viewer.desktop", VIEWER)
        self.put(self.local, "viewer.desktop", mine)
        out = self.fix()
        self.assertIn("info: Left 1 launcher(s)", out)
        self.assertIn("failed=0", out)
        self.assertEqual(self.read("viewer.desktop"), mine)

    def test_a_read_only_launcher_it_did_not_write_is_left_without_an_error(self):
        # The case that printed "Permission denied": an installer left a
        # root-owned copy, still with its placeholder, in the user's folder.
        theirs = VIEWER.replace("Name=Viewer", "Name=Installed Viewer")
        self.put(self.system, "viewer.desktop", VIEWER)
        self.put(self.local, "viewer.desktop", theirs)
        os.chmod(os.path.join(self.local, "viewer.desktop"), stat.S_IRUSR)
        out = self.fix()  # asserts empty stderr
        self.assertIn("info: Left 1 launcher(s)", out)
        self.assertIn("failed=0", out)

    def test_an_unreadable_launcher_it_did_not_write_is_left_without_an_error(self):
        if os.geteuid() == 0:
            self.skipTest("root reads any file")
        self.put(self.system, "viewer.desktop", VIEWER)
        self.put(self.local, "viewer.desktop", "[Desktop Entry]\nExec=x\n")
        self.put(self.local, "other.desktop", "[Desktop Entry]\nExec=y\n")
        for name in ("viewer.desktop", "other.desktop"):
            os.chmod(os.path.join(self.local, name), 0)
        out = self.fix()  # asserts empty stderr
        self.assertIn("info: Left 1 launcher(s)", out)
        self.assertIn("failed=0", out)

    def test_removes_its_copy_once_the_app_is_gone_or_fixed_upstream(self):
        self.put(self.system, "viewer.desktop", VIEWER)
        self.put(self.system, "editor.desktop", VIEWER.replace("viewer", "editor"))
        self.fix()
        os.remove(os.path.join(self.system, "viewer.desktop"))
        self.put(self.system, "editor.desktop", PLAIN)
        out = self.fix()
        self.assertIn("ok: Removed 2 launcher fix(es)", out)
        self.assertEqual(os.listdir(self.local), [])

    def test_never_removes_other_managed_or_unmarked_files(self):
        self.put(self.local, "xfce4-terminal.desktop",
                 "[Desktop Entry]\n# Managed by debian-intel-macbook-post-install -- re-running setup.sh rewrites it.\n")
        self.put(self.local, "custom.desktop", PLAIN)
        self.fix()
        self.assertEqual(sorted(os.listdir(self.local)), ["custom.desktop", "xfce4-terminal.desktop"])

    def test_a_failed_write_is_a_failure_not_a_fix(self):
        if os.geteuid() == 0:
            self.skipTest("root ignores directory permissions")
        self.put(self.system, "viewer.desktop", VIEWER)
        os.makedirs(self.local)
        os.chmod(self.local, stat.S_IRUSR | stat.S_IXUSR)
        out = self.fix()
        self.assertIn("fail: App launcher fix (1 could not be written", out)
        self.assertIn("failed=1", out)
        self.assertNotIn("ok: Fixed", out)

    def test_called_on_the_users_launcher_folder(self):
        self.assertIn('fix_desktop_launchers /usr/share/applications "$ACTUAL_HOME/.local/share/applications"', TEXT)


if __name__ == "__main__":
    unittest.main()
