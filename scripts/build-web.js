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

// The Android package is dedicated to Color Clash only.
// Keep legacy DOM elements in the document because the shared script
// still wires handlers to them, but hide all other game entry points.
const indexPath = path.join(out, 'index.html');
let html = fs.readFileSync(indexPath, 'utf8');
html = html.replace(/<title>[\\s\\S]*?<\\/title>/i, '<title>Color Clash</title>');
html = html.replace(
  /<meta name="description" content="[^"]*">/i,
  '<meta name="description" content="Color Clash — solo challenges and online multiplayer rooms.">'
);
const appOnlyStyle = `
<style id="color-clash-android-only">
  .multi-title,
  #home .multi-title + p,
  #home .multi-title + p + .grid,
  .game-card,
  .creator-credit,
  #multiLobby,
  #multiGame { display: none !important; }
</style>
`;
html = html.replace(/<\\/head>/i, appOnlyStyle + '\\n</head>');
fs.writeFileSync(indexPath, html, 'utf8');

console.log('Color Clash-only Android web app copied to www/');
