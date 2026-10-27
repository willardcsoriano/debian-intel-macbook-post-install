"""Check a keyd config (or keyd-application-mapper app.conf) against keyd
2.5.0's grammar: key names from `keyd list-keys`, modifiers, layer
references, composite-layer order, and macro() for key sequences.

keyd itself skips a line it can't parse and runs with the rest, so a mistake
here becomes a key that silently does nothing. keyd 2.5.0 has no command to
check a file, so this does it.

    python3 tests/keyd_validate.py conf FILE
    python3 tests/keyd_validate.py app FILE LAYER[,LAYER...]
"""
import os
import re
import sys

KEYS_FILE = os.path.join(os.path.dirname(__file__), "keyd-keys-2.5.0.txt")
MODIFIERS = set("CMASG")
ALIASES = {"meta", "control", "shift", "alt", "altgr"}
BUILTIN_LAYERS = {"main", "control", "shift", "alt", "meta", "altgr"}
LAYER_ACTIONS = re.compile(r"(layer|swap|toggle|oneshot)\((\w+)\)")
LAYER_MACRO_ACTIONS = re.compile(r"(swapm|layerm|togglem|oneshotm)\((\w+),\s*(.+)\)")


def known_keys():
    with open(KEYS_FILE, encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip() and not line.startswith("#")}


def validate(text, mode, keys, extra_layers=()):
    """Returns (errors, layers in definition order). mode is "conf" for
    /etc/keyd/*.conf or "app" for app.conf, whose bindings name layers that
    live in the main config (extra_layers)."""
    errors, layers, order, refs = [], set(BUILTIN_LAYERS), [], []

    def key(token, where):
        *mods, name = token.split("-") if token != "-" else [token]
        for m in mods:
            if m not in MODIFIERS:
                errors.append(f"{where}: bad modifier {m!r} in {token!r}")
        if name not in keys:
            errors.append(f"{where}: unknown key {name!r} in {token!r}")

    def macro_token(token, where):
        # keyd also takes a pause ("50ms", under 1024) and types any other
        # group of characters as text. Text is only accepted when it holds a
        # character no key name has (a path's "/"), so a misspelt key name
        # is still an error rather than typed out.
        m = re.fullmatch(r"(\d+)ms", token)
        if m:
            if int(m.group(1)) >= 1024:
                errors.append(f"{where}: pause {token!r} must be under 1024ms")
            return
        if "/" in token and token.isprintable():
            return
        key(token, where)

    def action(value, where):
        m = LAYER_ACTIONS.fullmatch(value)
        if m:
            refs.append((m.group(2), where))
            return
        m = LAYER_MACRO_ACTIONS.fullmatch(value)
        if m:
            refs.append((m.group(2), where))
            for token in m.group(3).split():
                key(token, where)
            return
        if value.startswith("command(") or value == "noop":
            return
        m = re.fullmatch(r"macro\((.+)\)", value)
        if m:
            for token in m.group(1).split():
                macro_token(token, where)
            return
        if len(value.split()) != 1:
            # keyd: "invalid key or action", and the line is dropped
            errors.append(f"{where}: {value!r} is several keys; wrap it in macro(...)")
            return
        key(value, where)

    section = None
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = f"line {n}"
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            if mode == "app":
                continue
            name, _, mods = section.partition(":")
            for m in filter(None, mods.split("-")):
                if m not in MODIFIERS:
                    errors.append(f"{where}: bad layer modifier {m!r}")
            if "+" in name:
                for part in name.split("+"):
                    if part not in layers:
                        errors.append(f"{where}: composite part {part!r} must be defined before [{section}]")
            layers.add(name)
            order.append(name)
            continue
        if mode == "conf" and section == "ids":
            continue
        if "=" not in line:
            errors.append(f"{where}: not a binding: {line!r}")
            continue
        lhs, value = (x.strip() for x in line.split("=", 1))
        if mode == "app":
            layer, _, name = lhs.rpartition(".")
            if layer:
                refs.append((layer, where))
        else:
            name = lhs
        if name not in keys and name not in ALIASES:
            errors.append(f"{where}: unknown key {name!r}")
        action(value, where)

    layers |= set(extra_layers)
    for name, where in refs:
        if name not in layers:
            errors.append(f"{where}: layer {name!r} is not defined")
    return errors, order


def main(argv):
    if len(argv) < 3 or argv[1] not in ("conf", "app"):
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[2], encoding="utf-8") as f:
        text = f.read()
    extra = argv[3].split(",") if len(argv) > 3 else ()
    errors, order = validate(text, argv[1], known_keys(), extra)
    print("\n".join(errors) if errors else f"OK: layers {order or 'n/a'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
