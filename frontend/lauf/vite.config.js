import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

export default defineConfig({
  plugins: [svelte()],
  test: {
    environment: 'jsdom',
    include: ['tests/**/*.test.js'],
    // Uten browser-betingelsen løser Svelte 5 til server-varianten, og
    // komponentene monterer ikke i jsdom.
    server: { deps: { inline: ['@testing-library/svelte'] } },
  },
  resolve: {
    conditions: ['browser'],
  },
})
