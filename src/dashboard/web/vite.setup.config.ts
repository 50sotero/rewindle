// Rewindle Setup's wizard (setup.html, src/setup/). It shares the dashboard's tokens, fonts and components but is built on
// its own, into src/dashboard/build-output/setup-web, which installer/setup/build.ps1 embeds in the setup program. The
// dashboard's build (vite.config.ts) has index.html as its only input, so nothing of the wizard reaches dist/web.
import { defineConfig, type Plugin } from 'vite';
import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath, URL } from 'node:url';

// `npm run dev:setup` opens the wizard at the server's root.
const setupAtRoot = (): Plugin => ({
  name: 'rewindle-setup-root',
  configureServer(server) {
    server.middlewares.use((request, _response, next) => {
      if (request.url === '/' || request.url?.startsWith('/?')) request.url = '/setup.html' + request.url.slice(1);
      next();
    });
  },
});

export default defineConfig({
  plugins: [tailwindcss(), setupAtRoot()],
  resolve: { alias: { '@': fileURLToPath(new URL('.', import.meta.url)) } },
  base: './',
  build: {
    outDir: '../build-output/setup-web', emptyOutDir: true, target: 'es2022',
    rollupOptions: {
      input: { setup: fileURLToPath(new URL('./setup.html', import.meta.url)) },
      onwarn(warning, warn) {
        if (warning.code === 'MODULE_LEVEL_DIRECTIVE' && warning.message.includes('use client')) return;
        if (warning.code === 'SOURCEMAP_ERROR' && warning.message.includes("Can't resolve original location")) return;
        warn(warning);
      },
      output: { manualChunks: { motion: ['motion/react'] } },
    },
  },
  server: { strictPort: true, port: 5179, host: '127.0.0.1' },
});
