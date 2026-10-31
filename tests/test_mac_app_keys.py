"""mac-app-keys, which gives keyd the per-app bindings in app.conf for the app
in front: reading app.conf, choosing an app's bindings, calling keyd, the
single-instance lock, and the app.conf setup.sh writes. The X event loop needs
a display, so it is checked by hand, not here.

    python3 -m unittest discover -s tests
"""
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import setup_extract  # noqa: E402

SOURCE = setup_extract.heredoc(r"^sudo tee \"\$MAC_APP_KEYS\" > /dev/null << 'MACAPPKEYS'$", "MACAPPKEYS")
AK = types.ModuleType("mac_app_keys")
exec(compile(SOURCE, "mac-app-keys", "exec"), AK.__dict__)


def stub(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)
    return path


class Naming(unittest.TestCase):
    def test_normalize_class(self):
        self.assertEqual(AK.normalize_class("Xfce4-terminal"), "xfce4-terminal")
        self.assertEqual(AK.normalize_class("libreoffice-writer"), "libreoffice-writer")
        self.assertEqual(AK.normalize_class("Google Chrome"), "google-chrome")
        self.assertEqual(AK.normalize_class("..Odd__Name.."), "odd-name")
        self.assertEqual(AK.normalize_class(""), "")


class ParseConfig(unittest.TestCase):
    def test_sections_in_order(self):
        sections, problems = AK.parse_config(
            "# top\n\n[xfce4-terminal]\ncmd.c = C-S-c\n  # note\ncmd.v = C-S-v\n[thunar]\ncmd.up = A-up\n")
        self.assertEqual(sections, [("xfce4-terminal", ["cmd.c = C-S-c", "cmd.v = C-S-v"]),
                                    ("thunar", ["cmd.up = A-up"])])
        self.assertEqual(problems, [])

    def test_title_sections_are_skipped_with_a_reason(self):
        sections, problems = AK.parse_config("[firefox|*Gmail*]\ncmd.k = C-k\n[thunar]\na = b\n")
        self.assertEqual(sections, [("thunar", ["a = b"])])
        self.assertEqual(len(problems), 1)
        self.assertIn("title", problems[0])

    def test_binding_before_any_section(self):
        sections, problems = AK.parse_config("cmd.c = C-S-c\n[thunar]\n")
        self.assertEqual(sections, [("thunar", [])])
        self.assertIn("line 1", problems[0])

    def test_empty(self):
        self.assertEqual(AK.parse_config(""), ([], []))


class Choosing(unittest.TestCase):
    SECTIONS = [("xfce4-terminal", ["a = 1"]), ("libreoffice*", ["b = 2"]),
                ("*", ["c = 3"]), ("thunar", ["d = 4"])]

    def test_globs_and_order(self):
        self.assertEqual(AK.bindings_for(self.SECTIONS, "libreoffice-writer"), ["b = 2", "c = 3"])
        self.assertEqual(AK.bindings_for(self.SECTIONS, "xfce4-terminal"), ["a = 1", "c = 3"])

    def test_case_matters(self):
        # classes are lowercased before matching, so an uppercase section never matches
        self.assertEqual(AK.bindings_for([("Thunar", ["x = y"])], "thunar"), [])

    def test_no_app_in_front(self):
        self.assertEqual(AK.bindings_for([("thunar", ["x = y"])], ""), [])


class WrittenAppConf(unittest.TestCase):
    """The app.conf setup.sh writes, as mac-app-keys reads it."""

    @classmethod
    def setUpClass(cls):
        cls.sections, cls.problems = AK.parse_config(setup_extract.app_conf())

    def bindings(self, app_class):
        return AK.bindings_for(self.sections, app_class)

    def test_reads_cleanly(self):
        self.assertEqual(self.problems, [])

    def test_terminal(self):
        terminal = self.bindings("xfce4-terminal")
        self.assertIn("cmd.c = C-S-c", terminal)
        self.assertIn("cmd.backspace = C-u", terminal)
        # Cmd+Tab is the terminal's own Ctrl+Tab key now, not a per-app binding
        self.assertFalse([b for b in terminal if b.startswith("cmd.tab")])
        self.assertIn("cmd+shift.rightbrace = C-tab", terminal)

    def test_only_xfce4_terminal_gets_terminal_keys(self):
        self.assertEqual(self.bindings("gnome-terminal"), [])

    def test_files_hidden_files(self):
        self.assertIn("cmd+shift.dot = C-h", self.bindings("thunar"))

    def test_other_apps(self):
        self.assertIn("cmd.semicolon = f7", self.bindings("libreoffice-calc"))
        self.assertEqual(self.bindings("mousepad"), [])


class KeydCalls(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "calls")

    def keyd(self, exit_code=0):
        path = stub(self.dir, "keyd", f'echo "$*" >> "{self.log}"\nexit {exit_code}')
        return AK.Keyd([path])

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def test_applies_then_skips_a_repeat(self):
        keyd = self.keyd()
        self.assertTrue(keyd.apply(["cmd.c = C-S-c"]))
        self.assertTrue(keyd.apply(["cmd.c = C-S-c"]))
        self.assertEqual(self.calls(), ["bind reset cmd.c = C-S-c"])

    def test_force_applies_again(self):
        keyd = self.keyd()
        keyd.apply(["a = b"])
        keyd.apply(["a = b"], force=True)
        self.assertEqual(len(self.calls()), 2)

    def test_switching_to_an_app_without_keys_resets(self):
        keyd = self.keyd()
        keyd.apply(["a = b"])
        keyd.apply([])
        self.assertEqual(self.calls(), ["bind reset a = b", "bind reset"])

    def test_failure_is_retried(self):
        keyd = self.keyd(exit_code=1)
        self.assertFalse(keyd.apply(["a = b"]))
        self.assertFalse(keyd.apply(["a = b"]))
        self.assertEqual(len(self.calls()), 2)

    def test_missing_keyd(self):
        keyd = AK.Keyd([os.path.join(self.dir, "nowhere")])
        self.assertFalse(keyd.apply(["a = b"]))

    def test_finds_debians_name_first(self):
        stub(self.dir, "keyd", "")
        stub(self.dir, "keyd.rvaiya", "")
        old = os.environ["PATH"]
        try:
            os.environ["PATH"] = self.dir
            self.assertEqual(AK.keyd_command(), [os.path.join(self.dir, "keyd.rvaiya")])
            os.remove(os.path.join(self.dir, "keyd.rvaiya"))
            self.assertEqual(AK.keyd_command(), [os.path.join(self.dir, "keyd")])
            os.remove(os.path.join(self.dir, "keyd"))
            self.assertIsNone(AK.keyd_command())
        finally:
            os.environ["PATH"] = old


class ConfigReload(unittest.TestCase):
    def test_reads_again_after_a_change(self):
        path = os.path.join(tempfile.mkdtemp(), "app.conf")
        config = AK.Config(path)
        self.assertEqual(config.current(), [])
        with open(path, "w") as f:
            f.write("[thunar]\na = b\n")
        self.assertEqual(config.current(), [("thunar", ["a = b"])])
        with open(path, "w") as f:
            f.write("[thunar]\na = bc\n")  # a different size, even within the same mtime tick
        self.assertEqual(config.current(), [("thunar", ["a = bc"])])
        os.remove(path)
        self.assertEqual(config.current(), [])


class SingleInstance(unittest.TestCase):
    def test_second_copy_is_refused(self):
        path = os.path.join(tempfile.mkdtemp(), "mac-app-keys.pid")
        first = AK.take_lock(path)
        self.assertIsNotNone(first)
        with open(path) as f:
            self.assertEqual(f.read(), f"{os.getpid()}\n")
        self.assertIsNone(AK.take_lock(path))
        os.close(first)
        second = AK.take_lock(path)
        self.assertIsNotNone(second)
        os.close(second)


class CommandLine(unittest.TestCase):
    def run_cli(self, *args, conf="[thunar]\ncmd.up = A-up\n"):
        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, ".config/keyd"))
        with open(os.path.join(home, ".config/keyd/app.conf"), "w") as f:
            f.write(conf)
        script = os.path.join(home, "mac-app-keys")
        with open(script, "w") as f:
            f.write(SOURCE)
        return subprocess.run([sys.executable, script, *args], env=dict(os.environ, HOME=home),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)

    def test_show(self):
        result = self.run_cli("--show", "thunar")
        self.assertEqual((result.returncode, result.stdout), (0, "cmd.up = A-up\n"))

    def test_bad_usage(self):
        for args in (("--show",), ("--show", "a", "b"), ("thunar",)):
            self.assertEqual(self.run_cli(*args).returncode, 2)


class Installed(unittest.TestCase):
    def test_started_at_login_from_the_installed_path(self):
        body = setup_extract.heredoc(r'^cat > ".*/autostart/mac-app-keys\.desktop" << APP_KEYS_AUTOSTART$',
                                     "APP_KEYS_AUTOSTART")
        self.assertIn("Exec=$MAC_APP_KEYS\n", body)

    def test_keyds_mapper_is_no_longer_fetched(self):
        self.assertNotIn("raw.githubusercontent.com/rvaiya", setup_extract.setup_text())


class OldMapperLeftovers(unittest.TestCase):
    """The block that removes keyd-application-mapper's log and lock, run
    for real against a temporary home."""

    BLOCK = re.compile(r'^if \[ ! -e "\$KAM_BIN" \]; then\n.*?^fi$', re.M | re.S)

    def run_block(self, mapper_installed):
        blocks = self.BLOCK.findall(setup_extract.setup_text())
        self.assertEqual(len(blocks), 1)
        home = tempfile.mkdtemp()
        keyd = os.path.join(home, ".config/keyd")
        os.makedirs(keyd)
        for name in ("app.log", "app.lock", "app.conf"):
            open(os.path.join(keyd, name), "w").close()
        kam_bin = os.path.join(home, "keyd-application-mapper")
        if mapper_installed:
            open(kam_bin, "w").close()
        subprocess.run(["bash", "-c", f'ACTUAL_HOME="$1" KAM_BIN="$2"\n{blocks[0]}', "_", home, kam_bin],
                       check=True, timeout=30)
        return sorted(os.listdir(keyd))

    def test_removed_once_the_mapper_is_gone(self):
        self.assertEqual(self.run_block(mapper_installed=False), ["app.conf"])

    def test_kept_while_a_mapper_is_still_installed(self):
        self.assertEqual(self.run_block(mapper_installed=True), ["app.conf", "app.lock", "app.log"])


if __name__ == "__main__":
    unittest.main()
