// templates.mjs — deterministic, zero-dependency SVG slide engine for the Pocket presentation/narration system.
//
// WHY SVG: the gateway is zero-dep by design. SVG lets us PRODUCE a genuinely FAANG-grade slide as a pure, deterministic
// string (no canvas/puppeteer/font binaries at generation time). Rasterization (SVG->PNG) and video assembly (frames+audio)
// stay OUT of this module — they're an injected capability at the endpoint, so the core stays pure + testable + portable.
//
// DETERMINISM CONTRACT (load-bearing — the whole system is "deterministically be the shape for each"): renderSlide is a
// pure function. Same {template, style, content} -> byte-identical SVG. No Date/Math.random, no ambient state. This is what
// lets a deck be regenerated, diffed, cached by content-hash, and reviewed.
//
// 16:9 at 1920x1080 (video-native). Text is XML-escaped. Long text is wrapped by a deterministic width estimate.

export const CANVAS = Object.freeze({ w: 1920, h: 1080 });

// A single system-font stack (rendered at raster time). Kept identical across styles so wrap-estimates are stable.
const FONT = "'Inter','SF Pro Display','Helvetica Neue',Arial,system-ui,sans-serif";
// Average glyph advance as a fraction of font-size for this stack — used ONLY for deterministic wrapping. Intentionally
// slightly generous so lines never overflow the safe area.
const GLYPH_ADV = 0.54;

// ---------------------------------------------------------------------------------------------------------------------
// STYLES — each is a deterministic, FAANG-grade design system (palette + accent treatment). Add styles here; each must
// define the same keys so every template renders under every style.
// ---------------------------------------------------------------------------------------------------------------------
export const SLIDE_STYLES = Object.freeze({
  // Linear/Vercel dark — near-black, restrained, one luminous accent.
  midnight: {
    bg: '#0B0F19', panel: '#111827', fg: '#F8FAFC', muted: '#94A3B8', hair: '#1E293B',
    accent: '#6366F1', accent2: '#22D3EE', onAccent: '#0B0F19',
    grad: [['#6366F1', 0], ['#22D3EE', 1]],
  },
  // Stripe/keynote aurora — deep saturated gradient field, white type.
  aurora: {
    bg: '#0A0616', panel: '#17102B', fg: '#FFFFFF', muted: '#C4B5FD', hair: '#2A1E48',
    accent: '#A855F7', accent2: '#EC4899', onAccent: '#FFFFFF',
    grad: [['#7C3AED', 0], ['#DB2777', 1]],
  },
  // Apple/editorial light — warm paper, ink text, single confident accent.
  paper: {
    bg: '#FAFAF7', panel: '#FFFFFF', fg: '#0B1220', muted: '#5B6472', hair: '#E7E7E0',
    accent: '#2563EB', accent2: '#0EA5E9', onAccent: '#FFFFFF',
    grad: [['#2563EB', 0], ['#0EA5E9', 1]],
  },
});

export const SLIDE_TEMPLATES = Object.freeze([
  'title', 'section', 'bullets', 'stat', 'quote', 'twoCol', 'imageCaption', 'closing',
]);

const MARGIN = 150;             // safe-area padding
const CONTENT_W = CANVAS.w - MARGIN * 2;

// ---- primitives ------------------------------------------------------------------------------------------------------

export function escapeXml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/** Deterministic greedy word-wrap by estimated advance width. Returns an array of lines (never > maxLines). */
export function wrapText(text, fontSize, maxWidth, maxLines = 8) {
  const words = String(text == null ? '' : text).split(/\s+/).filter(Boolean);
  const perChar = fontSize * GLYPH_ADV;
  const maxChars = Math.max(1, Math.floor(maxWidth / perChar));
  const lines = [];
  let cur = '';
  for (const word of words) {
    const cand = cur ? cur + ' ' + word : word;
    if (cand.length <= maxChars || !cur) {
      cur = cand;
    } else {
      lines.push(cur);
      cur = word;
      // `>=` not `===`: for maxLines=1, `maxLines-1` is 0 and this is only reached AFTER a push (length>=1), so `===`
      // never fired -> unbounded wrapping. `>=` breaks correctly at maxLines=1 and is identical for maxLines>=2.
      if (lines.length >= maxLines - 1) break;
    }
  }
  if (cur && lines.length < maxLines) lines.push(cur);
  // If we truncated, ellipsize the last kept line.
  const consumed = lines.join(' ').split(/\s+/).filter(Boolean).length;
  if (consumed < words.length && lines.length) {
    let last = lines[lines.length - 1];
    while (last.length && (last.length + 1) * perChar > maxWidth) last = last.slice(0, -1);
    lines[lines.length - 1] = last.replace(/[.,;:\s]*$/, '') + '…';
  }
  return lines;
}

/** Multi-line <text> as stacked tspans from a common (x,y) top baseline. */
function textBlock(lines, { x, y, size, weight = 400, fill, spacing = 1.18, anchor = 'start', letter = 0 }) {
  const lh = Math.round(size * spacing);
  const tspans = lines.map((ln, i) =>
    `<tspan x="${x}" dy="${i === 0 ? 0 : lh}">${escapeXml(ln)}</tspan>`).join('');
  const ls = letter ? ` letter-spacing="${letter}"` : '';
  return `<text x="${x}" y="${y + size * 0.5}" font-family="${FONT}" font-size="${size}" font-weight="${weight}" ` +
    `fill="${fill}" text-anchor="${anchor}"${ls} style="dominant-baseline:alphabetic">${tspans}</text>`;
}

function kicker(text, st, { x = MARGIN, y = MARGIN } = {}) {
  if (!text) return '';
  return `<text x="${x}" y="${y}" font-family="${FONT}" font-size="26" font-weight="700" fill="${st.accent}" ` +
    `letter-spacing="4" style="text-transform:uppercase">${escapeXml(String(text).toUpperCase())}</text>`;
}

function footer(brand, st, page) {
  const parts = [];
  parts.push(`<line x1="${MARGIN}" y1="${CANVAS.h - 96}" x2="${CANVAS.w - MARGIN}" y2="${CANVAS.h - 96}" stroke="${st.hair}" stroke-width="2"/>`);
  if (brand) parts.push(`<text x="${MARGIN}" y="${CANVAS.h - 54}" font-family="${FONT}" font-size="24" font-weight="600" fill="${st.muted}">${escapeXml(brand)}</text>`);
  if (page != null) parts.push(`<text x="${CANVAS.w - MARGIN}" y="${CANVAS.h - 54}" font-family="${FONT}" font-size="24" font-weight="600" fill="${st.muted}" text-anchor="end">${escapeXml(String(page))}</text>`);
  return parts.join('');
}

function defsFor(st) {
  const stops = st.grad.map(([c, o]) => `<stop offset="${o}" stop-color="${c}"/>`).join('');
  return `<defs><linearGradient id="acc" x1="0" y1="0" x2="1" y2="1">${stops}</linearGradient>` +
    `<linearGradient id="field" x1="0" y1="0" x2="1" y2="1">` +
    `<stop offset="0" stop-color="${st.bg}"/><stop offset="1" stop-color="${st.panel}"/></linearGradient></defs>`;
}

function doc(bodyEls, st, { field = false } = {}) {
  const bg = field
    ? `<rect width="${CANVAS.w}" height="${CANVAS.h}" fill="url(#field)"/>`
    : `<rect width="${CANVAS.w}" height="${CANVAS.h}" fill="${st.bg}"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CANVAS.w}" height="${CANVAS.h}" ` +
    `viewBox="0 0 ${CANVAS.w} ${CANVAS.h}" role="img">${defsFor(st)}${bg}${bodyEls.join('')}</svg>`;
}

// ---- templates -------------------------------------------------------------------------------------------------------
// Each: (content, style, page) -> svg string. Content keys are documented per template; missing keys degrade gracefully.

const TEMPLATES = {
  title(c, st, page) {
    const titleLines = wrapText(c.title, 120, CONTENT_W, 3);
    const subLines = c.subtitle ? wrapText(c.subtitle, 40, CONTENT_W * 0.86, 3) : [];
    const titleY = 400 - (titleLines.length - 1) * 40;
    return doc([
      `<rect x="0" y="0" width="14" height="${CANVAS.h}" fill="url(#acc)"/>`,
      kicker(c.kicker, st, { x: MARGIN, y: 250 }),
      textBlock(titleLines, { x: MARGIN, y: titleY, size: 120, weight: 800, fill: st.fg, spacing: 1.05 }),
      subLines.length ? textBlock(subLines, { x: MARGIN, y: titleY + titleLines.length * 132 + 30, size: 40, weight: 400, fill: st.muted, spacing: 1.3 }) : '',
      footer(c.brand, st, page),
    ], st, { field: true });
  },

  section(c, st, page) {
    const num = c.number != null ? String(c.number).padStart(2, '0') : '';
    const titleLines = wrapText(c.title, 96, CONTENT_W, 3);
    return doc([
      num ? `<text x="${MARGIN}" y="360" font-family="${FONT}" font-size="240" font-weight="800" fill="url(#acc)" opacity="0.16">${escapeXml(num)}</text>` : '',
      kicker(c.kicker || 'Section', st, { x: MARGIN, y: 250 }),
      textBlock(titleLines, { x: MARGIN, y: 520 - (titleLines.length - 1) * 50, size: 96, weight: 800, fill: st.fg, spacing: 1.06 }),
      c.subtitle ? textBlock(wrapText(c.subtitle, 38, CONTENT_W * 0.8, 2), { x: MARGIN, y: 700, size: 38, weight: 400, fill: st.muted, spacing: 1.3 }) : '',
      footer(c.brand, st, page),
    ], st);
  },

  bullets(c, st, page) {
    const items = (Array.isArray(c.bullets) ? c.bullets : []).slice(0, 6);
    const titleLines = wrapText(c.title, 64, CONTENT_W, 2);
    const startY = 300 + (titleLines.length - 1) * 74;
    const rowH = Math.min(120, Math.floor((CANVAS.h - startY - 160) / Math.max(1, items.length)));
    const rows = items.map((raw, i) => {
      const y = startY + i * rowH;
      const lines = wrapText(raw, 40, CONTENT_W - 90, 2);
      return `<circle cx="${MARGIN + 12}" cy="${y - 2}" r="9" fill="url(#acc)"/>` +
        textBlock(lines, { x: MARGIN + 60, y: y - 18, size: 40, weight: 500, fill: st.fg, spacing: 1.2 });
    });
    return doc([
      kicker(c.kicker, st),
      textBlock(titleLines, { x: MARGIN, y: 210, size: 64, weight: 800, fill: st.fg, spacing: 1.08 }),
      `<line x1="${MARGIN}" y1="${startY - 56}" x2="${MARGIN + 120}" y2="${startY - 56}" stroke="url(#acc)" stroke-width="6" stroke-linecap="round"/>`,
      ...rows,
      footer(c.brand, st, page),
    ], st);
  },

  stat(c, st, page) {
    const value = String(c.value == null ? '' : c.value);
    const size = value.length > 6 ? 260 : 360;
    return doc([
      kicker(c.kicker, st),
      `<text x="${MARGIN}" y="560" font-family="${FONT}" font-size="${size}" font-weight="850" fill="url(#acc)">${escapeXml(value)}</text>`,
      c.label ? textBlock(wrapText(c.label, 54, CONTENT_W, 2), { x: MARGIN, y: 640, size: 54, weight: 700, fill: st.fg, spacing: 1.15 }) : '',
      c.support ? textBlock(wrapText(c.support, 34, CONTENT_W * 0.8, 3), { x: MARGIN, y: 760, size: 34, weight: 400, fill: st.muted, spacing: 1.3 }) : '',
      footer(c.brand, st, page),
    ], st);
  },

  quote(c, st, page) {
    const lines = wrapText(c.quote, 66, CONTENT_W - 80, 5);
    const top = 380 - (lines.length - 1) * 42;
    return doc([
      `<text x="${MARGIN - 10}" y="330" font-family="${FONT}" font-size="240" font-weight="800" fill="url(#acc)" opacity="0.25">&#8220;</text>`,
      textBlock(lines, { x: MARGIN, y: top, size: 66, weight: 600, fill: st.fg, spacing: 1.24 }),
      c.attribution ? `<text x="${MARGIN}" y="${top + lines.length * 88 + 70}" font-family="${FONT}" font-size="36" font-weight="600" fill="${st.accent}">— ${escapeXml(c.attribution)}</text>` : '',
      footer(c.brand, st, page),
    ], st);
  },

  twoCol(c, st, page) {
    const cols = (Array.isArray(c.columns) ? c.columns : []).slice(0, 2);
    const colW = (CONTENT_W - 80) / 2;
    const titleLines = wrapText(c.title, 60, CONTENT_W, 2);
    const startY = 320 + (titleLines.length - 1) * 70;
    const colEls = cols.map((col, i) => {
      const x = MARGIN + i * (colW + 80);
      const head = col.heading ? `<text x="${x}" y="${startY}" font-family="${FONT}" font-size="34" font-weight="800" fill="${st.accent}">${escapeXml(col.heading)}</text>` : '';
      const body = textBlock(wrapText(col.body, 34, colW, 8), { x, y: startY + 60, size: 34, weight: 400, fill: st.fg, spacing: 1.32 });
      return `<rect x="${x}" y="${startY - 60}" width="4" height="${CANVAS.h - startY - 120}" fill="url(#acc)" opacity="0.5"/>` + head + body;
    });
    return doc([
      kicker(c.kicker, st),
      textBlock(titleLines, { x: MARGIN, y: 210, size: 60, weight: 800, fill: st.fg, spacing: 1.08 }),
      ...colEls,
      footer(c.brand, st, page),
    ], st);
  },

  imageCaption(c, st, page) {
    // Deterministic: an image is referenced by href (embedded/served by the caller); we render a framed area + caption.
    const boxX = MARGIN, boxY = 240, boxW = CONTENT_W, boxH = 560;
    const img = c.href
      ? `<image href="${escapeXml(c.href)}" x="${boxX}" y="${boxY}" width="${boxW}" height="${boxH}" preserveAspectRatio="xMidYMid slice"/>`
      : `<rect x="${boxX}" y="${boxY}" width="${boxW}" height="${boxH}" fill="${st.panel}" stroke="${st.hair}" stroke-width="2"/>` +
        `<text x="${boxX + boxW / 2}" y="${boxY + boxH / 2}" font-family="${FONT}" font-size="30" fill="${st.muted}" text-anchor="middle">${escapeXml(c.placeholder || 'image')}</text>`;
    return doc([
      kicker(c.kicker, st),
      c.title ? textBlock(wrapText(c.title, 52, CONTENT_W, 1), { x: MARGIN, y: 200, size: 52, weight: 800, fill: st.fg }) : '',
      `<clipPath id="imgclip"><rect x="${boxX}" y="${boxY}" width="${boxW}" height="${boxH}" rx="18"/></clipPath>`,
      `<g clip-path="url(#imgclip)">${img}</g>`,
      c.caption ? textBlock(wrapText(c.caption, 30, CONTENT_W, 2), { x: MARGIN, y: boxY + boxH + 60, size: 30, weight: 400, fill: st.muted, spacing: 1.3 }) : '',
      footer(c.brand, st, page),
    ], st);
  },

  closing(c, st, page) {
    const titleLines = wrapText(c.title || 'Thank you', 108, CONTENT_W, 2);
    return doc([
      `<rect x="0" y="0" width="${CANVAS.w}" height="${CANVAS.h}" fill="url(#field)"/>`,
      `<rect x="0" y="${CANVAS.h - 16}" width="${CANVAS.w}" height="16" fill="url(#acc)"/>`,
      textBlock(titleLines, { x: MARGIN, y: 470 - (titleLines.length - 1) * 46, size: 108, weight: 800, fill: st.fg, spacing: 1.05 }),
      c.cta ? textBlock(wrapText(c.cta, 40, CONTENT_W * 0.8, 2), { x: MARGIN, y: 650, size: 40, weight: 500, fill: st.accent, spacing: 1.3 }) : '',
      c.contact ? `<text x="${MARGIN}" y="800" font-family="${FONT}" font-size="32" font-weight="500" fill="${st.muted}">${escapeXml(c.contact)}</text>` : '',
    ], st, { field: false });
  },
};

/**
 * Render ONE slide to a deterministic SVG string.
 * @param {{template:string, style?:string, content?:object, page?:number|string}} spec
 * @returns {{ svg:string, width:number, height:number, template:string, style:string }}
 */
export function renderSlide(spec = {}) {
  const template = spec.template;
  if (!TEMPLATES[template]) throw new Error(`renderSlide: unknown template "${template}" (known: ${SLIDE_TEMPLATES.join(', ')})`);
  const styleName = spec.style || 'midnight';
  const st = SLIDE_STYLES[styleName];
  if (!st) throw new Error(`renderSlide: unknown style "${styleName}" (known: ${Object.keys(SLIDE_STYLES).join(', ')})`);
  const content = spec.content && typeof spec.content === 'object' ? spec.content : {};
  const svg = TEMPLATES[template](content, st, spec.page);
  return { svg, width: CANVAS.w, height: CANVAS.h, template, style: styleName };
}

/**
 * Render a whole deck. `deck.slides` is an array of {template, content}. `deck.style`/`deck.brand` apply to all slides
 * unless a slide overrides them. Page numbers are assigned deterministically (1-based, title/section/closing unnumbered).
 * @returns {{ slides: Array<{svg,width,height,template,style}>, count:number, style:string }}
 */
export function renderDeck(deck = {}) {
  const style = deck.style || 'midnight';
  const brand = deck.brand;
  const slides = (Array.isArray(deck.slides) ? deck.slides : []);
  let page = 0;
  const out = slides.map((s) => {
    const numbered = !['title', 'section', 'closing'].includes(s.template);
    if (numbered) page += 1;
    const content = { brand, ...(s.content || {}) };
    return renderSlide({ template: s.template, style: s.style || style, content, page: numbered ? page : null });
  });
  return { slides: out, count: out.length, style };
}
