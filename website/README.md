# Hisingen website

The product website is a static Vite + TypeScript site. It is intentionally separated from the Swift application and has no runtime server, API route, database, analytics script or secret.

## Local development

```bash
cd website
npm install
npm run dev
```

Open the URL printed by Vite. Development uses `/` as its base path for convenient local navigation.

## Production build

```bash
cd website
npm ci
npm run typecheck
npm run build
npm run preview
```

Production builds use `/Hisingen/` as the Vite base path. The output in `website/dist` is the complete static site and can be served by any static host.

The site copies selected, source-controlled screenshots into `website/public/assets/product/` with semantic names based on what each screen actually shows. The numeric source filenames and older labels are not treated as authoritative. Source screenshots in the repository are not modified. The page deliberately uses a small set of readable product screens rather than loading the complete screenshot archive.

## Design system

`DESIGN_SYSTEM.md` documents the web-only visual language, layout tokens, component rules, accessibility requirements, responsive behavior and anti-patterns. It does not describe the native macOS application UI.

## GitHub Pages deployment

`.github/workflows/pages.yml` deploys independently from the macOS workflows. It runs on pushes to `main` that touch `website/**` or the Pages workflow, and can also be started with `workflow_dispatch`.

In the repository settings, set Pages' source to **GitHub Actions**. The workflow installs the locked npm dependencies, typechecks, builds, uploads `website/dist`, and deploys the artifact with the minimum Pages permissions.

## Base path and custom domains

`website/vite.config.ts` sets the production base to `/Hisingen/`. Asset URLs in the HTML use `%BASE_URL%`, and imported CSS/JS assets are rewritten by Vite, so the generated site works at `https://nicolaskheirallah.github.io/Hisingen/` rather than assuming the domain root.

The deployed `oauth-callback.html` is part of the static output because Volvo's OAuth flow requires an HTTPS redirect before returning to the `hisingen://` URL scheme. Keep `website/public/oauth-callback.html` as the canonical deployed copy; `docs/oauth-callback.html` is the source documentation copy.

To move to a custom domain:

1. Build with `VITE_BASE_PATH=/` and `VITE_SITE_URL=https://example.com`, or add those values to a local `.env.production` file.
2. Update the canonical, Open Graph, Twitter, robots and sitemap URLs in `public/robots.txt` / `public/sitemap.xml`.
3. Add the domain to the repository Pages settings and add a `public/CNAME` file containing the domain.

No application code or hosting architecture needs to change.
