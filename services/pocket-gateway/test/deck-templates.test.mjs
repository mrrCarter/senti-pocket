// deck-templates.test.mjs — the deterministic SVG slide engine. Zero-dep; `node --test` runs without install.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  renderSlide, renderDeck, wrapText, escapeXml, CANVAS, SLIDE_STYLES, SLIDE_TEMPLATES,
} from '../src/deck/templates.mjs';

const sampleFor = (tpl) => ({
  title: { kicker: 'Q3 Review', title: 'Governed agents, shipped', subtitle: 'How the crew ships without breaking things', brand: 'SentinelLayer' },
  section: { number: 2, title: 'The write path', subtitle: 'From proposal to signed receipt' },
  bullets: { title: 'What landed', bullets: ['First live write, verified', 'Adapter seam closed', 'Auth boundary gated', 'Presentation system'] },
  stat: { kicker: 'Reliability', value: '206/206', label: 'merges gated since 05-21', support: 'Every merge carries a signed evidence bundle.' },
  quote: { quote: 'The web was built for humans. This is the clearance layer for the agentic version.', attribution: 'Carter' },
  twoCol: { title: 'Before / after', columns: [{ heading: 'Before', body: 'Manual review, inconsistent gates.' }, { heading: 'After', body: 'One framework, cited per PR.' }] },
  imageCaption: { title: 'The dashboard', caption: 'Live clearance decisions, per request.', placeholder: 'dashboard.png' },
  closing: { title: 'Thank you', cta: 'Start shipping governed agents', contact: 'sentinelayer.com' },
}[tpl]);

test('every template renders under every style -> valid, sized SVG', () => {
  for (const tpl of SLIDE_TEMPLATES) {
    for (const style of Object.keys(SLIDE_STYLES)) {
      const r = renderSlide({ template: tpl, style, content: sampleFor(tpl), page: 3 });
      assert.equal(r.width, CANVAS.w);
      assert.equal(r.height, CANVAS.h);
      assert.match(r.svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/, `${tpl}/${style} starts with <svg`);
      assert.match(r.svg, /<\/svg>$/, `${tpl}/${style} closes </svg>`);
      // balanced-enough: equal count of <text ... </text> is not required, but no unclosed <svg
      assert.equal((r.svg.match(/<svg /g) || []).length, 1);
      assert.ok(r.svg.length > 200, `${tpl}/${style} is non-trivial`);
    }
  }
});

test('renderSlide is DETERMINISTIC — same input, byte-identical output', () => {
  const spec = { template: 'bullets', style: 'aurora', content: sampleFor('bullets'), page: 4 };
  const a = renderSlide(spec).svg;
  const b = renderSlide(structuredClone(spec)).svg;
  assert.equal(a, b);
  // and stable across calls interleaved with other renders
  renderSlide({ template: 'stat', style: 'paper', content: sampleFor('stat') });
  assert.equal(renderSlide(spec).svg, a);
});

test('content is XML-escaped — no injection into the SVG', () => {
  const r = renderSlide({ template: 'title', content: { title: '<script>alert(1)</script> & "risk" \'x\'' } });
  assert.ok(!r.svg.includes('<script>'), 'raw <script> must not appear');
  assert.ok(r.svg.includes('&lt;script&gt;'), 'angle brackets escaped');
  assert.ok(r.svg.includes('&amp;'), 'ampersand escaped');
  assert.ok(r.svg.includes('&quot;') || r.svg.includes('&apos;'), 'quotes escaped');
});

test('escapeXml handles null/undefined/numbers without throwing', () => {
  assert.equal(escapeXml(null), '');
  assert.equal(escapeXml(undefined), '');
  assert.equal(escapeXml(42), '42');
  assert.equal(escapeXml('a<b>c'), 'a&lt;b&gt;c');
});

test('wrapText wraps by width and never exceeds maxLines; truncation ellipsizes', () => {
  const many = Array.from({ length: 80 }, (_, i) => `word${i}`).join(' ');
  const lines = wrapText(many, 40, 800, 4);
  assert.ok(lines.length <= 4, 'respects maxLines');
  assert.ok(lines[lines.length - 1].endsWith('…'), 'ellipsizes when truncated');
  // short text -> single line, no ellipsis
  const one = wrapText('hello world', 40, 1200, 4);
  assert.deepEqual(one, ['hello world']);
  // empty / nullish -> no lines
  assert.deepEqual(wrapText('', 40, 800), []);
  assert.deepEqual(wrapText(null, 40, 800), []);
});

test('wrapText honors maxLines EXACTLY for every bound incl. 1 (regression: relay Finding 1)', () => {
  const long = 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda';
  // maxLines=1 previously ran unbounded (returned 9 lines). Must be capped at 1 and ellipsized.
  const one = wrapText(long, 40, 200, 1);
  assert.equal(one.length, 1, 'maxLines=1 returns exactly one line');
  assert.ok(one[0].endsWith('…'), 'maxLines=1 ellipsizes the truncated line');
  // maxLines 2..4 stay exactly N when the text overflows (fix is a no-op for these).
  for (const n of [2, 3, 4]) {
    assert.equal(wrapText(long, 40, 200, n).length, n, `maxLines=${n} caps at ${n}`);
  }
  // imageCaption's real call site (title, size 52, full content width, maxLines 1) must not overflow.
  const capTitle = wrapText('An extremely long image caption title that would previously overflow the entire slide area', 52, 1620, 1);
  assert.equal(capTitle.length, 1, 'imageCaption title capped at 1 line');
});

test('unknown template or style throws a helpful error', () => {
  assert.throws(() => renderSlide({ template: 'nope' }), /unknown template "nope"/);
  assert.throws(() => renderSlide({ template: 'title', style: 'neon' }), /unknown style "neon"/);
});

test('missing content degrades gracefully (no throw, still valid SVG)', () => {
  for (const tpl of SLIDE_TEMPLATES) {
    const r = renderSlide({ template: tpl, content: {} });
    assert.match(r.svg, /<\/svg>$/, `${tpl} renders with empty content`);
  }
});

test('renderDeck: page numbering skips title/section/closing; style inherits + overrides; brand injected', () => {
  const deck = renderDeck({
    style: 'midnight', brand: 'SentinelLayer',
    slides: [
      { template: 'title', content: sampleFor('title') },
      { template: 'bullets', content: sampleFor('bullets') },       // page 1
      { template: 'section', content: sampleFor('section') },        // unnumbered
      { template: 'stat', content: sampleFor('stat'), style: 'aurora' }, // page 2, overridden style
      { template: 'closing', content: sampleFor('closing') },
    ],
  });
  assert.equal(deck.count, 5);
  assert.equal(deck.style, 'midnight');
  // per-slide style override honored
  assert.equal(deck.slides[3].style, 'aurora');
  assert.equal(deck.slides[1].style, 'midnight');
  // brand injected into a numbered slide's footer
  assert.ok(deck.slides[1].svg.includes('SentinelLayer'), 'brand appears on bullets footer');
  // numbered slides carry a page number in the footer; title does not
  assert.ok(deck.slides[1].svg.includes('>1<'), 'bullets shows page 1');
  assert.ok(!deck.slides[0].svg.match(/>\d+<\/text>\s*<\/svg>/), 'title has no trailing page number');
});

test('renderDeck determinism across the whole deck', () => {
  const spec = { style: 'paper', brand: 'X', slides: SLIDE_TEMPLATES.map((t) => ({ template: t, content: sampleFor(t) })) };
  const a = renderDeck(spec).slides.map((s) => s.svg).join('');
  const b = renderDeck(structuredClone(spec)).slides.map((s) => s.svg).join('');
  assert.equal(a, b);
});
