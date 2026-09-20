import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

export default defineConfig({
  plugins: [svelte()],
  test: {
    environment: 'jsdom',
    include: ['tests/**/*.test.js'],
    setupFiles: ['tests/setup.js'],
    // Uten browser-betingelsen løser Svelte 5 til server-varianten, og
    // komponentene monterer ikke i jsdom.
    server: { deps: { inline: ['@testing-library/svelte'] } },
  },
  resolve: {
    // `browser` må med for at Svelte 5 skal løse til klientvarianten, men
    // lista **erstatter** standardbetingelsene — uten `import`, `module` og
    // `default` finner Vite ikke inngangen til vanlige pakker i det hele
    // tatt, og feilen sier «No known conditions for "." specifier».
    conditions: ['svelte', 'browser', 'import', 'module', 'default'],
  },
})
