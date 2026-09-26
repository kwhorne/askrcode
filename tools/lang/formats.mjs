// Numbers and dates in the reader's format, from ICU -- not from memory.
//
//   node tools/lang/formats.mjs
//
// writes src/core/Askr.Core.LangData.pas and tests/vectors/formats.txt.
// Both are checked in, like the crypto vectors: the Pascal formatting is
// held against what ICU itself writes, and a person does not type the
// month names of forty languages.
//
// Each style is read out of ICU by formatting a known moment and naming
// the parts: a numeric month that came out as "01" for January is MM, one
// that came out as "1" is M, a month in letters is a name from the table
// the same style writes. The patterns are the ones ICU uses, with its
// literals -- the Arabic direction marks, the Thai era, the "kl." -- as
// they are.
//
// Every date is Gregorian: Thai is written with the Gregorian year, not
// the Buddhist one. Every locale here writes 0-9; one that does not is
// refused until the Pascal side maps digits.

import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

// The languages the plural rules cover, and a few regions whose formats
// are not their language's.
export const tags = [
  'en', 'en-GB', 'en-AU', 'en-CA', 'nb', 'nn', 'da', 'sv', 'de', 'de-AT', 'de-CH',
  'nl', 'fi', 'et', 'el', 'hu', 'tr', 'bg', 'af', 'sq', 'eu', 'gl', 'ka', 'az',
  'kk', 'ur', 'sw', 'fr', 'fr-CA', 'fr-CH', 'pt', 'pt-PT', 'es', 'es-MX', 'it', 'ca',
  'pl', 'ru', 'uk', 'be', 'cs', 'sk', 'hr', 'sr', 'bs', 'ro', 'lt', 'lv', 'ar',
  'he', 'is', 'ja', 'zh', 'zh-TW', 'ko', 'th', 'vi', 'id', 'ms',
]

const UTC = { timeZone: 'UTC', calendar: 'gregory' }
const at = (y, m, d, h = 0, min = 0, s = 0) => new Date(Date.UTC(y, m - 1, d, h, min, s))

function dateParts(tag, opts, when) {
  return new Intl.DateTimeFormat(tag, { ...UTC, ...opts }).formatToParts(when)
}

// A pattern: literals as written, a {token} for each field.
function pattern(tag, opts) {
  // 5 January 2026, 09:07:03 -- every field that can be padded is small.
  const small = dateParts(tag, opts, at(2026, 1, 5, 9, 7, 3))
  const pm = dateParts(tag, opts, at(2026, 1, 5, 14, 7, 3))
  const midnight = dateParts(tag, opts, at(2026, 1, 5, 0, 7, 3))
  let out = ''
  let texts = false
  for (let i = 0; i < small.length; i++) {
    const p = small[i]
    switch (p.type) {
      case 'literal':
      case 'era':
        if (/[{}]/.test(p.value)) throw new Error(`a brace in ${tag}: ${p.value}`)
        // V8's format() writes an ordinary space where ICU has a narrow
        // no-break one (U+202F) -- a web-compatibility choice, and what a
        // browser shows. formatToParts keeps ICU's; the text follows
        // format(), since that is what the reader sees next to it.
        out += p.value.replace(/\u202f/g, ' ')
        break
      case 'year':
        out += p.value.length === 2 ? '{yy}' : '{yyyy}'
        break
      case 'month':
        // A number only when it is nothing but digits: Korean writes 1월
        // and Vietnamese thg 1, which are names like any other.
        if ([...p.value].every((c) => digitsOf(tag).includes(c)))
          out += p.value.length === 2 ? '{MM}' : '{M}'
        else {
          out += '{MMMM}'
          texts = true
        }
        break
      case 'day':
        out += p.value.length === 2 ? '{dd}' : '{d}'
        break
      case 'hour': {
        // 14:07 written 14 is a 24-hour clock; a 12-hour one writes 2,
        // and midnight as 12 or as 0.
        const two = p.value.length === 2
        if (isTwentyFour(tag, pm[i].value)) out += two ? '{HH}' : '{H}'
        else out += isZero(tag, midnight[i].value) ? (two ? '{KK}' : '{K}') : (two ? '{hh}' : '{h}')
        break
      }
      case 'minute':
        out += '{mm}'
        break
      case 'second':
        out += '{ss}'
        break
      case 'dayPeriod':
        out += '{a}'
        break
      default:
        throw new Error(`${tag}: a part called ${p.type} in ${JSON.stringify(opts)}`)
    }
  }
  return { pattern: out, texts }
}

function digitsOf(tag) {
  const nf = new Intl.NumberFormat(tag, { useGrouping: false })
  return Array.from({ length: 10 }, (_, d) => nf.format(d)).join('')
}

// 14 in the locale's digits means a 24-hour clock.
function isTwentyFour(tag, value) {
  const d = digitsOf(tag)
  return value === d[1] + d[4]
}
function isZero(tag, value) {
  const d = digitsOf(tag)
  return value === d[0] || value === d[0] + d[0]
}

// The month names a style writes, in the context it writes them: Polish
// "stycznia" in a date, not "styczeń" on its own.
function monthsOf(tag, opts) {
  const names = []
  for (let m = 1; m <= 12; m++) {
    const part = dateParts(tag, opts, at(2026, m, 5)).find((p) => p.type === 'month')
    names.push(part.value)
  }
  return names
}

// The word for the time of day, for each of the 24 hours: AM and PM for
// most, and for Traditional Chinese five of them -- early morning,
// morning, noon, afternoon, evening. The minutes never change it.
function dayPeriods(tag) {
  const get = (h) => {
    const own = dateParts(tag, { timeStyle: 'short' }, at(2026, 1, 5, h, 30))
      .find((p) => p.type === 'dayPeriod')?.value
    if (own !== undefined) return own
    return dateParts(tag, { hour: 'numeric', minute: '2-digit', hourCycle: 'h12' }, at(2026, 1, 5, h, 30))
      .find((p) => p.type === 'dayPeriod')?.value ?? ''
  }
  return Array.from({ length: 24 }, (_, h) => get(h))
}

function numbers(tag) {
  // Every locale here writes 0-9. One that does not -- Persian, Arabic in
  // Egypt -- needs the Pascal side to map digits first, and a test for it;
  // until then it is refused here rather than printed wrong there.
  if (digitsOf(tag) !== '0123456789')
    throw new Error(`${tag} writes digits other than 0-9: map them in Askr.Core.Format first`)
  const parts = new Intl.NumberFormat(tag, { maximumFractionDigits: 3 }).formatToParts(-1234567.891)
  const val = (t) => parts.filter((p) => p.type === t).map((p) => p.value)[0] ?? ''
  // A group separator for four digits, or only from five: Polish and
  // Spanish write 1000 but 10 000.
  const grouped4 = new Intl.NumberFormat(tag).formatToParts(1000).some((p) => p.type === 'group')
  // Everything in front of the first digit of a negative number: the sign,
  // and in Arabic the direction mark ICU writes before it.
  const minus = parts.slice(0, parts.findIndex((p) => p.type === 'integer')).map((p) => p.value).join('')
  return {
    decimal: val('decimal'),
    group: val('group'),
    minus,
    minGrouping: grouped4 ? 1 : 2,
  }
}

function localeData(tag) {
  const d = {}
  const n = numbers(tag)
  Object.assign(d, n)
  for (const style of ['short', 'medium', 'long']) {
    const p = pattern(tag, { dateStyle: style })
    d['date_' + style] = p.pattern
    d['months_' + style] = p.texts ? monthsOf(tag, { dateStyle: style }) : []
    const dt = pattern(tag, { dateStyle: style, timeStyle: 'short' })
    d['datetime_' + style] = dt.pattern
    if (dt.texts && !p.texts) throw new Error(`${tag}: a month in letters only with a time`)
  }
  d.time_short = pattern(tag, { timeStyle: 'short' }).pattern
  d.time_medium = pattern(tag, { timeStyle: 'medium' }).pattern
  d.day_periods = dayPeriods(tag)
  return d
}

// ---------------------------------------------------------------- Pascal --

function pas(s) {
  return "'" + s.replace(/'/g, "''") + "'"
}

const data = tags.map((t) => [t, localeData(t)])
const lines = []
lines.push('{ Askr.Core.LangData -- numbers and dates, per locale, from ICU.')
lines.push('')
lines.push('  Generated by tools/lang/formats.mjs from ICU ' + process.versions.icu +
  ' (CLDR ' + process.versions.cldr + '). Do not edit:')
lines.push('  run the script again, and tests/vectors/formats.txt comes with it.')
lines.push('')
lines.push('  A pattern is literals as ICU writes them and a (*token*) in braces for')
lines.push('  each field: yyyy yy M MM MMMM d dd H HH h hh K KK mm ss a. A months')
lines.push('  list is the twelve names that style writes, joined with |, and empty')
lines.push('  when its month is a number. }')
lines.push('unit Askr.Core.LangData;')
lines.push('')
lines.push('{$mode Delphi}{$H+}')
lines.push('')
lines.push('interface')
lines.push('')
lines.push('type')
lines.push('  TLocaleFormat = record')
lines.push('    Tag: string;')
lines.push('    Decimal, Group, Minus: string;')
lines.push('    MinGrouping: Integer;')
lines.push('    DateShort, DateMedium, DateLong: string;')
lines.push('    DateTimeShort, DateTimeMedium, DateTimeLong: string;')
lines.push('    TimeShort, TimeMedium: string;')
lines.push('    MonthsShort, MonthsMedium, MonthsLong: string;')
lines.push('    DayPeriods: string;   { 24 words, one per hour, joined with | }')
lines.push('  end;')
lines.push('')
lines.push(`const`)
lines.push(`  LocaleFormats: array[0..${data.length - 1}] of TLocaleFormat = (`)
data.forEach(([t, d], i) => {
  lines.push(`    (Tag: ${pas(t)};`)
  lines.push(`     Decimal: ${pas(d.decimal)}; Group: ${pas(d.group)}; Minus: ${pas(d.minus)};`)
  lines.push(`     MinGrouping: ${d.minGrouping};`)
  lines.push(`     DateShort: ${pas(d.date_short)}; DateMedium: ${pas(d.date_medium)}; DateLong: ${pas(d.date_long)};`)
  lines.push(`     DateTimeShort: ${pas(d.datetime_short)}; DateTimeMedium: ${pas(d.datetime_medium)}; DateTimeLong: ${pas(d.datetime_long)};`)
  lines.push(`     TimeShort: ${pas(d.time_short)}; TimeMedium: ${pas(d.time_medium)};`)
  lines.push(`     MonthsShort: ${pas(d.months_short.join('|'))};`)
  lines.push(`     MonthsMedium: ${pas(d.months_medium.join('|'))};`)
  lines.push(`     MonthsLong: ${pas(d.months_long.join('|'))};`)
  lines.push(`     DayPeriods: ${pas(d.day_periods.join('|'))})${i < data.length - 1 ? ',' : ''}`)
})
lines.push('  );')
lines.push('')
lines.push('implementation')
lines.push('')
lines.push('end.')
writeFileSync(join(root, 'src/core/Askr.Core.LangData.pas'), lines.join('\n') + '\n')

// ---------------------------------------------------------------- vectors --

const vectors = ['# locale|kind|input|expected -- written by tools/lang/formats.mjs from ICU ' +
  process.versions.icu + '. Do not edit.']
const moments = [at(2026, 1, 5, 9, 7, 3), at(2026, 11, 23, 14, 45, 59), at(1999, 12, 31, 0, 30, 0)]
const iso = (w) => w.toISOString().slice(0, 19).replace('T', ' ')
for (const t of tags) {
  const nf = (o) => new Intl.NumberFormat(t, o)
  for (const v of [0, 7, 1000, 12345, -1234567, 1000000]) vectors.push(`${t}|int|${v}|${nf().format(v)}`)
  for (const [v, dec] of [[1234.5678, 2], [-0.25, 2], [3.14159, 3], [1000000.1, 1], [42, 0]])
    vectors.push(`${t}|dec${dec}|${v}|${nf({ minimumFractionDigits: dec, maximumFractionDigits: dec }).format(v)}`)
  for (const w of moments) {
    for (const style of ['short', 'medium', 'long']) {
      vectors.push(`${t}|date_${style}|${iso(w)}|${new Intl.DateTimeFormat(t, { ...UTC, dateStyle: style }).format(w)}`)
      vectors.push(`${t}|datetime_${style}|${iso(w)}|${new Intl.DateTimeFormat(t, { ...UTC, dateStyle: style, timeStyle: 'short' }).format(w)}`)
    }
    vectors.push(`${t}|time_short|${iso(w)}|${new Intl.DateTimeFormat(t, { ...UTC, timeStyle: 'short' }).format(w)}`)
    vectors.push(`${t}|time_medium|${iso(w)}|${new Intl.DateTimeFormat(t, { ...UTC, timeStyle: 'medium' }).format(w)}`)
  }
}
writeFileSync(join(root, 'tests/vectors/formats.txt'), vectors.join('\n') + '\n')
console.log(`${data.length} locales, ${vectors.length - 1} vectors`)
