#!/usr/bin/env node
// Ratchets for the UI review of 2026-09-22. Each section is one honest gate:
// it scans the shipped sources for a concrete regression and exits nonzero
// listing the violations. `node Scripts/verify-ui-discipline.mjs` runs every
// section; pass a section name to run one.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const uiDir = path.join(root, 'Sources', 'Hisingen', 'UI');

function walkSwift(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkSwift(p));
    else if (entry.name.endsWith('.swift')) out.push(p);
  }
  return out;
}
const files = walkSwift(uiDir).map((p) => ({
  rel: path.relative(root, p),
  lines: fs.readFileSync(p, 'utf8').split(/\r?\n/),
}));

function windowJoin(lines, i, before, after) {
  return lines.slice(Math.max(0, i - before), i + after).join('\n');
}

const failures = [];
function fail(section, msg) {
  failures.push(`[${section}] ${msg}`);
}

// --- format: every String(format:) in UI pins L10n.displayLocale -------------
function checkFormat() {
  for (const { rel, lines } of files) {
    lines.forEach((line, i) => {
      if (!line.includes('String(format:')) return;
      const window = windowJoin(lines, i, 0, 4);
      if (!window.includes('locale:')) {
        fail('format', `${rel}:${i + 1} String(format:) without locale:`);
      }
    });
    // Date.FormatStyle / dateTime must pin the locale too.
    lines.forEach((line, i) => {
      if (line.includes('FormatStyle') && line.includes('.dateTime') && !windowJoin(lines, i, 2, 3).includes('locale(')) {
        fail('format', `${rel}:${i + 1} FormatStyle without .locale(...)`);
      }
    });
  }
}

// --- fonts: no frozen point sizes or system text styles outside the ramp -----
const FONT_FILE_ALLOWLIST = [
  'Sources/Hisingen/UI/Theme/HisingenTheme+Typography.swift', // the ramp itself
  'Sources/Hisingen/UI/Components/LicensePlateBadge.swift', // fixed plate geometry, documented
];
function checkFonts() {
  for (const { rel, lines } of files) {
    const allowed = FONT_FILE_ALLOWLIST.some((a) => rel.endsWith(a));
    lines.forEach((line, i) => {
      const frozen = /\.font\(\.system\(size:\s*[\d.]+/.exec(line) ?? /Font\.system\(size:\s*[\d.]+/.exec(line);
      if (frozen && !allowed) fail('fonts', `${rel}:${i + 1} frozen point size`);
      const sysStyle = /\.font\(\.(headline|headline2|caption|caption2|footnote|subheadline|callout|body|title|title2|title3|largeTitle)\b/.exec(line);
      if (sysStyle && !allowed) fail('fonts', `${rel}:${i + 1} system text style ${sysStyle[1]}`);
      const handTracking = /\.tracking\(/.exec(line);
      // Sanctioned forms: the displayTracking helper (sites with their own ScaledMetric, like
      // the hero numerals) and the inline plate's fixed glyph spacing.
      const helper = line.includes('displayTracking(forSize:');
      const plateSpacing = line.includes('// plate spacing, not type tracking');
      if (handTracking && !allowed && !helper && !plateSpacing) {
        // The ramp owns tracking; call sites hand-rolling it was a review finding.
        fail('fonts', `${rel}:${i + 1} hand-rolled .tracking() (ramp owns tracking)`);
      }
    });
  }
}

// --- tints: CardHeader colors come from tokens, not system colors ------------
const SYSTEM_COLORS = 'indigo|teal|mint|cyan|purple|pink|brown|gray|grey|black|white|blue|green|red|orange|yellow';
function checkTints() {
  const tintRe = new RegExp(`color:\\s*\\.(${SYSTEM_COLORS})\\b`);
  for (const { rel, lines } of files) {
    lines.forEach((line, i) => {
      if (!line.includes('CardHeader(')) return;
      const window = windowJoin(lines, i, 0, 6);
      const m = tintRe.exec(window);
      if (m) fail('tints', `${rel}:${i + 1} CardHeader raw system color .${m[1]}`);
    });
  }
}

// --- sliders: every Slider carries an accessibilityLabel ---------------------
function checkSliders() {
  const sliderRe = /Slider\((value|double):/;
  for (const { rel, lines } of files) {
    lines.forEach((line, i) => {
      if (!sliderRe.test(line)) return;
      const window = windowJoin(lines, i, 0, 30);
      if (!window.includes('accessibilityLabel')) {
        fail('sliders', `${rel}:${i + 1} Slider without accessibilityLabel`);
      }
    });
  }
}

// --- rows: tap-only rows become real, responsive controls --------------------
const ROW_TAP_BAN = [
  'Sources/Hisingen/UI/Settings/SettingsFleetCard.swift',
  'Sources/Hisingen/UI/Settings/NotificationToggleRow.swift',
  'Sources/Hisingen/UI/Controls/ScheduleEditorSheet.swift',
];
function checkRows() {
  for (const { rel, lines } of files) {
    if (!ROW_TAP_BAN.some((a) => rel.endsWith(a))) continue;
    lines.forEach((line, i) => {
      // Rows hosting a nested control (switch, delete button) cannot be Buttons; they
      // mark the constraint inline and answer the pointer through a hover wash instead.
      const nestedHost = windowJoin(lines, i, 10, 0).toLowerCase().includes('// row hosts a nested');
      if (line.includes('.onTapGesture') && !nestedHost) {
        fail('rows', `${rel}:${i + 1} onTapGesture row (use a pressable Button)`);
      }
    });
  }
  const overview = files.find((f) => f.rel.endsWith('History/HistoryDashboardView+AwardOverview.swift'));
  overview.lines.forEach((line, i) => {
    if (line.includes('.buttonStyle(.plain)')) fail('rows', `${overview.rel}:${i + 1} plain button without feedback`);
  });
}

// --- hover: the house pressable style answers the pointer --------------------
function checkHover() {
  const motion = files.find((f) => f.rel.endsWith('UI/Motion.swift'));
  if (!motion.lines.join('\n').includes('.onHover')) {
    fail('hover', 'Motion.swift PressableButtonBody has no .onHover response');
  }
}

// --- selection: tinted fills, not stroke outlines -----------------------------
// Sanctioned boundaries: functional separation that is not selection state.
const SELECTION_ALLOWLIST = [];
function checkSelection() {
  for (const { rel, lines } of files) {
    if (SELECTION_ALLOWLIST.some((a) => rel.endsWith(a))) continue;
    lines.forEach((line, i) => {
      if (!line.includes('.stroke(')) return;
      const window = windowJoin(lines, i, 6, 2);
      // A hollow radio circle is a glyph, not a card outline, so it is exempt.
      if (/isSelected/.test(window) && !/Circle\(\)\s*\n\s*\.stroke/.test(window)) {
        fail('selection', `${rel}:${i + 1} stroke-drawn selection (tinted fill, no outline)`);
      }
    });
  }
}

// --- haptics: commits confirm through the tactile channel --------------------
const HAPTIC_FILES = [
  // PreferenceBinder.toggle is the single write path for the settings switches
  // (SettingsDisplayCard, NotificationToggleRow and the rest), so its haptic covers them.
  'Sources/Hisingen/UI/Settings/PreferenceBinder.swift',
  'Sources/Hisingen/UI/Settings/SettingsFeatureToggleRow.swift',
  'Sources/Hisingen/UI/Controls/ScheduleEditorSheet.swift',
  'Sources/Hisingen/UI/Components/CommandReceiptChip.swift',
];
function checkHaptics() {
  for (const rel of HAPTIC_FILES) {
    const f = files.find((x) => x.rel.endsWith(rel));
    if (!f) { fail('haptics', `missing file ${rel}`); continue; }
    if (!f.lines.join('\n').includes('HapticFeedback')) fail('haptics', `${rel} has no haptic on commit`);
  }
}

// --- menus: secondary-click on the content macOS users expect ----------------
const MENU_FILES = [
  'Sources/Hisingen/UI/History/HistoryDashboardView+Trips.swift',
  'Sources/Hisingen/UI/History/ChargingSessionRow.swift',
  'Sources/Hisingen/UI/Controls/ScheduleEditorSheet.swift',
];
function checkMenus() {
  for (const rel of MENU_FILES) {
    const f = files.find((x) => x.rel.endsWith(rel));
    if (!f) { fail('menus', `missing file ${rel}`); continue; }
    if (!f.lines.join('\n').includes('.contextMenu')) fail('menus', `${rel} has no .contextMenu`);
  }
}

// --- ax: the live charging curve is adjustable without a pointer -------------
function checkAX() {
  const charts = files.find((f) => f.rel.endsWith('History/ChargingChartsViews.swift'));
  if (!charts.lines.join('\n').includes('accessibilityAdjustableAction')) {
    fail('ax', 'live curve has no accessibilityAdjustableAction');
  }
}

// --- keyboard: sheets cancel, gear is reachable, refresh never locks ---------
function checkKeyboard() {
  const picker = files.find((f) => f.rel.endsWith('Settings/TabItemPickerSheet.swift'));
  if (!picker.lines.join('\n').includes('.cancelAction')) fail('keyboard', 'TabItemPickerSheet has no .cancelAction');
  const shell = files.find((f) => f.rel.endsWith('Shell/HisingenContentView.swift'));
  if (!/keyboardShortcut\("\+"/.test(shell.lines.join('\n')) && !shell.lines.join('\n').includes('keyboardShortcut(",",')) {
    fail('keyboard', 'settings gear has no in-panel keyboard shortcut');
  }
  const overview = files.find((f) => f.rel.endsWith('History/HistoryDashboardView+AwardOverview.swift'));
  if (overview.lines.join('\n').includes('.disabled(isLoading)')) {
    fail('keyboard', 'History refresh button disables during load instead of queueing');
  }
}

// --- help: icon-only controls carry tooltips ---------------------------------
const HELP_FILES = [
  'Components/CommandReceiptChip.swift',
  'Controls/ControlsBanners.swift',
  'Controls/ScheduleEditorSheet.swift',
  'History/HistoryDashboardView.swift',
  'Settings/SettingsTabsAndCardsCard.swift',
  'Settings/TabItemPickerSheet.swift',
  'Settings/SettingsNavigation.swift',
];
function checkHelp() {
  for (const rel of HELP_FILES) {
    const f = files.find((x) => x.rel.endsWith(rel));
    if (!f) { fail('help', `missing file ${rel}`); continue; }
    if (!f.lines.join('\n').includes('.help(')) fail('help', `${rel} has no .help tooltip`);
  }
}

// --- washes: tinted washes raise under Increase Contrast ---------------------
const WASH_FILES = [
  'Shell/DismissibleNoticeBanner.swift',
  'Controls/ControlsBanners.swift',
  'Components/CommandReceiptChip.swift',
  'Controls/ChargingControlsCard.swift',
  'Settings/SettingsNavigation.swift',
  'Settings/TabItemPickerSheet.swift',
  'History/HistoryDashboardView.swift',
];
function checkWashes() {
  for (const rel of WASH_FILES) {
    const f = files.find((x) => x.rel.endsWith(rel));
    if (!f) { fail('washes', `missing file ${rel}`); continue; }
    const text = f.lines.join('\n');
    if (!text.includes('increasedContrast') && !text.includes('tintedWashOpacity')) {
      fail('washes', `${rel} wash does not respond to Increase Contrast`);
    }
  }
}

// --- reduce: the Copied-coordinates label respects Reduce Motion -------------
function checkReduce() {
  const openings = files.find((f) => f.rel.endsWith('Vehicle/OpeningsCardViews.swift'));
  const text = openings.lines.join('\n');
  if (!text.includes('reduceMotion ? nil : Motion')) {
    fail('reduce', 'OpeningsCardViews Copied label animation is not Reduce-Motion gated');
  }
}

// --- copy: no em/en dashes inside UI string literals -------------------------
function checkCopy() {
  const literalRe = /"(?:[^"\\]|\\.)*"/g;
  for (const { rel, lines } of files) {
    lines.forEach((line, i) => {
      let m;
      literalRe.lastIndex = 0;
      while ((m = literalRe.exec(line))) {
        const literal = m[0];
        // Em dashes are banned outright. A spaced en dash is the same sentence device in
        // disguise. Standalone nil placeholders ("–") and unspaced ranges (5–15, ⌃⌥1–9) stay.
        if (/—/.test(literal) || /(^|\s)–(\s|$)/.test(literal)) {
          fail('copy', `${rel}:${i + 1} spaced or em dash in string literal`);
        }
      }
    });
  }
}

const sections = {
  format: checkFormat,
  fonts: checkFonts,
  tints: checkTints,
  sliders: checkSliders,
  rows: checkRows,
  hover: checkHover,
  selection: checkSelection,
  haptics: checkHaptics,
  menus: checkMenus,
  ax: checkAX,
  keyboard: checkKeyboard,
  help: checkHelp,
  washes: checkWashes,
  reduce: checkReduce,
  copy: checkCopy,
};

const arg = process.argv[2];
const run = arg && sections[arg] ? { [arg]: sections[arg] } : sections;
for (const [name, fn] of Object.entries(run)) {
  const before = failures.length;
  fn();
  if (failures.length === before) console.log(`ui-discipline ${name}: OK`);
}
if (failures.length) {
  failures.forEach((f) => console.error(f));
  console.error(`UI DISCIPLINE FAILED (${failures.length})`);
  process.exit(1);
}
if (!arg) console.log('UI DISCIPLINE OK');
