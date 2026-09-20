// Lauf — UI-komponenter for Askr.
//
// Bolk 1: det som skal til for at en CRUD-app kan skrives. Se LAUF.md for
// rekkefølgen, og frontend/lauf/README.md for hvordan de brukes.
//
// <Form> ligger i @askrcode/lauf/inertia, ikke her — den er den eneste
// komponenten som kjenner Inertia, og en app uten Inertia skal ikke måtte
// installere den for å få en knapp.

import ButtonBase from './Button.svelte'
import ButtonGroup from './ButtonGroup.svelte'
import TableBase from './Table.svelte'
import TableHead from './TableHead.svelte'
import TableBody from './TableBody.svelte'
import TableRow from './TableRow.svelte'
import TableHeader from './TableHeader.svelte'
import TableCell from './TableCell.svelte'

export { cn } from './utils.js'
export { FORM, FIELD } from './context.js'

export { default as Icon } from './Icon.svelte'
export { default as Spinner } from './Spinner.svelte'

export { default as Heading } from './Heading.svelte'
export { default as Text } from './Text.svelte'
export { default as Badge } from './Badge.svelte'
export { default as Card } from './Card.svelte'
export { default as Separator } from './Separator.svelte'

export { default as Field } from './Field.svelte'
export { default as Input } from './Input.svelte'
export { default as Textarea } from './Textarea.svelte'
export { default as Select } from './Select.svelte'
export { default as Checkbox } from './Checkbox.svelte'
export { default as Radio } from './Radio.svelte'
export { default as Switch } from './Switch.svelte'
export { default as Pagination } from './Pagination.svelte'

// Sammensatt eksport. Flux skriver <flux:button.group>; Svelte har ikke
// punktnotasjon på komponenter, men en komponent er en funksjon, og en
// funksjon kan bære felter. <Button.Group> leses som en member-uttrykk og
// virker. Delene eksporteres også hver for seg, for den som heller vil det.
export const Button = Object.assign(ButtonBase, { Group: ButtonGroup })
export const Table = Object.assign(TableBase, {
  Head: TableHead,
  Body: TableBody,
  Row: TableRow,
  Header: TableHeader,
  Cell: TableCell,
})

export { ButtonGroup, TableHead, TableBody, TableRow, TableHeader, TableCell }
