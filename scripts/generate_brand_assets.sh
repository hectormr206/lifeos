#!/bin/bash
# Script para generar assets visuales de LifeOS en SVG de alta calidad (calidad sistema)
# Genera un tema de iconos freedesktop completo + wallpapers

set -euo pipefail

ICON_DIR="image/files/usr/share/icons/LifeOS/scalable"
WALLPAPER_DIR="image/files/usr/share/backgrounds/lifeos"

mkdir -p "$ICON_DIR"/{apps,places,mimetypes,actions,categories,status}
mkdir -p "$WALLPAPER_DIR"

echo "Generando tema de iconos LifeOS y wallpapers..."

# ============================================================================
# WALLPAPERS
# ============================================================================

# Wallpaper: Minimal (4K)
cat << 'EOF' > "$WALLPAPER_DIR/lifeos-minimal-wallpaper.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3840 2160" width="3840" height="2160">
  <defs>
    <radialGradient id="glow" cx="50%" cy="100%" r="70%" fx="50%" fy="100%">
      <stop offset="0%" stop-color="#00D4AA" stop-opacity="0.15" />
      <stop offset="50%" stop-color="#161830" stop-opacity="0.5" />
      <stop offset="100%" stop-color="#0F0F1B" stop-opacity="1" />
    </radialGradient>
  </defs>
  <rect width="3840" height="2160" fill="#0F0F1B" />
  <rect width="3840" height="2160" fill="url(#glow)" />
</svg>
EOF

# Wallpaper: Axi Xochimilco canonico (4K)
cat << 'EOF' > "$WALLPAPER_DIR/lifeos-axi-night-wallpaper.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3840 2160">
  <defs>
    <linearGradient id="sky" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#070A12" />
      <stop offset="45%" stop-color="#0F0F1B" />
      <stop offset="100%" stop-color="#161830" />
    </linearGradient>
    <radialGradient id="tealGlow" cx="74%" cy="34%" r="34%">
      <stop offset="0%" stop-color="#00D4AA" stop-opacity="0.22" />
      <stop offset="100%" stop-color="#00D4AA" stop-opacity="0" />
    </radialGradient>
    <radialGradient id="pinkGlow" cx="68%" cy="46%" r="18%">
      <stop offset="0%" stop-color="#FF6B9D" stop-opacity="0.16" />
      <stop offset="100%" stop-color="#FF6B9D" stop-opacity="0" />
    </radialGradient>
    <linearGradient id="water" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#00D4AA" stop-opacity="0.02" />
      <stop offset="100%" stop-color="#00D4AA" stop-opacity="0.16" />
    </linearGradient>
    <linearGradient id="bodyFill" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#3EF0C8" />
      <stop offset="65%" stop-color="#00D4AA" />
      <stop offset="100%" stop-color="#009E82" />
    </linearGradient>
    <linearGradient id="gillFill" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#FFC0D7" />
      <stop offset="65%" stop-color="#FF6B9D" />
      <stop offset="100%" stop-color="#E65086" />
    </radialGradient>
  </defs>
  <rect width="3840" height="2160" fill="url(#sky)" />
  <rect width="3840" height="2160" fill="url(#tealGlow)" />
  <rect width="3840" height="2160" fill="url(#pinkGlow)" />
  <ellipse cx="2640" cy="1660" rx="1700" ry="560" fill="url(#water)" />
  <g opacity="0.16" fill="#0C131A">
    <path d="M0 2160 L0 1800 C140 1780 180 1680 250 1500 C320 1710 360 1810 480 2160 Z"/>
    <path d="M540 2160 L540 1770 C620 1740 670 1600 720 1450 C770 1660 820 1810 940 2160 Z"/>
    <path d="M3090 2160 L3090 1760 C3180 1730 3220 1610 3270 1420 C3330 1610 3380 1760 3480 2160 Z"/>
  </g>
  <g>
    <path d="M3270 1310 C3470 1325 3650 1455 3710 1635 C3530 1605 3375 1545 3260 1450 C3180 1385 3175 1318 3270 1310 Z" fill="url(#bodyFill)"/>
    <ellipse cx="2980" cy="1365" rx="455" ry="270" fill="url(#bodyFill)"/>
    <ellipse cx="2580" cy="1180" rx="255" ry="195" fill="url(#bodyFill)"/>
    <g>
      <path d="M2455 1065 C2310 1000 2240 890 2235 760 C2350 790 2455 845 2515 935 Z" fill="url(#gillFill)"/>
      <path d="M2400 1130 C2245 1110 2120 1010 2065 875 C2205 880 2335 940 2430 1035 Z" fill="url(#gillFill)" opacity="0.96"/>
      <path d="M2710 1060 C2845 995 2930 890 2950 760 C2835 790 2735 845 2665 934 Z" fill="url(#gillFill)"/>
      <path d="M2765 1128 C2925 1110 3055 1010 3110 875 C2965 880 2835 938 2738 1035 Z" fill="url(#gillFill)" opacity="0.96"/>
    </g>
  </g>
</svg>
EOF

echo "  Wallpapers generados en $WALLPAPER_DIR"

# ============================================================================
# APPS ICONS
# ============================================================================

# --- firefox: globe with meridians ---
cat << 'EOF' > "$ICON_DIR/apps/firefox.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <circle cx="256" cy="256" r="200" fill="#161830"/>
  <circle cx="256" cy="256" r="160" fill="none" stroke="#00D4AA" stroke-width="16"/>
  <ellipse cx="256" cy="256" rx="80" ry="160" fill="none" stroke="#00D4AA" stroke-width="12"/>
  <line x1="96" y1="256" x2="416" y2="256" stroke="#00D4AA" stroke-width="12"/>
  <line x1="256" y1="96" x2="256" y2="416" stroke="#00D4AA" stroke-width="12"/>
  <path d="M120 180 Q256 160 392 180" fill="none" stroke="#00D4AA" stroke-width="8"/>
  <path d="M120 332 Q256 352 392 332" fill="none" stroke="#00D4AA" stroke-width="8"/>
</svg>
EOF

# --- chromium: circle with segments ---
cat << 'EOF' > "$ICON_DIR/apps/chromium.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <circle cx="256" cy="256" r="200" fill="#161830"/>
  <circle cx="256" cy="256" r="80" fill="#00D4AA"/>
  <circle cx="256" cy="256" r="50" fill="#161830"/>
  <path d="M256 176 L380 390" stroke="#00D4AA" stroke-width="12" fill="none"/>
  <path d="M256 176 L132 390" stroke="#00D4AA" stroke-width="12" fill="none"/>
  <path d="M132 390 L380 390" stroke="#00D4AA" stroke-width="12" fill="none"/>
</svg>
EOF

# --- cosmic-files: file manager with folder shape ---
cat << 'EOF' > "$ICON_DIR/apps/cosmic-files.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="64" y="80" width="384" height="352" rx="32" fill="#161830"/>
  <path d="M64 140 C64 118 82 100 104 100 L200 100 L232 132 L408 132 C430 132 448 150 448 172 L448 400 C448 422 430 440 408 440 L104 440 C82 440 64 422 64 400 Z" fill="#00D4AA"/>
  <rect x="180" y="260" width="152" height="16" rx="8" fill="#161830" opacity="0.3"/>
  <rect x="180" y="300" width="100" height="16" rx="8" fill="#161830" opacity="0.2"/>
</svg>
EOF

# --- cosmic-edit: text editor with pencil ---
cat << 'EOF' > "$ICON_DIR/apps/cosmic-edit.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="80" y="56" width="320" height="400" rx="32" fill="#161830"/>
  <rect x="120" y="120" width="200" height="16" rx="8" fill="#00D4AA" opacity="0.7"/>
  <rect x="120" y="160" width="160" height="16" rx="8" fill="#00D4AA" opacity="0.5"/>
  <rect x="120" y="200" width="240" height="16" rx="8" fill="#00D4AA" opacity="0.7"/>
  <rect x="120" y="240" width="120" height="16" rx="8" fill="#00D4AA" opacity="0.5"/>
  <path d="M380 300 L440 240 L464 264 L404 324 Z" fill="#00D4AA"/>
  <path d="M370 310 L380 300 L404 324 L394 334 L360 340 Z" fill="#FF6B9D"/>
</svg>
EOF

# --- cosmic-term: terminal ---
cat << 'EOF' > "$ICON_DIR/apps/cosmic-term.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="64" width="416" height="384" rx="32" fill="#0F0F1B"/>
  <rect x="48" y="64" width="416" height="64" rx="32" fill="#161830"/>
  <circle cx="96" cy="96" r="12" fill="#FF6B9D"/>
  <circle cx="144" cy="96" r="12" fill="#F0C420"/>
  <circle cx="192" cy="96" r="12" fill="#00D4AA"/>
  <path d="M96 192 L144 240 L96 288" fill="none" stroke="#00D4AA" stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="176" y="272" width="80" height="24" fill="#00D4AA"/>
</svg>
EOF

# --- cosmic-settings: gear ---
cat << 'EOF' > "$ICON_DIR/apps/cosmic-settings.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="100" fill="#161830"/>
  <path d="M280 96 L280 136 C296 140 310 148 322 158 L358 138 L392 196 L356 216 C358 228 358 240 356 252 L392 272 L358 330 L322 310 C310 320 296 328 280 332 L280 372 L232 372 L232 332 C216 328 202 320 190 310 L154 330 L120 272 L156 252 C154 240 154 228 156 216 L120 196 L154 138 L190 158 C202 148 216 140 232 136 L232 96 Z" fill="#00D4AA"/>
  <circle cx="256" cy="234" r="52" fill="#161830"/>
</svg>
EOF

# --- flatpak: package box ---
cat << 'EOF' > "$ICON_DIR/apps/flatpak.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <path d="M256 64 L448 160 L448 352 L256 448 L64 352 L64 160 Z" fill="#161830"/>
  <path d="M256 64 L448 160 L256 256 L64 160 Z" fill="#00D4AA"/>
  <line x1="256" y1="256" x2="256" y2="448" stroke="#00D4AA" stroke-width="8"/>
  <line x1="64" y1="160" x2="256" y2="256" stroke="#161830" stroke-width="4"/>
  <line x1="448" y1="160" x2="256" y2="256" stroke="#161830" stroke-width="4"/>
</svg>
EOF

# --- steam: gamepad ---
cat << 'EOF' > "$ICON_DIR/apps/steam.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="100" fill="#161830"/>
  <rect x="112" y="192" width="288" height="160" rx="48" fill="#00D4AA"/>
  <circle cx="192" cy="260" r="36" fill="#161830"/>
  <circle cx="192" cy="260" r="16" fill="#00D4AA"/>
  <circle cx="336" cy="244" r="16" fill="#161830"/>
  <circle cx="304" cy="276" r="16" fill="#161830"/>
  <circle cx="368" cy="276" r="16" fill="#161830"/>
  <circle cx="336" cy="308" r="16" fill="#161830"/>
  <rect x="156" y="176" width="24" height="40" rx="12" fill="#00D4AA"/>
  <rect x="332" y="176" width="24" height="40" rx="12" fill="#00D4AA"/>
</svg>
EOF

# --- discord: speech bubble with waves ---
cat << 'EOF' > "$ICON_DIR/apps/discord.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="100" fill="#161830"/>
  <path d="M128 144 C128 128 140 116 156 116 L356 116 C372 116 384 128 384 144 L384 336 C384 352 372 364 356 364 L200 364 L144 408 L144 364 L156 364 C140 364 128 352 128 336 Z" fill="#00D4AA"/>
  <circle cx="216" cy="248" r="24" fill="#161830"/>
  <circle cx="296" cy="248" r="24" fill="#161830"/>
</svg>
EOF

# --- telegram: paper plane ---
cat << 'EOF' > "$ICON_DIR/apps/telegram.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="100" fill="#161830"/>
  <path d="M128 256 L400 128 L300 400 L248 288 Z" fill="#00D4AA"/>
  <line x1="400" y1="128" x2="248" y2="288" stroke="#161830" stroke-width="8"/>
  <line x1="248" y1="288" x2="248" y2="380" stroke="#FF6B9D" stroke-width="8" stroke-linecap="round"/>
</svg>
EOF

# --- code (VSCode): bracket pairs ---
cat << 'EOF' > "$ICON_DIR/apps/code.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="32" fill="#161830"/>
  <path d="M192 144 L128 256 L192 368" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M320 144 L384 256 L320 368" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="288" y1="128" x2="224" y2="384" stroke="#FF6B9D" stroke-width="20" stroke-linecap="round"/>
</svg>
EOF

# --- spotify: circle with sound waves ---
cat << 'EOF' > "$ICON_DIR/apps/spotify.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <circle cx="256" cy="256" r="208" fill="#161830"/>
  <path d="M152 208 Q256 176 360 208" fill="none" stroke="#00D4AA" stroke-width="24" stroke-linecap="round"/>
  <path d="M168 272 Q256 244 344 272" fill="none" stroke="#00D4AA" stroke-width="20" stroke-linecap="round"/>
  <path d="M184 332 Q256 308 328 332" fill="none" stroke="#00D4AA" stroke-width="16" stroke-linecap="round"/>
</svg>
EOF

# --- thunderbird: envelope ---
cat << 'EOF' > "$ICON_DIR/apps/thunderbird.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="100" fill="#161830"/>
  <rect x="96" y="144" width="320" height="224" rx="24" fill="#00D4AA"/>
  <path d="M96 168 L256 296 L416 168" fill="none" stroke="#161830" stroke-width="16" stroke-linejoin="round"/>
  <path d="M96 344 L200 264" fill="none" stroke="#161830" stroke-width="8"/>
  <path d="M416 344 L312 264" fill="none" stroke="#161830" stroke-width="8"/>
</svg>
EOF

# --- lifeos-dashboard: grid of tiles ---
cat << 'EOF' > "$ICON_DIR/apps/lifeos-dashboard.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="48" fill="#161830"/>
  <rect x="88" y="88" width="152" height="152" rx="24" fill="#00D4AA"/>
  <rect x="272" y="88" width="152" height="72" rx="24" fill="#00D4AA"/>
  <rect x="272" y="184" width="152" height="56" rx="24" fill="#FF6B9D"/>
  <rect x="88" y="272" width="72" height="152" rx="24" fill="#FF6B9D"/>
  <rect x="184" y="272" width="240" height="152" rx="24" fill="#00D4AA"/>
</svg>
EOF

# --- lifeos-axi: mascot logo ---
cat << 'EOF' > "$ICON_DIR/apps/lifeos-axi.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <path d="M 120 180 Q 40 160 60 120 Q 80 180 140 210" fill="none" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>
  <path d="M 100 256 Q 20 256 30 200 Q 60 256 120 256" fill="none" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>
  <path d="M 120 332 Q 40 352 60 392 Q 80 332 140 302" fill="none" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>
  <path d="M 392 180 Q 472 160 452 120 Q 432 180 372 210" fill="none" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>
  <path d="M 412 256 Q 492 256 482 200 Q 452 256 392 256" fill="none" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>
  <path d="M 392 332 Q 472 352 452 392 Q 432 332 372 302" fill="none" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>
  <rect x="106" y="106" width="300" height="260" rx="130" fill="#00D4AA"/>
  <circle cx="196" cy="226" r="24" fill="#0F0F1B"/>
  <circle cx="204" cy="218" r="8" fill="#E8E8E8"/>
  <circle cx="316" cy="226" r="24" fill="#0F0F1B"/>
  <circle cx="324" cy="218" r="8" fill="#E8E8E8"/>
  <path d="M 236 276 Q 256 296 276 276" fill="none" stroke="#0F0F1B" stroke-width="8" stroke-linecap="round"/>
</svg>
EOF

# --- gimp: paintbrush ---
cat << 'EOF' > "$ICON_DIR/apps/gimp.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="48" width="416" height="416" rx="100" fill="#161830"/>
  <path d="M352 128 L384 160 L208 336 L160 352 L176 304 Z" fill="#00D4AA"/>
  <path d="M352 128 L384 160 L368 176 L336 144 Z" fill="#FF6B9D"/>
  <circle cx="168" cy="344" r="20" fill="#00D4AA" opacity="0.5"/>
  <circle cx="136" cy="376" r="16" fill="#FF6B9D" opacity="0.4"/>
</svg>
EOF

# --- libreoffice-calc: spreadsheet grid ---
cat << 'EOF' > "$ICON_DIR/apps/libreoffice-calc.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="64" y="64" width="384" height="384" rx="32" fill="#161830"/>
  <rect x="112" y="112" width="288" height="288" rx="8" fill="none" stroke="#00D4AA" stroke-width="8"/>
  <line x1="208" y1="112" x2="208" y2="400" stroke="#00D4AA" stroke-width="6"/>
  <line x1="304" y1="112" x2="304" y2="400" stroke="#00D4AA" stroke-width="6"/>
  <line x1="112" y1="208" x2="400" y2="208" stroke="#00D4AA" stroke-width="6"/>
  <line x1="112" y1="304" x2="400" y2="304" stroke="#00D4AA" stroke-width="6"/>
  <rect x="216" y="216" width="80" height="80" fill="#00D4AA" opacity="0.3"/>
</svg>
EOF

# --- libreoffice-writer: document with lines ---
cat << 'EOF' > "$ICON_DIR/apps/libreoffice-writer.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="96" y="48" width="320" height="416" rx="32" fill="#161830"/>
  <rect x="144" y="112" width="224" height="20" rx="10" fill="#00D4AA"/>
  <rect x="144" y="160" width="180" height="14" rx="7" fill="#00D4AA" opacity="0.6"/>
  <rect x="144" y="196" width="224" height="14" rx="7" fill="#00D4AA" opacity="0.6"/>
  <rect x="144" y="232" width="200" height="14" rx="7" fill="#00D4AA" opacity="0.6"/>
  <rect x="144" y="268" width="224" height="14" rx="7" fill="#00D4AA" opacity="0.6"/>
  <rect x="144" y="304" width="160" height="14" rx="7" fill="#00D4AA" opacity="0.6"/>
  <rect x="144" y="340" width="224" height="14" rx="7" fill="#00D4AA" opacity="0.6"/>
  <rect x="144" y="376" width="120" height="14" rx="7" fill="#00D4AA" opacity="0.4"/>
</svg>
EOF

# --- system-monitor: pulse line in a screen ---
cat << 'EOF' > "$ICON_DIR/apps/system-monitor.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="48" y="64" width="416" height="320" rx="32" fill="#161830"/>
  <polyline points="96,280 160,280 192,200 224,320 256,160 288,280 320,240 352,280 416,280" fill="none" stroke="#00D4AA" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="192" y="384" width="128" height="16" rx="8" fill="#161830"/>
  <rect x="160" y="416" width="192" height="16" rx="8" fill="#161830"/>
</svg>
EOF

# --- text-editor: simple notepad ---
cat << 'EOF' > "$ICON_DIR/apps/text-editor.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="80" y="48" width="352" height="416" rx="32" fill="#161830"/>
  <rect x="80" y="48" width="352" height="64" rx="32" fill="#00D4AA"/>
  <rect x="128" y="152" width="256" height="12" rx="6" fill="#00D4AA" opacity="0.6"/>
  <rect x="128" y="188" width="200" height="12" rx="6" fill="#00D4AA" opacity="0.5"/>
  <rect x="128" y="224" width="240" height="12" rx="6" fill="#00D4AA" opacity="0.6"/>
  <rect x="128" y="260" width="180" height="12" rx="6" fill="#00D4AA" opacity="0.5"/>
  <rect x="128" y="296" width="256" height="12" rx="6" fill="#00D4AA" opacity="0.6"/>
  <rect x="128" y="332" width="140" height="12" rx="6" fill="#00D4AA" opacity="0.4"/>
</svg>
EOF

echo "  Apps icons: 20 generados"

# ============================================================================
# PLACES ICONS
# ============================================================================

# --- folder: base folder ---
cat << 'EOF' > "$ICON_DIR/places/folder.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <path d="M48 96 C48 69.5 69.5 48 96 48 L208 48 C224 48 238 56 246 69 L272 112 L416 112 C442.5 112 464 133.5 464 160 L464 416 C464 442.5 442.5 464 416 464 L96 464 C69.5 464 48 442.5 48 416 Z" fill="#161830"/>
  <path d="M48 160 C48 142.3 62.3 128 80 128 L432 128 C449.7 128 464 142.3 464 160 L464 416 C464 442.5 442.5 464 416 464 L96 464 C69.5 464 48 442.5 48 416 Z" fill="#00D4AA"/>
  <rect x="220" y="240" width="72" height="16" rx="8" fill="#161830" opacity="0.3"/>
</svg>
EOF

# Helper: folder with emblem
generate_folder_icon() {
  local name="$1"
  local emblem="$2"
  cat << EOF > "$ICON_DIR/places/$name.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <path d="M48 96 C48 69.5 69.5 48 96 48 L208 48 C224 48 238 56 246 69 L272 112 L416 112 C442.5 112 464 133.5 464 160 L464 416 C464 442.5 442.5 464 416 464 L96 464 C69.5 464 48 442.5 48 416 Z" fill="#161830"/>
  <path d="M48 160 C48 142.3 62.3 128 80 128 L432 128 C449.7 128 464 142.3 464 160 L464 416 C464 442.5 442.5 464 416 464 L96 464 C69.5 464 48 442.5 48 416 Z" fill="#00D4AA"/>
  $emblem
</svg>
EOF
}

# --- folder-documents: document page ---
generate_folder_icon "folder-documents" \
  '<rect x="216" y="224" width="80" height="100" rx="8" fill="#161830" opacity="0.4"/><rect x="232" y="248" width="48" height="8" rx="4" fill="#00D4AA" opacity="0.6"/><rect x="232" y="264" width="36" height="8" rx="4" fill="#00D4AA" opacity="0.6"/><rect x="232" y="280" width="48" height="8" rx="4" fill="#00D4AA" opacity="0.6"/>'

# --- folder-download: down arrow ---
generate_folder_icon "folder-download" \
  '<path d="M256 220 L256 320" stroke="#161830" stroke-width="20" stroke-linecap="round" opacity="0.4"/><path d="M216 288 L256 328 L296 288" stroke="#161830" stroke-width="20" stroke-linecap="round" stroke-linejoin="round" fill="none" opacity="0.4"/>'

# --- folder-music: musical note ---
generate_folder_icon "folder-music" \
  '<circle cx="232" cy="320" r="24" fill="#161830" opacity="0.4"/><rect x="252" y="224" width="8" height="96" rx="4" fill="#161830" opacity="0.4"/><path d="M256 224 L296 208 L296 248 L256 264" fill="#161830" opacity="0.4"/>'

# --- folder-pictures: mountain/sun ---
generate_folder_icon "folder-pictures" \
  '<circle cx="228" cy="248" r="20" fill="#161830" opacity="0.3"/><path d="M196 340 L256 268 L296 304 L320 276 L356 340 Z" fill="#161830" opacity="0.3"/>'

# --- folder-videos: play triangle ---
generate_folder_icon "folder-videos" \
  '<path d="M232 236 L232 332 L312 284 Z" fill="#161830" opacity="0.35"/>'

# --- folder-home: house ---
generate_folder_icon "folder-home" \
  '<path d="M256 224 L208 264 L216 264 L216 328 L296 328 L296 264 L304 264 Z" fill="#161830" opacity="0.35"/><rect x="240" y="296" width="32" height="32" rx="4" fill="#00D4AA" opacity="0.4"/>'

# --- user-home: house ---
cat << 'EOF' > "$ICON_DIR/places/user-home.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <path d="M256 80 L64 256 L112 256 L112 432 L400 432 L400 256 L448 256 Z" fill="#00D4AA"/>
  <rect x="208" y="304" width="96" height="128" rx="8" fill="#161830"/>
  <path d="M256 80 L64 256 L112 256 L112 432 L400 432 L400 256 L448 256 Z" fill="none" stroke="#161830" stroke-width="8"/>
</svg>
EOF

# --- user-trash: trash can ---
cat << 'EOF' > "$ICON_DIR/places/user-trash.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect x="144" y="128" width="224" height="320" rx="24" fill="#161830"/>
  <rect x="168" y="160" width="176" height="256" rx="16" fill="#00D4AA" opacity="0.2"/>
  <rect x="128" y="96" width="256" height="40" rx="16" fill="#00D4AA"/>
  <rect x="208" y="64" width="96" height="40" rx="16" fill="#00D4AA"/>
  <line x1="224" y1="200" x2="224" y2="376" stroke="#00D4AA" stroke-width="12" stroke-linecap="round" opacity="0.5"/>
  <line x1="288" y1="200" x2="288" y2="376" stroke="#00D4AA" stroke-width="12" stroke-linecap="round" opacity="0.5"/>
</svg>
EOF

# --- network-workgroup: connected nodes ---
cat << 'EOF' > "$ICON_DIR/places/network-workgroup.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <line x1="256" y1="160" x2="152" y2="336" stroke="#00D4AA" stroke-width="8"/>
  <line x1="256" y1="160" x2="360" y2="336" stroke="#00D4AA" stroke-width="8"/>
  <line x1="152" y1="336" x2="360" y2="336" stroke="#00D4AA" stroke-width="8"/>
  <circle cx="256" cy="152" r="48" fill="#161830" stroke="#00D4AA" stroke-width="8"/>
  <circle cx="152" cy="344" r="48" fill="#161830" stroke="#00D4AA" stroke-width="8"/>
  <circle cx="360" cy="344" r="48" fill="#161830" stroke="#00D4AA" stroke-width="8"/>
  <rect x="232" y="128" width="48" height="48" rx="8" fill="#00D4AA"/>
  <rect x="128" y="320" width="48" height="48" rx="8" fill="#00D4AA"/>
  <rect x="336" y="320" width="48" height="48" rx="8" fill="#00D4AA"/>
</svg>
EOF

# --- folder-templates: overlapping pages ---
generate_folder_icon "folder-templates" \
  '<rect x="224" y="232" width="68" height="88" rx="6" fill="#161830" opacity="0.25"/><rect x="216" y="224" width="68" height="88" rx="6" fill="#161830" opacity="0.4"/><rect x="228" y="248" width="40" height="6" rx="3" fill="#00D4AA" opacity="0.5"/><rect x="228" y="262" width="28" height="6" rx="3" fill="#00D4AA" opacity="0.5"/>'

# --- folder-projects: wrench/cog ---
generate_folder_icon "folder-projects" \
  '<circle cx="256" cy="292" r="40" fill="#161830" opacity="0.35"/><circle cx="256" cy="292" r="20" fill="#00D4AA" opacity="0.4"/><rect x="248" y="232" width="16" height="24" rx="4" fill="#161830" opacity="0.35"/><rect x="248" y="336" width="16" height="24" rx="4" fill="#161830" opacity="0.35"/><rect x="196" y="284" width="24" height="16" rx="4" fill="#161830" opacity="0.35"/><rect x="292" y="284" width="24" height="16" rx="4" fill="#161830" opacity="0.35"/>'

echo "  Places icons: 12 generados"

# ============================================================================
# MIMETYPES ICONS
# ============================================================================

# Helper: document icon with label
generate_mime_icon() {
  local name="$1"
  local label="$2"
  local accent="${3:-#00D4AA}"
  cat << EOF > "$ICON_DIR/mimetypes/$name.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <path d="M112 48 L336 48 L400 112 L400 464 L112 464 Z" fill="#161830"/>
  <path d="M336 48 L336 112 L400 112 Z" fill="$accent" opacity="0.5"/>
  $label
</svg>
EOF
}

# --- text-plain ---
generate_mime_icon "text-plain" \
  '<rect x="160" y="168" width="192" height="12" rx="6" fill="#00D4AA" opacity="0.6"/><rect x="160" y="204" width="160" height="12" rx="6" fill="#00D4AA" opacity="0.5"/><rect x="160" y="240" width="192" height="12" rx="6" fill="#00D4AA" opacity="0.6"/><rect x="160" y="276" width="140" height="12" rx="6" fill="#00D4AA" opacity="0.5"/><rect x="160" y="312" width="192" height="12" rx="6" fill="#00D4AA" opacity="0.6"/><rect x="160" y="348" width="120" height="12" rx="6" fill="#00D4AA" opacity="0.4"/>'

# --- text-x-script ---
generate_mime_icon "text-x-script" \
  '<text x="176" y="240" font-family="monospace" font-size="36" fill="#00D4AA" opacity="0.8">&lt;/&gt;</text><rect x="160" y="280" width="192" height="10" rx="5" fill="#00D4AA" opacity="0.4"/><rect x="160" y="308" width="140" height="10" rx="5" fill="#00D4AA" opacity="0.3"/><rect x="160" y="336" width="170" height="10" rx="5" fill="#FF6B9D" opacity="0.4"/>' "#FF6B9D"

# --- text-html ---
generate_mime_icon "text-html" \
  '<text x="172" y="300" font-family="monospace" font-size="64" font-weight="bold" fill="#00D4AA" opacity="0.7">&lt;&gt;</text>'

# --- image-png ---
generate_mime_icon "image-png" \
  '<rect x="160" y="180" width="192" height="144" rx="12" fill="#00D4AA" opacity="0.2"/><circle cx="208" cy="224" r="20" fill="#00D4AA" opacity="0.5"/><path d="M160 300 L232 244 L280 284 L320 248 L352 300 L352 312 C352 318 346 324 340 324 L172 324 C166 324 160 318 160 312 Z" fill="#00D4AA" opacity="0.5"/>'

# --- image-svg+xml ---
generate_mime_icon "image-svg+xml" \
  '<circle cx="256" cy="260" r="60" fill="none" stroke="#00D4AA" stroke-width="12"/><rect x="220" y="224" width="72" height="72" rx="8" fill="none" stroke="#FF6B9D" stroke-width="8"/>' "#FF6B9D"

# --- audio-x-generic ---
generate_mime_icon "audio-x-generic" \
  '<circle cx="232" cy="340" r="40" fill="#00D4AA" opacity="0.5"/><rect x="268" y="200" width="12" height="140" rx="6" fill="#00D4AA" opacity="0.6"/><path d="M276 200 L328 172 L328 228 L276 256" fill="#00D4AA" opacity="0.5"/>'

# --- video-x-generic ---
generate_mime_icon "video-x-generic" \
  '<rect x="152" y="200" width="208" height="136" rx="16" fill="#00D4AA" opacity="0.3"/><path d="M240 240 L240 312 L300 276 Z" fill="#00D4AA" opacity="0.7"/>'

# --- application-pdf ---
generate_mime_icon "application-pdf" \
  '<text x="168" y="320" font-family="sans-serif" font-size="80" font-weight="bold" fill="#FF6B9D" opacity="0.7">PDF</text>' "#FF6B9D"

# --- application-x-compressed ---
generate_mime_icon "application-x-compressed" \
  '<rect x="228" y="160" width="56" height="28" rx="4" fill="#00D4AA" opacity="0.5"/><rect x="200" y="196" width="56" height="28" rx="4" fill="#00D4AA" opacity="0.5"/><rect x="228" y="232" width="56" height="28" rx="4" fill="#00D4AA" opacity="0.5"/><rect x="200" y="268" width="56" height="28" rx="4" fill="#00D4AA" opacity="0.5"/><rect x="200" y="304" width="112" height="72" rx="8" fill="#00D4AA" opacity="0.4"/>'

# --- application-json ---
generate_mime_icon "application-json" \
  '<text x="164" y="300" font-family="monospace" font-size="56" font-weight="bold" fill="#00D4AA" opacity="0.7">{ }</text>'

# --- application-x-executable ---
generate_mime_icon "application-x-executable" \
  '<path d="M216 220 L216 340" stroke="#00D4AA" stroke-width="16" stroke-linecap="round" opacity="0.6"/><path d="M256 200 L256 360" stroke="#00D4AA" stroke-width="16" stroke-linecap="round" opacity="0.8"/><path d="M296 220 L296 340" stroke="#00D4AA" stroke-width="16" stroke-linecap="round" opacity="0.6"/><path d="M224 340 L256 370 L288 340" stroke="#00D4AA" stroke-width="12" stroke-linecap="round" stroke-linejoin="round" fill="none" opacity="0.5"/>'

# --- application-x-font ---
generate_mime_icon "application-x-font" \
  '<text x="188" y="340" font-family="serif" font-size="160" font-weight="bold" fill="#00D4AA" opacity="0.6">A</text>'

echo "  Mimetypes icons: 12 generados"

# ============================================================================
# ACTIONS ICONS
# ============================================================================

generate_action_icon() {
  local name="$1"
  local content="$2"
  cat << EOF > "$ICON_DIR/actions/$name.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  $content
</svg>
EOF
}

# --- document-open: folder opening ---
generate_action_icon "document-open" \
  '<path d="M64 128 C64 106 82 88 104 88 L200 88 L232 120 L376 120 C398 120 416 138 416 160 L416 192 L160 192 L96 384 L64 384 Z" fill="#161830"/><path d="M96 192 L416 192 L352 384 L32 384 Z" fill="#00D4AA"/>'

# --- document-save: floppy disk ---
generate_action_icon "document-save" \
  '<rect x="80" y="80" width="352" height="352" rx="32" fill="#161830"/><rect x="144" y="80" width="176" height="128" rx="8" fill="#00D4AA" opacity="0.5"/><rect x="256" y="96" width="40" height="96" rx="4" fill="#161830"/><rect x="144" y="288" width="224" height="128" rx="16" fill="#00D4AA"/><rect x="176" y="312" width="160" height="12" rx="6" fill="#161830" opacity="0.3"/><rect x="176" y="340" width="120" height="12" rx="6" fill="#161830" opacity="0.2"/>'

# --- document-new: page with plus ---
generate_action_icon "document-new" \
  '<path d="M128 48 L336 48 L400 112 L400 464 L128 464 Z" fill="#161830"/><path d="M336 48 L336 112 L400 112 Z" fill="#00D4AA" opacity="0.5"/><line x1="264" y1="208" x2="264" y2="368" stroke="#00D4AA" stroke-width="24" stroke-linecap="round"/><line x1="184" y1="288" x2="344" y2="288" stroke="#00D4AA" stroke-width="24" stroke-linecap="round"/>'

# --- edit-copy: two overlapping pages ---
generate_action_icon "edit-copy" \
  '<rect x="160" y="128" width="256" height="320" rx="24" fill="#00D4AA"/><rect x="96" y="64" width="256" height="320" rx="24" fill="#161830"/><rect x="136" y="136" width="176" height="12" rx="6" fill="#00D4AA" opacity="0.6"/><rect x="136" y="168" width="140" height="12" rx="6" fill="#00D4AA" opacity="0.5"/><rect x="136" y="200" width="176" height="12" rx="6" fill="#00D4AA" opacity="0.6"/>'

# --- edit-paste: clipboard ---
generate_action_icon "edit-paste" \
  '<rect x="112" y="96" width="288" height="368" rx="24" fill="#161830"/><rect x="200" y="64" width="112" height="48" rx="16" fill="#00D4AA"/><rect x="152" y="192" width="208" height="12" rx="6" fill="#00D4AA" opacity="0.6"/><rect x="152" y="228" width="160" height="12" rx="6" fill="#00D4AA" opacity="0.5"/><rect x="152" y="264" width="208" height="12" rx="6" fill="#00D4AA" opacity="0.6"/><rect x="152" y="300" width="140" height="12" rx="6" fill="#00D4AA" opacity="0.5"/>'

# --- edit-delete: X mark ---
generate_action_icon "edit-delete" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><line x1="176" y1="176" x2="336" y2="336" stroke="#FF6B9D" stroke-width="32" stroke-linecap="round"/><line x1="336" y1="176" x2="176" y2="336" stroke="#FF6B9D" stroke-width="32" stroke-linecap="round"/>'

# --- edit-undo: curved arrow left ---
generate_action_icon "edit-undo" \
  '<path d="M176 256 C176 176 224 128 320 128 C400 128 432 192 432 256 C432 320 400 368 320 368 L208 368" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><path d="M240 312 L176 368 L240 424" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>'

# --- edit-redo: curved arrow right ---
generate_action_icon "edit-redo" \
  '<path d="M336 256 C336 176 288 128 192 128 C112 128 80 192 80 256 C80 320 112 368 192 368 L304 368" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><path d="M272 312 L336 368 L272 424" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>'

# --- list-add: plus in circle ---
generate_action_icon "list-add" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><line x1="256" y1="160" x2="256" y2="352" stroke="#00D4AA" stroke-width="32" stroke-linecap="round"/><line x1="160" y1="256" x2="352" y2="256" stroke="#00D4AA" stroke-width="32" stroke-linecap="round"/>'

# --- list-remove: minus in circle ---
generate_action_icon "list-remove" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><line x1="160" y1="256" x2="352" y2="256" stroke="#00D4AA" stroke-width="32" stroke-linecap="round"/>'

# --- view-refresh: circular arrows ---
generate_action_icon "view-refresh" \
  '<path d="M368 176 C336 120 288 96 240 96 C160 96 96 168 96 256 C96 344 160 416 240 416" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><path d="M144 336 C176 392 224 416 272 416 C352 416 416 344 416 256 C416 168 352 96 272 96" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><path d="M344 128 L384 176 L336 200" fill="none" stroke="#00D4AA" stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/><path d="M168 384 L128 336 L176 312" fill="none" stroke="#00D4AA" stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/>'

# --- go-next: right arrow ---
generate_action_icon "go-next" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><line x1="160" y1="256" x2="352" y2="256" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><path d="M288 192 L352 256 L288 320" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>'

# --- go-previous: left arrow ---
generate_action_icon "go-previous" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><line x1="352" y1="256" x2="160" y2="256" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><path d="M224 192 L160 256 L224 320" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>'

# --- window-close: X in square ---
generate_action_icon "window-close" \
  '<rect x="80" y="80" width="352" height="352" rx="32" fill="#161830"/><line x1="192" y1="192" x2="320" y2="320" stroke="#FF6B9D" stroke-width="28" stroke-linecap="round"/><line x1="320" y1="192" x2="192" y2="320" stroke="#FF6B9D" stroke-width="28" stroke-linecap="round"/>'

echo "  Actions icons: 14 generados"

# ============================================================================
# CATEGORIES ICONS
# ============================================================================

generate_category_icon() {
  local name="$1"
  local content="$2"
  cat << EOF > "$ICON_DIR/categories/$name.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  $content
</svg>
EOF
}

# --- preferences-system: gear ---
generate_category_icon "preferences-system" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><path d="M280 96 L280 136 C296 140 310 148 322 158 L358 138 L392 196 L356 216 C358 228 358 240 356 252 L392 272 L358 330 L322 310 C310 320 296 328 280 332 L280 372 L232 372 L232 332 C216 328 202 320 190 310 L154 330 L120 272 L156 252 C154 240 154 228 156 216 L120 196 L154 138 L190 158 C202 148 216 140 232 136 L232 96 Z" fill="#00D4AA"/><circle cx="256" cy="234" r="52" fill="#161830"/>'

# --- preferences-desktop: monitor with slider ---
generate_category_icon "preferences-desktop" \
  '<rect x="80" y="80" width="352" height="264" rx="24" fill="#161830"/><rect x="200" y="344" width="112" height="16" rx="8" fill="#161830"/><rect x="168" y="368" width="176" height="16" rx="8" fill="#161830"/><rect x="128" y="184" width="256" height="8" rx="4" fill="#00D4AA" opacity="0.4"/><circle cx="224" cy="188" r="16" fill="#00D4AA"/><rect x="128" y="240" width="256" height="8" rx="4" fill="#00D4AA" opacity="0.4"/><circle cx="320" cy="244" r="16" fill="#FF6B9D"/>'

# --- system-file-manager: folder ---
generate_category_icon "system-file-manager" \
  '<path d="M64 128 C64 106 82 88 104 88 L200 88 L232 120 L408 120 C430 120 448 138 448 160 L448 384 C448 406 430 424 408 424 L104 424 C82 424 64 406 64 384 Z" fill="#161830"/><path d="M64 172 C64 156 76 144 92 144 L420 144 C436 144 448 156 448 172 L448 384 C448 406 430 424 408 424 L104 424 C82 424 64 406 64 384 Z" fill="#00D4AA"/>'

# --- utilities-terminal: terminal prompt ---
generate_category_icon "utilities-terminal" \
  '<rect x="48" y="64" width="416" height="384" rx="32" fill="#161830"/><path d="M112 192 L176 256 L112 320" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/><rect x="208" y="296" width="120" height="24" rx="12" fill="#00D4AA"/>'

# --- applications-internet: globe ---
generate_category_icon "applications-internet" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><circle cx="256" cy="256" r="160" fill="none" stroke="#00D4AA" stroke-width="12"/><ellipse cx="256" cy="256" rx="80" ry="160" fill="none" stroke="#00D4AA" stroke-width="10"/><line x1="96" y1="256" x2="416" y2="256" stroke="#00D4AA" stroke-width="10"/><path d="M108 176 Q256 152 404 176" fill="none" stroke="#00D4AA" stroke-width="8"/><path d="M108 336 Q256 360 404 336" fill="none" stroke="#00D4AA" stroke-width="8"/>'

# --- applications-multimedia: play button with notes ---
generate_category_icon "applications-multimedia" \
  '<circle cx="256" cy="256" r="192" fill="#161830"/><path d="M208 160 L208 352 L368 256 Z" fill="#00D4AA"/>'

# --- applications-games: dice ---
generate_category_icon "applications-games" \
  '<rect x="80" y="80" width="352" height="352" rx="48" fill="#161830"/><circle cx="176" cy="176" r="24" fill="#00D4AA"/><circle cx="256" cy="256" r="24" fill="#00D4AA"/><circle cx="336" cy="336" r="24" fill="#00D4AA"/><circle cx="336" cy="176" r="24" fill="#FF6B9D"/><circle cx="176" cy="336" r="24" fill="#FF6B9D"/>'

# --- applications-development: code brackets ---
generate_category_icon "applications-development" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><path d="M192 144 L112 256 L192 368" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/><path d="M320 144 L400 256 L320 368" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/><line x1="288" y1="128" x2="224" y2="384" stroke="#FF6B9D" stroke-width="16" stroke-linecap="round"/>'

echo "  Categories icons: 8 generados"

# ============================================================================
# STATUS ICONS
# ============================================================================

generate_status_icon() {
  local name="$1"
  local content="$2"
  cat << EOF > "$ICON_DIR/status/$name.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  $content
</svg>
EOF
}

# --- dialog-information: i in circle ---
generate_status_icon "dialog-information" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><circle cx="256" cy="160" r="24" fill="#00D4AA"/><rect x="240" y="216" width="32" height="160" rx="16" fill="#00D4AA"/>'

# --- dialog-warning: triangle with ! ---
generate_status_icon "dialog-warning" \
  '<path d="M256 64 L464 432 L48 432 Z" fill="#161830"/><path d="M256 96 L440 416 L72 416 Z" fill="none" stroke="#FF6B9D" stroke-width="8"/><rect x="240" y="200" width="32" height="120" rx="16" fill="#FF6B9D"/><circle cx="256" cy="368" r="20" fill="#FF6B9D"/>'

# --- dialog-error: X in circle ---
generate_status_icon "dialog-error" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><circle cx="256" cy="256" r="180" fill="none" stroke="#FF6B9D" stroke-width="12"/><line x1="176" y1="176" x2="336" y2="336" stroke="#FF6B9D" stroke-width="32" stroke-linecap="round"/><line x1="336" y1="176" x2="176" y2="336" stroke="#FF6B9D" stroke-width="32" stroke-linecap="round"/>'

# --- dialog-question: ? in circle ---
generate_status_icon "dialog-question" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><path d="M200 192 C200 144 232 112 272 112 C320 112 352 144 352 192 C352 232 320 248 296 264 C280 276 272 288 272 312" fill="none" stroke="#00D4AA" stroke-width="28" stroke-linecap="round"/><circle cx="272" cy="376" r="20" fill="#00D4AA"/>'

# --- network-online: signal bars full ---
generate_status_icon "network-online" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><rect x="152" y="312" width="40" height="80" rx="8" fill="#00D4AA"/><rect x="216" y="256" width="40" height="136" rx="8" fill="#00D4AA"/><rect x="280" y="200" width="40" height="192" rx="8" fill="#00D4AA"/><rect x="344" y="144" width="40" height="248" rx="8" fill="#00D4AA"/>'

# --- network-offline: signal bars with X ---
generate_status_icon "network-offline" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><rect x="152" y="312" width="40" height="80" rx="8" fill="#00D4AA" opacity="0.3"/><rect x="216" y="256" width="40" height="136" rx="8" fill="#00D4AA" opacity="0.3"/><rect x="280" y="200" width="40" height="192" rx="8" fill="#00D4AA" opacity="0.3"/><rect x="344" y="144" width="40" height="248" rx="8" fill="#00D4AA" opacity="0.3"/><line x1="160" y1="160" x2="368" y2="368" stroke="#FF6B9D" stroke-width="24" stroke-linecap="round"/>'

# --- battery-full: full battery ---
generate_status_icon "battery-full" \
  '<rect x="80" y="160" width="320" height="192" rx="24" fill="#161830"/><rect x="400" y="216" width="32" height="80" rx="12" fill="#161830"/><rect x="104" y="184" width="272" height="144" rx="12" fill="#00D4AA"/>'

# --- battery-low: low battery ---
generate_status_icon "battery-low" \
  '<rect x="80" y="160" width="320" height="192" rx="24" fill="#161830"/><rect x="400" y="216" width="32" height="80" rx="12" fill="#161830"/><rect x="104" y="184" width="72" height="144" rx="12" fill="#FF6B9D"/>'

# --- audio-volume-high: speaker with waves ---
generate_status_icon "audio-volume-high" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><path d="M160 208 L208 208 L280 144 L280 368 L208 304 L160 304 Z" fill="#00D4AA"/><path d="M320 192 C344 216 356 240 356 264 C356 288 344 312 320 332" fill="none" stroke="#00D4AA" stroke-width="16" stroke-linecap="round"/><path d="M340 152 C376 184 396 220 396 260 C396 300 376 336 340 368" fill="none" stroke="#00D4AA" stroke-width="12" stroke-linecap="round" opacity="0.6"/>'

# --- audio-volume-muted: speaker with X ---
generate_status_icon "audio-volume-muted" \
  '<circle cx="256" cy="256" r="208" fill="#161830"/><path d="M144 208 L192 208 L264 144 L264 368 L192 304 L144 304 Z" fill="#00D4AA" opacity="0.4"/><line x1="320" y1="208" x2="400" y2="304" stroke="#FF6B9D" stroke-width="20" stroke-linecap="round"/><line x1="400" y1="208" x2="320" y2="304" stroke="#FF6B9D" stroke-width="20" stroke-linecap="round"/>'

echo "  Status icons: 10 generados"

# ============================================================================
# INDEX.THEME
# ============================================================================

cat << 'EOF' > "image/files/usr/share/icons/LifeOS/index.theme"
[Icon Theme]
Name=LifeOS
Comment=LifeOS flat icon theme with Teal Axi accent
Inherits=Adwaita,hicolor
Example=folder

Directories=scalable/apps,scalable/places,scalable/mimetypes,scalable/actions,scalable/categories,scalable/status

[scalable/apps]
Size=512
MinSize=16
MaxSize=1024
Type=Scalable
Context=Applications

[scalable/places]
Size=512
MinSize=16
MaxSize=1024
Type=Scalable
Context=Places

[scalable/mimetypes]
Size=512
MinSize=16
MaxSize=1024
Type=Scalable
Context=MimeTypes

[scalable/actions]
Size=512
MinSize=16
MaxSize=1024
Type=Scalable
Context=Actions

[scalable/categories]
Size=512
MinSize=16
MaxSize=1024
Type=Scalable
Context=Categories

[scalable/status]
Size=512
MinSize=16
MaxSize=1024
Type=Scalable
Context=Status
EOF

echo ""
echo "Tema de iconos LifeOS generado:"
echo "  Iconos: $ICON_DIR/ (apps, places, mimetypes, actions, categories, status)"
echo "  Index:  image/files/usr/share/icons/LifeOS/index.theme"
echo "  Wallpapers: $WALLPAPER_DIR/"
echo ""

# Count total icons
TOTAL=$(find "$ICON_DIR" -name "*.svg" | wc -l)
echo "Total: $TOTAL iconos SVG + 2 wallpapers + index.theme"
