#!/usr/bin/env python3
"""Fail when a destructive entry point can erase every vehicle by omission.

"Erase local vehicle data" once reached a whole-database wipe through ordinary
optional propagation: `SettingsDatabaseCard` passed `state?.identity.vin`, a nil
snapshot made that `nil`, and every storage tier read `nil` as "every vehicle" —
thirteen unscoped `DELETE FROM` statements while the reader was told the erase
succeeded.

The rule enforced here: a per-vehicle erase must be impossible to spell without
a vehicle. "All vehicles" is allowed, but only through an entry point that names
it, so an optional VIN parameter carrying a default is rejected on any
destructive member. The explicitly-named fleet-wide members are also listed, so
a reviewer can confirm each one is deliberate rather than inherited.

Not yet enforced: VIN normalization belonging to one module rather than to the
29 call sites that re-derive it. That rule needs the `VIN` value type to have a
home to point at.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"

# Members whose name promises destruction. A defaulted optional VIN on one of
# these is the shape that let an omitted argument mean "everything".
DESTRUCTIVE = re.compile(r"^(wipe|clear|delete|erase|drop|remove)", re.IGNORECASE)

# A VIN parameter that callers may simply not pass.
OPTIONAL_VIN_PARAMETER = re.compile(r"\bvin\s*:\s*String\?\s*=")

FUNC = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)", re.DOTALL)

# Fleet-wide members have to say so in their name.
NAMES_THE_SCOPE = re.compile(r"(All|Everything|EveryVehicle|Fleet)", re.IGNORECASE)


def swift_files() -> list[pathlib.Path]:
    return sorted(SOURCES.rglob("*.swift"))


def scan() -> tuple[list[str], list[str]]:
    violations: list[str] = []
    fleet_wide: list[str] = []
    for path in swift_files():
        text = path.read_text(encoding="utf-8")
        for match in FUNC.finditer(text):
            name, params = match.group(1), match.group(2)
            where = path.relative_to(ROOT)
            line = text.count("\n", 0, match.start()) + 1
            if not DESTRUCTIVE.match(name):
                continue
            if OPTIONAL_VIN_PARAMETER.search(params):
                violations.append(
                    f"{where}:{line}: {name}(…) takes a defaulted optional VIN — "
                    "'all vehicles' must be a named call, not an omitted argument"
                )
            elif "String" in params and "vin" in params and NAMES_THE_SCOPE.search(name):
                fleet_wide.append(f"{where}:{line}: {name}(…)")
    return violations, fleet_wide


def main() -> int:
    violations, fleet_wide = scan()

    if fleet_wide:
        print(f"Fleet-wide destructive members ({len(fleet_wide)}) — confirm each is deliberate:")
        for entry in fleet_wide:
            print(f"  {entry}")
        print()

    if violations:
        print("Destructive members can widen to every vehicle by omission:", file=sys.stderr)
        for entry in violations:
            print(f"  {entry}", file=sys.stderr)
        print(
            "\nGive the member a required vehicle and add a separately-named "
            "fleet-wide counterpart.",
            file=sys.stderr,
        )
        return 1

    print(
        f"No destructive member accepts a defaulted optional VIN "
        f"({len(swift_files())} files checked)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
