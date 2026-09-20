<script>
  import { Link } from '@inertiajs/svelte'
  let { rammeverk = 'Askr', versjon = '', arena = 0, reservert = 0, requests = 0 } = $props()

  const bytes = (n) =>
    n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} kB`
</script>

<main>
  <nav>
    <Link href="/">Forside</Link>
    <Link href="/customers">Customers</Link>
  </nav>

  <h1>{rammeverk}</h1>
  <p class="lead">
    Én binærfil serverer denne siden. Ingen php-fpm, ingen køarbeider,
    ingen prosesstyring ved siden av.
  </p>

  <table>
    <tbody>
      <tr><td>Arena brukt av denne requesten</td><td class="num">{bytes(arena)}</td></tr>
      <tr><td>Arena reservert av workeren</td><td class="num">{bytes(reservert)}</td></tr>
      <tr><td>Requests servert</td><td class="num">{requests}</td></tr>
      <tr><td>Inertia-versjon</td><td class="num"><span class="pill">{versjon}</span></td></tr>
    </tbody>
  </table>

  <footer>
    Klikk på Customers. Det er en Inertia-navigering: ingen full sidelasting,
    bare en JSON-payload fra Askr og en ny Svelte-komponent.
  </footer>
</main>

