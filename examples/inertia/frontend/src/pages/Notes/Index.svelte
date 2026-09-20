<script>
  import { router, useForm } from '@inertiajs/svelte'

  let { notes = [], total = 0, errors = {}, skall = '' } = $props()

  const form = useForm({ tittel: '', tekst: '' })

  function submit(e) {
    e.preventDefault()
    $form.post('/notes', { onSuccess: () => $form.reset() })
  }
</script>

<main>
  <h1>Notes</h1>
  <p class="lead">
    {total} notes · lagret i SQLite · servert av
    <span class="pill">{skall || 'ukjent skall'}</span>
  </p>

  <form onsubmit={submit}>
    <input placeholder="Tittel" bind:value={$form.tittel} />
    {#if errors.tittel}<span class="feil">{errors.tittel}</span>{/if}
    <input placeholder="Tekst" bind:value={$form.tekst} />
    <button type="submit" disabled={$form.processing}>Legg til</button>
  </form>

  <table>
    <tbody>
      {#each notes as n (n.id)}
        <tr>
          <td>
            <strong class:viktig={n.viktig}>{n.tittel}</strong>
            {#if n.tekst}<div class="tekst">{n.tekst}</div>{/if}
          </td>
          <td class="num">
            <button class="liten" onclick={() => router.post(`/notes/${n.id}/toggle`)}>
              {n.viktig ? '★' : '☆'}
            </button>
            <button class="liten" onclick={() => router.post(`/notes/${n.id}/delete`)}>
              slett
            </button>
          </td>
        </tr>
      {/each}
    </tbody>
  </table>
</main>

<style>
  form { display: flex; gap: 0.5rem; align-items: center; margin-bottom: 2rem; flex-wrap: wrap; }
  input {
    padding: 0.45rem 0.6rem; border: 1px solid var(--line); border-radius: 6px;
    background: transparent; color: var(--fg); font: inherit; flex: 1 1 10rem;
  }
  button {
    padding: 0.45rem 0.9rem; border: 1px solid var(--accent); border-radius: 6px;
    background: var(--accent); color: var(--bg); font: inherit; cursor: pointer;
  }
  button.liten { background: transparent; color: var(--muted); border-color: var(--line); padding: 0.2rem 0.5rem; font-size: 0.8rem; }
  .feil { color: #b3261e; font-size: 0.8rem; flex-basis: 100%; }
  .viktig { color: var(--accent); }
  .tekst { color: var(--muted); font-size: 0.85rem; margin-top: 0.15rem; }
</style>
