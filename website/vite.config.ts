import { defineConfig, loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), 'VITE_');
  const base = env.VITE_BASE_PATH ?? (mode === 'production' ? '/Hisingen/' : '/');
  const siteUrl = (env.VITE_SITE_URL ?? 'https://nicolaskheirallah.github.io/Hisingen/').replace(/\/$/, '');

  return {
    base,
    plugins: [{
      name: 'replace-site-url',
      transformIndexHtml: (html: string) => html.replaceAll('__SITE_URL__', siteUrl),
    }],
    build: {
      outDir: 'dist',
      emptyOutDir: true,
    },
  };
});
