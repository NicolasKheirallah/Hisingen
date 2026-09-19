#!/usr/bin/env node
// Surface discipline for the 2026 (Liquid Glass) design language.
//
// The redesign removed four ornaments from the default card path and concentrated glass
// drawing in one theme token. Those decisions decay quietly: a new call site re-adds a
// stroke here, a copy-pasted glassEffect there, and the language drifts back. This script
// re-checks the invariants from source so the drift fails a gate instead of shipping.
//
// Checked against Sources/:
//   1. no specular rim: liquidGlassSpecularBorder and cardRim are gone entirely
//   2. glassEffect( appears only in Theme/ (the hisControlGlass / hisFloatingGlass tokens)
//   3. SwiftUI materials appear only in Theme/ (the one-translucent-surface rule)
//   4. cardBoundary(increasedContrast:) is the only boundary form (accessibility-only)
//   5. Card.swift draws no shadow beyond CardHeader's one permitted glyph glow
//   6. the chip family (Pill, StateSummaryChip, CommandReceiptChip) draws no stroke
//   7. the shadow ladder (SurfaceElevation / shadow(for:)) is gone
//   8. sections are not surfaces: cardSurface is gone and Card.swift draws no fill,
//      no background and no clip — content groups sit directly on the panel glass
//
// Usage: node Scripts/verify-surface-discipline.mjs   (from the repository root)

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOT = "Sources/Hisingen/UI";
const THEME = join(ROOT, "Theme");

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...walk(path));
    else if (name.endsWith(".swift")) out.push(path);
  }
  return out;
}

const files = walk(ROOT);
const failures = [];

function check(name, predicate, detail) {
  if (!predicate) failures.push(`${name}: ${detail}`);
}

function contains(path, needle) {
  return readFileSync(path, "utf8").includes(needle);
}

// 1 + 7 + 8: the ornaments, the ladder and the section surface are deleted, not merely unused.
for (const symbol of [
  "liquidGlassSpecularBorder",
  "cardRim",
  "SurfaceElevation",
  "shadow(for",
  "cardSurface",
]) {
  check(
    "ornaments removed",
    files.every((f) => !contains(f, symbol)),
    `"${symbol}" still appears in ${files.filter((f) => contains(f, symbol)).join(", ")}`
  );
}

// 2 + 3: glass and materials are theme-only.
for (const f of files) {
  const inTheme = f.startsWith(THEME);
  for (const needle of ["glassEffect(", ".regularMaterial", ".ultraThinMaterial", ".barMaterial"]) {
    if (!contains(f, needle)) continue;
    check(
      "theme-only drawing",
      inTheme,
      `"${needle}" outside Theme/: ${f}`
    );
  }
}

// 4: the boundary is accessibility-only. Every call must pass the contrast environment or a
//    literal true; `increasedContrast: false` is the always-on ornament the redesign removed.
//    Line comments are stripped first: doc comments name the token and would otherwise parse
//    as argument-less calls.
for (const f of files) {
  const source = readFileSync(f, "utf8").replace(/\/\/[^\n]*/g, "");
  if (!source.includes("cardBoundary(")) continue;
  const args = [...source.matchAll(/cardBoundary\(increasedContrast:\s*([^)]{0,60})\)/g)]
    .map((match) => match[1].trim());
  check("boundary is accessibility-only", args.length > 0, `cardBoundary( call not parseable in ${f}`);
  for (const arg of args) {
    check(
      "boundary is accessibility-only",
      arg === "Bool" || arg === "true" || (arg.includes("contrast") && !arg.includes("false")),
      `cardBoundary( drawn unconditionally in ${f}`
    );
  }
}

// 5 + 8: the section draws no shadow and no surface. CardHeader's pulsing glyph glow is the
//    one permitted focus accent (core R-13), so at most one `.shadow(` may appear in the file,
//    and the deleted shadow ladder must not be referenced. With no fill the clip is gone too.
const card = join(ROOT, "Components/Card.swift");
const cardSource = readFileSync(card, "utf8");
check(
  "section shadow",
  !cardSource.includes("CardShadow") &&
    !cardSource.includes("shadow(for") &&
    (cardSource.match(/\.shadow\(/g) ?? []).length <= 1,
  "Card.swift draws a section shadow"
);
for (const needle of [".background(", ".fill(", "clipShape", "Material"]) {
  check(
    "section surface",
    !cardSource.includes(needle),
    `Card.swift draws a surface: "${needle}"`
  );
}

// 6: the chip family is fill-only.
for (const chip of ["Pill.swift", "StateSummaryChip.swift", "CommandReceiptChip.swift"]) {
  const path = join(ROOT, "Components", chip);
  check("chip family", !contains(path, ".stroke("), `${chip} draws a stroke`);
}

if (failures.length > 0) {
  console.error("surface discipline: FAILED");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("surface discipline: verified — no ornaments, glass and materials theme-only, boundary accessibility-only");
