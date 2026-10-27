"""The keyd config and app.conf that setup.sh writes are valid keyd 2.5.0,
and the validator itself catches the mistakes it exists for.

    python3 -m unittest discover -s tests
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import keyd_validate  # noqa: E402
import setup_extract  # noqa: E402

KEYS = keyd_validate.known_keys()


def conf_errors(text):
    return keyd_validate.validate(text, "conf", KEYS)[0]


class SetupWritesValidKeyd(unittest.TestCase):
    def test_default_conf(self):
        errors, order = keyd_validate.validate(setup_extract.keyd_config(), "conf", KEYS)
        self.assertEqual(errors, [])
        self.assertIn("cmd", order)

    def test_app_conf(self):
        _, layers = keyd_validate.validate(setup_extract.keyd_config(), "conf", KEYS)
        errors, _ = keyd_validate.validate(setup_extract.app_conf(), "app", KEYS, layers)
        self.assertEqual(errors, [])

    def test_app_conf_covers_both_terminals(self):
        text = setup_extract.app_conf()
        for section in ("[xfce4-terminal]", "[gnome-terminal]", "[thunar]"):
            self.assertIn(section, text)


class ValidatorCatchesMistakes(unittest.TestCase):
    """Each of these broke or nearly broke a real config."""

    def test_bare_key_sequence(self):
        # keyd 2.5.0 dropped "backspace = S-home delete" with "invalid key or action"
        self.assertTrue(conf_errors("[main]\nbackspace = S-home delete\n"))
        self.assertEqual(conf_errors("[main]\nbackspace = macro(S-home delete)\n"), [])

    def test_unknown_key_name(self):
        self.assertTrue(conf_errors("[main]\nleftcmd = layer(nav)\n[nav]\n"))

    def test_bad_modifier(self):
        self.assertTrue(conf_errors("[main]\na = X-b\n"))

    def test_undefined_layer(self):
        self.assertTrue(conf_errors("[main]\nmeta = layer(cmd)\n"))

    def test_composite_before_its_parts(self):
        self.assertTrue(conf_errors("[cmd+shift]\na = b\n[cmd:C]\n"))
        self.assertEqual(conf_errors("[cmd:C]\n[cmd+shift]\na = b\n"), [])

    def test_macro_pause_and_typed_path(self):
        self.assertEqual(conf_errors("[main]\na = macro(C-l 50ms /home/u/Downloads enter)\n"), [])
        self.assertTrue(conf_errors("[main]\na = macro(C-l 2000ms enter)\n"))
        # a misspelt key name is not quietly typed as text
        self.assertTrue(conf_errors("[main]\na = macro(C-l enetr)\n"))

    def test_app_conf_unknown_layer(self):
        errors, _ = keyd_validate.validate("[thunar]\nnav.a = b\n", "app", KEYS, ["cmd"])
        self.assertTrue(errors)


class HeredocRendering(unittest.TestCase):
    def test_backtick_would_run_as_a_command(self):
        with self.assertRaises(ValueError):
            setup_extract.render_unquoted("# Cmd+` switches windows\n", {})

    def test_command_substitution(self):
        with self.assertRaises(ValueError):
            setup_extract.render_unquoted("x = $(id)\n", {})

    def test_unexpected_variable(self):
        with self.assertRaises(ValueError):
            setup_extract.render_unquoted("x = $HOME\n", {})

    def test_escapes_and_known_variable(self):
        out = setup_extract.render_unquoted(r"a \$(cat f) \` $MAX ${MAX}", {"MAX": 9})
        self.assertEqual(out, "a $(cat f) ` 9 9")


if __name__ == "__main__":
    unittest.main()
