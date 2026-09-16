#!/usr/bin/env python3
"""Enforce the contrast claims the theme files make about themselves.

Three token modules assert that this script recomputes their ratios:

  * ``Palette.swift``                    – the per-theme ``accent`` guarantee
  * ``HisingenTheme+Surfaces.swift``     – the card / chip / boundary claims
  * ``HisingenTheme+StatusColors.swift`` – "recomputes every one of these pairs and fails the build"

Those claims were true of the prose and false of the repository: the script did not exist, so
nothing enforced them and a tenth theme could be added with no signal. It parses the
``Color(light:dark:)`` pairs straight out of Swift source rather than restating them, so a token
edit is checked without anyone remembering to update a fixture here.

Ratios are computed per WCAG 2.x: relative luminance from linearised sRGB channels, then
``(L_lighter + 0.05) / (L_darker + 0.05)``.

What is checked, and against which floor:

  * ``ink`` / ``inkMuted`` against ``canvas`` and against the card        – 4.5:1 (WCAG 1.4.3 AA)
  * ``accent`` as text against the card and its own 12 % wash             – 4.5:1
  * every semantic status token as text, same two surfaces               – 4.5:1
  * ``polestarAmber`` as text against the Polestar canvas                 – 3:1
  * the Increase Contrast card boundary against ``canvas``                – 3:1 (WCAG 1.4.11)
  * each chart series against the card, and the two that share axes        – 3:1 (WCAG 1.4.11)
  * the chip fill is darker than the card it sits on (structural, no ratio)

The status family is checked because it is used as 10–12 pt text inside ``Pill``,
``StateSummaryChip`` and ``CommandReceiptChip``, which draw it on a 12 % wash of itself over a
card; the accent is checked for the same reason (selected control labels, counters, badges), which
is also why ``Palette`` holds accent-tinted text backgrounds at or below 12 %.

Usage:
    python3 Scripts/verify-app-contrast.py            # check, exit non-zero on failure
    python3 Scripts/verify-app-contrast.py --verbose  # print every measured pair
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass

THEME_DIR = pathlib.Path("Sources/Hisingen/UI/Theme")
PALETTE_MODULE = THEME_DIR / "Palette.swift"
PALETTE = THEME_DIR / "HisingenTheme+Palette.swift"
SURFACES = THEME_DIR / "HisingenTheme+Surfaces.swift"
STATUS_COLORS = THEME_DIR / "HisingenTheme+StatusColors.swift"

# Every theme the palette defines, in the order `AppTheme` declares them.
THEMES = [
    "polestar",
    "volvo",
    "hisingen",
    "nordicNight",
    "aurora",
    "swedishGold",
    "cyanRacing",
    "forest",
    "sandDune",
]

APPEARANCES = ["light", "dark"]

TEXT_FLOOR = 4.5
GRAPHIC_FLOOR = 3.0

# The card / chip derivation, mirroring `Palette.surface(_:lift:sink:)` and the values passed to
# it by `Palette.cardFill` and `Palette.chipFill`. Kept in sync by hand: if a lift changes in
# Swift, change it here too, or this script measures a surface the app no longer draws.
CARD_LIFT = {"light": 0.55, "dark": 0.16}
CHIP_SINK = {"light": 0.05, "dark": 0.28}

# The wash a status chip or an accent-tinted control draws under its own label.
TEXT_WASH = 0.12

STATUS_TOKENS = [
    "semanticGood",
    "semanticActive",
    "semanticWarning",
    "semanticCritical",
    "semanticFault",
    "semanticFuel",
]

CHART_TOKENS = {
    "chartPositive": "chartPos",
    "chartInfo": "chartInf",
    "chartAttention": "chartAtt",
    "chartHealth": "chartHlt",
}


@dataclass(frozen=True)
class RGB:
    r: float
    g: float
    b: float

    def __str__(self) -> str:
        return f"#{round(self.r * 255):02X}{round(self.g * 255):02X}{round(self.b * 255):02X}"

    def over(self, backdrop: "RGB", alpha: float) -> "RGB":
        """This colour composited at `alpha` over an opaque backdrop."""
        return RGB(
            self.r * alpha + backdrop.r * (1 - alpha),
            self.g * alpha + backdrop.g * (1 - alpha),
            self.b * alpha + backdrop.b * (1 - alpha),
        )

    def lifted(self, lift: float, sink: float = 0.0) -> "RGB":
        """`lift` of the way to white, then `sink` of the way to black. See `Palette`."""
        def channel(v: float) -> float:
            return (v + (1 - v) * lift) * (1 - sink)

        return RGB(channel(self.r), channel(self.g), channel(self.b))


def _linearise(channel: float) -> float:
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def luminance(colour: RGB) -> float:
    r, g, b = (_linearise(c) for c in (colour.r, colour.g, colour.b))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a: RGB, b: RGB) -> float:
    la, lb = luminance(a), luminance(b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


# MARK: - Parsing


def _strip_comments(source: str) -> str:
    """Drop // and /* */ comments so a ratio quoted in prose is never parsed as a colour."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def _parse_nscolor(expression: str) -> RGB | None:
    """Parse the NSColor forms the theme files use, or None if the form is unsupported."""
    expression = expression.strip()

    named = re.fullmatch(r"NSColor\.(white|black)", expression)
    if named:
        value = 1.0 if named.group(1) == "white" else 0.0
        return RGB(value, value, value)

    # NSColor(white: 0.98, alpha: 1)
    white = re.fullmatch(r"NSColor\(\s*white:\s*([0-9.]+)\s*,\s*alpha:\s*[0-9.]+\s*\)", expression)
    if white:
        value = float(white.group(1))
        return RGB(value, value, value)

    # NSColor(red: 0x1e/255, green: 0x3a/255, blue: 0x5f/255, alpha: 1)
    hex_form = re.fullmatch(
        r"NSColor\(\s*red:\s*0x([0-9a-fA-F]+)/255\s*,\s*green:\s*0x([0-9a-fA-F]+)/255\s*,"
        r"\s*blue:\s*0x([0-9a-fA-F]+)/255\s*,\s*alpha:\s*[0-9.]+\s*\)",
        expression,
    )
    if hex_form:
        r, g, b = (int(hex_form.group(i), 16) / 255 for i in (1, 2, 3))
        return RGB(r, g, b)

    # NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    decimal = re.fullmatch(
        r"NSColor\(\s*red:\s*([0-9.]+)\s*,\s*green:\s*([0-9.]+)\s*,\s*blue:\s*([0-9.]+)\s*,"
        r"\s*alpha:\s*[0-9.]+\s*\)",
        expression,
    )
    if decimal:
        return RGB(*(float(decimal.group(i)) for i in (1, 2, 3)))

    return None


def _pair_in(body: str) -> tuple[RGB, RGB] | None:
    """The (light, dark) pair in a fragment, or None if it declares no parseable pair.

    The light colour is the first NSColor expression and the dark colour is the one that follows
    the `dark:` label. Scanning for those two anchors is more robust than matching the enclosing
    `Color(light:dark:)`, whose arguments nest parentheses.
    """
    dark_label = re.search(r"dark:", body)
    if not dark_label:
        return None
    light = None
    for match in re.finditer(r"NSColor(?:\((?:[^()]|\([^()]*\))*\)|\.(?:white|black))", body):
        if match.start() > dark_label.end() and light is not None:
            dark = _parse_nscolor(match.group(0))
            if dark:
                return light, dark
        elif light is None:
            light = _parse_nscolor(match.group(0))
    return None


def _find_dynamic_pair(source: str, anchor: str) -> tuple[RGB, RGB] | None:
    """First dual-appearance pair declared at or after `anchor` (a unique declaration prefix)."""
    start = source.find(anchor)
    if start < 0:
        return None
    return _pair_in(source[start : start + 400])


def _palette_blocks(source: str) -> dict[str, str]:
    """Split `static let <theme> = Palette( ... )` into its argument body, per theme."""
    blocks: dict[str, str] = {}
    for match in re.finditer(r"static let (\w+)\s*=\s*Palette\(", source):
        start = match.end()
        depth = 1
        index = start
        while index < len(source) and depth > 0:
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
            index += 1
        blocks[match.group(1)] = source[start : index - 1]
    return blocks


def _field(block: str, field: str) -> tuple[RGB, RGB] | None:
    """The dual-appearance pair of a named `Palette` field."""
    match = re.search(rf"(?<![A-Za-z0-9_]){re.escape(field)}:\s*", block)
    if not match:
        return None
    return _pair_in(block[match.end() : match.end() + 400])


def _rgb_tuple(block: str, field: str) -> RGB | None:
    """A raw `(r, g, b)` component tuple, e.g. `canvasLightRGB: (0.96, 0.97, 0.98)`."""
    match = re.search(
        rf"(?<![A-Za-z0-9_]){re.escape(field)}:\s*\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)",
        block,
    )
    if not match:
        return None
    return RGB(*(float(match.group(i)) for i in (1, 2, 3)))


# MARK: - Checks


@dataclass
class Failure:
    label: str
    ratio: float
    floor: float

    def __str__(self) -> str:
        return f"{self.label}: {self.ratio:.2f}:1 is below the {self.floor}:1 floor"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verbose", action="store_true", help="print every measured pair")
    args = parser.parse_args()

    required = (PALETTE_MODULE, PALETTE, SURFACES, STATUS_COLORS)
    missing = [p for p in required if not p.exists()]
    if missing:
        print(f"contrast: cannot find {', '.join(str(p) for p in missing)}", file=sys.stderr)
        print("contrast: run this from the repository root", file=sys.stderr)
        return 1

    module = _strip_comments(PALETTE_MODULE.read_text(encoding="utf-8"))
    surfaces = _strip_comments(SURFACES.read_text(encoding="utf-8"))
    status = _strip_comments(STATUS_COLORS.read_text(encoding="utf-8"))
    accessory = _strip_comments(PALETTE.read_text(encoding="utf-8"))
    combined = "\n".join((module, surfaces, status, accessory))

    blocks = _palette_blocks(module)
    absent = [theme for theme in THEMES if theme not in blocks]
    if absent:
        print(f"contrast: could not parse Palette for: {', '.join(absent)}", file=sys.stderr)
        return 1

    def per_theme(field: str) -> dict[str, tuple[RGB, RGB]]:
        table: dict[str, tuple[RGB, RGB]] = {}
        for theme in THEMES:
            pair = _field(blocks[theme], field)
            if pair:
                table[theme] = pair
        return table

    canvas = per_theme("canvas")
    ink = per_theme("ink")
    ink_muted = per_theme("inkMuted")
    accent = per_theme("accent")

    for name, table in (("canvas", canvas), ("ink", ink), ("inkMuted", ink_muted), ("accent", accent)):
        if len(table) != len(THEMES):
            missing_themes = ", ".join(t for t in THEMES if t not in table)
            print(f"contrast: could not parse `{name}` for: {missing_themes}", file=sys.stderr)
            return 1

    # The card and chip fills are derived in Swift from the canvas; recompute them the same way.
    card: dict[str, tuple[RGB, RGB]] = {}
    chip: dict[str, tuple[RGB, RGB]] = {}
    for theme in THEMES:
        raw = {
            appearance: _rgb_tuple(blocks[theme], f"canvas{appearance.capitalize()}RGB")
            for appearance in APPEARANCES
        }
        if any(value is None for value in raw.values()):
            print(f"contrast: could not parse canvasLightRGB/canvasDarkRGB for {theme}", file=sys.stderr)
            return 1
        card[theme] = tuple(  # type: ignore[assignment]
            raw[appearance].lifted(CARD_LIFT[appearance]) for appearance in APPEARANCES
        )
        chip[theme] = tuple(  # type: ignore[assignment]
            raw[appearance].lifted(CARD_LIFT[appearance], CHIP_SINK[appearance])
            for appearance in APPEARANCES
        )

    amber = _find_dynamic_pair(combined, "static let polestarAmber")
    if amber is None:
        print("contrast: could not parse polestarAmber", file=sys.stderr)
        return 1

    boundary = _find_dynamic_pair(combined, "static let cardBoundaryIncreased")
    if boundary is None:
        print("contrast: could not parse cardBoundaryIncreased", file=sys.stderr)
        return 1

    statuses: dict[str, tuple[RGB, RGB]] = {}
    for name in STATUS_TOKENS:
        pair = _find_dynamic_pair(status, f"static let {name}")
        if pair is None:
            print(f"contrast: could not parse {name}", file=sys.stderr)
            return 1
        statuses[name] = pair

    chart: dict[str, tuple[RGB, RGB]] = {}
    for name, swift_name in CHART_TOKENS.items():
        pair = _find_dynamic_pair(module, f"static let {swift_name}")
        if pair is None:
            print(f"contrast: could not parse chart token {swift_name}", file=sys.stderr)
            return 1
        chart[name] = pair

    failures: list[Failure] = []
    measured = 0

    def check(label: str, fg: RGB, bg: RGB, floor: float) -> None:
        nonlocal measured
        measured += 1
        ratio = contrast(fg, bg)
        status_text = "ok  " if ratio >= floor else "FAIL"
        if args.verbose or ratio < floor:
            print(f"  {status_text} {ratio:6.2f}:1  {label}")
        if ratio < floor:
            failures.append(Failure(label, ratio, floor))

    print("Text tiers against canvas and card (floor 4.5:1, WCAG 1.4.3 AA)")
    for theme in THEMES:
        for appearance, index in (("light", 0), ("dark", 1)):
            for token_name, table in (("ink", ink), ("inkMuted", ink_muted)):
                check(
                    f"{theme}/{appearance} {token_name} on canvas",
                    table[theme][index],
                    canvas[theme][index],
                    TEXT_FLOOR,
                )
                check(
                    f"{theme}/{appearance} {token_name} on card",
                    table[theme][index],
                    card[theme][index],
                    TEXT_FLOOR,
                )

    print("Accent as text on the card and on its own 12 % wash (floor 4.5:1)")
    for theme in THEMES:
        for appearance, index in (("light", 0), ("dark", 1)):
            foreground = accent[theme][index]
            backdrop = card[theme][index]
            check(f"{theme}/{appearance} accent on card", foreground, backdrop, TEXT_FLOOR)
            check(
                f"{theme}/{appearance} accent on 12 % accent wash",
                foreground,
                foreground.over(backdrop, TEXT_WASH),
                TEXT_FLOOR,
            )

    print("Semantic status tokens as text on the card and their own 12 % wash (floor 4.5:1)")
    for theme in THEMES:
        for appearance, index in (("light", 0), ("dark", 1)):
            backdrop = card[theme][index]
            for name, pair in statuses.items():
                foreground = pair[index]
                check(f"{theme}/{appearance} {name} on card", foreground, backdrop, TEXT_FLOOR)
                check(
                    f"{theme}/{appearance} {name} on 12 % wash",
                    foreground,
                    foreground.over(backdrop, TEXT_WASH),
                    TEXT_FLOOR,
                )

    print("Polestar amber as text on the Polestar canvas (floor 3:1, large text)")
    for appearance, index in (("light", 0), ("dark", 1)):
        check(
            f"polestar/{appearance} polestarAmber on canvas",
            amber[index],
            canvas["polestar"][index],
            GRAPHIC_FLOOR,
        )

    print("Card boundary against canvas, Increase Contrast (floor 3:1, WCAG 1.4.11)")
    for theme in THEMES:
        for appearance, index in (("light", 0), ("dark", 1)):
            check(
                f"{theme}/{appearance} cardBoundaryIncreased on canvas",
                boundary[index],
                canvas[theme][index],
                GRAPHIC_FLOOR,
            )

    print("Chart series against the card and against each other (floor 3:1, WCAG 1.4.11)")
    for theme in THEMES:
        for appearance, index in (("light", 0), ("dark", 1)):
            for name in CHART_TOKENS:
                check(
                    f"{theme}/{appearance} {name} on card",
                    chart[name][index],
                    card[theme][index],
                    GRAPHIC_FLOOR,
                )
    for appearance, index in (("light", 0), ("dark", 1)):
        check(
            f"{appearance} chartInfo vs chartAttention (plotted on shared axes)",
            chart["chartInfo"][index],
            chart["chartAttention"][index],
            GRAPHIC_FLOOR,
        )

    print("Chip fill reads as inset on the card (no ratio floor; darker in both appearances)")
    for theme in THEMES:
        for appearance, index in (("light", 0), ("dark", 1)):
            measured += 1
            if luminance(chip[theme][index]) >= luminance(card[theme][index]):
                failures.append(
                    Failure(
                        f"{theme}/{appearance} chipFill is not darker than cardFill",
                        contrast(chip[theme][index], card[theme][index]),
                        1.0,
                    )
                )
            elif args.verbose:
                print(
                    f"  ok   {contrast(chip[theme][index], card[theme][index]):6.2f}:1  "
                    f"{theme}/{appearance} chipFill on cardFill"
                )

    print()
    if failures:
        print(f"contrast: FAILED — {len(failures)} of {measured} pairs below floor")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"contrast: passed — {measured} pairs at or above their floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
