<script>
  import { Field, Button, Checkbox } from '../../src/index.js'
  import { Form } from '../../src/inertia/index.js'
  let { errors, data = { title: 'x', tag_ids: ['2'] } } = $props()
  const tags = [
    { id: 1, name: 'Red' },
    { id: 2, name: 'Green' },
    { id: 3, name: 'Blue' },
  ]
</script>

<Form action="/posts" method="post" {data} {errors}>
  <Field name="tag_ids" label="Tags" as="fieldset">
    {#each tags as t (t.id)}
      <Checkbox name="tag_ids" value={String(t.id)} label={t.name} />
    {/each}
  </Field>
  <Button type="submit" variant="primary">Save</Button>
</Form>
