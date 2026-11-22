import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// `npm run dev` proxies the API to a clank-web on :8080 (for example the
// dev VM's, forwarded to the WSL side).
export default defineConfig({
  plugins: [svelte()],
  // The box refuses a POST whose Origin isn't its own host (sameOrigin in
  // api.go), so the proxy presents the page as coming from the box.
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
        configure: (proxy) =>
          proxy.on('proxyReq', (req) => {
            if (req.getHeader('origin')) req.setHeader('origin', 'http://localhost:8080');
          }),
      },
    },
  },
});
