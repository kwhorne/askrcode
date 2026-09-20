import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup } from '@testing-library/svelte'
import { violations } from './axe.js'

import Icon from '../src/Icon.svelte'
import { ArrowDownTray } from '../src/icons/micro/index.js'

afterEach(cleanup)

function svg(container) {
  return container.querySelector('svg')
}

describe('Icon', () => {
  it('tegner ikonet', () => {
    const { container } = render(Icon, { icon: ArrowDownTray })
    expect(svg(container)).not.toBeNull()
    expect(container.querySelector('path')).not.toBeNull()
  })

  it('tegner ingenting uten et ikon', () => {
    const { container } = render(Icon, {})
    expect(svg(container)).toBeNull()
  })

  // Et ikon ved siden av tekst er dekorasjon og skal være usynlig for en
  // skjermleser. Sier det navnet sitt i tillegg til knappeteksten, hører
  // man det samme to ganger.
  it('er skjult for skjermlesere når det ikke har et navn', () => {
    const { container } = render(Icon, { icon: ArrowDownTray })
    expect(svg(container).getAttribute('aria-hidden')).toBe('true')
    expect(svg(container).hasAttribute('aria-label')).toBe(false)
  })

  // Et ikon som står alene — en lukkeknapp, en sorteringspil — er den
  // eneste informasjonen som finnes, og må ha et navn.
  it('får rolle og navn når det står alene', () => {
    const { container } = render(Icon, { icon: ArrowDownTray, label: 'Download' })
    expect(svg(container).getAttribute('role')).toBe('img')
    expect(svg(container).getAttribute('aria-label')).toBe('Download')
    expect(svg(container).hasAttribute('aria-hidden')).toBe(false)
  })

  it('har en standardstørrelse, og tar imot andre', () => {
    const { container } = render(Icon, { icon: ArrowDownTray })
    expect(svg(container).getAttribute('class')).toContain('size-5')
    cleanup()

    const lg = render(Icon, { icon: ArrowDownTray, size: 'lg' })
    expect(svg(lg.container).getAttribute('class')).toContain('size-6')
  })

  it('faller tilbake til standardstørrelsen på et ukjent navn', () => {
    const { container } = render(Icon, { icon: ArrowDownTray, size: 'kjempestor' })
    expect(svg(container).getAttribute('class')).toContain('size-5')
  })

  // Den som bruker komponenten skal vinne. Uten cn() gjør de ikke det.
  it('lar appens egen klasse overstyre størrelsen', () => {
    const { container } = render(Icon, { icon: ArrowDownTray, class: 'size-10' })
    const cls = svg(container).getAttribute('class')
    expect(cls).toContain('size-10')
    expect(cls).not.toContain('size-5')
  })

  it('sender ukjente attributter videre', () => {
    const { container } = render(Icon, {
      icon: ArrowDownTray,
      'data-testid': 'ned',
    })
    expect(svg(container).getAttribute('data-testid')).toBe('ned')
  })

  // Tilgjengelighet er halve leveransen i dette biblioteket, så den må ha en
  // port og ikke en god intensjon. axe kjøres på hver komponent i hver
  // tilstand etter hvert som de kommer.
  it('har ingen axe-brudd, verken skjult eller navngitt', async () => {
    const dekorativ = render(Icon, { icon: ArrowDownTray })
    expect(await violations(dekorativ.container)).toEqual([])
    cleanup()

    const alene = render(Icon, { icon: ArrowDownTray, label: 'Download' })
    expect(await violations(alene.container)).toEqual([])
  }, 30000)
})
