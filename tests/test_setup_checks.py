"""setup.sh's "already done" checks must test the goal, not just that a file
exists or a word appears in it. Each function is pulled out of setup.sh and
run in bash against real files in a temporary directory, with sudo stubbed to
run the command as the test user, so nothing outside that directory changes.

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

# Stand-ins for the helpers the functions call
PRELUDE = r'''
sudo() { "$@"; }
print_ok()   { echo "OK: $1"; }
print_skip() { echo "SKIP: $1"; }
print_fail() { echo "FAIL: $1"; }
FAILED=()
'''


def function(name):
    """The body of `name() {` ... `}` from setup.sh, exactly once."""
    lines = setup_extract.setup_text().split("\n")
    starts = [i for i, line in enumerate(lines) if line == f"{name}() {{"]
    if len(starts) != 1:
        raise LookupError(f"{len(starts)} definitions of {name} in setup.sh")
    end = lines.index("}", starts[0])
    return "\n".join(lines[starts[0]:end + 1]) + "\n"


def run(script, *args):
    """Run setup.sh functions plus script; returns (rc, stdout)."""
    code = PRELUDE + "".join(function(f) for f in ("ensure_file", "vscode_source_ok", "grub_has_s2idle"))
    r = subprocess.run(["bash", "-c", code + script, "_", *args],
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout


class EnsureFile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.path = os.path.join(self.dir, "etc", "thing.conf")

    def ensure(self, content="a\nb"):
        return run('ensure_file "$1" "$2" label; rc=$?; echo "rc=$rc failed=${#FAILED[@]}"',
                   self.path, content)

    def read(self):
        with open(self.path) as f:
            return f.read()

    def test_missing_file_is_written(self):
        rc, out = self.ensure()
        self.assertIn("OK: label", out)
        self.assertIn("rc=0 failed=0", out)
        self.assertEqual(self.read(), "a\nb\n")

    def test_matching_file_is_left_alone(self):
        self.ensure()
        before = os.stat(self.path).st_mtime_ns
        _, out = self.ensure()
        self.assertIn("SKIP: label", out)
        self.assertIn("rc=1", out)
        self.assertEqual(os.stat(self.path).st_mtime_ns, before)

    def test_edited_file_is_rewritten_not_reported_done(self):
        self.ensure()
        with open(self.path, "w") as f:
            f.write("a\nsomething else\n")
        _, out = self.ensure()
        self.assertIn("OK: label", out)
        self.assertEqual(self.read(), "a\nb\n")

    def test_empty_file_is_rewritten(self):
        # what a download or write cut short leaves behind
        os.makedirs(os.path.dirname(self.path))
        open(self.path, "w").close()
        _, out = self.ensure()
        self.assertIn("OK: label", out)
        self.assertEqual(self.read(), "a\nb\n")

    def test_failed_write_is_a_failure(self):
        os.makedirs(os.path.dirname(self.path))
        os.chmod(os.path.dirname(self.path), 0o500)
        self.addCleanup(os.chmod, os.path.dirname(self.path), 0o700)
        if os.access(os.path.dirname(self.path), os.W_OK):
            self.skipTest("running as root: a read-only directory is still writable")
        _, out = self.ensure()
        self.assertIn("FAIL: label", out)
        self.assertNotIn("OK: label", out)
        self.assertIn("rc=2 failed=1", out)


class VscodeSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        home = os.path.join(cls.dir, "gnupg")
        os.mkdir(home, 0o700)
        env = dict(os.environ, GNUPGHOME=home)
        subprocess.run(["gpg", "--batch", "--passphrase", "", "--quick-gen-key",
                        "test <test@example.invalid>", "ed25519", "sign", "never"],
                       env=env, check=True, capture_output=True, timeout=60)
        cls.key = os.path.join(cls.dir, "valid.gpg")
        with open(cls.key, "wb") as f:
            f.write(subprocess.run(["gpg", "--export"], env=env, check=True,
                                   capture_output=True, timeout=60).stdout)
        cls.empty = os.path.join(cls.dir, "empty.gpg")
        open(cls.empty, "w").close()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def check(self, text):
        path = os.path.join(self.dir, "vscode.list")
        if text is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            with open(path, "w") as f:
                f.write(text)
        return run('if vscode_source_ok "$1"; then echo true; else echo false; fi', path)[1].strip()

    def line(self, keyring, repo="https://packages.microsoft.com/repos/code"):
        return f"deb [arch=amd64,arm64,armhf signed-by={keyring}] {repo} stable main\n"

    def test_valid_key_passes(self):
        self.assertEqual(self.check(self.line(self.key)), "true")

    def test_another_keyring_path_passes_if_valid(self):
        # VS Code's own package writes its own keyring path: that is fine
        other = os.path.join(self.dir, "microsoft.gpg")
        shutil.copy(self.key, other)
        self.assertEqual(self.check(self.line(other)), "true")

    def test_empty_or_missing_key_fails(self):
        self.assertEqual(self.check(self.line(self.empty)), "false")
        self.assertEqual(self.check(self.line(os.path.join(self.dir, "nope.gpg"))), "false")

    def test_no_source_or_wrong_repo_or_no_key_fails(self):
        self.assertEqual(self.check(None), "false")
        self.assertEqual(self.check(self.line(self.key, "https://example.com/other")), "false")
        self.assertEqual(self.check("deb https://packages.microsoft.com/repos/code stable main\n"), "false")


class GrubS2idle(unittest.TestCase):
    def check(self, text):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        path = os.path.join(d, "grub")
        if text is not None:
            with open(path, "w") as f:
                f.write(text)
        return run('if grub_has_s2idle "$1"; then echo true; else echo false; fi', path)[1].strip()

    def test_active_default_line(self):
        self.assertEqual(self.check('GRUB_CMDLINE_LINUX_DEFAULT="quiet mem_sleep_default=s2idle"\n'), "true")
        self.assertEqual(self.check('GRUB_CMDLINE_LINUX_DEFAULT="mem_sleep_default=s2idle quiet"\n'), "true")

    def test_comment_other_variable_or_lookalike_does_not_count(self):
        self.assertEqual(self.check('#GRUB_CMDLINE_LINUX_DEFAULT="quiet mem_sleep_default=s2idle"\n'
                                    'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n'), "false")
        self.assertEqual(self.check('GRUB_CMDLINE_LINUX="mem_sleep_default=s2idle"\n'
                                    'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n'), "false")
        self.assertEqual(self.check('GRUB_CMDLINE_LINUX_DEFAULT="mem_sleep_default=s2idlex"\n'), "false")

    def test_missing_file(self):
        self.assertEqual(self.check(None), "false")


class NoExistenceOnlyChecks(unittest.TestCase):
    """The files setup.sh owns are checked by content, not by existence."""

    def test_owned_files_go_through_ensure_file(self):
        text = setup_extract.setup_text()
        for path in ("$BLACKLIST_FILE", "/etc/modules-load.d/broadcom.conf", "$UU_EXTRA",
                     "$ACPOWER_OVERRIDE_FILE", "/etc/modules-load.d/facetimehd.conf",
                     "/etc/modprobe.d/alsa-base.conf"):
            with self.subTest(path=path):
                self.assertIn(f'ensure_file {path if path.startswith("/") else chr(34) + path + chr(34)} ', text)
                self.assertNotRegex(text, re.escape(f'[ ! -f "{path}" ]'))


if __name__ == "__main__":
    unittest.main()
