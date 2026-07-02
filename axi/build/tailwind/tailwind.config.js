/**
 * Tailwind CSS build config for LifeOS/Axi.
 *
 * WHY THIS EXISTS
 * ---------------
 * The app previously loaded the Tailwind Play CDN (tailwind.js, ~451 KB) which
 * runs the JIT compiler in the browser. That logs a production warning and
 * scans the DOM at runtime. This config compiles a small, purged, offline
 * stylesheet from the actual template/JS classes instead.
 *
 * The Play CDN build used here corresponds to Tailwind v3.4.16 (see the version
 * string embedded in the old vendor/tailwind.js). The app defined NO custom
 * `tailwind.config` object anywhere — it used stock Tailwind defaults plus
 * arbitrary-value utilities (e.g. bg-[var(--teal)]). All brand colors live in
 * CSS custom properties inside <style> blocks, which are independent of
 * Tailwind. So this config keeps the default theme and only sets `content`.
 *
 * HOW TO REBUILD
 * --------------
 *   cd axi
 *   npx -y tailwindcss@3.4.16 \
 *     -c build/tailwind/tailwind.config.js \
 *     -i build/tailwind/input.css \
 *     -o src/axi/static/vendor/tailwind.css \
 *     --minify
 *
 * After rebuilding, bump CACHE_VERSION in src/axi/static/sw.js so the service
 * worker re-precaches the new stylesheet.
 */
module.exports = {
  content: [
    // Jinja templates are the primary source of utility classes, including the
    // string literals inside Alpine `:class="..."` expressions.
    "./src/axi/templates/**/*.html",
    // App JS may reference utility classes; scanned defensively (vendor/* is
    // excluded — those are third-party bundles, not our class sources).
    "./src/axi/static/*.js",
  ],
  // The app relies on stock Tailwind defaults; no custom theme was configured
  // via the CDN, so nothing to extend here.
  theme: {
    extend: {},
  },
  // Runtime-constructed / dynamically-toggled classes that the static content
  // scanner could miss. Everything here also appears as a literal in a
  // `:class` expression today, but we safelist them explicitly so a future
  // refactor that moves the toggle into JS cannot silently drop the rule.
  safelist: [
    "flex", "justify-end", "justify-start", "text-left", "text-right",
    "rotate-180", "translate-x-5", "ring-1", "mt-1", "w-3", "h-3",
    { pattern: /^ring-(red|pink|teal|amber|green|blue|purple)-(400|500)$/ },
    { pattern: /^ring-(red|pink|teal|amber|green|blue|purple)-500\/(20|30|40|50)$/ },
  ],
};
