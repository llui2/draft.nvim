// Generate a browser regression page beside the preview's KaTeX assets.
// node tests/preview.mjs /tmp/draft-browser/check.html
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const html = readFileSync('lua/draft/preview.html', 'utf8');
const indexSource = readFileSync('draft.tex', 'utf8');
const indexTargets = [...indexSource.matchAll(/\\href\{([^}]+\.tex)\}/g)].map(match => match[1]);
assert.equal(indexTargets.length, 9);
for (const target of indexTargets) assert.ok(existsSync(target), `index target exists: ${target}`);
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
const scaledSvg = {
  getScreenCTM() { return { inverse() { return { a: 0.25, b: 0, c: 0, d: 0.5, e: 0, f: 0 }; } }; },
  createSVGPoint() { return { matrixTransform(matrix) { return {x: this.x * matrix.a, y: this.y * matrix.d}; } }; },
};
const screenStart = context.window.draftFigureDragPoint(scaledSvg, 20, 10);
const screenEnd = context.window.draftFigureDragPoint(scaledSvg, 100, 50);
const pointDelta = context.window.draftFigureTexDisplacement(screenEnd.x - screenStart.x, screenEnd.y - screenStart.y, 72.27 / 72);
assert.ok(Math.abs(pointDelta.x - 20.075) < 0.001);
assert.ok(Math.abs(pointDelta.y + 20.075) < 0.001);
const movedShift = context.window.draftFigureShiftAfterDrag(1.25, -0.5, pointDelta.x, pointDelta.y);
assert.equal(movedShift.x, 21.325);
assert.equal(movedShift.y, -20.575);
for (const environment of ['equation', 'equation*', 'align', 'gather', 'multline']) {
  context.fixture = `\\begin{${environment}}\nx=1\n\\end{${environment}}`;
  assert.equal(vm.runInContext('source = fixture; parse()[0].kind', context), 'math');
}

function preview(tex) {
  context.fixture = tex;
  return vm.runInContext('source = fixture; (() => { const items = []; const html = parse().map(block => renderBlock(block, items)).join(""); return {html, items}; })()', context);
}
const renderedIndex = preview(indexSource);
assert.equal(renderedIndex.items.length, 0);
assert.equal((renderedIndex.html.match(/href="draft:\/\/open\?/g) || []).length, 9);
for (const [environment, tag] of [['itemize','ul'], ['enumerate','ol'], ['quote','blockquote'], ['center','div']]) {
  const result = preview(`\\begin{${environment}}\n${tag === 'ul' || tag === 'ol' ? '\\item ' : ''}First\n${tag === 'ul' || tag === 'ol' ? '\\item ' : ''}Second\n\\end{${environment}}`);
  assert.match(result.html, new RegExp(`<${tag}[ >]`));
  assert.equal(result.items.length, 0);
}
assert.match(preview(String.raw`\begin{itemize}\item Outer\begin{enumerate}\item Inner\end{enumerate}\end{itemize}`).html, /<ul>[\s\S]*<li>[\s\S]*<ol>[\s\S]*Inner/);
assert.equal(preview(String.raw`\foo{kept \textbf{bold}}`).items.length, 0);
assert.match(preview(String.raw`\foo{kept \textbf{bold}}`).html, /<strong/);
assert.match(preview(String.raw`\newcommand{\R}{\mathbb{R}}
$\R$`).html, /\\mathbb\{R\}/);
assert.match(preview(String.raw`\newcommand{\vect}[1]{\mathbf{#1}}
$\vect{x}$`).html, /\\mathbf\{x\}/);
assert.match(preview(String.raw`\newcommand{\pair}[2]{#1+#2}
\renewcommand{\pair}[2]{#2-#1}
$\pair{a}{b}$`).html, /b-a/);
assert.match(preview(String.raw`\DeclareMathOperator{\rank}{rank}
$\rank A$`).html, /\\operatorname\{rank\}/);
const linkedDocument = preview(String.raw`\href{templates/annotated-curves.tex}{Annotated curves}
\href{https://example.com/article}{External article}
\href{javascript:alert(1)}{Unsupported}
\label{sec:results}
\href{#sec:results}{Jump to results}`);
assert.match(linkedDocument.html, /href="draft:\/\/open\?target=templates%2Fannotated-curves\.tex&start=0"/);
assert.match(linkedDocument.html, /href="https:\/\/example\.com\/article"/);
assert.match(preview(String.raw`\url{https://example.com}`).html, /href="https:\/\/example\.com"/);
assert.match(linkedDocument.html, /id="sec:results"/);
assert.match(linkedDocument.html, /href="#sec:results"/);
assert.doesNotMatch(linkedDocument.html, /href="javascript:/);
assert.equal(preview(String.raw`\usepackage[anything]{unknown}
\usepackage{amsmath}
Visible`).items.length, 0);
assert.match(preview(String.raw`\newcommand{\loop}{\loop}
$\loop$`).items[0].message, /Recursive/);
preview('α\n\\broken');
assert.equal(vm.runInContext('diagnosticText(problem("warning", "Unsupported preview command \\\\broken", 3, 10))', context), 'Unsupported preview command \\broken\nline 2: \\broken');

assert.match(preview(Array.from({length: 18}, (_, i) => `\\newcommand{\\m${String.fromCharCode(97+i)}}{\\m${String.fromCharCode(98+i)}}`).join('\n') + '\n$\\ma$').items[0].message, /limit/);
assert.match(preview(String.raw`\newcommand{\bad}[1]{\bad{#1}}
$\bad{x}$`).items[0].message, /Recursive/);
const unicodeDeclaration = String.raw`\newcommand{\word}{α}
Visible`;
context.fixture = unicodeDeclaration;
assert.equal(vm.runInContext('source = fixture; parse()[0].startOffset', context), byteLengthForTest(unicodeDeclaration.slice(0, unicodeDeclaration.indexOf('Visible'))));
function byteLengthForTest(value) {return new TextEncoder().encode(value).length;}
preview('α\n\\broken');
let copied;
context.navigator = {clipboard: {async writeText(value) {copied = value;}}};
context.setTimeout = () => {};
context.button = {getAttribute() {return 'Copy';}, setAttribute() {}, style: {}};
await vm.runInContext('copyDiagnostics([problem("warning", "Test", 3, 10)], button)', context);
assert.equal(copied, 'Test\nline 2: \\broken');
// Exercise the file/WKWebView fallback when the asynchronous clipboard is absent.
context.navigator = {};
context.window.getSelection = () => ({rangeCount: 0, removeAllRanges() {}, addRange() {}});
context.document.createElement = () => ({style: {}, select() {}, remove() {}});
context.document.body = {append() {}};
context.document.execCommand = command => {assert.equal(command, 'copy'); return true;};
await vm.runInContext('copyDiagnostics([problem("error", "Error", 3, 10)], button)', context);
assert.equal(context.button.title, 'Copied');
context.document.execCommand = () => false;
await vm.runInContext('copyDiagnostics([problem("error", "Error", 3, 10)], button)', context);
assert.equal(context.button.title, 'Could not copy diagnostic');
console.log('Draft: JavaScript syntax, fragments, math environments, inline wrappers and UTF-8 checks passed');

const note = readFileSync('tests/fixtures/lightweight.tex', 'utf8');
assert.equal(preview(note).items.length, 0);
assert.match(preview(note).html, /<strong[^>]*>[\s\S]*important/);

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
      window.updateSource(['\\documentclass[tikz,border=2pt]{standalone}', '\\begin{document}\\begin{tikzpicture}\\draw (0,0)--(1,1);\\end{tikzpicture}\\end{document}'].join('\n'));
      window.updateFigure('<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0L1 1"/></svg>', null);
      const validFigure = document.querySelector('.tikz-figure svg');
      check(validFigure, 'inline vector figure');
      window.updateFigure(null, 'synthetic compile error');
      check(document.querySelector('.tikz-figure svg') === validFigure, 'last valid figure survives compile error');
      check(!document.getElementById('problems').hidden, 'figure compile error is reported');
      window.updateSource(['\\documentclass[tikz,border=2pt]{standalone}', '\\begin{document}\\begin{tikzpicture}\\node[name=critical,xshift=1.25pt,yshift=-0.5pt] {A};\\end{tikzpicture}\\end{document}'].join('\n'));
      window.updateFigure('<svg xmlns="http://www.w3.org/2000/svg" width="100pt" height="100pt" viewBox="0 0 100 100"><g data-draft-node="critical" data-draft-xshift="1.25" data-draft-yshift="-0.5" fill="rgb(0%, 0%, 0%)"><rect x="10" y="10" width="30" height="20"/></g></svg>', null, 37);
      let editRequest;
      const interceptEdit = event => { editRequest = event.detail; event.preventDefault(); };
      window.addEventListener('draft-node-edit', interceptEdit, {once: true});
      const editableSvg = document.querySelector('.tikz-figure svg');
      const editableGroup = editableSvg.querySelector('[data-draft-node="critical"]');
      const box = editableGroup.getBoundingClientRect();
      const startX = box.left + box.width / 2, startY = box.top + box.height / 2;
      const beforePoint = window.draftFigureDragPoint(editableSvg, startX, startY);
      editableGroup.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,button:0,pointerId:91,clientX:startX,clientY:startY}));
      window.dispatchEvent(new PointerEvent('pointermove', {bubbles:true,pointerId:91,clientX:startX+24,clientY:startY-12}));
      const afterPoint = window.draftFigureDragPoint(editableSvg, startX+24, startY-12);
      window.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,button:0,pointerId:91,clientX:startX+24,clientY:startY-12}));
      const expected = window.draftFigureShiftAfterDrag(1.25,-0.5,
        window.draftFigureTexDisplacement(afterPoint.x-beforePoint.x, afterPoint.y-beforePoint.y, 72.27/72).x,
        window.draftFigureTexDisplacement(afterPoint.x-beforePoint.x, afterPoint.y-beforePoint.y, 72.27/72).y);
      check(editRequest?.name === 'critical' && editRequest.tick === 37, 'drag request uses source node ID and changedtick');
      check(editRequest?.dx === expected.x && editRequest?.dy === expected.y, 'drag request converts zoomed SVG movement into cumulative TeX shifts');
      check(editableGroup.getAttribute('transform')?.startsWith('translate('), 'label moves during drag');
      window.completeNodeEdit(false, 'test rejection');
      check(!editableGroup.hasAttribute('transform'), 'rejected edit rolls visual label back');
      window.removeEventListener('draft-node-edit', interceptEdit);
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
      window.updateSource(NOTE);
      check(document.querySelectorAll('ul li').length === 4, 'nested list rendering');
      check(document.getElementById('problems').hidden, 'lightweight note has no diagnostics');
      check(!document.querySelector('.katex-error'), 'custom math commands render');
      window.updateSource(NOTE.replace('\\mathbb{R}', '\\mathbb{C}'));
      check(document.querySelector('.katex').textContent.includes('C'), 'macro edit invalidates rendered math');
      window.updateSource(NOTE);
      const listStart = byteLength(NOTE.slice(0, NOTE.indexOf('First point')));
      window.sourceToPreview(listStart, listStart + 5, 'char');
      check(window.getSelection().toString() === 'First', 'list source range');
      clearSync();
      const controls = document.createElement('div');
      controls.style.cssText = 'position:fixed;bottom:40px;right:4px;font:12px sans-serif';
      const diagnostic = document.createElement('button');
      diagnostic.textContent = 'Test diagnostics';
      diagnostic.onclick = () => window.updateSource(NOTE + '\n\\unhandled\n\\another');
      controls.append(diagnostic);
      const errorTest = document.createElement('button'); errorTest.textContent = 'Test error';
      errorTest.onclick = () => window.updateSource(NOTE + '\n$\\undefinedmathcommand$');
      controls.append(errorTest);
      const paste = document.createElement('textarea');
      paste.setAttribute('aria-label', 'Clipboard verification');
      controls.append(paste);
      const read = document.createElement('button'); read.textContent = 'Read system clipboard';
      read.onclick = async () => { try { paste.value = await navigator.clipboard.readText(); } catch (error) { paste.value = error.message; } };
      controls.append(read); document.body.append(controls);
      status.textContent = results.length + ' browser checks passed';
      status.dataset.result = 'passed';
      status.title = results.join('\n');
    } catch (error) {
      status.textContent = 'FAILED: ' + error.message + '\nPassed: ' + results.join(', ');
      status.dataset.result = 'failed';
    }
  });
`.replace('FIXTURE', () => JSON.stringify(fixture)).replaceAll('NOTE', () => JSON.stringify(note));
new vm.Script(browserChecks);
if (process.argv[2]) writeFileSync(process.argv[2], html.replace('</body>', () => `<script>${browserChecks}</script></body>`));
