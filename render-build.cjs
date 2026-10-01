// Builds a small Render site with a direct GitHub Releases download.
const fs = require('node:fs');
const path = require('node:path');
const releaseUrl = process.env.APP_DOWNLOAD_URL;
if (!releaseUrl || !/^https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/download\//.test(releaseUrl)) {
  throw new Error('Set APP_DOWNLOAD_URL to the published GitHub Releases ZIP URL before deployment.');
}
const output = path.join(__dirname, 'render-dist');
const source = fs.existsSync(path.join(__dirname, 'dist', 'index.html')) ? path.join(__dirname, 'dist') : __dirname;
fs.mkdirSync(output, { recursive: true });
for (const filename of ['index.html', 'style.css', 'HELP-RU.txt']) {
  fs.copyFileSync(path.join(source, filename), path.join(output, filename));
}
const original = fs.readFileSync(path.join(source, 'app.js'), 'utf8');
const start = original.indexOf('const downloadButton =');
if (start < 0) throw new Error('Download button initialization missing');
const direct = `const downloadButton = document.getElementById('download-app');\n` +
  `downloadButton.addEventListener('click', () => { window.location.assign(${JSON.stringify(releaseUrl)}); });\n`;
fs.writeFileSync(path.join(output, 'app.js'), original.slice(0, start) + direct);
console.log('Render site ready: interactive examples and direct GitHub release download.');
