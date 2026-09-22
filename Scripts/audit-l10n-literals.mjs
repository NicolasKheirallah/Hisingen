#!/usr/bin/env node
// Audits that every user-facing string literal routed through L10n actually has a key in the
// English strings table. L10n falls back to the key itself, so a missing key renders English
// for every locale and the parity checker (which diffs other locales against en) cannot see
// it. This scan closes that blind spot.
//
// Patterns audited:
//   L10n.text("Key")              / L10n.format("Key", ...)
//   L10n.displayLocale-agnostic literal titles in App Intents:
//   static let title: LocalizedStringResource = "Key"
//   static let parameterTitle / requestValueDialog patterns using LocalizedStringResource literals
//
// A committed baseline (Scripts/l10n-literals-baseline.json) lists keys that predate this
// audit and are still unkeyed. The gate fails on anything NEW: new code must key its strings;
// baseline entries are retired by adding the key, not by editing the gate.
//
// Prints AUDIT_L10N_PASSED and exits 0 when every discovered key either exists in en.lproj
// or is recorded in the baseline.

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const sourcesDir = path.join(root, "Sources", "Hisingen");
const enPath = path.join(sourcesDir, "Resources", "en.lproj", "Localizable.strings");
const baselinePath = path.join(root, "Scripts", "l10n-literals-baseline.json");

function walk(dir, files = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, files);
    else if (entry.name.endsWith(".swift")) files.push(full);
  }
  return files;
}

function parseEnKeys(text) {
  const keys = new Set();
  const line = /^\s*"((?:[^"\\]|\\.)*)"\s*=/;
  for (const row of text.split("\n")) {
    const m = row.match(line);
    if (m) keys.add(m[1].replace(/\\"/g, '"'));
  }
  return keys;
}

const enKeys = parseEnKeys(fs.readFileSync(enPath, "utf8"));
const baseline = new Set(JSON.parse(fs.readFileSync(baselinePath, "utf8")));

const patterns = [
  /L10n\.text\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]/g,
  /L10n\.format\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]/g,
  /static\s+let\s+title:\s*LocalizedStringResource\s*=\s*"((?:[^"\\]|\\.)*)"/g,
  /static\s+let\s+(?:openInAppName|shortTitle):\s*LocalizedStringResource\s*=\s*"((?:[^"\\]|\\.)*)"/g,
];

const missing = new Map(); // key -> [file:line]
for (const file of walk(sourcesDir)) {
  const text = fs.readFileSync(file, "utf8");
  const relative = path.relative(root, file);
  text.split("\n").forEach((row, index) => {
    for (const pattern of patterns) {
      pattern.lastIndex = 0;
      let m;
      while ((m = pattern.exec(row)) !== null) {
        const key = m[1].replace(/\\"/g, '"');
        if (!enKeys.has(key)) {
          const at = `${relative}:${index + 1}`;
          missing.set(key, [...(missing.get(key) ?? []), at]);
        }
      }
    }
  });
}

const unbaselined = [...missing.keys()].filter((key) => !baseline.has(key));
if (unbaselined.length > 0) {
  console.error(`AUDIT_L10N_FAILED: ${unbaselined.length} new string literal(s) have no en.lproj key:`);
  for (const key of unbaselined.sort()) {
    console.error(`  "${key}"  at ${missing.get(key).join(", ")}`);
  }
  process.exit(1);
}

const retired = [...baseline].filter((key) => enKeys.has(key) || !missing.has(key));
console.log(`AUDIT_L10N_PASSED: all literals keyed or baselined (${baseline.size} baselined, ${retired.length} ready to retire)`);
