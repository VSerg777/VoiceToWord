const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const outputDirectory = process.argv[2];
if (!outputDirectory) throw new Error('Pass the website output directory.');
fs.mkdirSync(outputDirectory, { recursive: true });
const output = path.join(outputDirectory, 'vosk-model-small-ru-0.22.tar.gz');
if (fs.existsSync(output) && fs.statSync(output).size > 1_000_000) {
  console.log('Russian Vosk browser model already prepared.');
  process.exit(0);
}

async function main() {
  const response = await fetch('https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip', { signal: AbortSignal.timeout(180_000) });
  if (!response.ok) throw new Error(`Could not download the Vosk Russian model: HTTP ${response.status}`);
  const archive = Buffer.from(await response.arrayBuffer());
  if (archive.length < 1_000_000) throw new Error('The downloaded Vosk model archive is unexpectedly small.');

  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'vosk-browser-model-'));
  try {
    const zipPath = path.join(temporary, 'model.zip');
    const extracted = path.join(temporary, 'extracted');
    const modelDirectory = path.join(temporary, 'model');
    fs.writeFileSync(zipPath, archive);
    fs.mkdirSync(extracted);
    execFileSync('unzip', ['-q', zipPath, '-d', extracted], { stdio: 'inherit' });
    const modelRoot = path.join(extracted, 'vosk-model-small-ru-0.22');
    if (!fs.existsSync(path.join(modelRoot, 'am', 'final.mdl'))) throw new Error('The Russian model archive has an unexpected layout.');
    fs.cpSync(modelRoot, modelDirectory, { recursive: true });
    fs.mkdirSync(path.join(modelDirectory, 'conf'), { recursive: true });
    fs.writeFileSync(path.join(modelDirectory, 'conf', 'model.conf'), [
      '--min-active=200', '--max-active=3000', '--beam=10.0', '--lattice-beam=2.0',
      '--acoustic-scale=1.0', '--frame-subsampling-factor=3',
      '--endpoint.silence-phones=1:2:3:4:5:6:7:8:9:10',
      '--endpoint.rule2.min-trailing-silence=0.5',
      '--endpoint.rule3.min-trailing-silence=0.75', ''
    ].join('\n'));
    execFileSync('tar', ['-czf', output, '-C', modelDirectory, '.'], { stdio: 'inherit' });
    console.log(`Prepared Vosk Browser model: ${output} (${(fs.statSync(output).size / 1_000_000).toFixed(1)} MB)`);
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
