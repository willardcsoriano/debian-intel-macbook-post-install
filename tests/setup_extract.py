"""Pull generated files out of setup.sh, so tests check what the script
actually writes rather than a copy that can drift from it."""
import os
import re
import subprocess

SETUP = os.path.join(os.path.dirname(__file__), "..", "setup.sh")


def setup_text():
    with open(SETUP, encoding="utf-8") as f:
        return f.read()


def heredoc(opening_line_pattern, terminator):
    """Body of the heredoc whose opening line matches the regex, up to the
    line equal to terminator. Refuses to guess: exactly one match."""
    lines = setup_text().split("\n")
    starts = [i for i, line in enumerate(lines) if re.search(opening_line_pattern, line)]
    if len(starts) != 1:
        raise LookupError(f"{len(starts)} lines in setup.sh match {opening_line_pattern!r}")
    body = []
    for line in lines[starts[0] + 1:]:
        if line == terminator:
            return "\n".join(body) + "\n"
        body.append(line)
    raise LookupError(f"no {terminator!r} after {opening_line_pattern!r}")


def render_unquoted(body, variables):
    """Expand an unquoted heredoc the way bash would, for the forms the keyd
    config uses: \\$ \\\\ \\` and $NAME / ${NAME}. A backtick or $( that
    isn't escaped would run as a command when setup.sh writes the file, and
    any other variable is unexpected, so both are errors."""
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body) and body[i + 1] in "$`\\":
            out.append(body[i + 1])
            i += 2
            continue
        if c == "`":
            raise ValueError(f"unescaped backtick at offset {i}: runs as a command in an unquoted heredoc")
        if c == "$":
            m = re.match(r"\$(?:\{(\w+)\}|(\w+))", body[i:])
            if body.startswith("$(", i):
                raise ValueError(f"unescaped $( at offset {i}: runs as a command in an unquoted heredoc")
            if not m:
                out.append(c)
                i += 1
                continue
            name = m.group(1) or m.group(2)
            if name not in variables:
                raise ValueError(f"unexpected variable ${name} in the heredoc")
            out.append(str(variables[name]))
            i += m.end()
            continue
        out.append(c)
        i += 1
    return "".join(out)


def keyd_config(max_brightness=2777):
    body = heredoc(r'^sudo tee "\$KEYD_CONF" > /dev/null << EOF$', "EOF")
    return render_unquoted(body, {"MAX_BRIGHTNESS": max_brightness})


def app_conf():
    """Run the block that writes ~/.config/keyd/app.conf, with its output
    sent to stdout instead. It only echoes and cats, so running it is safe."""
    lines = setup_text().split("\n")
    marker = [line for line in lines if line.startswith("KAM_MARKER=")]
    start = [i for i, line in enumerate(lines) if line == "    {"]
    end = [i for i, line in enumerate(lines) if line == '    } > "$KAM_CONF"']
    if len(marker) != 1 or len(start) != 1 or len(end) != 1:
        raise LookupError("app.conf block not found exactly once in setup.sh")
    script = marker[0] + "\n" + "\n".join(lines[start[0]:end[0]]) + "\n    }\n"
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True).stdout
