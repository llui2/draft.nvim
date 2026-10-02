// Generate a browser regression page beside the preview's KaTeX assets.
// node tests/preview.mjs /tmp/draft-browser/check.html
import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const html = readFileSync('lua/draft/preview.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script); // Check the production script, not only the harness.
const fixture = String.raw`\section{Reading α}

This is \text{important} and \texttt{:Dp}. Lluís α 😀 reads $e^{i\pi}=-1$.
Second rendered line for a multiline selection.

\[
  \int_0^1 x\,dx = \frac12
\]

Final mapped line.`;
// Exercise the actual parser and renderer without a DOM.
const inert = { addEventListener() {} };
const context = vm.createContext({ TextEncoder, innerHeight: 800, window: inert,
  document: { getElementById() { return inert; } },
  katex: { renderToString(value) { return `<math>${value}</math>`; } } });
vm.runInContext(script, context);
context.fixture = fixture;
const blocks = vm.runInContext('source = fixture; parse()', context);
assert.equal(blocks.length, 4);
assert.equal(blocks[2].kind, 'math');
const rendered = vm.runInContext('renderBlock(parse()[1], [])', context);
assert.match(rendered, /class="texttt"/);
assert.match(rendered, /data-inline-command="true"/);
assert.equal(vm.runInContext('utf16AtByte("α😀", 6)', context), 3);
for (const environment of ['equation', 'equation*', 'align', 'gather', 'multline']) {
  context.fixture = `\\begin{${environment}}\nx=1\n\\end{${environment}}`;
  assert.equal(vm.runInContext('source = fixture; parse()[0].kind', context), 'math');
}
console.log('Draft: JavaScript syntax, fragments, math environments, inline wrappers and UTF-8 checks passed');

const browserChecks = String.raw`
  const results = [];
  const check = (value, name) => { if (!value) throw Error(name); results.push(name); };
  const fixture = FIXTURE;
  const byteAt = text => byteLength(fixture.slice(0, fixture.indexOf(text)));
  const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
  const markerIsFixed = () => {
    const rect = document.getElementById('reading-mark').getBoundingClientRect();
    return Math.abs(rect.top - innerHeight * .25) < 1 && rect.left === 8;
  };
  window.addEventListener('load', async () => {
    const status = document.createElement('pre');
    status.id = 'test-results';
    status.style.cssText = 'position:fixed;bottom:4px;right:4px;max-width:60%;font:11px monospace;background:var(--background);z-index:30';
    document.body.append(status);
    try {
      window.updateSource(fixture);
      check(document.querySelector('h1').textContent === 'Reading α', 'heading');
      check(document.querySelector('.texttt').textContent === ':Dp', 'monospace');
      window.sourceToPreview(byteAt('\\text{'), byteAt('\\text{') + 1, 'cursor');
      check(window.getSelection().toString() === 'important', 'text command cursor range');
      window.sourceToPreview(byteAt('important') + 3, byteAt('important') + 4, 'cursor');
      check(window.getSelection().toString() === 'important', 'text argument cursor range');
      window.sourceToPreview(byteAt(':Dp'), byteAt(':Dp') + 1, 'cursor');
      check(window.getSelection().toString() === ':Dp', 'texttt cursor range');
      window.sourceToPreview(byteAt('\\text{'), byteAt('\\text{') + byteLength('\\text{important}'), 'char');
      check(window.getSelection().toString() === 'important', 'Visual range across command syntax');
      window.sourceToPreview(byteAt('Lluís'), byteAt('Lluís') + byteLength('Lluís α 😀'), 'char');
      check(window.getSelection().toString() === 'Lluís α 😀', 'UTF-8 Visual range');
      window.sourceToPreview(byteAt('$e'), byteAt('$e') + 1, 'cursor');
      check(document.querySelector('.sync-target')?.dataset.math === 'true', 'inline math');
      window.sourceToPreview(byteAt('\\['), byteAt('\\[') + 1, 'cursor');
      check(document.querySelector('.display.sync-target'), 'display math');
      clearSync();
      const wordStart = byteAt('important');
      const selection = window.getSelection();
      selection.addRange(rangeFor(wordStart, wordStart + 9));
      const anchor = window.previewReadingAnchor();
      check(anchor.selection && anchor.start === wordStart && anchor.end === wordStart + 9, 'browser word selection');
      selection.removeAllRanges();
      selection.addRange(rangeFor(byteAt('Lluís'), byteAt('Second') + 6));
      const multiline = window.previewReadingAnchor();
      check(multiline.selection && multiline.start === byteAt('Lluís') && multiline.end === byteAt('Second') + 6, 'browser multiline selection');
      clearSync();
      const prior = document.querySelector('p');
      window.updateSource('prefix\n\n' + fixture);
      check([...document.querySelectorAll('p')].includes(prior), 'incremental DOM reuse');
      const inner = [...document.querySelectorAll('[data-inline-command]')].find(el => el.textContent === 'important').firstElementChild;
      check(Number(inner.dataset.mapStart) === wordStart + 8, 'incremental byte offset shift');
      const long = fixture + '\n\n' + Array.from({length: 35}, (_, i) => 'Reading paragraph ' + i + '. A longer line for navigation.').join('\n\n');
      window.updateSource(long);
      jumpReading(false);
      await frame();
      check(readingAnchor?.element.closest('h1'), 'gg first mapped position');
      check(markerIsFixed(), 'fixed marker after gg');
      document.getElementById('document').style.marginLeft = '70px';
      updateReadingMark();
      check(markerIsFixed(), 'marker independent of document position');
      document.getElementById('document').style.marginLeft = '';
      updateReadingMark();
      const startOffset = readingAnchor.offset;
      window.scrollBy({top: lineHeight(), behavior: 'instant'});
      await frame(); updateReadingMark();
      check(readingAnchor.offset >= startOffset, 'line reading motion');
      check(markerIsFixed(), 'fixed marker after line motion');
      const beforePage = readingAnchor.offset;
      window.scrollBy({top: innerHeight * .5, behavior: 'instant'});
      await frame(); updateReadingMark();
      check(readingAnchor.offset > beforePage, 'half viewport reading motion');
      check(markerIsFixed(), 'fixed marker after page motion');
      const y = scrollY;
      window.updateSource(long + '\n\nExtra final line.');
      check(Math.abs(scrollY - y) < 2, 'stable scroll on append');
      jumpReading(true);
      await frame();
      check(readingAnchor?.element.textContent.includes('Extra final line.'), 'G last mapped position');
      check(markerIsFixed(), 'fixed marker after G');
      const mark = document.getElementById('reading-mark').getBoundingClientRect();
      check(mark.top >= 0 && mark.bottom <= innerHeight, 'visible reading mark');
      const reading = window.previewReadingAnchor();
      check(!reading.selection && reading.start === reading.end, 'marker cursor sync');
      check(getComputedStyle(document.documentElement).scrollbarWidth === 'none', 'hidden scrollbar');
      window.setDraftAppearance('dark');
      check(getComputedStyle(document.body).backgroundColor === 'rgb(28, 28, 30)', 'dark appearance');
      window.setDraftAppearance('light');
      check(getComputedStyle(document.body).backgroundColor === 'rgb(255, 255, 255)', 'light appearance');
      window.updateSource(fixture);
      jumpReading(false);
      status.textContent = results.length + ' browser checks passed';
      status.dataset.result = 'passed';
      status.title = results.join('\n');
    } catch (error) {
      status.textContent = 'FAILED: ' + error.message + '\nPassed: ' + results.join(', ');
      status.dataset.result = 'failed';
    }
  });
`.replace('FIXTURE', JSON.stringify(fixture));
if (process.argv[2]) writeFileSync(process.argv[2], html.replace('</body>', `<script>${browserChecks}</script></body>`));
