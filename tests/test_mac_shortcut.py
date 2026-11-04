"""mac-shortcut (emoji picker, Dock toggle, small volume steps, colour
inversion), run against
stub tools, and the hand-off from keyd to XFCE: every Super combo the keyd
config sends must be a shortcut XFCE has.

    python3 -m unittest discover -s tests
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import setup_extract  # noqa: E402

SOURCE = setup_extract.heredoc(r"^sudo tee \"\$MAC_SHORTCUT\" > /dev/null << 'MACSHORTCUT'$", "MACSHORTCUT")
MS = types.ModuleType("mac_shortcut")
exec(compile(SOURCE, "mac-shortcut", "exec"), MS.__dict__)

# Lines as Debian's unicode-data 15.1 ships them
EMOJI_TEST = """# group: Smileys & Emotion
1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
263A FE0F                                              ; fully-qualified     # ☺️ E0.6 smiling face
263A                                                   ; unqualified         # ☺ E0.6 smiling face
1F441 200D 1F5E8                                       ; minimally-qualified # 👁‍🗨 E2.0 eye in speech bubble
1F44B 1F3FD                                            ; fully-qualified     # 👋🏽 E1.0 waving hand: medium skin tone
# subgroup: component
1F3FB                                                  ; component           # 🏻 E1.0 light skin tone
"""


class Emoji(unittest.TestCase):
    def test_entries(self):
        self.assertEqual(MS.emoji_entries(EMOJI_TEST),
                         ["😀 grinning face", "☺️ smiling face", "👋🏽 waving hand: medium skin tone"])

    def test_the_installed_list_parses(self):
        # setup.sh installs unicode-data; CI installs it too
        with open(MS.EMOJI_TEST, encoding="utf-8") as f:
            entries = MS.emoji_entries(f.read())
        self.assertGreater(len(entries), 3000)
        self.assertIn("😀 grinning face", entries)


class Dock(unittest.TestCase):
    def test_hide_remembers_the_mode_it_replaces(self):
        self.assertEqual(MS.next_dock_mode("'intelligent'", None), ("'auto'", "'intelligent'"))
        self.assertEqual(MS.next_dock_mode("'none'", "'window-dodge'"), ("'auto'", "'none'"))

    def test_show_restores_it(self):
        self.assertEqual(MS.next_dock_mode("'auto'", "'none'"), ("'none'", None))
        self.assertEqual(MS.next_dock_mode("'auto'", None), (MS.DOCK_DEFAULT_MODE, None))


PACTL = "Volume: front-left: 32768 /  50% / -18.06 dB,   front-right: 32768 /  50% / -18.06 dB\n"


class Volume(unittest.TestCase):
    def test_steps(self):
        self.assertEqual(MS.new_volume(PACTL, 1), 51)
        self.assertEqual(MS.new_volume(PACTL, -1), 49)

    def test_stops_at_the_ends(self):
        self.assertEqual(MS.new_volume(PACTL.replace("50%", "100%"), 1), 100)
        self.assertEqual(MS.new_volume(PACTL.replace("50%", "0%"), -1), 0)
        # PulseAudio can be past 100% already (set elsewhere): a step down still works
        self.assertEqual(MS.new_volume(PACTL.replace("50%", "120%"), -1), 100)

    def test_unreadable(self):
        with self.assertRaises(ValueError):
            MS.new_volume("Connection failure: Connection refused\n", 1)


class FullRun(unittest.TestCase):
    """The script as XFCE runs it, with gsettings, pactl, rofi, xclip and
    xdotool stubbed: each stub logs its arguments."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "calls")
        stub = f'#!/bin/sh\necho "$(basename "$0") $*" >> "{self.log}"\n'
        replies = {
            "gsettings": 'case "$2" in net.launchpad.plank) echo "[\'dock1\']";; *) if [ "$1" = get ]; then cat "$0.mode"; fi;; esac',
            "pactl": f"printf '%s' '{PACTL}'",
            "rofi": 'cat > /dev/null; cat "$0.pick"',
            "xclip": "cat > /dev/null",
        }
        for name in ("gsettings", "pactl", "rofi", "xclip", "xdotool"):
            path = os.path.join(self.dir, name)
            with open(path, "w") as f:
                f.write(stub + replies.get(name, "") + "\n")
            os.chmod(path, 0o755)
        # The emoji list is read from a fixture instead of /usr/share
        self.write("emoji-test.txt", EMOJI_TEST)
        quoted = f'"{MS.EMOJI_TEST}"'
        self.assertEqual(SOURCE.count(quoted), 1)
        self.script = os.path.join(self.dir, "mac-shortcut")
        with open(self.script, "w") as f:
            f.write(SOURCE.replace(quoted, f'"{os.path.join(self.dir, "emoji-test.txt")}"'))

    def write(self, name, text):
        with open(os.path.join(self.dir, name), "w") as f:
            f.write(text)

    def run_script(self, *args):
        env = dict(os.environ, PATH=self.dir + ":/usr/bin:/bin", XDG_STATE_HOME=os.path.join(self.dir, "state"))
        result = subprocess.run([sys.executable, self.script, *args], env=env, capture_output=True,
                                text=True, stdin=subprocess.DEVNULL, timeout=30)
        calls = []
        if os.path.exists(self.log):
            with open(self.log) as f:
                calls = f.read().splitlines()
        return result, calls

    def test_volume(self):
        result, calls = self.run_script("volume", "+1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], "pactl set-sink-volume @DEFAULT_SINK@ 51%")

    def test_dock_round_trip(self):
        schema = "net.launchpad.plank.dock.settings:/net/launchpad/plank/docks/dock1/"
        self.write("gsettings.mode", "'none'\n")
        result, calls = self.run_script("toggle-dock")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], f"gsettings set {schema} hide-mode 'auto'")
        self.write("gsettings.mode", "'auto'\n")
        result, calls = self.run_script("toggle-dock")
        self.assertEqual(calls[-1], f"gsettings set {schema} hide-mode 'none'")

    def test_emoji_types_and_copies_the_pick(self):
        self.write("rofi.pick", "👋🏽 waving hand: medium skin tone\n")
        result, calls = self.run_script("emoji")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("xclip -selection clipboard", calls)
        self.assertEqual(calls[-1], "xdotool type --clearmodifiers -- 👋🏽")

    def test_emoji_closed_types_nothing(self):
        self.write("rofi.pick", "")
        result, calls = self.run_script("emoji")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([c for c in calls if c.startswith(("xdotool", "xclip"))])

    def test_bad_usage(self):
        for args in ((), ("volume",), ("volume", "loud"), ("dance",), ("invert", "now")):
            result, calls = self.run_script(*args)
            self.assertEqual((result.returncode, calls), (2, []))


class Invert(unittest.TestCase):
    def test_reverses_the_ramp(self):
        self.assertEqual(MS.inverted([0, 100, 65535]), [65535, 100, 0])

    def test_twice_gives_the_ramp_back(self):
        # a calibrated (non-linear) ramp survives the round trip untouched
        ramp = [0, 900, 5000, 30000, 65535]
        self.assertEqual(MS.inverted(MS.inverted(ramp)), ramp)

    def test_empty(self):
        self.assertEqual(MS.inverted([]), [])


# A stand-in for python-xlib's RandR calls: CRTCs come from the JSON file in
# $FAKE_RANDR, and each set_crtc_gamma and sync is appended to $FAKE_RANDR.log.
FAKE_XLIB = {
    "Xlib/__init__.py": "",
    "Xlib/ext/__init__.py": "",
    "Xlib/display.py": """
import os
class _Screen:
    root = object()
class Display:
    def screen(self):
        return _Screen()
    def sync(self):
        with open(os.environ["FAKE_RANDR"] + ".log", "a") as f:
            f.write("sync\\n")
""",
    "Xlib/ext/randr.py": """
import json, os, types
def _crtcs():
    with open(os.environ["FAKE_RANDR"]) as f:
        return {c["id"]: c for c in json.load(f)}
def get_screen_resources(root):
    return types.SimpleNamespace(crtcs=list(_crtcs()), config_timestamp=7)
def get_crtc_info(root, crtc, timestamp):
    assert timestamp == 7
    return types.SimpleNamespace(outputs=_crtcs()[crtc]["outputs"])
def get_crtc_gamma(root, crtc):
    r = _crtcs()[crtc]["ramp"]
    return types.SimpleNamespace(red=list(r), green=list(r), blue=list(r))
def set_crtc_gamma(root, crtc, size, red, green, blue):
    with open(os.environ["FAKE_RANDR"] + ".log", "a") as f:
        f.write(json.dumps(["set", crtc, size, red, green, blue]) + "\\n")
""",
}


class InvertRun(unittest.TestCase):
    """mac-shortcut invert as XFCE runs it, against the fake RandR above."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        for path, text in FAKE_XLIB.items():
            full = os.path.join(self.dir, "lib", path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as f:
                f.write(text)
        self.script = os.path.join(self.dir, "mac-shortcut")
        with open(self.script, "w") as f:
            f.write(SOURCE)
        self.state = os.path.join(self.dir, "crtcs.json")

    def run_invert(self, crtcs):
        with open(self.state, "w") as f:
            json.dump(crtcs, f)
        env = dict(os.environ, PYTHONPATH=os.path.join(self.dir, "lib"), FAKE_RANDR=self.state)
        result = subprocess.run([sys.executable, self.script, "invert"], env=env, capture_output=True,
                                text=True, stdin=subprocess.DEVNULL, timeout=30)
        log = []
        if os.path.exists(self.state + ".log"):
            with open(self.state + ".log") as f:
                log = [line if line == "sync" else json.loads(line) for line in f.read().splitlines()]
        return result, log

    def test_inverts_only_lit_displays(self):
        result, log = self.run_invert([
            {"id": 62, "outputs": [65], "ramp": [0, 16399, 65535]},
            {"id": 63, "outputs": [], "ramp": [0, 16384, 65472]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log, [["set", 62, 3, [65535, 16399, 0], [65535, 16399, 0], [65535, 16399, 0]], "sync"])

    def test_every_lit_display(self):
        result, log = self.run_invert([
            {"id": 62, "outputs": [65], "ramp": [0, 65535]},
            {"id": 63, "outputs": [66], "ramp": [10, 60000]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([entry[1] for entry in log if entry != "sync"], [62, 63])

    def test_nothing_to_invert_is_a_failure(self):
        # no lit display, or one whose driver exposes no ramp: say so, exit 1
        for crtcs in ([], [{"id": 63, "outputs": [], "ramp": [0, 1]}],
                      [{"id": 62, "outputs": [65], "ramp": []}]):
            result, log = self.run_invert(crtcs)
            self.assertEqual(result.returncode, 1)
            self.assertIn("no display has a gamma ramp", result.stderr)
            self.assertNotIn("set", [entry[0] for entry in log if entry != "sync"])


# XFCE's own default shortcuts that the keyd config relies on
XFCE_DEFAULTS = {"<Super>tab", "<Super>p"}


# keyd key names that X spells differently
KEYSYMS = {"left": "Left", "right": "Right", "up": "Up", "down": "Down"}


def xfce_combo(keyd_combo):
    """M-A-minus -> <Super><Alt>minus, modifiers in a fixed order."""
    *mods, key = keyd_combo.split("-")
    names = {"M": "<Super>", "S": "<Shift>", "A": "<Alt>", "C": "<Primary>"}
    return "".join(names[m] for m in sorted(mods)) + KEYSYMS.get(key, key)


def window_keys():
    """(combo, xfwm4 action) for each window binding setup.sh writes."""
    body = setup_extract.heredoc(r"^done << 'WINDOW_KEYS'$", "WINDOW_KEYS")
    return [tuple(line.split("|", 1)) for line in body.splitlines()]


def normalize(xfce):
    mods = re.findall(r"<(\w+)>", xfce)
    key = re.sub(r"<\w+>", "", xfce)
    letters = {"Super": "M", "Shift": "S", "Alt": "A", "Primary": "C", "Control": "C"}
    return xfce_combo("-".join(sorted(letters[m] for m in mods) + [key]))


class KeydReachesXfce(unittest.TestCase):
    def xfce_bindings(self):
        text = setup_extract.setup_text()
        found = re.findall(r"-p '/commands/custom/([^']+)'", text)
        found += [line.split("|", 1)[0] for line in
                  setup_extract.heredoc(r"^done << SHORTCUTS$", "SHORTCUTS").splitlines()]
        found += [combo for combo, _ in window_keys()]
        return {normalize(b) for b in found}

    def test_every_super_combo_is_bound(self):
        sent = set(re.findall(r"(?<![\w-])(M-[A-Za-z0-9-]+)", setup_extract.keyd_config()))
        self.assertGreater(len(sent), 10)
        bound = self.xfce_bindings() | {normalize(d) for d in XFCE_DEFAULTS}
        for combo in sorted(sent):
            with self.subTest(combo=combo):
                self.assertIn(xfce_combo(combo), bound)

    def test_no_combo_bound_twice(self):
        text = setup_extract.setup_text()
        found = re.findall(r"-p '/commands/custom/([^']+)'", text)
        found += [line.split("|", 1)[0] for line in
                  setup_extract.heredoc(r"^done << SHORTCUTS$", "SHORTCUTS").splitlines()]
        found += [combo for combo, _ in window_keys()]
        normalized = [normalize(b) for b in found]
        self.assertEqual(len(normalized), len(set(normalized)))


def keyd_layer(name):
    """The key = value lines of one [layer] in the keyd config, as a dict."""
    found, current = {}, None
    for line in setup_extract.keyd_config().splitlines():
        line = line.strip()
        if line.startswith("["):
            current = line
        elif current == f"[{name}]" and "=" in line and not line.startswith("#"):
            key, value = (part.strip() for part in line.split("=", 1))
            found[key] = value
    return found


class ScreenshotKeys(unittest.TestCase):
    def test_area_screenshot_keys_reach_flameshot(self):
        flameshot_on = {normalize(b) for b in re.findall(
            r"-p '/commands/custom/([^']+)' -s 'flameshot gui'", setup_extract.setup_text())}
        for layer, key in (("cmd+shift", "4"), ("cmd+shift", "5"), ("cmd+option", "s")):
            with self.subTest(key=f"{layer}.{key}"):
                self.assertIn(xfce_combo(keyd_layer(layer)[key]), flameshot_on)


LAUNCHER = """[Desktop Entry]
Version=1.0
Name[de]=Xfce-Terminal
Name[en_GB]=Xfce Terminal
Name=Xfce Terminal
Comment=Use the command line
Exec=xfce4-terminal
[Desktop Action preferences]
Name=Terminal Preferences
"""


class TerminalLauncher(unittest.TestCase):
    def run_function(self, text):
        function = re.search(r"^terminal_launcher\(\) \{\n.*?^\}\n", setup_extract.setup_text(),
                             re.S | re.M).group(0)
        path = os.path.join(tempfile.mkdtemp(), "xfce4-terminal.desktop")
        with open(path, "w") as f:
            f.write(text)
        return subprocess.run(["bash", "-c", function + 'terminal_launcher "$1"', "-", path],
                              capture_output=True, text=True, check=True).stdout

    def test_english_names_become_terminal(self):
        lines = self.run_function(LAUNCHER).splitlines()
        self.assertIn("Name=Terminal", lines)
        self.assertIn("Name[en_GB]=Terminal", lines)
        self.assertNotIn("Name=Xfce Terminal", lines)

    def test_everything_else_is_kept(self):
        lines = self.run_function(LAUNCHER).splitlines()
        self.assertEqual(lines[0], "[Desktop Entry]")
        self.assertIn("debian-intel-macbook-post-install", lines[1])
        for kept in ("Name[de]=Xfce-Terminal", "Exec=xfce4-terminal", "Name=Terminal Preferences"):
            self.assertIn(kept, lines)
        self.assertEqual(len(lines), len(LAUNCHER.splitlines()) + 1)

    def test_the_installed_launcher(self):
        installed = "/usr/share/applications/xfce4-terminal.desktop"
        if not os.path.exists(installed):
            self.skipTest("xfce4-terminal is not installed here")
        with open(installed) as f:
            self.assertIn("Name=Terminal", self.run_function(f.read()).splitlines())


class AppFinderReload(unittest.TestCase):
    """The block that asks a running App Finder to quit, run against stubs:
    pgrep reports a running App Finder until `xfce4-appfinder --quit` has
    stopped it (or never, for one that ignores the request), and the stub
    App Finder exits 1 either way, as 4.20 does."""

    def run_block(self, running, quits=True):
        block = re.search(r'^if pgrep -u "\$USER" -x xfce4-appfinder > /dev/null; then\n.*?^fi$',
                          setup_extract.setup_text(), re.S | re.M).group(0)
        bin_dir = tempfile.mkdtemp()
        calls, alive = os.path.join(bin_dir, "calls"), os.path.join(bin_dir, "alive")
        if running:
            open(alive, "w").close()
        stubs = {
            "pgrep": f'echo "pgrep $*" >> "{calls}"\n[ -e "{alive}" ]',
            "xfce4-appfinder": f'echo "xfce4-appfinder $*" >> "{calls}"\n'
                               + (f'rm -f "{alive}"\n' if quits else "") + "exit 1",
            "sleep": "exit 0",
        }
        for name, body in stubs.items():
            path = os.path.join(bin_dir, name)
            with open(path, "w") as f:
                f.write("#!/bin/sh\n" + body + "\n")
            os.chmod(path, 0o755)
        script = ('print_ok() { echo "ok: $1"; }\nprint_warning() { echo "warn: $1"; }\n'
                  "LOG_FILE=/dev/null\n" + block)
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True,
                             env=dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"])).stdout
        with open(calls) as f:
            return f.read().splitlines(), out

    def test_a_running_app_finder_is_asked_to_quit(self):
        calls, out = self.run_block(running=True)
        self.assertIn("xfce4-appfinder --quit", calls)
        self.assertEqual(out, "ok: App Finder reloaded (the next F4 shows the updated launchers)\n")

    def test_one_that_stays_running_is_reported_not_claimed(self):
        calls, out = self.run_block(running=True, quits=False)
        self.assertIn("xfce4-appfinder --quit", calls)
        self.assertTrue(out.startswith("warn: App Finder is still running"), out)

    def test_nothing_happens_when_none_is_running(self):
        calls, out = self.run_block(running=False)
        self.assertEqual([c for c in calls if c.startswith("xfce4-appfinder")], [])
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()


# XFCE's default shortcuts, shipped by libxfce4ui-common (CI installs it too)
XFCE_DEFAULTS_XML = "/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"


class WindowKeys(unittest.TestCase):
    def test_actions_are_real_xfwm4_actions(self):
        # A misspelled action name is accepted by xfconf and silently does
        # nothing, so check each against the actions XFCE itself ships.
        import xml.etree.ElementTree as ET
        root = ET.parse(XFCE_DEFAULTS_XML).getroot()
        xfwm4 = root.find("./property[@name='xfwm4']")
        actions = {p.get("value") for p in xfwm4.iter("property") if p.get("type") == "string"}
        self.assertIn("tile_left_key", actions)
        for combo, action in window_keys():
            with self.subTest(combo=combo):
                self.assertIn(action, actions)

    def test_every_tile_key_reaches_its_action(self):
        # Fn+Control+arrow (and the Home/End/PageUp/PageDown Apple's driver
        # turns them into) lands on the matching tile; Fn+Control+F fills.
        layer = keyd_layer("control+globe")
        actions = {normalize(combo): action for combo, action in window_keys()}
        expect = {"left": "tile_left_key", "home": "tile_left_key",
                  "right": "tile_right_key", "end": "tile_right_key",
                  "up": "tile_up_key", "pageup": "tile_up_key",
                  "down": "tile_down_key", "pagedown": "tile_down_key",
                  "f": "maximize_window_key"}
        for key, action in expect.items():
            with self.subTest(key=key):
                self.assertEqual(actions[xfce_combo(layer[key])], action)
