#!/usr/bin/env python3
"""Checks that the two shells hold the same theme tokens.

The Plasma shell's Theme.qml and the macOS shell's ThemeCatalog.swift hold
the same colours in two languages; a theme changed in one and not the other
would leave the shells looking different. The type scale and the motion
steps live in Theme.qml and Theme.swift, and are checked the same way. Run
it from the repository's root:

    python3 scripts/check_themes.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QML = ROOT / "ui/plasma/qml/Theme.qml"
SWIFT = ROOT / "ui/macos/Sources/OmegaNotchKit/ThemeCatalog.swift"
SWIFT_THEME = ROOT / "ui/macos/Sources/OmegaNotch/Theme.swift"


def parse_qml(path):
    """The themes in Theme.qml: {name: {token: "#AARRGGBB"}}."""
    themes, cur, in_colors = {}, None, False
    for line in path.read_text().splitlines():
        if in_colors:
            if re.match(r"^\s{12}\}$", line):
                in_colors = False
                continue
            for token, value in re.findall(
                r'(\w+):\s*"(#[0-9A-Fa-f]{8}|#[0-9A-Fa-f]{6})"', line
            ):
                if cur:
                    themes[cur][token] = value.upper()
            continue
        theme_header = re.match(r"^\s{8}(\w+): \{$", line)
        if theme_header:
            cur = theme_header.group(1)
            themes[cur] = {}
            continue
        if re.match(r"^\s{12}colors: \{$", line):
            in_colors = True
            continue
        if re.match(r"^\s{8}\},$", line):
            cur = None
    return themes


def parse_swift(path):
    """The themes in ThemeCatalog.swift: {name: {token: (hex, alpha)}}."""
    themes, cur = {}, None
    for line in path.read_text().splitlines():
        header = re.match(r"\s*static let (\w+): \[String: ThemeColor\] = \[$", line)
        if header:
            cur = header.group(1)
            themes[cur] = {}
            continue
        if cur is None:
            continue
        for token, hexa, alpha in re.findall(
            r'"(\w+)":\s*ThemeColor\("(#[0-9A-Fa-f]{6})"(?:,\s*([0-9a-fA-Fx.]+)\s*/\s*255)?\)', line
        ):
            themes[cur][token] = (hexa.upper(), _alpha(alpha))
        for token, white in re.findall(
            r'"(\w+)":\s*\.white\(([0-9a-fA-Fx.]+)\s*/\s*255\)', line
        ):
            themes[cur][token] = ("#FFFFFF", _alpha(white))
        if re.match(r"^\s*\]", line):
            cur = None
    return themes


def _alpha(value):
    if not value:
        return 1.0
    return round(float(int(value, 16) if value.startswith("0x") else value) / 255, 4)


def qml_value(value):
    """A colour as Theme.qml writes it, as (hex, alpha)."""
    if len(value) == 9:
        return "#" + value[3:], round(int(value[1:3], 16) / 255, 4)
    return value, 1.0


def parse_defaults(path):
    """The tokens Theme.qml starts with, before any theme is applied."""
    defaults = {}
    for line in path.read_text().splitlines():
        m = re.match(r'\s*property color (\w+):\s*"(#[0-9A-Fa-f]{8}|#[0-9A-Fa-f]{6})"', line)
        if m:
            defaults[m.group(1)] = m.group(2).upper()
    return defaults


def parse_qml_scale(path):
    """The type/motion tokens in Theme.qml, as {name: number or tuple}."""
    text = path.read_text()
    scale = {}
    for m in re.finditer(
        r"readonly property (?:int|real|double) (type\w+|motion\w+):\s*([0-9.]+)\s*$",
        text,
        re.MULTILINE,
    ):
        scale[m.group(1)] = float(m.group(2))
    for m in re.finditer(r"readonly property var (motion\w+):\s*\[([^\]]*)\]", text):
        scale[m.group(1)] = tuple(round(float(v), 4) for v in m.group(2).split(","))
    return scale


def parse_swift_scale(path):
    """The type/motion tokens in Theme.swift, as {name: number or tuple}."""
    text = path.read_text()
    scale = {}
    for m in re.finditer(
        r"static let (type\w+|motion\w+):\s*(?:CGFloat|Double|Int)\s*=\s*([0-9.]+)\s*$",
        text,
        re.MULTILINE,
    ):
        scale[m.group(1)] = float(m.group(2))
    for m in re.finditer(r"static let (motion\w+):\s*\[Double\]\s*=\s*\[([^\]]*)\]", text):
        scale[m.group(1)] = tuple(round(float(v), 4) for v in m.group(2).split(","))
    return scale


def main():
    qml = parse_qml(QML)
    swift = parse_swift(SWIFT)
    problems = []

    for name, tokens in qml.items():
        other = swift.get(name)
        if other is None:
            problems.append(f"{name}: the macOS shell has no such theme")
            continue
        if set(tokens) != set(other):
            problems.append(
                f"{name}: the tokens differ; only in Plasma={sorted(set(tokens) - set(other))} "
                f"only in macOS={sorted(set(other) - set(tokens))}"
            )
        for token, value in tokens.items():
            if token not in other:
                continue
            if qml_value(value) != other[token]:
                problems.append(
                    f"{name}.{token}: Plasma {qml_value(value)} but macOS {other[token]}"
                )

    for name in swift:
        if name not in qml:
            problems.append(f"{name}: the Plasma shell has no such theme")

    # The app starts in the default theme, so Theme.qml's own tokens have to
    # be the default theme's.
    defaults = parse_defaults(QML)
    default_theme = qml.get("noir", {})
    for token, value in defaults.items():
        if token in default_theme and qml_value(value) != qml_value(default_theme[token]):
            problems.append(
                f"the default {token} is {value}, but the Noir theme says {default_theme[token]}"
            )

    if problems:
        print("The shells' themes have drifted apart:")
        for problem in problems:
            print("  " + problem)
        return 1
    total = sum(len(tokens) for tokens in qml.values())

    # The type scale and the motion steps, held in Theme.qml and Theme.swift.
    qml_scale = parse_qml_scale(QML)
    swift_scale = parse_swift_scale(SWIFT_THEME)
    for name in sorted(set(qml_scale) | set(swift_scale)):
        if name not in swift_scale:
            problems.append(f"{name}: the macOS shell has no such type/motion token")
        elif name not in qml_scale:
            problems.append(f"{name}: the Plasma shell has no such type/motion token")
        elif qml_scale[name] != swift_scale[name]:
            problems.append(
                f"{name}: Plasma {qml_scale[name]} but macOS {swift_scale[name]}"
            )

    if problems:
        print("The shells' themes have drifted apart:")
        for problem in problems:
            print("  " + problem)
        return 1
    print(
        f"The shells agree on {len(qml)} themes and {total} tokens, "
        f"plus {len(qml_scale)} type and motion steps."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
