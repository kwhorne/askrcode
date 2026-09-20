<!-- Denne siden bruker Inertias useForm direkte, og ikke <Form>.

     Det er med vilje: Lauf skal ikke kreve sitt eget skjemalag for å være
     til nytte. <Field> tar da `error` som prop og kontrollen en
     `bind:value`, og alt det andre — etiketten, aria-describedby,
     aria-invalid — virker som før. Customers/New viser den andre veien.

     Siden serveres av desktop-demoen (examples/desktop), ikke av
     Inertia-demoen, og bruker derfor ikke den delte Layout-en: rutene der
     er andre. -->
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
