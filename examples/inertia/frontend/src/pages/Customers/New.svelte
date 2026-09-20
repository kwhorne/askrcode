<script>
  import { Link, useForm } from '@inertiajs/svelte'

  let { errors = {}, sendt = null } = $props()

  const form = useForm({
    name: sendt?.name ?? '',
    email: sendt?.email ?? '',
    balance: sendt?.balance ?? 0,
  })

  function submit(e) {
    e.preventDefault()
    $form.post('/customers')
  }
</script>

<main>
  <nav>
    <Link href="/">Forside</Link>
    <Link href="/customers">Customers</Link>
  </nav>

  <h1>Ny customer</h1>
  <p class="lead">Valideringen kjører i Pascal, på modellen.</p>

  <form onsubmit={submit}>
    <div class="felt">
      <label for="name">Name</label>
      <input id="name" bind:value={$form.name} />
      {#if errors.name}<span class="feil">{errors.name}</span>{/if}
    </div>

    <div class="felt">
      <label for="email">E-post</label>
      <input id="email" bind:value={$form.email} />
      {#if errors.email}<span class="feil">{errors.email}</span>{/if}
    </div>

    <div class="felt">
      <label for="balance">Balance</label>
      <input id="balance" type="number" step="0.01" bind:value={$form.balance} />
      {#if errors.balance}<span class="feil">{errors.balance}</span>{/if}
    </div>

    <button type="submit" disabled={$form.processing}>Opprett</button>
  </form>
</main>

<style>
  form { max-width: 26rem; }
  .felt { display: flex; flex-direction: column; gap: 0.3rem; margin-bottom: 1.1rem; }
  label { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
  input {
    padding: 0.5rem 0.6rem; border: 1px solid var(--line); border-radius: 6px;
    background: transparent; color: var(--fg); font: inherit;
  }
  input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  .feil { color: #b3261e; font-size: 0.8rem; }
  @media (prefers-color-scheme: dark) { .feil { color: #f2b8b5; } }
  button {
    padding: 0.5rem 1.1rem; border: 1px solid var(--accent); border-radius: 6px;
    background: var(--accent); color: var(--bg); font: inherit; cursor: pointer;
  }
  button:disabled { opacity: 0.5; cursor: default; }
</style>
