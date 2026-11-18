"""The README's install links name the version being released.

release-please rewrites version strings only inside
<!-- x-release-please-start-version --> ... <!-- x-release-please-end -->
blocks of README.md (release-please-config.json lists it as a generic extra
file). A link outside a block would keep pointing at an old tag after the
next release, so every versioned raw.githubusercontent.com link must sit in
a block and name the version in .release-please-manifest.json.

    python3 -m unittest discover -s tests
"""
import json
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")
LINK = re.compile(r"raw\.githubusercontent\.com/willardcsoriano/"
                  r"debian-intel-macbook-post-install/v(\d+\.\d+\.\d+)/")


def read(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as f:
        return f.read()


def links(text):
    """(line number, version, inside a release-please block) per link."""
    found, inside = [], False
    for n, line in enumerate(text.split("\n"), 1):
        if "x-release-please-start-version" in line:
            inside = True
        elif "x-release-please-end" in line:
            inside = False
        for m in LINK.finditer(line):
            found.append((n, m.group(1), inside))
    return found


class ReleaseLinks(unittest.TestCase):
    def test_every_install_link_is_in_a_block_and_names_the_released_version(self):
        version = json.loads(read(".release-please-manifest.json"))["."]
        found = links(read("README.md"))
        self.assertGreaterEqual(len(found), 3, "the setup and theming links went missing")
        for n, v, inside in found:
            with self.subTest(line=n):
                self.assertTrue(inside, f"README.md:{n} is outside a release-please block")
                self.assertEqual(v, version)

    def test_version_txt_matches_the_manifest(self):
        version = json.loads(read(".release-please-manifest.json"))["."]
        self.assertEqual(read("version.txt").strip(), version)

    def test_readme_is_listed_for_the_generic_updater(self):
        config = json.loads(read("release-please-config.json"))
        self.assertIn({"type": "generic", "path": "README.md"},
                      config["packages"]["."]["extra-files"])

    def test_a_link_outside_a_block_is_caught(self):
        text = ("<!-- x-release-please-start-version -->\n"
                "raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.2.3/a\n"
                "<!-- x-release-please-end -->\n"
                "raw.githubusercontent.com/willardcsoriano/debian-intel-macbook-post-install/v1.2.3/b\n")
        self.assertEqual(links(text), [(2, "1.2.3", True), (4, "1.2.3", False)])


if __name__ == "__main__":
    unittest.main()
