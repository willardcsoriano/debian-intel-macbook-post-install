"""themes.sh's dock setup (configure_dock), run against a stub gsettings that
keeps Plank's settings in files, and a temporary HOME and app directory.

    python3 -m unittest discover -s tests
"""
import os
import re
import subprocess
import tempfile
import unittest

THEMES = os.path.join(os.path.dirname(__file__), "..", "themes.sh")

# gsettings: "get SCHEMA KEY" prints the stored value, "set SCHEMA KEY VALUE"
# stores it, the way GSettings prints an empty string list when nothing is set.
GSETTINGS = """#!/bin/sh
dir="$GSETTINGS_STORE"
case "$1" in
    get) if [ -f "$dir/$3" ]; then cat "$dir/$3"; else echo "@as []"; fi ;;
    set) printf '%s\\n' "$4" > "$dir/$3" ;;
    *) exit 1 ;;
esac
"""


def themes_text():
    with open(THEMES, encoding="utf-8") as f:
        return f.read()


def block(text, pattern):
    match = re.search(pattern, text, re.S | re.M)
    if not match:
        raise AssertionError(f"not found in themes.sh: {pattern}")
    return match.group(0)


def dock_code():
    """The arrays and functions configure_dock needs, as themes.sh defines them."""
    text = themes_text()
    parts = [block(text, r"^CURATED_APPS=\(\n.*?^\)\n"),
             block(text, r"^RETIRED_APPS=\(\n.*?^\)\n"),
             block(text, r"^PLANK_DOCK=.*?\n"),
             block(text, r"^PLANK_LAUNCHERS=.*?\n")]
    for name in ("remove_managed_launchers", "is_managed_dockitem", "configure_dock"):
        parts.append(block(text, rf"^{name}\(\) \{{\n.*?^\}}\n"))
    return "".join(parts)


def launcher_dirs_code():
    return block(themes_text(), r"^launcher_dirs\(\) \{\n.*?^\}\n")


class LauncherDirs(unittest.TestCase):
    """launcher_dirs: the XDG lookup order, user data dir first."""

    def dirs(self, **env):
        base = {k: v for k, v in os.environ.items() if k not in ("XDG_DATA_HOME", "XDG_DATA_DIRS")}
        base.update(HOME="/home/u", **env)
        out = subprocess.run(["bash", "-euo", "pipefail", "-c", launcher_dirs_code() + "launcher_dirs\n"],
                             env=base, check=True, capture_output=True, text=True, timeout=30).stdout
        return out.splitlines()

    def test_defaults_put_the_user_dir_first(self):
        self.assertEqual(self.dirs(), ["/home/u/.local/share/applications",
                                       "/usr/local/share/applications",
                                       "/usr/share/applications"])

    def test_session_xdg_variables_are_followed(self):
        self.assertEqual(self.dirs(XDG_DATA_HOME="/data/me",
                                   XDG_DATA_DIRS="/usr/share/xfce4:/var/lib/flatpak/exports/share/:/usr/share"),
                         ["/data/me/applications", "/usr/share/xfce4/applications",
                          "/var/lib/flatpak/exports/share/applications", "/usr/share/applications"])

    def test_empty_entries_are_skipped(self):
        self.assertEqual(self.dirs(XDG_DATA_DIRS=":/usr/share::"),
                         ["/home/u/.local/share/applications", "/usr/share/applications"])


class DockFollowsTheLauncherTheMenuUses(unittest.TestCase):
    """Issue #64: setup.sh writes fixed copies of launchers to the user's data
    dir; the dock must point at those, not the system file they hide, or the
    running app shows as a second icon."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, self.root, ignore_errors=True)
        self.home = os.path.join(self.root, "home")
        self.user_apps = os.path.join(self.home, ".local/share/applications")
        self.sys_share = os.path.join(self.root, "usr/share")
        self.store = os.path.join(self.root, "gsettings")
        self.bin = os.path.join(self.root, "bin")
        for d in (self.user_apps, os.path.join(self.sys_share, "applications"), self.store, self.bin):
            os.makedirs(d)
        with open(os.path.join(self.bin, "gsettings"), "w") as f:
            f.write(GSETTINGS)
        os.chmod(os.path.join(self.bin, "gsettings"), 0o755)

    def app(self, directory, name):
        open(os.path.join(directory, name + ".desktop"), "w").close()

    def launcher(self, item):
        path = os.path.join(self.home, ".config/plank/dock1/launchers", item)
        with open(path) as f:
            return re.search(r"^Launcher=(.*)$", f.read(), re.M).group(1)

    def run_dock(self):
        script = (dock_code() + launcher_dirs_code() + "mapfile -t SEARCH_DIRS < <(launcher_dirs)\n"
                  "configure_dock Transparent apps\n")
        env = {k: v for k, v in os.environ.items() if k not in ("XDG_DATA_HOME", "XDG_DATA_DIRS")}
        env.update(HOME=self.home, GSETTINGS_STORE=self.store, XDG_DATA_DIRS=self.sys_share,
                   PATH=self.bin + ":" + os.environ["PATH"])
        subprocess.run(["bash", "-euo", "pipefail", "-c", script], env=env, check=True,
                       capture_output=True, text=True, timeout=30)

    def test_user_copy_wins_over_the_system_file(self):
        sys_apps = os.path.join(self.sys_share, "applications")
        self.app(sys_apps, "org.xfce.ristretto")
        self.app(self.user_apps, "org.xfce.ristretto")
        self.app(sys_apps, "galculator")             # no user copy
        self.run_dock()
        self.assertEqual(self.launcher("org.xfce.ristretto.dockitem"),
                         f"file://{self.user_apps}/org.xfce.ristretto.desktop")
        self.assertEqual(self.launcher("galculator.dockitem"), f"file://{sys_apps}/galculator.desktop")

    def test_themes_sh_builds_its_dirs_from_launcher_dirs(self):
        self.assertRegex(themes_text(), r"(?m)^mapfile -t SEARCH_DIRS < <\(launcher_dirs\)$")


class ConfigureDock(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.home = os.path.join(self.root, "home")
        self.apps = os.path.join(self.root, "apps")
        self.store = os.path.join(self.root, "gsettings")
        self.bin = os.path.join(self.root, "bin")
        for d in (self.home, self.apps, self.store, self.bin):
            os.makedirs(d)
        with open(os.path.join(self.bin, "gsettings"), "w") as f:
            f.write(GSETTINGS)
        os.chmod(os.path.join(self.bin, "gsettings"), 0o755)
        # Installed apps: Files only under its second name, no Firefox
        for app in ("org.xfce.thunar", "xfce4-appfinder", "chromium", "org.xfce.mousepad",
                    "libreoffice-writer", "vlc", "firefox-esr-not-this"):
            open(os.path.join(self.apps, app + ".desktop"), "w").close()
        self.launchers = os.path.join(self.home, ".config/plank/dock1/launchers")

    def pin(self, name, launcher="file:///usr/share/applications/x.desktop"):
        os.makedirs(self.launchers, exist_ok=True)
        with open(os.path.join(self.launchers, name), "w") as f:
            f.write(f"[PlankDockItemPreferences]\nLauncher={launcher}\n")

    def set_items(self, *names):
        with open(os.path.join(self.store, "dock-items"), "w") as f:
            f.write("[" + ", ".join(f"'{n}'" for n in names) + "]\n")

    def run_dock(self, theme, contents):
        script = (dock_code() + f'SEARCH_DIRS=("{self.apps}")\n'
                  f'configure_dock {theme} {contents}\n')
        env = dict(os.environ, HOME=self.home, GSETTINGS_STORE=self.store,
                   PATH=self.bin + ":" + os.environ["PATH"])
        subprocess.run(["bash", "-euo", "pipefail", "-c", script], env=env, check=True,
                       capture_output=True, text=True, timeout=30)

    def setting(self, key):
        with open(os.path.join(self.store, key)) as f:
            return f.read().strip()

    def items(self):
        return re.findall(r"'([^']*)'", self.setting("dock-items"))

    def test_curated_apps_in_order_then_trash(self):
        self.run_dock("Transparent", "apps")
        self.assertEqual(self.items(), [
            "org.xfce.thunar.dockitem", "xfce4-appfinder.dockitem", "chromium.dockitem",
            "org.xfce.mousepad.dockitem", "libreoffice-writer.dockitem", "vlc.dockitem",
            "zzz-trash.dockitem"])
        with open(os.path.join(self.launchers, "chromium.dockitem")) as f:
            self.assertIn(f"Launcher=file://{self.apps}/chromium.desktop\n", f.read())
        with open(os.path.join(self.launchers, "zzz-trash.dockitem")) as f:
            self.assertIn("Launcher=docklet://trash\n", f.read())

    def test_dock_is_locked_and_styled(self):
        self.run_dock("Transparent", "apps")
        self.assertEqual(self.setting("lock-items"), "true")
        self.assertEqual(self.setting("theme"), "Transparent")
        self.assertEqual(self.setting("position"), "bottom")
        self.assertEqual(self.setting("hide-mode"), "intelligent")

    def test_user_pins_are_kept_and_retired_items_removed(self):
        self.pin("VS Code.dockitem")
        self.pin("htop.dockitem")       # an earlier version of this script put it there
        self.pin("xfce4-terminal.dockitem")
        self.set_items("htop.dockitem", "VS Code.dockitem", "gone.dockitem",
                       "xfce4-terminal.dockitem")
        self.run_dock("Transparent", "apps")
        items = self.items()
        self.assertEqual(items[-2:], ["VS Code.dockitem", "zzz-trash.dockitem"])
        self.assertNotIn("htop.dockitem", items)
        self.assertNotIn("gone.dockitem", items)     # pinned, but its file is gone
        self.assertNotIn("xfce4-terminal.dockitem", items)
        self.assertFalse(os.path.exists(os.path.join(self.launchers, "htop.dockitem")))
        self.assertTrue(os.path.exists(os.path.join(self.launchers, "VS Code.dockitem")))

    def test_rerun_converges(self):
        self.pin("VS Code.dockitem")
        self.set_items("VS Code.dockitem")
        self.run_dock("Transparent", "apps")
        first = self.items()
        self.run_dock("Transparent", "apps")
        self.assertEqual(self.items(), first)

    def test_classic_mode_keeps_only_user_pins(self):
        self.pin("VS Code.dockitem")
        self.set_items("chromium.dockitem", "VS Code.dockitem", "zzz-trash.dockitem")
        self.pin("chromium.dockitem")
        self.pin("zzz-trash.dockitem", "docklet://trash")
        self.run_dock("Default", "none")
        self.assertEqual(self.items(), ["VS Code.dockitem"])
        self.assertEqual(sorted(os.listdir(self.launchers)), ["VS Code.dockitem"])
        self.assertEqual(self.setting("lock-items"), "true")

    def test_empty_dock(self):
        self.run_dock("Default", "none")
        self.assertEqual(self.setting("dock-items"), "@as []")


# Each Dock entry's command, as setup.sh's Desktop shortcut runs it
DOCK_TO_DESKTOP = {
    "thunar": "thunar", "xfce4-appfinder": "xfce4-appfinder", "chromium": "chromium",
    "org.xfce.mousepad": "mousepad", "libreoffice-writer": "libreoffice --writer",
    "libreoffice-calc": "libreoffice --calc", "libreoffice-impress": "libreoffice --impress",
    "org.xfce.ristretto": "ristretto", "vlc": "vlc", "galculator": "galculator",
    "xfce-settings-manager": "xfce4-settings-manager",
}


class DesktopMatchesDock(unittest.TestCase):
    def test_setup_desktop_shortcuts_are_the_dock_apps(self):
        curated = re.findall(r'^    "([^" ]+)', block(themes_text(), r"^CURATED_APPS=\(\n.*?^\)\n"), re.M)
        self.assertEqual(sorted(curated), sorted(DOCK_TO_DESKTOP))
        with open(os.path.join(os.path.dirname(__file__), "..", "setup.sh"), encoding="utf-8") as f:
            desktop = re.findall(r'^create_shortcut "[^"]+" "([^"]+)"', f.read(), re.M)
        self.assertEqual(sorted(desktop), sorted(DOCK_TO_DESKTOP.values()))

    def test_themes_adds_no_desktop_copies(self):
        # setup.sh owns the Desktop; copies from themes.sh doubled every icon
        self.assertNotIn("place_desktop_icons", themes_text())


class NoDeadSettingsFile(unittest.TestCase):
    def test_the_old_settings_file_is_not_written(self):
        # Plank reads GSettings; writing the old file changed nothing
        self.assertNotIn("[PlankDockPreferences]", themes_text())


if __name__ == "__main__":
    unittest.main()
