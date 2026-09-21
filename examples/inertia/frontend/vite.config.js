import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'

// The build goes in ../public/build, which Askr serves statically.
// manifest: true gives ../public/build/.vite/manifest.json, which the Pascal
// side reads to find the file names with the hash in them.
export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  // Lauf sits as a file: dependency, that is, a symlink out of this tree,
  // and has its own copies of svelte and @inertiajs/svelte for testing.
  // Without dedupe Vite resolves them separately, and then createInertiaApp
  // initialises the app's router while <Form> imports Lauf's — which is
  // never set up. The error is "Cannot read properties of undefined (reading
  // 'visit')", a long way from the cause. An app that installs Lauf from npm
  // does not hit it, because npm then hoists one copy.
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
