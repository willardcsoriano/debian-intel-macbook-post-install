"""The keyboard-backlight watcher and lock-screen display sleep that setup.sh
installs: the watcher's decision for each poll, how it reads the display and
session state, and that the greeter script can never fail.

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


def load_watcher():
    source = setup_extract.heredoc(r"^    sudo tee \"\$KBD_WATCH\" > /dev/null << 'KBDWATCH'$", "KBDWATCH")
    module = types.ModuleType("kbd_backlight_follow_display")
    exec(compile(source, "kbd-backlight-follow-display", "exec"), module.__dict__)
    return module


WATCHER = load_watcher()
decide = WATCHER.decide


def run(polls, start_level):
    """Feed (display_on, user_level_or_None) polls through decide() against a
    simulated light; returns the light's level after each poll."""
    level, saved, seen = start_level, None, []
    for display_on, user_level in polls:
        if user_level is not None:
            level = user_level
        new, saved = decide(display_on, level, saved)
        if new is not None:
            level = new
        seen.append(level)
    return seen


class Decide(unittest.TestCase):
    def test_off_with_display_and_back(self):
        self.assertEqual(run([(True, None), (False, None), (False, None), (True, None)], 12),
                         [12, 0, 0, 12])

    def test_light_already_off_stays_off(self):
        self.assertEqual(run([(False, None), (True, None)], 0), [0, 0])

    def test_level_set_while_dimmed_wins(self):
        # The user raises the light on wake before the next poll: not overwritten.
        self.assertEqual(run([(False, None), (True, 40)], 12), [0, 40])

    def test_display_on_never_touches_the_light(self):
        self.assertEqual(run([(True, None), (True, 30), (True, None)], 12), [12, 30, 30])

    def test_repeated_off_cycles(self):
        polls = [(False, None), (True, None), (False, None), (True, None)]
        self.assertEqual(run(polls, 7), [0, 7, 0, 7])

    def test_saved_level_survives_a_long_off_period(self):
        new, saved = decide(False, 25, None)
        self.assertEqual((new, saved), (0, 25))
        for _ in range(100):
            new, saved = decide(False, 0, saved)
            self.assertIsNone(new)
        self.assertEqual(decide(True, 0, saved), (25, None))


def fake_drm(outputs):
    """outputs: {name: (enabled, dpms)} -> a directory shaped like /sys/class/drm."""
    root = tempfile.mkdtemp()
    for name, (enabled, dpms) in outputs.items():
        os.makedirs(os.path.join(root, name))
        for attr, value in (("enabled", enabled), ("dpms", dpms)):
            with open(os.path.join(root, name, attr), "w") as f:
                f.write(value + "\n")
    os.makedirs(os.path.join(root, "card0"))  # the card itself has no dpms: ignored
    return root


class DisplayState(unittest.TestCase):
    """Values as the kernel reports them (seen on a MacBook Air 7,2)."""

    def test_panel_on(self):
        self.assertTrue(WATCHER.display_is_on(fake_drm({
            "card0-eDP-1": ("enabled", "On"), "card0-HDMI-A-1": ("disabled", "Off")})))

    def test_panel_off(self):
        self.assertFalse(WATCHER.display_is_on(fake_drm({
            "card0-eDP-1": ("enabled", "Off"), "card0-HDMI-A-1": ("disabled", "Off")})))

    def test_external_screen_still_on(self):
        self.assertTrue(WATCHER.display_is_on(fake_drm({
            "card0-eDP-1": ("enabled", "Off"), "card0-HDMI-A-1": ("enabled", "On")})))

    def test_disabled_output_does_not_count(self):
        # Only enabled outputs light anything, whatever a disabled one reports.
        self.assertFalse(WATCHER.display_is_on(fake_drm({
            "card0-eDP-1": ("enabled", "Off"), "card0-DP-1": ("disabled", "On")})))

    def test_nothing_readable_means_on(self):
        self.assertTrue(WATCHER.display_is_on(tempfile.mkdtemp()))


class SessionState(unittest.TestCase):
    def write(self, text):
        root = tempfile.mkdtemp()
        with open(os.path.join(root, "3"), "w") as f:
            f.write(text)
        return root

    def test_active_and_locked_sessions_are_alive(self):
        for state in ("active", "online"):
            self.assertTrue(WATCHER.session_alive("3", self.write(f"UID=1000\nSTATE={state}\nACTIVE=0\n")))

    def test_closing_or_gone(self):
        self.assertFalse(WATCHER.session_alive("3", self.write("STATE=closing\n")))
        self.assertFalse(WATCHER.session_alive("4", self.write("STATE=active\n")))


class GreeterScript(unittest.TestCase):
    def script(self):
        m = re.search(r"^    GREETER_SCRIPT_CONTENT='(.*?)'$", setup_extract.setup_text(), re.S | re.M)
        self.assertIsNotNone(m, "GREETER_SCRIPT_CONTENT not found in setup.sh")
        return m.group(1)

    def test_exits_zero_even_when_xset_fails(self):
        bindir = tempfile.mkdtemp()
        with open(os.path.join(bindir, "xset"), "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(bindir, "xset"), 0o755)
        env = dict(os.environ, PATH=bindir + ":/usr/bin:/bin")
        result = subprocess.run(["sh", "-c", self.script()], env=env)
        self.assertEqual(result.returncode, 0)

    def test_powers_the_display_off(self):
        self.assertIn("xset +dpms dpms 60 60 60", self.script())


if __name__ == "__main__":
    unittest.main()
