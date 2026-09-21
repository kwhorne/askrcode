// Shared classes for everything that floats above the page: menu,
// popover, tooltip, modal. One place, so they look like one family rather
// than four components written on four different days.
//
// `data-state` is set by Bits UI (open/closed), and the animation hangs
// off that rather than off a separate piece of state we would have to
// keep ourselves.

export const surface =
  'z-50 rounded-surface border border-line bg-raised shadow-lg ' +
  'data-[state=open]:animate-in data-[state=closed]:animate-out ' +
  'motion-reduce:transition-none'

export const menuItem =
  'flex w-full cursor-default select-none items-center gap-2 rounded-sm ' +
  'px-2 py-1.5 text-sm text-fg outline-none ' +
  'data-[highlighted]:bg-line/60 data-[disabled]:opacity-50 ' +
  'data-[disabled]:pointer-events-none'
