const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const root = path.resolve(__dirname, '../..');
const archivePath = path.join(root, 'macos', 'VoskWordListener-macOS-universal.zip');
const output = path.join(root, 'website', 'dist', 'downloads');
const filename = path.basename(archivePath);
const archive = fs.readFileSync(archivePath);
fs.mkdirSync(output, { recursive: true });
const parts = [];
const chunkSize = 16 * 1024 * 1024;
for (let offset = 0; offset < archive.length; offset += chunkSize) {
  const part = `mac-${parts.length + 1}.bin`;
  fs.writeFileSync(path.join(output, part), archive.subarray(offset, offset + chunkSize));
  parts.push(part);
}
const manifest = {
  filename,
  bytes: archive.length,
  sha256: crypto.createHash('sha256').update(archive).digest('hex'),
  parts
};
fs.writeFileSync(path.join(output, 'release-mac.json'), JSON.stringify(manifest, null, 2));
const reconstructed = Buffer.concat(parts.map(part => fs.readFileSync(path.join(output, part))));
if (!archive.equals(reconstructed)) throw new Error('Mac archive reconstruction failed');
console.log(JSON.stringify({ bytes: manifest.bytes, parts: parts.length, sha256: manifest.sha256 }));
