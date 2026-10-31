import { createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const publicPrefix = Buffer.from('302a300506032b6570032100', 'hex');
const sparkleNS = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
const feedMarker = Buffer.from('<!-- sparkle-signatures:\n');

function decode(value, size, label) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Error(`Invalid ${label}`);
  const data = Buffer.from(value, 'base64');
  if (data.length !== size || data.toString('base64') !== value) throw new Error(`Invalid ${label}`);
  return data;
}

function pythonJSON(script, input) {
  const result = spawnSync('python3', ['-c', script], { input, encoding: 'utf8', maxBuffer: 2 * 1024 * 1024, timeout: 10000 });
  if (result.status !== 0) throw new Error(`Invalid XML/plist: ${result.stderr?.trim() || result.error || 'parser failed'}`);
  return JSON.parse(result.stdout);
}

function parseXML(content) {
  return pythonJSON(`import sys,json,xml.etree.ElementTree as E
data=sys.stdin.read()
if '<!DOCTYPE' in data.upper() or '<!ENTITY' in data.upper(): raise ValueError('DTD/entities are forbidden')
root=E.fromstring(data)
if root.tag != 'rss': raise ValueError('Expected rss document')
items=root.findall('./channel/item')
if len(items) != 1: raise ValueError('Expected exactly one stable release item')
item=items[0]; ns={'s':'${sparkleNS}'}
def one(path):
 nodes=item.findall(path,ns)
 if len(nodes)!=1: raise ValueError('Expected exactly one '+path)
 return nodes[0]
enclosure=one('enclosure'); notes=one('s:releaseNotesLink')
print(json.dumps({'version':one('s:shortVersionString').text,'build':one('s:version').text,'minimum':one('s:minimumSystemVersion').text,'enclosure':enclosure.attrib,'notes':notes.attrib,'notesURL':notes.text}))`, content);
}


export function verifyAppcast({ feed, archive, notes, plist, expectedTag }) {
  if (plist.SURequireSignedFeed !== true || plist.SUVerifyUpdateBeforeExtraction !== true) throw new Error('Final bundle must require signed feeds and verified extraction');
  const keyBytes = decode(plist.SUPublicEDKey, 32, 'embedded public key');
  const publicKey = createPublicKey({ key: Buffer.concat([publicPrefix, keyBytes]), format: 'der', type: 'spki' });
  const marker = feed.lastIndexOf(feedMarker);
  if (marker < 0) throw new Error('Appcast feed signature is missing');
  const block = feed.subarray(marker).toString('utf8');
  const match = /^<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+=*)\nlength: ([0-9]+)\n-->\s*$/.exec(block);
  if (!match || Number(match[2]) !== marker) throw new Error('Invalid signed feed length/block');
  const content = feed.subarray(0, marker);
  if (!verify(null, content, publicKey, decode(match[1], 64, 'feed signature'))) throw new Error('Feed signature verification failed');
  const item = parseXML(content);
  if (!/^\d+\.\d+\.\d+$/.test(item.version || '') || !/^\d+$/.test(item.build || '')) throw new Error('Invalid appcast version/build');
  if (item.version !== plist.CFBundleShortVersionString || item.build !== String(plist.CFBundleVersion)) throw new Error('Appcast version/build does not match bundle');
  if (item.minimum !== plist.LSMinimumSystemVersion) throw new Error('Minimum macOS version does not match bundle');
  if (expectedTag && expectedTag !== `v${item.version}`) throw new Error('Appcast version does not match release tag');
  const prefix = `https://github.com/NicolasKheirallah/Hisingen/releases/download/v${item.version}/`;
  if (item.enclosure.url !== `${prefix}Hisingen.app.zip` || item.notesURL !== `${prefix}Hisingen.app.md`) throw new Error('Unexpected release asset URL');
  for (const [name, bytes, attrs] of [['Archive', archive, item.enclosure], ['Release notes', notes, item.notes]]) {
    const length = attrs.length ?? attrs[`{${sparkleNS}}length`];
    if (!/^\d+$/.test(length || '') || Number(length) !== bytes.length) throw new Error(`${name} length mismatch`);
    const signature = decode(attrs[`{${sparkleNS}}edSignature`], 64, `${name} signature`);
    if (!verify(null, bytes, publicKey, signature)) throw new Error(`${name} signature verification failed`);
  }
  return { version: item.version, build: item.build };
}

export function verifyAppcastFiles(feedPath, archivePath, notesPath, plistPath, expectedTag) {
  if (![feedPath, archivePath, notesPath, plistPath].every(Boolean)) throw new Error('Provide appcast, archive, notes and final bundle Info.plist');
  const plist = pythonJSON('import sys,plistlib,json; print(json.dumps(plistlib.loads(sys.stdin.buffer.read())))', readFileSync(plistPath));
  const embedded = pythonJSON("import sys,io,zipfile,plistlib,json; z=zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())); i=z.getinfo('Hisingen.app/Contents/Info.plist'); assert i.file_size < 1048576; print(json.dumps(plistlib.loads(z.read(i))))", readFileSync(archivePath));
  for (const key of ['SUPublicEDKey', 'CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion', 'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']) {
    if (embedded[key] !== plist[key]) throw new Error(`Archive embedded ${key} differs from final bundle`);
  }
  return verifyAppcast({ feed: readFileSync(feedPath), archive: readFileSync(archivePath), notes: readFileSync(notesPath), plist, expectedTag });
}

export function appcastSelfTest() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const rawKey = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  const archive = Buffer.from('test update bytes');
  const notes = Buffer.from('Release notes.\n');
  const signature = bytes => sign(null, bytes, privateKey).toString('base64');
  const plist = { SURequireSignedFeed: true, SUVerifyUpdateBeforeExtraction: true, SUPublicEDKey: rawKey, CFBundleShortVersionString: '1.2.3', CFBundleVersion: '42', LSMinimumSystemVersion: '15.0' };
  const xml = `<rss xmlns:sparkle="${sparkleNS}"><channel><item><sparkle:version>42</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion><sparkle:releaseNotesLink sparkle:edSignature="${signature(notes)}" sparkle:length="${notes.length}">https://github.com/NicolasKheirallah/Hisingen/releases/download/v1.2.3/Hisingen.app.md</sparkle:releaseNotesLink><enclosure url="https://github.com/NicolasKheirallah/Hisingen/releases/download/v1.2.3/Hisingen.app.zip" length="${archive.length}" sparkle:edSignature="${signature(archive)}" /></item></channel></rss>`;
  const signedFeed = xmlText => {
    const content = Buffer.from(xmlText);
    return Buffer.concat([content, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${signature(content)}\nlength: ${content.length}\n-->\n`)]);
  };
  const input = { feed: signedFeed(xml), archive, notes, plist, expectedTag: 'v1.2.3' };
  verifyAppcast(input);
  const warnedNotes = Buffer.concat([Buffer.from('<!-- sparkle-sign-warning: signed -->\n'), notes]);
  const warnedXML = xml.replace(signature(notes), signature(warnedNotes)).replace(`sparkle:length="${notes.length}"`, `sparkle:length="${warnedNotes.length}"`);
  verifyAppcast({ ...input, notes: warnedNotes, feed: signedFeed(warnedXML) });
  const negatives = [
    { ...input, archive: Buffer.from('bad update bytes!') },
    { ...input, notes: Buffer.from('Changed notes.\n') },
    { ...input, feed: Buffer.from(input.feed.toString().replace('1.2.3', '1.2.4')) },
    { ...input, feed: signedFeed(xml.replace('length="17"', 'length="1"')) },
    { ...input, feed: signedFeed(xml.replace('https://github.com/', 'http://github.com/')) },
    { ...input, feed: signedFeed(xml.replace('<rss ', '<rss broken ')) },
    { ...input, expectedTag: 'v1.2.4' },
    { ...input, plist: { ...plist, CFBundleVersion: '43' } },
    { ...input, plist: { ...plist, SURequireSignedFeed: false } },
    { ...input, plist: { ...plist, SUPublicEDKey: Buffer.alloc(32).toString('base64') } },
    { ...input, feed: signedFeed(xml.replace('</channel>', xml.match(/<item>.*<\/item>/s)[0] + '</channel>')) },
  ];
  for (const [index, invalid] of negatives.entries()) {
    let rejected = false;
    try { verifyAppcast(invalid); } catch { rejected = true; }
    if (!rejected) throw new Error(`Tampering negative control ${index + 1} unexpectedly passed`);
  }
  console.log('updater-appcast-self-test-passed');
}
