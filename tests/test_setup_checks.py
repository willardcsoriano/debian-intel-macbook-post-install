"""setup.sh's "already done" checks must test the goal, not just that a file
exists or a word appears in it. Each function is pulled out of setup.sh and
run in bash against real files in a temporary directory, with sudo stubbed to
run the command as the test user, so nothing outside that directory changes.

    python3 -m unittest discover -s tests
"""
import os
import re
import shlex
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
print_info() { echo "INFO: $1"; }
FAILED=()
LOG_FILE=/dev/null
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
    code = PRELUDE + "".join(function(f) for f in ("ensure_file", "vscode_source_ok", "grub_has_s2idle", "upower_time_policy",
                                                  "sleep_keeps_sessions_unfrozen", "managed_launcher",
                                                  "install_sleep_action"))
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


class UpowerTimePolicy(unittest.TestCase):
    """Debian's UPower.conf as shipped, and the shapes it can drift into."""

    DEBIAN = ("[UPower]\nEnableWattsUpPro=false\nNoPollBatteries=false\nIgnoreLid=false\n"
              "UsePercentageForPolicy=true\nPercentageLow=20.0\nPercentageCritical=5.0\n"
              "PercentageAction=2.0\nTimeLow=1200\nTimeCritical=300\nTimeAction=120\n"
              "AllowRiskyCriticalPowerAction=false\nCriticalPowerAction=HybridSleep\n")

    def apply(self, text):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        path = os.path.join(d, "UPower.conf")
        if text is not None:
            with open(path, "w") as f:
                f.write(text)
        rc = run('upower_time_policy "$1"; echo "rc=$?"', path)[1].strip()
        after = open(path).read() if os.path.exists(path) else None
        return rc, after

    def test_debian_default_is_switched_and_nothing_else_changes(self):
        rc, after = self.apply(self.DEBIAN)
        self.assertEqual(rc, "rc=0")
        self.assertEqual(after, self.DEBIAN.replace("UsePercentageForPolicy=true", "UsePercentageForPolicy=false"))

    def test_already_set_is_left_alone(self):
        text = self.DEBIAN.replace("UsePercentageForPolicy=true", "UsePercentageForPolicy=false")
        self.assertEqual(self.apply(text), ("rc=1", text))

    def test_missing_line_is_added_to_the_section(self):
        rc, after = self.apply("[UPower]\nCriticalPowerAction=HybridSleep\n")
        self.assertEqual(rc, "rc=0")
        self.assertEqual(after, "[UPower]\nUsePercentageForPolicy=false\nCriticalPowerAction=HybridSleep\n")

    def test_a_comment_does_not_count_as_set(self):
        rc, after = self.apply("[UPower]\n# UsePercentageForPolicy=false\nUsePercentageForPolicy=true\n")
        self.assertEqual(rc, "rc=0")
        self.assertIn("\nUsePercentageForPolicy=false\n", after)
        self.assertNotIn("UsePercentageForPolicy=true", after)

    def test_no_section_or_no_file_fails(self):
        self.assertEqual(self.apply("CriticalPowerAction=HybridSleep\n")[0], "rc=2")
        self.assertEqual(self.apply(None), ("rc=2", None))


class SleepConf(unittest.TestCase):
    def test_hibernates_after_ten_minutes_of_s2idle(self):
        text = setup_extract.setup_text()
        m = re.search(r"ensure_file /etc/systemd/sleep\.conf \\\n\s*\$'([^']*)'", text)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1).split("\\n"),
                         ["[Sleep]", "AllowSuspendThenHibernate=yes", "HibernateDelaySec=10min",
                          "MemorySleepMode=s2idle"])


class SleepKeepsSessionsUnfrozen(unittest.TestCase):
    """Issue #65: systemd's user.slice freeze deadlocked on the document
    portal, so every unit that runs systemd-sleep gets a drop-in that skips it."""

    DROPIN = "[Service]\nEnvironment=SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=0\n"

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = os.path.join(self.dir, "lib")
        self.etc = os.path.join(self.dir, "etc")
        os.mkdir(self.src)

    def unit(self, name, execstart):
        with open(os.path.join(self.src, name), "w") as f:
            f.write(f"[Unit]\nDescription=x\n\n[Service]\nType=oneshot\nExecStart={execstart}\n")

    def apply(self):
        return run('sleep_keeps_sessions_unfrozen "$1" "$2"; echo "rc=$? failed=${#FAILED[@]}"',
                   self.src, self.etc)[1]

    def dropins(self):
        found = {}
        for root, _, files in os.walk(self.etc):
            for name in files:
                with open(os.path.join(root, name)) as f:
                    found[os.path.relpath(os.path.join(root, name), self.etc)] = f.read()
        return found

    def test_every_sleep_unit_gets_the_dropin_and_nothing_else_does(self):
        self.unit("systemd-suspend.service", "/usr/lib/systemd/systemd-sleep suspend")
        self.unit("systemd-suspend-then-hibernate.service",
                  "/usr/lib/systemd/systemd-sleep suspend-then-hibernate")
        self.unit("systemd-logind.service", "/usr/lib/systemd/systemd-logind")
        self.unit("sleep-lookalike.service", "/usr/bin/echo systemd-sleep suspend")
        out = self.apply()
        self.assertIn("rc=0 failed=0", out)
        self.assertEqual(self.dropins(), {
            "systemd-suspend.service.d/10-no-session-freeze.conf": self.DROPIN,
            "systemd-suspend-then-hibernate.service.d/10-no-session-freeze.conf": self.DROPIN,
        })

    def test_second_run_changes_nothing_and_says_so(self):
        self.unit("systemd-suspend.service", "/usr/lib/systemd/systemd-sleep suspend")
        self.apply()
        self.assertIn("rc=1 failed=0", self.apply())

    def test_one_missing_dropin_is_restored(self):
        self.unit("systemd-suspend.service", "/usr/lib/systemd/systemd-sleep suspend")
        self.unit("systemd-hibernate.service", "/usr/lib/systemd/systemd-sleep hibernate")
        self.apply()
        os.remove(os.path.join(self.etc, "systemd-hibernate.service.d", "10-no-session-freeze.conf"))
        self.assertIn("rc=0 failed=0", self.apply())
        self.assertEqual(len(self.dropins()), 2)

    def test_no_sleep_units_is_a_failure_not_a_silent_skip(self):
        self.unit("systemd-logind.service", "/usr/lib/systemd/systemd-logind")
        out = self.apply()
        self.assertIn("rc=2 failed=1", out)
        self.assertEqual(self.dropins(), {})

    def test_a_failed_write_wins_over_a_successful_one(self):
        self.unit("a-sleep.service", "/usr/lib/systemd/systemd-sleep suspend")
        self.unit("b-sleep.service", "/usr/lib/systemd/systemd-sleep hibernate")
        os.makedirs(self.etc)
        open(os.path.join(self.etc, "b-sleep.service.d"), "w").close()  # a file where the dir goes
        out = self.apply()
        self.assertIn("rc=2 failed=1", out)
        self.assertIn("a-sleep.service.d/10-no-session-freeze.conf", self.dropins())

    def test_this_systemd_reads_the_variable(self):
        """The switch exists in the installed systemd-sleep, not just in docs."""
        binary = "/usr/lib/systemd/systemd-sleep"
        if not os.path.exists(binary):
            self.skipTest("no systemd-sleep on this machine")
        with open(binary, "rb") as f:
            self.assertIn(b"SYSTEMD_SLEEP_FREEZE_USER_SESSIONS", f.read())

    def test_setup_applies_it_to_the_real_unit_directories(self):
        self.assertIn("sleep_keeps_sessions_unfrozen /usr/lib/systemd/system /etc/systemd/system",
                      setup_extract.setup_text())


class EnsureFileReadsAsRoot(unittest.TestCase):
    """ensure_file compares through sudo, so a file only root can read (the
    polkit rules directory is root:polkitd 0750) is still recognised as done
    instead of being rewritten on every run."""

    def test_comparison_goes_through_sudo(self):
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        path = os.path.join(directory, "rule")
        with open(path, "w") as f:
            f.write("same\n")
        calls = os.path.join(directory, "calls")
        # Only a cat run through this sudo can read the file, as with a
        # root-only directory; without sudo it reads as missing.
        script = (f'CALLS={calls}\n'
                  'sudo() { echo "$*" >> "$CALLS"; IN_SUDO=1 "$@"; }\n'
                  'cat() { case "$*" in *rule*) [ -n "${IN_SUDO:-}" ] || return 1 ;; esac; command cat "$@"; }\n')
        rc, out = run(script + 'ensure_file "$1" same label; echo "rc=$?"', path)
        self.assertIn("rc=1", out)
        with open(calls) as f:
            self.assertIn(f"cat {path}", f.read())


class ManagedLauncher(unittest.TestCase):
    """managed_launcher: per-user launcher copies (the Terminal name)."""

    GEN = ('gen() { sed "1a # Managed by debian-intel-macbook-post-install" "$1"; }\n'
           'broken() { echo partial; return 1; }\n')

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = os.path.join(self.dir, "usr", "app.desktop")
        os.makedirs(os.path.dirname(self.src))
        with open(self.src, "w") as f:
            f.write("[Desktop Entry]\nName=App\n")
        self.dest = os.path.join(self.dir, "home", ".local", "share", "applications", "app.desktop")

    def apply(self, gen="gen"):
        return run(self.GEN + f'managed_launcher {gen} "$1" "$2" label; echo "rc=$? failed=${{#FAILED[@]}}"',
                   self.src, self.dest)[1]

    def read(self):
        with open(self.dest) as f:
            return f.read()

    def test_written_into_a_missing_directory(self):
        self.assertIn("rc=0 failed=0", self.apply())
        self.assertEqual(self.read(), "[Desktop Entry]\n# Managed by debian-intel-macbook-post-install\nName=App\n")

    def test_rerun_rewrites_its_own_copy(self):
        self.apply()
        with open(self.src, "a") as f:
            f.write("Comment=new in the package\n")
        self.assertIn("rc=0", self.apply())
        self.assertIn("Comment=new in the package", self.read())

    def test_the_users_own_launcher_is_left_alone(self):
        os.makedirs(os.path.dirname(self.dest))
        with open(self.dest, "w") as f:
            f.write("[Desktop Entry]\nName=Mine\n")
        out = self.apply()
        self.assertIn("SKIP: label (you have your own", out)
        self.assertIn("rc=1 failed=0", out)
        self.assertEqual(self.read(), "[Desktop Entry]\nName=Mine\n")

    def test_missing_package_is_skipped(self):
        os.remove(self.src)
        out = self.apply()
        self.assertIn("SKIP: label (app not installed)", out)
        self.assertIn("rc=1 failed=0", out)
        self.assertFalse(os.path.exists(self.dest))

    def test_failed_write_is_reported_and_leaves_no_file(self):
        out = self.apply("broken")
        self.assertIn("FAIL: label", out)
        self.assertIn("rc=2 failed=1", out)
        self.assertFalse(os.path.exists(self.dest))
        self.assertFalse(os.path.exists(self.dest + ".tmp"))
        # so the next run writes it, rather than taking a leftover for the user's own
        self.assertIn("rc=0 failed=0", self.apply())

    def test_failed_rewrite_keeps_the_previous_copy(self):
        self.apply()
        before = self.read()
        self.assertIn("rc=2", self.apply("broken"))
        self.assertEqual(self.read(), before)


class NoExistenceOnlyChecks(unittest.TestCase):
    """The files setup.sh owns are checked by content, not by existence."""

    def test_owned_files_go_through_ensure_file(self):
        text = setup_extract.setup_text()
        for path in ("$BLACKLIST_FILE", "/etc/modules-load.d/broadcom.conf", "$UU_EXTRA", "$AUTO_UPGRADES",
                     "$ACPOWER_OVERRIDE_FILE", "/etc/modules-load.d/facetimehd.conf",
                     "/etc/modprobe.d/alsa-base.conf", "/etc/systemd/sleep.conf",
                     "/etc/polkit-1/rules.d/50-networkmanager-inactive-session.rules",
                     "/etc/systemd/logind.conf.d/10-lid.conf",
                     "/etc/polkit-1/rules.d/50-disable-hibernate.rules"):
            with self.subTest(path=path):
                self.assertIn(f'ensure_file {path if path.startswith("/") else chr(34) + path + chr(34)} ', text)
                self.assertNotRegex(text, re.escape(f'[ ! -f "{path}" ]'))


    def test_owned_files_are_not_rewritten_unchecked(self):
        text = setup_extract.setup_text()
        for path in ("/etc/polkit-1/rules.d/50-networkmanager-inactive-session.rules",
                     "/etc/systemd/logind.conf.d/10-lid.conf",
                     "/etc/polkit-1/rules.d/50-disable-hibernate.rules"):
            with self.subTest(path=path):
                self.assertNotIn(f"sudo tee {path}", text)



class InstallSleepAction(unittest.TestCase):
    """install_sleep_action: sleep hooks as units tied to sleep.target.
    systemd 257 runs hook scripts only from /usr/lib/systemd/system-sleep, so
    the old /etc/systemd/system-sleep hooks never ran."""

    SCRIPT = '#!/bin/sh\necho "$1" >> "$(dirname "$0")/ran"'
    # $T is the test directory; the stub systemctl records calls there and
    # tracks "enabled" as a file.
    STUB = r"""
SLEEP_ACTION_DIR="$T/sbin" SLEEP_UNIT_DIR="$T/units" LEGACY_SLEEP_HOOK_DIR="$T/system-sleep"
systemctl() {
    echo "systemctl $*" >> "$T/calls"
    case "$1" in
        is-enabled) [ -f "$T/enabled" ] ;;
        enable) [ -z "${ENABLE_FAILS:-}" ] && touch "$T/enabled" ;;
    esac
}
"""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.legacy = os.path.join(self.dir, "system-sleep", "act")

    def apply(self, env=""):
        return run(f'T="$1"; {env}' + self.STUB +
                   'install_sleep_action act "$2" "Label"; echo "rc=$? failed=${#FAILED[@]}"',
                   self.dir, self.SCRIPT)[1]

    def calls(self):
        try:
            with open(os.path.join(self.dir, "calls")) as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def unit(self):
        with open(os.path.join(self.dir, "units", "act.service")) as f:
            return f.read()

    def test_first_run_installs_enables_and_does_not_start(self):
        out = self.apply()
        self.assertIn("rc=0 failed=0", out)
        script = os.path.join(self.dir, "sbin", "act")
        self.assertTrue(os.access(script, os.X_OK))
        unit = self.unit()
        for line in ("Before=sleep.target", "StopWhenUnneeded=yes", "Type=oneshot", "RemainAfterExit=yes",
                     f"ExecStart={script} pre", f"ExecStop={script} post", "WantedBy=sleep.target"):
            self.assertIn(line + "\n", unit)
        calls = self.calls()
        self.assertIn("systemctl daemon-reload", calls)
        self.assertIn("systemctl enable act.service", calls)
        self.assertNotIn("--now", calls)
        self.assertNotIn("start", calls)

    def test_rerun_changes_nothing(self):
        self.apply()
        open(os.path.join(self.dir, "calls"), "w").close()
        out = self.apply()
        self.assertIn("rc=0 failed=0", out)
        self.assertNotIn("OK:", out)
        self.assertEqual(self.calls(), "systemctl is-enabled --quiet act.service\n")

    def test_lost_exec_bit_is_restored(self):
        self.apply()
        script = os.path.join(self.dir, "sbin", "act")
        os.chmod(script, 0o644)
        self.apply()
        self.assertTrue(os.access(script, os.X_OK))

    def test_old_hook_that_is_still_ours_is_removed(self):
        os.makedirs(os.path.dirname(self.legacy))
        with open(self.legacy, "w") as f:
            f.write(self.SCRIPT + "\n")
        out = self.apply()
        self.assertFalse(os.path.exists(self.legacy))
        self.assertIn("OK: Removed the unused old hook", out)

    def test_old_hook_someone_changed_is_left(self):
        os.makedirs(os.path.dirname(self.legacy))
        with open(self.legacy, "w") as f:
            f.write("#!/bin/sh\n# edited\n")
        out = self.apply()
        self.assertTrue(os.path.exists(self.legacy))
        self.assertIn("INFO: Left", out)
        self.assertIn("rc=0 failed=0", out)

    def test_failed_enable_is_a_failure_and_retried_next_run(self):
        out = self.apply("ENABLE_FAILS=1; ")
        self.assertIn("FAIL: Label (enabling act.service)", out)
        self.assertIn("rc=2 failed=1", out)
        out = self.apply()
        self.assertIn("rc=0 failed=0", out)
        self.assertIn("systemctl enable act.service", self.calls())

    def test_failed_script_write_stops_before_the_unit(self):
        os.makedirs(os.path.join(self.dir, "sbin"))
        os.chmod(os.path.join(self.dir, "sbin"), 0o555)
        self.addCleanup(os.chmod, os.path.join(self.dir, "sbin"), 0o755)
        if os.geteuid() == 0:
            self.skipTest("root can write a read-only directory")
        out = self.apply()
        self.assertIn("rc=2 failed=1", out)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "units", "act.service")))

    @unittest.skipUnless(shutil.which("systemd-analyze"), "needs systemd-analyze")
    def test_unit_passes_systemd_analyze_verify(self):
        self.apply()
        r = subprocess.run(["systemd-analyze", "verify", os.path.join(self.dir, "units", "act.service")],
                           capture_output=True, text=True, timeout=60)
        own = [l for l in r.stderr.splitlines() if "act.service" in l]
        self.assertEqual(own, [], r.stderr)

    def test_the_unit_runs_the_script_with_pre_and_post(self):
        """Run ExecStart and ExecStop exactly as written in the unit."""
        self.apply()
        for key in ("ExecStart=", "ExecStop="):
            cmd = next(l for l in self.unit().splitlines() if l.startswith(key))[len(key):]
            subprocess.run(shlex.split(cmd), check=True, timeout=30)
        with open(os.path.join(self.dir, "sbin", "ran")) as f:
            self.assertEqual(f.read(), "pre\npost\n")

    def test_setup_never_writes_into_the_unread_hook_directory(self):
        text = setup_extract.setup_text()
        self.assertNotRegex(text, r"(ensure_file|tee|cp|install) +\S*/etc/systemd/system-sleep/")
        for name, var in (("touchpad-resume", "TOUCHPAD_RESUME_HOOK"), ("kbd-backlight-suspend", "KBD_SUSPEND_HOOK")):
            with self.subTest(name=name):
                self.assertIn(f'install_sleep_action {name} "${var}" ', text)


class RebootOnlyWhenNeeded(unittest.TestCase):
    """The run asks for a reboot exactly when a change needs one."""

    def test_lid_setting_flags_a_reboot_only_when_it_changed(self):
        self.assertRegex(setup_extract.setup_text(),
                         r'if ensure_file /etc/systemd/logind\.conf\.d/10-lid\.conf "\$LOGIND_LID_CONF" "[^"]*"; then\n'
                         r'\s+REBOOT_REQUIRED=true\n')

    def test_no_unconditional_after_reboot_claims(self):
        # Every success line that promises an effect "after reboot" sits right
        # after the change that sets REBOOT_REQUIRED.
        lines = setup_extract.setup_text().split("\n")
        for i, line in enumerate(lines):
            if re.search(r'print_ok ".*after (a )?reboot', line):
                with self.subTest(line=line.strip()):
                    self.assertTrue(any("REBOOT_REQUIRED=true" in l for l in lines[max(0, i - 3):i + 3]))


class OutputWording(unittest.TestCase):
    def test_skip_and_fail_wording_fits_every_step(self):
        # Most skips are not packages ("wpa_supplicant was not active"), and
        # most failures are not installs.
        text = setup_extract.setup_text()
        helpers = "".join(re.search(rf"(?m)^{name}\(\) +\{{.*\}}$", text).group(0) + "\n"
                          for name in ("print_skip", "print_fail"))
        r = subprocess.run(["bash", "-c", helpers + 'print_skip "Thing"; print_fail "Other"'],
                           capture_output=True, text=True, timeout=30)
        out = r.stdout
        self.assertIn("⊘ Thing — already done", out)
        self.assertIn("✘ Other — failed", out)
        self.assertNotIn("already installed", out)
        self.assertNotIn("failed to install", out)


class AutomaticUpdatesSwitchedOn(unittest.TestCase):
    """The file that switches on apt's periodic timers is written by setup.sh
    itself and checked by content, so a missing one is rewritten."""

    def written(self):
        text = setup_extract.setup_text()
        path = re.search(r'(?m)^AUTO_UPGRADES="([^"]+)"$', text)
        content = re.search(r"(?m)^AUTO_UPGRADES_CONTENT=(\$'.*')$", text)
        self.assertIsNotNone(path)
        self.assertIsNotNone(content)
        # bash expands the $'...' string exactly as setup.sh does
        r = subprocess.run(["bash", "-c", "printf '%s\\n' " + content.group(1)],
                           capture_output=True, text=True, timeout=30)
        return path.group(1), r.stdout

    def test_both_timers_switched_on(self):
        path, content = self.written()
        self.assertEqual(path, "/etc/apt/apt.conf.d/20auto-upgrades")
        self.assertEqual(content.splitlines(), ['APT::Periodic::Update-Package-Lists "1";',
                                                'APT::Periodic::Unattended-Upgrade "1";'])

    def test_not_left_to_an_unchecked_dpkg_reconfigure(self):
        self.assertNotIn("dpkg-reconfigure -f noninteractive unattended-upgrades",
                         setup_extract.setup_text())

    def test_missing_file_is_written_and_a_second_run_changes_nothing(self):
        path, content = self.written()
        directory = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        target = os.path.join(directory, "apt.conf.d", "20auto-upgrades")
        script = (f"AUTO_UPGRADES={shlex.quote(target)}\n"
                  + re.search(r"(?m)^AUTO_UPGRADES_CONTENT=.*$", setup_extract.setup_text()).group(0) + "\n"
                  + 'ensure_file "$AUTO_UPGRADES" "$AUTO_UPGRADES_CONTENT" label; a=$?\n'
                  + 'ensure_file "$AUTO_UPGRADES" "$AUTO_UPGRADES_CONTENT" label; echo "$a $?"')
        _, out = run(script)
        self.assertEqual(out.splitlines()[-1], "0 1")
        with open(target) as f:
            self.assertEqual(f.read(), content)


if __name__ == "__main__":
    unittest.main()
