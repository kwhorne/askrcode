import { clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

/**
 * Merges class names so that whoever uses the component wins.
 *
 * This is not decoration. Tailwind classes all have the same specificity,
 * so when two of them control the same thing — `w-auto` from the
 * component and `w-full` from the app — the order in the stylesheet
 * decides, not the order in the class attribute. Without tailwind-merge
 * an app cannot override anything at all, and it looks like an accident
 * when you run into it.
 *
 * @param {...any} inputs
 * @returns {string}
 */
export function cn(...inputs) {
  return twMerge(clsx(inputs))
}
