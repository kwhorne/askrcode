<script>
  import { Link } from '@inertiajs/svelte'
  import { Heading, Text, Table, Badge, Button, Dropdown, Modal, Tooltip } from '@askrcode/lauf'
  import { EllipsisHorizontal, PencilSquare, Trash, InformationCircle } from '@askrcode/lauf/icons/micro'
  import Layout from '../../Layout.svelte'

  let { customers = [], total = 0, generert = '' } = $props()

  let toDelete = $state(null)

  const money = (v) =>
    new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(v)
</script>

<Layout>
  <div class="mb-6 flex items-end justify-between gap-4">
    <div>
      <Heading level={1}>Customers</Heading>
      <Text muted>
        {total} rows, served by Askr and rendered by Svelte {generert}
        <Tooltip text="The number comes from Urd, the page from Svelte.">
          {#snippet trigger(props)}
            <span {...props} class="inline-flex align-middle text-muted"
              ><InformationCircle class="size-4" /></span>
          {/snippet}
        </Tooltip>
      </Text>
    </div>
    <Button href="/customers/new" variant="primary">New customer</Button>
  </div>

  <Table caption="Customers">
    <Table.Head>
      <Table.Row>
        <Table.Header>Name</Table.Header>
        <Table.Header>Email</Table.Header>
        <Table.Header align="right">Balance</Table.Header>
        <Table.Header align="right">Orders</Table.Header>
        <Table.Header>Status</Table.Header>
        <Table.Header align="right"><span class="sr-only">Actions</span></Table.Header>
      </Table.Row>
    </Table.Head>
    <Table.Body>
      {#each customers as c (c.id)}
        <Table.Row>
          <Table.Cell>
            <Link href={`/customers/${c.id}`} class="text-accent hover:underline">{c.name}</Link>
          </Table.Cell>
          <Table.Cell>{c.email ?? '—'}</Table.Cell>
          <Table.Cell align="right">{money(c.balance)}</Table.Cell>
          <Table.Cell align="right">{c.orders ? c.orders.length : '—'}</Table.Cell>
          <Table.Cell>
            <Badge color={c.active ? 'accent' : 'neutral'}>
              {c.active ? 'active' : 'inactive'}
            </Badge>
          </Table.Cell>
          <Table.Cell align="right">
            <Dropdown>
              {#snippet trigger(props)}
                <Button {...props} size="sm" icon={EllipsisHorizontal} label="Actions for {c.name}" />
              {/snippet}
              <Dropdown.Group label="Customer">
                <Dropdown.Item icon={PencilSquare} href={`/customers/${c.id}`}>Open</Dropdown.Item>
              </Dropdown.Group>
              <Dropdown.Separator />
              <Dropdown.Item icon={Trash} variant="danger" onclick={() => (toDelete = c)}>
                Delete
              </Dropdown.Item>
            </Dropdown>
          </Table.Cell>
        </Table.Row>
      {/each}
    </Table.Body>
  </Table>

  <!-- Deleting is not built in the demo; the modal is here to show the
       focus trap, Escape, and that the button which opened it gets focus
       back. -->
  <Modal
    open={toDelete !== null}
    onOpenChange={(v) => { if (!v) toDelete = null }}
    title="Delete customer"
    description="This cannot be undone."
    size="sm"
  >
    <p>{toDelete?.name} will be removed.</p>
    {#snippet footer()}
      <Button onclick={() => (toDelete = null)}>Cancel</Button>
      <Button variant="danger">Delete</Button>
    {/snippet}
  </Modal>
</Layout>
