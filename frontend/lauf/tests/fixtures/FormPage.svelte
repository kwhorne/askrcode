<script>
  import { Field, Input, Button, Checkbox } from '../../src/index.js'
  import { Form } from '../../src/inertia/index.js'
  let { errors, data = { name: '', email: '', active: false } } = $props()
</script>

<Form action="/customers" method="post" {data} {errors}>
  <Field name="name" label="Name"><Input /></Field>
  <Field name="email" label="Email"><Input type="email" /></Field>
  <Field name="active"><Checkbox label="Active" /></Field>
  <Button type="submit" variant="primary">Create</Button>
</Form>
