"""docs/apple-shortcuts.tsv, the audit of Apple's Mac keyboard shortcuts list
against this setup, matches the config setup.sh writes: every row it calls
mapped is bound, every row it calls native passes through as the Linux Ctrl
key, and every Files (Thunar) key it names is written to accels.scm.

    python3 -m unittest discover -s tests
"""
import csv
import os
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import setup_extract  # noqa: E402

AUDIT = os.path.join(os.path.dirname(__file__), "..", "docs", "apple-shortcuts.tsv")
COLUMNS = ["section", "apple", "action", "status", "where", "note"]
# mapped: a binding here does it. native: Cmd sends Ctrl and Linux uses the
# same key. thunar: a Files action given Finder's key. partial / exception:
# works, but differently (the note says how). hardware: the keyboard or
# firmware does it. possible: could be added. skipped: left out on purpose.
# no-equivalent: needs something this desktop doesn't have. unverified: not
# checked yet.
STATUSES = {"mapped", "native", "thunar", "partial", "exception", "hardware",
            "possible", "skipped", "no-equivalent", "unverified"}
NEEDS_WHERE = {"mapped", "thunar", "exception"}
NEEDS_NOTE = {"partial", "exception", "possible", "skipped", "no-equivalent", "unverified"}


def rows():
    with open(AUDIT, encoding="utf-8", newline="") as f:
        reader = csv.reader(f, delimiter="\t")
        header = next(reader)
        # Trailing empty columns are often trimmed by editors: pad them back
        return header, [dict(zip(header, r + [""] * (len(header) - len(r))))
                        | {"_line": n, "_width": len(r)}
                        for n, r in enumerate(reader, 2)]


def bindings(text, mode):
    """{layer: {key: value}} for the main config, {app: {layer.key: value}} for app.conf."""
    out, section = {}, None
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line[1:-1].split(":")[0] if mode == "conf" else line[1:-1]
            out.setdefault(section, {})
        elif "=" in line:
            key, value = (x.strip() for x in line.split("=", 1))
            out[section][key] = value
    return out


def accels():
    return {tuple(line.split("|", 1)) for line in
            setup_extract.heredoc(r"^done << 'ACCELS'$", "ACCELS").splitlines()}


CONF = bindings(setup_extract.keyd_config(), "conf")
APPS = bindings(setup_extract.app_conf(), "app")
ACCELS = accels()


def check_ref(ref):
    """None if the ref holds, else why not."""
    if ref.startswith("accel:"):
        action, _, accel = ref[len("accel:"):].partition("=")
        return None if (action, accel) in ACCELS else f"setup.sh doesn't give {action} the key {accel}"
    sign, body = ref[0], ref[1:]
    if sign not in "+-":
        return f"{ref!r}: expected +, - or accel:"
    app, _, binding = body.rpartition(":")
    if app:
        if sign == "-":
            return f"{ref!r}: only main-config refs can be -"
        return None if binding in APPS.get(app, {}) else f"app.conf [{app}] has no {binding}"
    layer, _, key = binding.rpartition(".")
    bound = key in CONF.get(layer, {})
    if sign == "+":
        return None if bound else f"[{layer}] doesn't bind {key}"
    if layer not in CONF:
        return f"[{layer}] isn't a layer"
    return f"[{layer}] binds {key} = {CONF[layer][key]}, so it isn't the plain Ctrl key" if bound else None


class AuditFile(unittest.TestCase):
    def test_shape(self):
        header, entries = rows()
        self.assertEqual(header, COLUMNS)
        self.assertGreater(len(entries), 150)
        for r in entries:
            with self.subTest(line=r["_line"]):
                self.assertLessEqual(r["_width"], len(COLUMNS))
                self.assertGreaterEqual(r["_width"], COLUMNS.index("status") + 1)
                self.assertIn(r["status"], STATUSES)
                if r["status"] in NEEDS_WHERE:
                    self.assertTrue(r["where"], "needs the binding that does it")
                if r["status"] in NEEDS_NOTE:
                    self.assertTrue(r["note"], f"a {r['status']} row says why")
                if r["status"] == "thunar":
                    self.assertIn("accel:", r["where"])

    def test_no_duplicates(self):
        _, entries = rows()
        seen = [(r["section"], r["apple"]) for r in entries]
        self.assertEqual(len(seen), len(set(seen)))


class AuditMatchesConfig(unittest.TestCase):
    def test_every_ref_holds(self):
        _, entries = rows()
        for r in entries:
            for ref in r["where"].split():
                with self.subTest(line=r["_line"], apple=r["apple"], ref=ref):
                    self.assertIsNone(check_ref(ref))

    def test_refs_are_checked_both_ways(self):
        # The checker itself: a binding that exists, one that doesn't, and a
        # key the Cmd layer overrides (so it is not "native").
        self.assertIsNone(check_ref("+cmd.h"))
        self.assertIsNotNone(check_ref("+cmd.nosuchkey"))
        self.assertIsNotNone(check_ref("-cmd.h"))
        self.assertIsNone(check_ref("-cmd.c"))
        self.assertIsNotNone(check_ref("-nosuchlayer.c"))
        self.assertIsNotNone(check_ref("+thunar:cmd.nosuchkey"))
        self.assertIsNotNone(check_ref("accel:ThunarWindow/open-desktop=<Primary>x"))

    def test_every_accel_is_audited(self):
        _, entries = rows()
        audited = {ref for r in entries for ref in r["where"].split() if ref.startswith("accel:")}
        for action, accel in ACCELS:
            if accel:  # an emptied key frees it for a Finder one
                self.assertIn(f"accel:{action}={accel}", audited)


ACCEL_BLOCK_START = re.compile(r'^THUNAR_ACCELS=')


class ThunarAccels(unittest.TestCase):
    """Runs setup.sh's accels.scm block against a scratch home."""

    def block(self):
        lines = setup_extract.setup_text().split("\n")
        start = [i for i, line in enumerate(lines) if ACCEL_BLOCK_START.match(line)]
        self.assertEqual(len(start), 1)
        end = lines.index("ACCELS", start[0])
        return "print_ok() { :; }\n" + "\n".join(lines[start[0]:end + 1]) + "\n"

    def run_block(self, home):
        subprocess.run(["bash", "-c", self.block()], env=dict(os.environ, ACTUAL_HOME=home), check=True)
        with open(os.path.join(home, ".config/Thunar/accels.scm")) as f:
            return f.read()

    def test_fresh_home(self):
        text = self.run_block(tempfile.mkdtemp())
        self.assertIn('(gtk_accel_path "<Actions>/ThunarWindow/open-desktop" "<Primary><Shift>d")', text)
        self.assertIn('(gtk_accel_path "<Actions>/ThunarShortcutsPane/sendto-shortcuts" "<Primary><Alt>b")', text)

    def test_keeps_other_keys_and_replaces_ours(self):
        home = tempfile.mkdtemp()
        os.makedirs(os.path.join(home, ".config/Thunar"))
        with open(os.path.join(home, ".config/Thunar/accels.scm"), "w") as f:
            f.write('; (gtk_accel_path "<Actions>/ThunarStandardView/duplicate" "")\n'
                    '(gtk_accel_path "<Actions>/ThunarWindow/open-desktop" "<Primary>F12")\n'
                    '(gtk_accel_path "<Actions>/ThunarWindow/new-tab" "<Primary>y")\n'
                    '; (gtk_accel_path "<Actions>/ThunarWindow/open-desktop-extra" "")\n')
        text = self.run_block(home)
        self.assertIn('"<Actions>/ThunarWindow/new-tab" "<Primary>y"', text)
        self.assertIn("open-desktop-extra", text)
        self.assertNotIn("<Primary>F12", text)
        for action, accel in ACCELS:
            self.assertEqual(text.count(f'"<Actions>/{action}"'), 1, action)
            self.assertIn(f'(gtk_accel_path "<Actions>/{action}" "{accel}")', text)

    def test_rerun_changes_nothing(self):
        home = tempfile.mkdtemp()
        first = self.run_block(home)
        self.assertEqual(self.run_block(home), first)


if __name__ == "__main__":
    unittest.main()
