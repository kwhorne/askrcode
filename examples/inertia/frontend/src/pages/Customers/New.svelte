<script>
  import { Field, Input, Button, Heading, Text } from '@askrcode/lauf'
  import { Form } from '@askrcode/lauf/inertia'
  import Layout from '../../Layout.svelte'

  let { errors = {}, sendt = null } = $props()
</script>

<Layout>
  <Heading level={1}>New customer</Heading>
  <Text muted class="mb-6">Validation runs in Pascal, on the model.</Text>

  <Form action="/customers" data={sendt ?? {}} {errors} class="max-w-sm">
    <Field name="name" label="Name"><Input /></Field>
    <Field name="email" label="Email"><Input type="email" /></Field>
    <Field name="balance" label="Balance"><Input type="number" step="0.01" /></Field>
    <Button type="submit" variant="primary" class="self-start">Create</Button>
  </Form>
</Layout>
