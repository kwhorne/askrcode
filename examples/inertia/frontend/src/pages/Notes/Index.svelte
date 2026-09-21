<!-- This page uses Inertia's useForm directly, and not <Form>.

     That is deliberate: Lauf must not require its own form layer to be
     useful. <Field> then takes `error` as a prop and the control a
     `bind:value`, and everything else — the label, aria-describedby,
     aria-invalid — works as before. Customers/New shows the other way.

     The page is served by the desktop demo (examples/desktop), not by the
     Inertia demo, and so does not use the shared Layout: the routes there
     are different. -->
<script>
  import { router, useForm } from '@inertiajs/svelte'
  import { Heading, Text, Badge, Button, Field, Input, Table } from '@askrcode/lauf'
  import { Star, Trash } from '@askrcode/lauf/icons/micro'

  let { notes = [], total = 0, errors = {}, skall = '' } = $props()

  const form = useForm({ tittel: '', tekst: '' })

  function submit(e) {
    e.preventDefault()
    $form.post('/notes', { onSuccess: () => $form.reset() })
  }
</script>

<main class="mx-auto max-w-3xl px-4 pt-10 pb-16">
  <Heading level={1}>Notes</Heading>
  <Text muted class="mb-6">
    {total} notes · stored in SQLite · served by <Badge>{skall || 'unknown shell'}</Badge>
  </Text>

  <form onsubmit={submit} class="mb-8 flex flex-wrap items-start gap-2">
    <Field name="tittel" error={errors.tittel} class="flex-1 min-w-40">
      <Input placeholder="Title" bind:value={$form.tittel} />
    </Field>
    <Field name="tekst" class="flex-1 min-w-40">
      <Input placeholder="Text" bind:value={$form.tekst} />
    </Field>
    <Button type="submit" variant="primary" loading={$form.processing}>Add</Button>
  </form>

  <Table caption="Notes">
    <Table.Body>
      {#each notes as n (n.id)}
        <Table.Row>
          <Table.Cell>
            <span class:text-accent={n.viktig} class="font-medium">{n.tittel}</span>
            {#if n.tekst}<div class="text-xs text-muted mt-0.5">{n.tekst}</div>{/if}
          </Table.Cell>
          <Table.Cell align="right">
            <Button.Group>
              <Button size="sm" icon={Star} label={n.viktig ? 'Unstar' : 'Star'}
                      onclick={() => router.post(`/notes/${n.id}/toggle`)} />
              <Button size="sm" icon={Trash} label="Delete"
                      onclick={() => router.post(`/notes/${n.id}/delete`)} />
            </Button.Group>
          </Table.Cell>
        </Table.Row>
      {/each}
    </Table.Body>
  </Table>
</main>
