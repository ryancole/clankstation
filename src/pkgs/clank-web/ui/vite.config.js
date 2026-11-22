import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// `npm run dev` proxies the API to a clank-web on :8080 (for example the
// dev VM's, forwarded to the WSL side).
export default defineConfig({
  plugins: [svelte()],
  server: { proxy: { '/api': 'http://localhost:8080' } },
});
