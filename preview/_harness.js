/* Headless harness: runs the preview's own logic with a stubbed DOM. */
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, 'ui_preview.html'), 'utf8');
const m = html.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.log('NO SCRIPT FOUND'); process.exit(1); }

/* --- minimal DOM stub --- */
function fakeNode() {
  const style = new Proxy({}, { get: () => '', set: () => true });
  const grad = { addColorStop() {} };
  const ctx = {
    setTransform() {}, clearRect() {}, beginPath() {}, moveTo() {}, lineTo() {},
    stroke() {}, fill() {}, arc() {}, closePath() {}, save() {}, restore() {},
    createLinearGradient: () => grad,
    fillStyle: '', strokeStyle: '', lineWidth: 1, filter: '', globalAlpha: 1,
    lineJoin: '', lineCap: '',
  };
  const el = {
    style, dataset: {}, classList: { add() {}, remove() {}, toggle() {} },
    querySelector: () => fakeNode(), querySelectorAll: () => [],
    addEventListener() {}, appendChild() {}, getAttribute: () => null, setAttribute() {},
    firstElementChild: null, textContent: '', innerHTML: '', value: '',
    clientWidth: 200, clientHeight: 80, width: 200, height: 80,
    getContext: () => ctx,
  };
  el.firstElementChild = el;
  return el;
}
global.document = {
  getElementById: () => fakeNode(), querySelector: () => fakeNode(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeNode(),
};
global.window = { addEventListener() {}, devicePixelRatio: 1 };
global.location = { hash: '' };
global.setInterval = () => 0;

/* --- run preview logic + tests --- */
const combined = m[1] + '\n' + fs.readFileSync(path.join(__dirname, '_tests.js'), 'utf8');
try {
  (0, eval)(combined);
} catch (e) {
  console.log('RUNTIME ERROR: ' + e.message);
  console.log((e.stack || '').split('\n').slice(0, 6).join('\n'));
  process.exit(1);
}
