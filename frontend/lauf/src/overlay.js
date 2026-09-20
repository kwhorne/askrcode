// Felles klasser for alt som svever over siden: meny, popover, tooltip,
// modal. Ett sted, slik at de ser ut som samme familie og ikke som fire
// komponenter skrevet på fire dager.
//
// `data-state` settes av Bits UI (open/closed), og animasjonen henger på
// den i stedet for på en egen tilstand vi ville måttet holde selv.

export const surface =
  'z-50 rounded-surface border border-line bg-raised shadow-lg ' +
  'data-[state=open]:animate-in data-[state=closed]:animate-out ' +
  'motion-reduce:transition-none'

export const menuItem =
  'flex w-full cursor-default select-none items-center gap-2 rounded-sm ' +
  'px-2 py-1.5 text-sm text-fg outline-none ' +
  'data-[highlighted]:bg-line/60 data-[disabled]:opacity-50 ' +
  'data-[disabled]:pointer-events-none'
