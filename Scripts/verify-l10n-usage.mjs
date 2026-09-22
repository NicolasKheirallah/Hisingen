#!/usr/bin/env node
// Two checks check-localization.py cannot do: that keys used in code exist in the
// strings table at all (its fallback returns the key, so parity stays green while
// every language shows English), and that the retention strings actually got
// translated instead of shipping value==key.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const sourcesDir = path.join(root, 'Sources', 'Hisingen');
const tablePath = path.join(sourcesDir, 'Resources', 'en.lproj', 'Localizable.strings');
const KEY_RE = /^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$/;

function walkSwift(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkSwift(p));
    else if (entry.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

// Swift string escapes are not JSON escapes (\u{00A0} especially), so decode them here.
function unescapeSwift(raw) {
  return raw.replace(/\\(u\{[0-9a-fA-F]+\}|.)/g, (whole, esc) => {
    if (esc.startsWith('u{')) return String.fromCodePoint(parseInt(esc.slice(2, -1), 16));
    switch (esc) {
      case 'n': return '\n';
      case 't': return '\t';
      case 'r': return '\r';
      case '"': return '"';
      case '\\': return '\\';
      default: return whole;
    }
  });
}

function parseTable(text) {
  const keys = new Map();
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('//')) continue;
    const m = KEY_RE.exec(trimmed);
    if (m) keys.set(unescapeSwift(m[1]), unescapeSwift(m[2]));
  }
  return keys;
}

const table = parseTable(fs.readFileSync(tablePath, 'utf8'));
const mode = process.argv[2] ?? '';

if (mode === '--retention') {
  // The retention horizons surface shipped with value==key in several locales;
  // every non-English table must carry real translations for these.
  const retentionKeys = [
    'Precise location retention',
    'High-volume sample retention',
    'Erase local history on sign out',
    'Prune Samples Older Than %d Days',
    'Keeps samples %d days. Charging and health summaries are kept %d days.',
    'Charging samples and telemetry older than %d days will be permanently removed. Summary sessions are kept.',
    'Off by default. Signing out keeps charging, trip and health history on this Mac; turn on to remove it with the session.',
  ];
  const resources = path.join(sourcesDir, 'Resources');
  const locales = fs.readdirSync(resources).filter((d) => d.endsWith('.lproj') && !d.startsWith('en.'));
  let failures = 0;
  for (const locale of locales) {
    const localized = parseTable(
      fs.readFileSync(path.join(resources, locale, 'Localizable.strings'), 'utf8')
    );
    for (const key of retentionKeys) {
      if (!table.has(key)) { console.error(`retention key missing from en table: ${key}`); failures++; continue; }
      const value = localized.get(key);
      if (value === undefined) { console.error(`${locale}: key absent: ${key}`); failures++; }
      else if (value === key || value === table.get(key)) { console.error(`${locale}: untranslated (value==English): ${key}`); failures++; }
    }
  }
  if (failures) { console.error(`RETENTION FAILED (${failures})`); process.exit(1); }
  console.log('RETENTION OK');
  process.exit(0);
}

const used = new Map(); // key -> first site
for (const file of walkSwift(sourcesDir)) {
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split(/\r?\n/);
  const re = /\bL10n\.(?:text|format)\(\s*"((?:[^"\\]|\\.)*)"/g;
  lines.forEach((line, i) => {
    let m;
    while ((m = re.exec(line))) {
      const key = unescapeSwift(m[1]);
      if (!used.has(key)) used.set(key, `${path.relative(root, file)}:${i + 1}`);
    }
  });
}

const missing = [...used.keys()].filter((k) => !table.has(k)).sort();
for (const key of missing) console.error(`missing from en table: "${key}"  (used at ${used.get(key)})`);
if (missing.length) {
  console.error(`L10N USAGE FAILED (${missing.length} of ${used.size} keys)`);
  process.exit(1);
}
console.log(`L10N USAGE OK (${used.size} keys checked)`);
