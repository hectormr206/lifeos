# Tailwind build (compiled, purged CSS)

The UI's Tailwind stylesheet is **pre-compiled and purged** at build time into
`../../src/axi/static/vendor/tailwind.css` (~21 KB). This replaces the old
Tailwind **Play CDN** bundle (`vendor/tailwind.js`, ~451 KB) which ran the JIT
compiler in the browser, logged a production warning, and scanned the DOM at
runtime.

## Version

Tailwind **v3.4.16** — matched to the major/minor of the Play CDN build that was
previously vendored (its embedded version string was `3.4.16`). The app defined
**no** custom `tailwind.config` object anywhere, so this build uses the stock
default theme. All brand colors (`--teal`, `--pink`, `--amber`, …) are CSS
custom properties declared in `<style>` blocks in the templates and are
independent of Tailwind.

## Files

- `tailwind.config.js` — `content` globs (templates + app JS) and a small
  safelist for dynamically-toggled classes.
- `input.css` — `@tailwind base/components/utilities` entry point. `base`
  (Preflight) is included because the Play CDN shipped it too.

## Rebuild

```sh
cd axi
npx -y tailwindcss@3.4.16 \
  -c build/tailwind/tailwind.config.js \
  -i build/tailwind/input.css \
  -o src/axi/static/vendor/tailwind.css \
  --minify
```

After rebuilding, **bump `CACHE_VERSION`** in `src/axi/static/sw.js` (e.g.
`axi-shell-v23` → `axi-shell-v24`) so the service worker re-precaches the new
stylesheet for offline use.

## Adding new classes

Tailwind only emits rules for classes it can see in the `content` files. If you
add a utility class that is built dynamically in JS (string concatenation) — not
as a literal in a template or `:class` expression — add it to the `safelist` in
`tailwind.config.js`, then rebuild. When in doubt, prefer safelisting: a
slightly larger CSS is far cheaper than a silently broken layout.
