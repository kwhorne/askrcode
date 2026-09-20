import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

// Bygget legges i ../public/build, som Askr serverer statisk.
// manifest: true gir ../public/build/.vite/manifest.json, som Pascal-siden
// leser for å finne filnavnene med hash i.
export default defineConfig({
  plugins: [svelte()],
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
