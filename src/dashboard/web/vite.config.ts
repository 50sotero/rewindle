import { defineConfig } from 'vite';
import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [tailwindcss()],
  resolve: { alias: { '@': fileURLToPath(new URL('.', import.meta.url)) } },
  base: './',
  build: {
    outDir: '../dist/web', emptyOutDir: true, target: 'es2022',
    rollupOptions: {
      // This embedded client has no server-component boundary. Keep the copied
      // source directives intact and suppress only their expected bundler notice.
      onwarn(warning, warn) {
        if (warning.code === 'MODULE_LEVEL_DIRECTIVE' && warning.message.includes('use client')) return;
        if (warning.code === 'SOURCEMAP_ERROR' && warning.message.includes("Can't resolve original location")) return;
        warn(warning);
      },
      output: { manualChunks: { charts: ['liveline'], motion: ['motion/react'] } },
    },
  },
  server: { strictPort: true, port: 5178 },
});
