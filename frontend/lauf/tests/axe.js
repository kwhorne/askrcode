import axe from 'axe-core'

// Felles axe-oppsett.
//
// To regler er slått av, og begge fortjener en forklaring, for en regel som
// er av i stillhet er verre enn en som ikke finnes:
//
//   region       — krever at alt innhold ligger i et landemerke. Vi
//                  rendrer én komponent, ikke en side, så den er alltid
//                  brutt her og alltid uinteressant.
//
//   color-contrast — **kan ikke måles i jsdom.** jsdom legger ikke ut noe,
//                  regner ikke ut farger og har ikke canvas, så axe faller
//                  tilbake på å gjette og kaster i stedet. Kontrast må
//                  derfor sjekkes i en ekte nettleser; det står som et
//                  eget punkt under «hva som må være sant» i LAUF.md.
//                  Denne suiten dekker altså struktur og navn, ikke farge.
const DISABLED = {
  region: { enabled: false },
  'color-contrast': { enabled: false },
}

/** Kjører axe og returnerer id-ene til bruddene — tom liste er bestått. */
export async function violations(container, options = {}) {
  const r = await axe.run(container, { rules: { ...DISABLED, ...(options.rules ?? {}) } })
  return r.violations.map((v) => v.id)
}
