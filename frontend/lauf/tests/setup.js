// jsdom mangler noen nettleser-API-er som komponenter med måling bruker.
// De stubbes her i stedet for i hver test.
//
// Merk hva det betyr: en stub som ikke observerer noe gjør at *koden* kan
// kjøre, ikke at *målingen* er riktig. Alt som avhenger av faktiske
// størrelser — flytende plassering, kollisjonsdeteksjon, dra i en slider
// med musa — er udekket her og sjekkes i en ekte nettleser.

class NoopObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
  takeRecords() {
    return []
  }
}

globalThis.ResizeObserver ??= NoopObserver
globalThis.IntersectionObserver ??= NoopObserver

globalThis.matchMedia ??= (query) => ({
  matches: false,
  media: query,
  onchange: null,
  addEventListener() {},
  removeEventListener() {},
  addListener() {},
  removeListener() {},
  dispatchEvent: () => false,
})

// Alt under rører DOM-prototyper, og setup-fila kjører også for testen som
// går i node-miljø (tree-shaking bygger med Vite, og esbuild nekter i
// jsdom). Der finnes ikke Element i det hele tatt, så vakten må stå.
if (typeof Element !== 'undefined') {
  // jsdom implementerer ikke scrollIntoView. Kommandopaletten ruller det
  // uthevede valget inn i synet, og uten stubben kommer feilen som en
  // ubehandlet rejection etter at testen er ferdig — altså langt fra der
  // den oppstod.
  Element.prototype.scrollIntoView ??= function () {}

  // jsdom har ikke pekerfangst, og Bits bruker den på slider og lignende.
  if (!Element.prototype.setPointerCapture) {
    Element.prototype.setPointerCapture = function () {}
    Element.prototype.releasePointerCapture = function () {}
    Element.prototype.hasPointerCapture = function () {
      return false
    }
  }
}
