import { describe, it, expect } from 'vitest'
import { cn } from '../src/utils.js'

describe('cn', () => {
  it('slår sammen klasser', () => {
    expect(cn('a', 'b')).toBe('a b')
  })

  it('hopper over falske verdier', () => {
    expect(cn('a', false && 'b', null, undefined, 'c')).toBe('a c')
  })

  it('tar imot betingelser som objekt og array', () => {
    expect(cn(['a', { b: true, c: false }])).toBe('a b')
  })

  // Dette er hele grunnen til at cn() finnes. Ryker den, kan ingen app
  // overstyre noe som helst i et komponentbibliotek bygget på Tailwind, og
  // symptomet er at class-attributtet «ikke virker».
  it('lar den siste vinne når to klasser styrer det samme', () => {
    expect(cn('w-auto', 'w-full')).toBe('w-full')
    expect(cn('px-2 py-1', 'px-4')).toBe('py-1 px-4')
    expect(cn('bg-surface', 'bg-accent')).toBe('bg-accent')
  })

  it('rører ikke klasser som ikke er i konflikt', () => {
    expect(cn('rounded-control border', 'w-full')).toBe('rounded-control border w-full')
  })
})
