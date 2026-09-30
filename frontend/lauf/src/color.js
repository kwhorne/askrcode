// Colour arithmetic for the themes: OKLCH and hex to sRGB, relative
// luminance and WCAG contrast. Shared by scripts/themes.mjs, which chooses
// shades by it, tests/themes.test.js, which measures what was written, and
// any page that wants to show the numbers: `@askrcode/lauf/color`. Not in
// the main entry, so a page that never asks does not carry it.
//
// A colour outside sRGB is clipped per channel. A browser maps it into the
// gamut by reducing chroma instead, which moves luminance a little; that is
// why the thresholds the generator holds itself to have a margin, and why
// lauf:check measures a sample of the themes again in Chrome.

// 'oklch(70.4% 0.14 182.503)', '#fff', '#fbfaf8' -> [r, g, b], 0..1, gamma
// encoded.
export function toSrgb(css) {
  const s = css.trim()
  if (s.startsWith('#')) return hexToSrgb(s)
  // The hue may be `none`: a gray with no hue at all, as neutral is.
  const m = s.match(/^oklch\(\s*([\d.]+)(%?)\s+([\d.]+)\s+([\d.]+|none)\s*\)$/)
  if (!m) throw new Error(`not a colour this reads: ${css}`)
  const L = parseFloat(m[1]) / (m[2] === '%' ? 100 : 1)
  const C = parseFloat(m[3])
  const h = m[4] === 'none' ? 0 : (parseFloat(m[4]) * Math.PI) / 180
  return oklabToSrgb(L, C * Math.cos(h), C * Math.sin(h))
}

function hexToSrgb(hex) {
  let h = hex.slice(1)
  if (h.length === 3) h = [...h].map((c) => c + c).join('')
  if (h.length !== 6) throw new Error(`not a colour this reads: ${hex}`)
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
}

function oklabToSrgb(L, a, b) {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3
  const lin = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ]
  return lin.map((c) => {
    const x = Math.min(1, Math.max(0, c))
    return x <= 0.0031308 ? 12.92 * x : 1.055 * x ** (1 / 2.4) - 0.055
  })
}

function linear(c) {
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4
}

export function luminance(css) {
  const [r, g, b] = (Array.isArray(css) ? css : toSrgb(css)).map(linear)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// WCAG 2 contrast ratio, 1 to 21.
export function contrast(a, b) {
  const la = luminance(a)
  const lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

// A over B at the given opacity, as a browser composites it: in gamma-
// encoded sRGB. What `bg-accent/15` over the surface is on the screen.
export function over(a, alpha, b) {
  const x = toSrgb(a)
  const y = toSrgb(b)
  return x.map((c, i) => alpha * c + (1 - alpha) * y[i])
}
