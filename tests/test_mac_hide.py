"""mac-hide, the helper behind Cmd+H and Cmd+Option+H: which windows it
picks, how it reads xprop, a full run against stub X tools, and that the keys
keyd emits are the ones XFCE binds to it.

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
import keyd_validate  # noqa: E402
import setup_extract  # noqa: E402

SOURCE = setup_extract.heredoc(r"^sudo tee \"\$MAC_HIDE\" > /dev/null << 'MACHIDE'$", "MACHIDE")
HIDE = types.ModuleType("mac_hide")
exec(compile(SOURCE, "mac-hide", "exec"), HIDE.__dict__)

# xprop output as XFCE 4.20 / xfwm4 reports it (seen on a MacBook Air 7,2)
TERMINAL = """_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL
_NET_WM_DESKTOP(CARDINAL) = 0
WM_CLASS(STRING) = "xfce4-terminal", "Xfce4-terminal"
_NET_WM_STATE(ATOM) = _NET_WM_STATE_MAXIMIZED_HORZ, _NET_WM_STATE_MAXIMIZED_VERT
"""
PANEL = """_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_DOCK
_NET_WM_DESKTOP(CARDINAL) = 4294967295
WM_CLASS(STRING) = "xfce4-panel", "Xfce4-panel"
_NET_WM_STATE(ATOM) = _NET_WM_STATE_STICKY, _NET_WM_STATE_SKIP_PAGER, _NET_WM_STATE_SKIP_TASKBAR
"""
UNTYPED = """_NET_WM_WINDOW_TYPE:  not found.
_NET_WM_DESKTOP(CARDINAL) = 1
WM_CLASS:  not found.
_NET_WM_STATE(ATOM) = _NET_WM_STATE_HIDDEN
"""


def win(wid, wm_class, desktop=0, normal=True, hidden=False):
    return {"id": wid, "wm_class": wm_class, "desktop": desktop, "normal": normal, "hidden": hidden}


TERM, BROWSER = ("xfce4-terminal", "Xfce4-terminal"), ("chromium", "Chromium")
DESK = [win(1, ("xfce4-panel", "Xfce4-panel"), HIDE.ALL_DESKTOPS, normal=False),
        win(2, ("xfdesktop", "Xfdesktop"), HIDE.ALL_DESKTOPS, normal=False),
        win(10, TERM), win(11, TERM), win(20, BROWSER)]


class Parsing(unittest.TestCase):
    def test_window_ids(self):
        self.assertEqual(HIDE.window_ids("_NET_CLIENT_LIST(WINDOW): window id # 0x1000003, 0xe00042\n"),
                         [0x1000003, 0xE00042])
        self.assertEqual(HIDE.window_ids("_NET_ACTIVE_WINDOW(WINDOW): window id # 0x3c05e5b, 0x0\n")[0],
                         0x3C05E5B)
        self.assertEqual(HIDE.window_ids("_NET_CLIENT_LIST:  not found.\n"), [])

    def test_normal_window(self):
        self.assertEqual(HIDE.window_info(7, TERMINAL), win(7, TERM))

    def test_panel_is_not_normal(self):
        info = HIDE.window_info(1, PANEL)
        self.assertFalse(info["normal"])
        self.assertEqual(info["desktop"], HIDE.ALL_DESKTOPS)

    def test_missing_properties(self):
        # EWMH: no type means normal; no class or desktop stays unknown
        self.assertEqual(HIDE.window_info(3, UNTYPED), win(3, None, 1, hidden=True))

    def test_quoted_class(self):
        info = HIDE.window_info(4, 'WM_CLASS(STRING) = "say \\"hi\\"", "App, Inc"\n')
        self.assertEqual(info["wm_class"], ('say \\"hi\\"', "App, Inc"))


class Choosing(unittest.TestCase):
    def test_hide_front_app_takes_all_its_windows(self):
        self.assertEqual(HIDE.to_hide(DESK, 10, "app"), [10, 11])

    def test_hide_others_keeps_the_front_app(self):
        self.assertEqual(HIDE.to_hide(DESK, 11, "others"), [20])

    def test_panels_and_desktop_never(self):
        for mode in ("app", "others"):
            for front in (10, 20):
                self.assertFalse({1, 2} & set(HIDE.to_hide(DESK, front, mode)))

    def test_desktop_focused_does_nothing(self):
        # Clicking the desktop makes it active; Cmd+H then must not hide everything
        for active in (2, 0, 999):
            self.assertEqual(HIDE.to_hide(DESK, active, "others"), [])

    def test_other_desktops_untouched(self):
        windows = DESK + [win(30, BROWSER, desktop=1), win(31, TERM, desktop=1)]
        self.assertEqual(HIDE.to_hide(windows, 10, "app"), [10, 11])
        self.assertEqual(HIDE.to_hide(windows, 10, "others"), [20])

    def test_sticky_window_counts_everywhere(self):
        windows = DESK + [win(40, ("vlc", "vlc"), HIDE.ALL_DESKTOPS)]
        self.assertEqual(HIDE.to_hide(windows, 10, "others"), [20, 40])

    def test_already_minimized_skipped(self):
        windows = DESK + [win(12, TERM, hidden=True)]
        self.assertEqual(HIDE.to_hide(windows, 10, "app"), [10, 11])

    def test_classless_front_window_hides_only_itself(self):
        windows = DESK + [win(50, None), win(51, None)]
        self.assertEqual(HIDE.to_hide(windows, 50, "app"), [50])
        self.assertIn(51, HIDE.to_hide(windows, 50, "others"))

    def test_only_window(self):
        self.assertEqual(HIDE.to_hide([win(10, TERM)], 10, "others"), [])


STUB_XPROP = r"""#!/usr/bin/python3
import sys
a = sys.argv[1:]
if a[:2] == ["-root", "_NET_ACTIVE_WINDOW"]:
    print("_NET_ACTIVE_WINDOW(WINDOW): window id # 0xa, 0x0")
elif a[:2] == ["-root", "_NET_CLIENT_LIST"]:
    print("_NET_CLIENT_LIST(WINDOW): window id # 0x1, 0xa, 0xb, 0x14, 0x15")
elif a[:2] == ["-id", "0x15"]:
    sys.exit("X Error: BadWindow")  # closed after the list was read
else:
    print(open(__file__ + "." + a[1]).read(), end="")
"""


class FullRun(unittest.TestCase):
    """Runs the script as XFCE would, with xprop and xdotool stubbed in PATH."""

    def run_hide(self, *args):
        bindir = tempfile.mkdtemp()
        log = os.path.join(bindir, "minimized")
        stubs = {"xprop": STUB_XPROP,
                 "xdotool": f'#!/bin/sh\necho "$@" >> "{log}"\n'}
        for name, text in stubs.items():
            with open(os.path.join(bindir, name), "w") as f:
                f.write(text)
            os.chmod(os.path.join(bindir, name), 0o755)
        browser = TERMINAL.replace('"xfce4-terminal", "Xfce4-terminal"', '"chromium", "Chromium"')
        for wid, text in (("0x1", PANEL), ("0xa", TERMINAL), ("0xb", TERMINAL), ("0x14", browser)):
            with open(os.path.join(bindir, "xprop." + wid), "w") as f:
                f.write(text)
        script = os.path.join(bindir, "mac-hide")
        with open(script, "w") as f:
            f.write(SOURCE)
        env = dict(os.environ, PATH=bindir + ":/usr/bin:/bin")
        result = subprocess.run([sys.executable, script, *args], env=env, capture_output=True, text=True)
        minimized = []
        if os.path.exists(log):
            with open(log) as f:
                minimized = f.read().split("\n")[:-1]
        return result, minimized

    def test_hide_app(self):
        result, minimized = self.run_hide("app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(minimized, ["windowminimize 10", "windowminimize 11"])

    def test_hide_others(self):
        result, minimized = self.run_hide("others")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(minimized, ["windowminimize 20"])

    def test_dry_run_touches_nothing(self):
        result, minimized = self.run_hide("others", "--dry-run")
        self.assertEqual((result.stdout, minimized), ("0x14\n", []))

    def test_bad_usage(self):
        for args in ((), ("all",), ("app", "others")):
            result, minimized = self.run_hide(*args)
            self.assertEqual((result.returncode, minimized), (2, []))


def xfce_key(keyd_combo):
    """keyd's M-S-h -> XFCE's <Super><Shift>h."""
    names = {"M": "<Super>", "S": "<Shift>", "A": "<Alt>", "C": "<Primary>"}
    *mods, key = keyd_combo.split("-")
    return "".join(names[m] for m in mods) + key


class KeysReachTheHelper(unittest.TestCase):
    """keyd emits a combo; XFCE must bind exactly that combo to mac-hide."""

    def bindings(self):
        text = setup_extract.setup_text()
        return dict(re.findall(r"-p '/commands/custom/([^']+)' -s \"\$MAC_HIDE (\w+)\"", text))

    def emitted(self, layer, key):
        section = None
        for line in setup_extract.keyd_config().split("\n"):
            if line.startswith("["):
                section = line.strip("[]").split(":")[0]
            elif section == layer and line.split("=")[0].strip() == key:
                return line.split("=", 1)[1].strip()
        self.fail(f"{layer}.{key} not in the keyd config")

    def test_cmd_h_hides_the_app(self):
        self.assertEqual(self.bindings().get(xfce_key(self.emitted("cmd", "h"))), "app")

    def test_cmd_option_h_hides_others(self):
        self.assertEqual(self.bindings().get(xfce_key(self.emitted("cmd+option", "h"))), "others")

    def test_cmd_option_m_minimizes_the_app(self):
        self.assertEqual(self.bindings().get(xfce_key(self.emitted("cmd+option", "m"))), "app")

    def test_fn_f11_shows_the_desktop(self):
        # Same combo as Cmd+F3, which XFCE binds to show_desktop_key by default
        self.assertEqual(self.emitted("main", "f11"), self.emitted("cmd", "scale"))
        self.assertIn("f11", keyd_validate.known_keys())


if __name__ == "__main__":
    unittest.main()
