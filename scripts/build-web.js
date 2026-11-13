const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const out = path.join(root, 'www');
const files = ['index.html', 'manifest.json', 'icon.svg', 'sw.js'];

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

for (const file of files) {
  const source = path.join(root, file);
  if (!fs.existsSync(source)) {
    if (file === 'sw.js' || file === 'icon.svg') continue;
    throw new Error('Required web asset is missing: ' + file);
  }
  fs.copyFileSync(source, path.join(out, file));
}

console.log('Web app copied to www/');
