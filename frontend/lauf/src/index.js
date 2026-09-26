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
import DropdownBase from './Dropdown.svelte'
import DropdownItem from './DropdownItem.svelte'
import DropdownSeparator from './DropdownSeparator.svelte'
import DropdownGroup from './DropdownGroup.svelte'
import TabsBase from './Tabs.svelte'
import TabPanel from './TabPanel.svelte'
import AccordionBase from './Accordion.svelte'
import AccordionItem from './AccordionItem.svelte'
import SidebarBase from './Sidebar.svelte'
import SidebarItem from './SidebarItem.svelte'
import CommandBase from './Command.svelte'
import CommandGroup from './CommandGroup.svelte'
import CommandItem from './CommandItem.svelte'

export { cn } from './utils.js'
export { provideStrings, strings, defaults as laufDefaults } from './strings.js'
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

// Bolk 2. Alt som åpner og lukker seg ligger på Bits UI, som eier
// fokusfelle, roving tabindex, Escape, klikk utenfor og plassering.
export { default as Modal } from './Modal.svelte'
export { default as Popover } from './Popover.svelte'
export { default as Tooltip } from './Tooltip.svelte'
export { default as Avatar } from './Avatar.svelte'
export { default as Callout } from './Callout.svelte'
export { default as Breadcrumbs } from './Breadcrumbs.svelte'
export { default as Skeleton } from './Skeleton.svelte'
export { default as Navbar } from './Navbar.svelte'
export { default as Toaster } from './Toaster.svelte'
export { toast, toasts, dismiss } from './toast.svelte.js'

// Bolk 3.
export { default as Progress } from './Progress.svelte'
export { default as Slider } from './Slider.svelte'
export { default as OtpInput } from './OtpInput.svelte'
export { default as Autocomplete } from './Autocomplete.svelte'
export { default as DatePicker } from './DatePicker.svelte'
export { default as FileUpload } from './FileUpload.svelte'
export { default as DataGrid } from './DataGrid.svelte'
export { default as Editor } from './Editor.svelte'
// The editor's own markdown renderer. Exported because an app that stores
// markdown also has to display it somewhere other than the editor, and it
// would be odd to require a markdown package for exactly that.
export { renderMarkdown, escapeHtml } from './markdown.js'
export {
  compare, sortRows, filterRows, clampPage, pageSlice,
  windowFor, selectionState, nextSort,
} from './datagrid.svelte.js'

// Sammensatt eksport. Flux skriver <flux:button.group>; Svelte har ikke
// punktnotasjon på komponenter, men en komponent er en funksjon, og en
// funksjon kan bære felter. <Button.Group> leses som en member-uttrykk og
// virker. Delene eksporteres også hver for seg, for den som heller vil det.
//
// Pure-merkingen foran hvert Object.assign er ikke pynt. Object.assign
// muterer første argument, så en bundler kan ikke bevise at kallet er trygt
// å fjerne — og da holdes både komponenten og alt den importerer. Uten
// merkingen dro en enkelt <Button> med seg hele Bits UI: 221 kB i stedet
// for 74. Premisstesten fanget det.
//
// Merkingen skrives ikke ut i klartekst i en linjekommentar: Rollup leser
// den som en ekte annotasjon på feil plass og advarer om at den fjernes.
export const Button = /*#__PURE__*/ Object.assign(ButtonBase, { Group: ButtonGroup })
export const Table = /*#__PURE__*/ Object.assign(TableBase, {
  Head: TableHead,
  Body: TableBody,
  Row: TableRow,
  Header: TableHeader,
  Cell: TableCell,
})

export const Dropdown = /*#__PURE__*/ Object.assign(DropdownBase, {
  Item: DropdownItem,
  Separator: DropdownSeparator,
  Group: DropdownGroup,
})
export const Tabs = /*#__PURE__*/ Object.assign(TabsBase, { Panel: TabPanel })
export const Accordion = /*#__PURE__*/ Object.assign(AccordionBase, { Item: AccordionItem })
export const Sidebar = /*#__PURE__*/ Object.assign(SidebarBase, { Item: SidebarItem })
export const Command = /*#__PURE__*/ Object.assign(CommandBase, {
  Group: CommandGroup,
  Item: CommandItem,
})

export { ButtonGroup, TableHead, TableBody, TableRow, TableHeader, TableCell }
export { DropdownItem, DropdownSeparator, DropdownGroup, TabPanel, AccordionItem, SidebarItem }
export { CommandGroup, CommandItem }
