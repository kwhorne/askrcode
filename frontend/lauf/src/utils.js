import { clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

/**
 * Slår sammen klassenavn slik at den som bruker komponenten vinner.
 *
 * Dette er ikke pynt. Tailwind-klasser har lik spesifisitet, så når to av
 * dem styrer det samme — `w-auto` fra komponenten og `w-full` fra appen —
 * er det rekkefølgen i stilarket som avgjør, ikke rekkefølgen i
 * class-attributtet. Uten tailwind-merge kan en app altså ikke overstyre
 * noe som helst, og det ser ut som en tilfeldighet når man treffer det.
 *
 * @param {...any} inputs
 * @returns {string}
 */
export function cn(...inputs) {
  return twMerge(clsx(inputs))
}
