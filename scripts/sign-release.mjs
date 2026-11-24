import {execFileSync} from 'node:child_process';
import {createPublicKey, verify} from 'node:crypto';
import {readFileSync, writeFileSync} from 'node:fs';
import {basename, join} from 'node:path';

const [tool, directory] = process.argv.slice(2);
const secret = process.env.SPARKLE_PRIVATE_KEY;
if (!secret) throw Error('Missing SPARKLE_PRIVATE_KEY');
delete process.env.SPARKLE_PRIVATE_KEY;

function plist(data) {
    return JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', '--', '-'], {input: data}));
}

function sign(args) {
    return execFileSync(tool, ['--ed-key-file', '-', ...args], {input: secret, encoding: 'utf8'}).trim();
}

function escapeXML(text) {
    return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

const expected = plist(readFileSync('Info.plist'));
const version = expected.CFBundleShortVersionString;
const archive = join(directory, 'YaaTerm-' + version + '-macOS.zip');
const embedded = plist(execFileSync('unzip', ['-p', archive, 'YaaTerm.app/Contents/Info.plist']));
for (const key of ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'SUPublicEDKey', 'SUFeedURL',
                   'SURequireSignedFeed', 'LSMinimumSystemVersion']) {
    if (embedded[key] !== expected[key]) throw Error('Archive differs from source for ' + key);
}
const data = readFileSync(archive);
const signature = sign(['-p', archive]);
const publicKey = createPublicKey({format: 'jwk', key: {kty: 'OKP', crv: 'Ed25519',
    x: Buffer.from(embedded.SUPublicEDKey, 'base64').toString('base64url')}});
if (!verify(null, data, publicKey, Buffer.from(signature, 'base64')))
    throw Error('Archive signature does not match the public key in YaaTerm');

const repo = 'https://github.com/yemaster/YaaTerm';
const notes = readFileSync('Resources/ReleaseNotes/' + version + '.txt', 'utf8').trim().split(/\r?\n/);
const html = '<ul>' + notes.map(line => '<li>' + escapeXML(line) + '</li>').join('') + '</ul>';
const feed = join(directory, 'appcast.xml');
writeFileSync(feed, `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>YaaTerm</title>
    <link>${repo}</link>
    <description>YaaTerm 更新日志</description>
    <item>
      <title>YaaTerm ${escapeXML(version)}</title>
      <sparkle:version>${escapeXML(embedded.CFBundleVersion)}</sparkle:version>
      <sparkle:shortVersionString>${escapeXML(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${escapeXML(embedded.LSMinimumSystemVersion)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${repo}/releases</sparkle:fullReleaseNotesLink>
      <description>${escapeXML(html)}</description>
      <enclosure url="${repo}/releases/download/v${encodeURIComponent(version)}/${encodeURIComponent(basename(archive))}"
                 type="application/octet-stream" length="${data.length}" sparkle:edSignature="${signature}"/>
    </item>
  </channel>
</rss>
`);
sign([feed]);
sign(['--verify', feed]);
console.log('Verified signed update feed and archive for YaaTerm ' + version);
