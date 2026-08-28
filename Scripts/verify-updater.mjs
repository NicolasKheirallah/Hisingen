import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const mode = process.argv[2];
const read = (path) => readFileSync(path, 'utf8');
const requireText = (source, value, label) => {
  if (!source.includes(value)) throw new Error(`Missing ${label}: ${value}`);
};
const requireFile = (path) => {
  if (!existsSync(path)) throw new Error(`Missing required file: ${path}`);
  return read(path);
};
const verifyAppcast = (appcast) => {
  if (!/<!-- sparkle-signatures:\s*edSignature:\s*\S+/m.test(appcast)) throw new Error('Appcast feed signature is missing');
  if (!/<enclosure\b[^>]*\bsparkle:edSignature="[^"]+"/s.test(appcast)) throw new Error('Update enclosure signature is missing');
  if (!/<sparkle:releaseNotesLink\b[^>]*\bsparkle:edSignature="[^"]+"/s.test(appcast)) throw new Error('Release-notes signature is missing');
  requireText(appcast, 'Hisingen.app.zip', 'update enclosure');
};

try {
  const packageFile = requireFile('Package.swift');
  const plist = requireFile('Resources/Info.plist');
  const service = requireFile('Sources/Hisingen/Services/Updates/UpdateService.swift');
  const workflow = requireFile('.github/workflows/release.yml');
  const docs = requireFile('docs/updater-architecture.md');

  if (mode === 'configuration') {
    requireText(packageFile, 'sparkle-project/Sparkle.git", exact: "2.9.6"', 'pinned Sparkle dependency');
    for (const key of ['SUFeedURL', 'SUPublicEDKey', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed']) requireText(plist, key, 'Sparkle security key');
    requireText(plist, 'https://nicolaskheirallah.github.io/Hisingen/updates/appcast.xml', 'HTTPS appcast');
    for (const symbol of ['SPUStandardUpdaterController', 'SUAppcastItem', 'allowedChannels', 'willExtractUpdate']) requireText(service, symbol, 'Sparkle service integration');
    const staging = mkdtempSync(join(tmpdir(), 'hisingen-updater-config-'));
    try {
      const stagedPlist = join(staging, 'Info.plist');
      copyFileSync('Resources/Info.plist', stagedPlist);
      const validKey = Buffer.alloc(32, 0x2a).toString('base64');
      const valid = spawnSync('sh', ['Scripts/configure-updater.sh', stagedPlist], {
        encoding: 'utf8',
        env: { ...process.env, REQUIRE_SPARKLE_UPDATER: 'true', SPARKLE_PUBLIC_ED_KEY: validKey },
      });
      if (valid.status !== 0) throw new Error(`Valid updater key was rejected: ${valid.stderr}`);
      const embedded = spawnSync('/usr/libexec/PlistBuddy', ['-c', 'Print :SUPublicEDKey', stagedPlist], { encoding: 'utf8' });
      if (embedded.status !== 0 || embedded.stdout.trim() !== validKey) throw new Error('Configured updater key was not embedded exactly');

      copyFileSync('Resources/Info.plist', stagedPlist);
      const shortKey = spawnSync('sh', ['Scripts/configure-updater.sh', stagedPlist], {
        encoding: 'utf8',
        env: { ...process.env, REQUIRE_SPARKLE_UPDATER: 'true', SPARKLE_PUBLIC_ED_KEY: Buffer.alloc(31).toString('base64') },
      });
      if (shortKey.status === 0) throw new Error('Short public-key negative control unexpectedly passed');
      console.log('updater-configuration-passed');
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }
  } else if (mode === 'release-pipeline') {
    for (const value of ['SPARKLE_PUBLIC_ED_KEY', 'SPARKLE_PRIVATE_ED_KEY', 'SPARKLE_TOOLS_SHA256', 'generate_appcast', '--ed-key-file', 'verify-sparkle-keypair.mjs', 'verify-updater.mjs appcast', 'publish-appcast.sh', 'xcrun notarytool submit', 'xcrun stapler staple']) requireText(`${workflow}\n${requireFile('Scripts/publish-appcast.sh')}`, value, 'release security control');
    if (!/- name: Generate signed Sparkle appcast and release notes[\s\S]*?env:[\s\S]*?SPARKLE_PUBLIC_ED_KEY:[\s\S]*?SPARKLE_PRIVATE_ED_KEY:/.test(workflow)) {
      throw new Error('Appcast generation step does not receive both Sparkle keys');
    }
    requireText(workflow, 'Hisingen.app.md', 'signed release notes asset');
    console.log('updater-release-pipeline-passed');
  } else if (mode === 'documentation') {
    for (const heading of ['# Native macOS updater', '## Audit of the retired updater', '## Security model', '## Release operation', '## Failure behavior']) requireText(docs, heading, 'required updater documentation');
    console.log('updater-documentation-passed');
  } else if (mode === 'release-notes') {
    const headings = [...requireFile('CHANGELOG.md').matchAll(/^## \[([^\]]+)\](?:\s+-.*)?$/gm)];
    if (headings.length < 2) throw new Error('Need at least two dated changelog sections for the release-notes test');
    const staging = mkdtempSync(join(tmpdir(), 'hisingen-release-notes-'));
    try {
      const output = join(staging, 'notes.md');
      const result = spawnSync('sh', ['Scripts/extract-release-notes.sh', headings[0][1], 'CHANGELOG.md', output], { encoding: 'utf8' });
      if (result.status !== 0) throw new Error(`Release-note extraction failed: ${result.stderr}`);
      const notes = read(output);
      requireText(notes, headings[0][0], 'selected release heading');
      if (notes.includes(headings[1][0])) throw new Error('Release notes leaked the next release heading');

      const negative = spawnSync('sh', ['Scripts/extract-release-notes.sh', '999999.0.0', 'CHANGELOG.md', join(staging, 'missing.md')], { encoding: 'utf8' });
      if (negative.status === 0) throw new Error('Missing-version negative control unexpectedly passed');
      console.log('updater-release-notes-passed');
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }
  } else if (mode === 'appcast') {
    const appcastPath = process.argv[3];
    if (!appcastPath) throw new Error('Usage: node Scripts/verify-updater.mjs appcast PATH/TO/appcast.xml');
    verifyAppcast(requireFile(appcastPath));
    console.log('updater-appcast-passed');
  } else if (mode === 'appcast-self-test') {
    const validAppcast = `<?xml version="1.0"?>
      <item xmlns:sparkle="https://www.andymatuschak.org/xml-namespaces/sparkle">
        <sparkle:releaseNotesLink sparkle:edSignature="notes-signature">Hisingen.app.md</sparkle:releaseNotesLink>
        <enclosure url="Hisingen.app.zip" sparkle:edSignature="archive-signature" />
      </item>
      <!-- sparkle-signatures:
      edSignature: feed-signature
      length: 123
      -->`;
    verifyAppcast(validAppcast);
    const negativeControls = [
      validAppcast.replace(/<!-- sparkle-signatures:[\s\S]*?-->/, ''),
      validAppcast.replace(' sparkle:edSignature="archive-signature"', ''),
      validAppcast.replace(' sparkle:edSignature="notes-signature"', ''),
    ];
    for (const invalidAppcast of negativeControls) {
      try {
        verifyAppcast(invalidAppcast);
        throw new Error('Unsigned appcast negative control unexpectedly passed');
      } catch (error) {
        if (!String(error.message).includes('signature is missing')) throw error;
      }
    }
    console.log('updater-appcast-self-test-passed');
  } else {
    throw new Error('Usage: node Scripts/verify-updater.mjs configuration|release-pipeline|documentation|release-notes|appcast|appcast-self-test');
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
