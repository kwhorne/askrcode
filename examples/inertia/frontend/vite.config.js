import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'

// Bygget legges i ../public/build, som Askr serverer statisk.
// manifest: true gir ../public/build/.vite/manifest.json, som Pascal-siden
// leser for å finne filnavnene med hash i.
export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  // Lauf ligger som file:-avhengighet, altså en symlink ut av dette treet,
  // og har sine egne kopier av svelte og @inertiajs/svelte til testing. Uten
  // dedupe løser Vite dem hver for seg, og da initialiserer
  // createInertiaApp appens router mens <Form> importerer Laufs — som aldri
  // er satt opp. Feilen blir «Cannot read properties of undefined (reading
  // 'visit')», langt fra årsaken. En app som installerer Lauf fra npm
  // treffer det ikke, fordi npm da hoister én kopi.
  resolve: { dedupe: ['svelte', '@inertiajs/svelte', '@inertiajs/core'] },
  base: '/build/',
  build: {
    manifest: true,
    outDir: '../public/build',
    emptyOutDir: true,
    rollupOptions: {
      input: 'src/main.js',
    },
  },
})
