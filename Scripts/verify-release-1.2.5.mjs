import fs from "node:fs";
import { execFileSync } from "node:child_process";

const version = "1.2.5";
const changelog = fs.readFileSync("CHANGELOG.md", "utf8");
const info = fs.readFileSync("Resources/Info.plist", "utf8");
const website = fs.readFileSync("website/index.html", "utf8");

const failures = [];
const requireMatch = (condition, message) => {
  if (!condition) failures.push(message);
};

requireMatch(
  changelog.includes(`## [${version}] - 2026-08-29`),
  "CHANGELOG.md is missing the dated 1.2.5 release heading"
);
for (const phrase of [
  "searchable section navigation",
  "Settings transfer",
  "selectable 30 / 90 / 180 / 365-day sample retention",
  "Localization validation now requires exact key parity",
]) {
  requireMatch(changelog.includes(phrase), `CHANGELOG.md is missing release note: ${phrase}`);
}

requireMatch(
  /<key>CFBundleShortVersionString<\/key>\s*<string>1\.2\.5<\/string>/.test(info),
  "Info.plist marketing version is not 1.2.5"
);
const build = info.match(/<key>CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/)?.[1];
requireMatch(Number(build) >= 6, "Info.plist build number was not incremented to at least 6");
requireMatch(website.includes('"softwareVersion":"1.2.5"'), "website structured data is not 1.2.5");
requireMatch(website.includes('"datePublished":"2026-08-29"'), "website publication date is not 2026-08-29");
requireMatch(website.includes("<li><span>Version</span>1.2.5</li>"), "website visible version is not 1.2.5");

if (failures.length) {
  console.error("release 1.2.5 verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

if (process.argv.includes("--committed")) {
  const status = execFileSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], {
    encoding: "utf8",
  });
  requireMatch(status.trim() === "", "non-ignored worktree is not clean after commit");
  const committedFiles = execFileSync("git", ["show", "--pretty=format:", "--name-only", "HEAD"], {
    encoding: "utf8",
  });
  for (const path of ["CHANGELOG.md", "Resources/Info.plist", "Sources/Hisingen/UI/SettingsView.swift"]) {
    requireMatch(committedFiles.split(/\r?\n/).includes(path), `HEAD does not contain ${path}`);
  }
  if (failures.length) {
    console.error("committed release 1.2.5 verification failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }
  console.log("committed release 1.2.5 verification passed");
} else {
  console.log("release 1.2.5 verification passed");
}
