<script>
  import {
    Heading, Text, Field, Button, Card, Separator,
    Progress, Slider, OtpInput, Autocomplete, Command, DatePicker, FileUpload,
    Editor, Tabs,
  } from '../src/index.js'
  import { User, Inbox, ArrowRight } from '../src/icons/micro/index.js'
  import Grid from './Grid.svelte'

  const alle = [
    { value: '1', label: 'Ada Lovelace' },
    { value: '2', label: 'Grace Hopper' },
    { value: '3', label: 'Katherine Johnson' },
  ]

  let søk = $state('')
  let kunde = $state('')
  let dato = $state('2026-09-20')
  let volum = $state(40)
  let kode = $state('')
  let filer = $state([])
  // The editor is here because the undo stack cannot be measured in
  // jsdom: document.execCommand does not exist there, so the test suite
  // runs through the fallback. This is a real browser.
  // Tabs are here for the contrast check across all three variants, and
  // because findable cannot be measured in jsdom: there is no
  // find-in-page there.
  let tab = $state('profile')
  const tabItems = [
    { value: 'profile', label: 'Profile', icon: User },
    { value: 'orders', label: 'Orders', icon: Inbox, badge: 12 },
    { value: 'more', label: 'More', iconTrailing: ArrowRight },
    { value: 'billing', label: 'Billing', disabled: true },
  ]

  let notes = $state('# Release notes\n\nAskr **0.8.1** adds a mail provider.\n\n- Resend over HTTP\n- `MailFromConfig`\n')

  const treff = $derived(
    alle.filter((a) => a.label.toLowerCase().includes(søk.toLowerCase()))
  )
</script>

<main class="mx-auto flex max-w-xl flex-col gap-6 p-6">
  <Heading level={1}>Lauf playground</Heading>
  <Text muted>Block 3, in a real browser.</Text>

  <Card class="flex flex-col gap-4">
    <Field name="customer" label="Customer" description="Type to filter.">
      <Autocomplete bind:value={kunde} items={treff} onsearch={(v) => (søk = v)} />
    </Field>

    <Field name="due" label="Due date">
      <DatePicker bind:value={dato} />
    </Field>

    <Field name="volume" label="Volume">
      <Slider bind:value={volum} min={0} max={100} step={5} />
    </Field>

    <Field name="code" label="Verification code">
      <OtpInput bind:value={kode} length={6} />
    </Field>

    <Field name="attachment" label="Attachment">
      <FileUpload bind:files={filer} multiple maxSize={1024 * 1024} />
    </Field>

    <Field name="notes" label="Release notes" description="Markdown.">
      <Editor bind:value={notes} rows={8} preview />
    </Field>

    <Progress value={volum} label="Upload" showValue />
  </Card>

  <Separator label="Tabs" />

  <Card class="flex flex-col gap-6">
    <Tabs bind:value={tab} tabs={tabItems}>
      <Tabs.Panel value="profile" findable>Profile panel</Tabs.Panel>
      <Tabs.Panel value="orders" findable>A needle in the orders panel</Tabs.Panel>
      <Tabs.Panel value="more" findable>More</Tabs.Panel>
      <Tabs.Panel value="billing" findable>Billing</Tabs.Panel>
    </Tabs>

    <Tabs value="orders" tabs={tabItems} variant="segmented" size="sm">
      <Tabs.Panel value="orders">Segmented, small</Tabs.Panel>
    </Tabs>

    <Tabs value="profile" tabs={tabItems} variant="pills">
      <Tabs.Panel value="profile">Pills</Tabs.Panel>
    </Tabs>
  </Card>

  <Separator label="Command" />

  <Card class="p-0">
    <Command label="Commands" placeholder="Search commands…">
      <Command.Group label="Customers">
        <Command.Item value="new" label="New customer" />
        <Command.Item value="all" label="All customers" />
      </Command.Group>
    </Command>
  </Card>

  <Separator />
  <Grid />

  <p class="text-xs text-muted" id="lauf-state">
    customer={kunde} due={dato} volume={volum} code={kode} files={filer.length}
    notes={notes.length}
  </p>
</main>
