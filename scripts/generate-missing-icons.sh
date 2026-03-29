#!/bin/bash
# Generate missing freedesktop icons for LifeOS theme
# Style: flat, 512x512, #161830 (dark) + #00D4AA (teal accent), rounded corners
set -euo pipefail

ICON_DIR="image/files/usr/share/icons/LifeOS/scalable"
DARK="#161830"
TEAL="#00D4AA"

svg() {
    local dir="$1" name="$2" body="$3"
    local path="$ICON_DIR/$dir/$name.svg"
    [ -f "$path" ] && return 0  # skip existing
    mkdir -p "$ICON_DIR/$dir"
    cat > "$path" << EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  $body
</svg>
EOF
    echo "  + $dir/$name.svg"
}

echo "=== Generating missing LifeOS icons ==="

# ─────────────────────────────────────────────────────────
# ACTIONS (currently 13, need ~40 more critical ones)
# ─────────────────────────────────────────────────────────
echo "[actions]"

# Navigation
svg actions go-home \
  "<circle cx=\"256\" cy=\"280\" r=\"160\" fill=\"$DARK\"/><path d=\"M256 120 L400 260 L360 260 L360 400 L152 400 L152 260 L112 260 Z\" fill=\"$TEAL\"/><rect x=\"216\" y=\"300\" width=\"80\" height=\"100\" rx=\"8\" fill=\"$DARK\"/>"

svg actions go-up \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M256 120 L380 320 L132 320 Z\" fill=\"$TEAL\"/>"

svg actions go-down \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M256 392 L380 192 L132 192 Z\" fill=\"$TEAL\"/>"

svg actions go-first \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><rect x=\"132\" y=\"152\" width=\"32\" height=\"208\" rx=\"8\" fill=\"$TEAL\"/><path d=\"M200 256 L340 152 L340 360 Z\" fill=\"$TEAL\"/>"

svg actions go-last \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><rect x=\"348\" y=\"152\" width=\"32\" height=\"208\" rx=\"8\" fill=\"$TEAL\"/><path d=\"M312 256 L172 152 L172 360 Z\" fill=\"$TEAL\"/>"

svg actions go-jump \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M256 120 L380 240 L300 240 L300 392 L212 392 L212 240 L132 240 Z\" fill=\"$TEAL\"/>"

# View
svg actions view-fullscreen \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$DARK\"/><path d=\"M120 120 L220 120 L120 220 Z\" fill=\"$TEAL\"/><path d=\"M392 120 L292 120 L392 220 Z\" fill=\"$TEAL\"/><path d=\"M120 392 L220 392 L120 292 Z\" fill=\"$TEAL\"/><path d=\"M392 392 L292 392 L392 292 Z\" fill=\"$TEAL\"/>"

svg actions view-restore \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$DARK\"/><path d=\"M200 200 L200 120 L120 200 Z\" fill=\"$TEAL\"/><path d=\"M312 312 L312 392 L392 312 Z\" fill=\"$TEAL\"/>"

svg actions zoom-in \
  "<circle cx=\"224\" cy=\"224\" r=\"160\" fill=\"$DARK\" stroke=\"$TEAL\" stroke-width=\"24\"/><rect x=\"152\" y=\"208\" width=\"144\" height=\"32\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"208\" y=\"152\" width=\"32\" height=\"144\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"340\" y=\"340\" width=\"120\" height=\"32\" rx=\"8\" fill=\"$TEAL\" transform=\"rotate(45 400 356)\"/>"

svg actions zoom-out \
  "<circle cx=\"224\" cy=\"224\" r=\"160\" fill=\"$DARK\" stroke=\"$TEAL\" stroke-width=\"24\"/><rect x=\"152\" y=\"208\" width=\"144\" height=\"32\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"340\" y=\"340\" width=\"120\" height=\"32\" rx=\"8\" fill=\"$TEAL\" transform=\"rotate(45 400 356)\"/>"

svg actions zoom-fit-best \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"120\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><circle cx=\"256\" cy=\"256\" r=\"40\" fill=\"$TEAL\"/>"

# Format
svg actions format-text-bold \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$DARK\"/><text x=\"256\" y=\"340\" font-family=\"sans-serif\" font-size=\"280\" font-weight=\"bold\" fill=\"$TEAL\" text-anchor=\"middle\">B</text>"

svg actions format-text-italic \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$DARK\"/><text x=\"256\" y=\"340\" font-family=\"sans-serif\" font-size=\"280\" font-style=\"italic\" fill=\"$TEAL\" text-anchor=\"middle\">I</text>"

svg actions format-text-underline \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$DARK\"/><text x=\"256\" y=\"300\" font-family=\"sans-serif\" font-size=\"240\" fill=\"$TEAL\" text-anchor=\"middle\">U</text><rect x=\"136\" y=\"370\" width=\"240\" height=\"16\" rx=\"4\" fill=\"$TEAL\"/>"

svg actions format-justify-left \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$DARK\"/><rect x=\"136\" y=\"128\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"136\" y=\"184\" width=\"180\" height=\"24\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/><rect x=\"136\" y=\"240\" width=\"220\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"136\" y=\"296\" width=\"160\" height=\"24\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/><rect x=\"136\" y=\"352\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/>"

svg actions format-justify-center \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$DARK\"/><rect x=\"136\" y=\"128\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"166\" y=\"184\" width=\"180\" height=\"24\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/><rect x=\"146\" y=\"240\" width=\"220\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"176\" y=\"296\" width=\"160\" height=\"24\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/><rect x=\"136\" y=\"352\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/>"

# Media
svg actions media-playback-start \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M200 140 L380 256 L200 372 Z\" fill=\"$TEAL\"/>"

svg actions media-playback-pause \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><rect x=\"172\" y=\"160\" width=\"56\" height=\"192\" rx=\"12\" fill=\"$TEAL\"/><rect x=\"284\" y=\"160\" width=\"56\" height=\"192\" rx=\"12\" fill=\"$TEAL\"/>"

svg actions media-playback-stop \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><rect x=\"168\" y=\"168\" width=\"176\" height=\"176\" rx=\"16\" fill=\"$TEAL\"/>"

svg actions media-record \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"96\" fill=\"#FF4444\"/>"

svg actions media-seek-forward \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M140 160 L260 256 L140 352 Z\" fill=\"$TEAL\"/><path d=\"M260 160 L380 256 L260 352 Z\" fill=\"$TEAL\"/>"

svg actions media-seek-backward \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M372 160 L252 256 L372 352 Z\" fill=\"$TEAL\"/><path d=\"M252 160 L132 256 L252 352 Z\" fill=\"$TEAL\"/>"

svg actions media-skip-forward \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M140 160 L300 256 L140 352 Z\" fill=\"$TEAL\"/><rect x=\"324\" y=\"160\" width=\"32\" height=\"192\" rx=\"8\" fill=\"$TEAL\"/>"

svg actions media-skip-backward \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M372 160 L212 256 L372 352 Z\" fill=\"$TEAL\"/><rect x=\"156\" y=\"160\" width=\"32\" height=\"192\" rx=\"8\" fill=\"$TEAL\"/>"

# System
svg actions system-lock-screen \
  "<rect x=\"96\" y=\"160\" width=\"320\" height=\"256\" rx=\"24\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"160\" r=\"80\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><circle cx=\"256\" cy=\"300\" r=\"32\" fill=\"$TEAL\"/><rect x=\"244\" y=\"320\" width=\"24\" height=\"48\" rx=\"8\" fill=\"$TEAL\"/>"

svg actions system-log-out \
  "<rect x=\"80\" y=\"80\" width=\"200\" height=\"352\" rx=\"24\" fill=\"$DARK\"/><path d=\"M280 256 L432 256\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\"/><path d=\"M380 200 L432 256 L380 312\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\" fill=\"none\"/>"

svg actions system-run \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"120\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><circle cx=\"256\" cy=\"256\" r=\"20\" fill=\"$TEAL\"/><rect x=\"248\" y=\"140\" width=\"16\" height=\"80\" rx=\"4\" fill=\"$TEAL\"/><rect x=\"248\" y=\"252\" width=\"100\" height=\"16\" rx=\"4\" fill=\"$TEAL\" transform=\"rotate(-30 256 256)\"/>"

svg actions system-search \
  "<circle cx=\"220\" cy=\"220\" r=\"140\" fill=\"$DARK\" stroke=\"$TEAL\" stroke-width=\"24\"/><rect x=\"330\" y=\"330\" width=\"120\" height=\"32\" rx=\"8\" fill=\"$TEAL\" transform=\"rotate(45 390 346)\"/>"

svg actions system-reboot \
  "<circle cx=\"256\" cy=\"280\" r=\"160\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><path d=\"M256 80 L256 240\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\"/><path d=\"M340 140 A160 160 0 1 1 172 140\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/>"

svg actions system-shutdown \
  "<circle cx=\"256\" cy=\"280\" r=\"160\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><path d=\"M256 80 L256 280\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\"/>"

# Window
svg actions window-new \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$DARK\"/><rect x=\"80\" y=\"80\" width=\"352\" height=\"56\" rx=\"24\" fill=\"$TEAL\"/><rect x=\"224\" y=\"200\" width=\"64\" height=\"192\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"144\" y=\"264\" width=\"224\" height=\"64\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.5\"/>"

svg actions window-maximize \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$DARK\" stroke=\"$TEAL\" stroke-width=\"16\"/><rect x=\"80\" y=\"80\" width=\"352\" height=\"56\" rx=\"24\" fill=\"$TEAL\"/>"

svg actions window-minimize \
  "<rect x=\"80\" y=\"360\" width=\"352\" height=\"32\" rx=\"12\" fill=\"$TEAL\"/>"

# Mail
svg actions mail-message-new \
  "<rect x=\"64\" y=\"128\" width=\"384\" height=\"280\" rx=\"24\" fill=\"$DARK\"/><path d=\"M80 144 L256 280 L432 144\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\"/><circle cx=\"400\" cy=\"140\" r=\"56\" fill=\"$TEAL\"/><rect x=\"384\" y=\"112\" width=\"32\" height=\"56\" rx=\"4\" fill=\"$DARK\"/><rect x=\"372\" y=\"128\" width=\"56\" height=\"24\" rx=\"4\" fill=\"$DARK\"/>"

svg actions mail-send \
  "<path d=\"M80 128 L432 256 L80 384 L160 256 Z\" fill=\"$DARK\" stroke=\"$TEAL\" stroke-width=\"12\"/><path d=\"M160 256 L432 256\" stroke=\"$TEAL\" stroke-width=\"12\"/>"

svg actions mail-reply-sender \
  "<rect x=\"120\" y=\"160\" width=\"320\" height=\"240\" rx=\"24\" fill=\"$DARK\"/><path d=\"M136 176 L280 280 L424 176\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><path d=\"M160 256 L80 320 L160 384\" stroke=\"$TEAL\" stroke-width=\"24\" fill=\"none\" stroke-linecap=\"round\"/>"

svg actions mail-forward \
  "<rect x=\"72\" y=\"160\" width=\"320\" height=\"240\" rx=\"24\" fill=\"$DARK\"/><path d=\"M88 176 L232 280 L376 176\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><path d=\"M352 256 L432 320 L352 384\" stroke=\"$TEAL\" stroke-width=\"24\" fill=\"none\" stroke-linecap=\"round\"/>"

# Misc
svg actions process-stop \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"#CC3333\"/><rect x=\"160\" y=\"232\" width=\"192\" height=\"48\" rx=\"12\" fill=\"white\"/>"

svg actions folder-new \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$DARK\"/><path d=\"M80 160 L432 160\" stroke=\"$TEAL\" stroke-width=\"8\"/><rect x=\"224\" y=\"240\" width=\"64\" height=\"128\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/><rect x=\"192\" y=\"272\" width=\"128\" height=\"64\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/>"

svg actions bookmark-new \
  "<path d=\"M128 64 L384 64 L384 448 L256 352 L128 448 Z\" fill=\"$DARK\"/><rect x=\"224\" y=\"128\" width=\"64\" height=\"160\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"176\" y=\"176\" width=\"160\" height=\"64\" rx=\"8\" fill=\"$TEAL\"/>"

svg actions help-about \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><text x=\"256\" y=\"340\" font-family=\"sans-serif\" font-size=\"280\" font-weight=\"bold\" fill=\"$TEAL\" text-anchor=\"middle\">?</text>"

# ─────────────────────────────────────────────────────────
# DEVICES (new context, 0 existing)
# ─────────────────────────────────────────────────────────
echo "[devices]"

svg devices computer \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"240\" rx=\"16\" fill=\"$DARK\"/><rect x=\"120\" y=\"88\" width=\"272\" height=\"192\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/><rect x=\"192\" y=\"304\" width=\"128\" height=\"24\" rx=\"4\" fill=\"$DARK\"/><rect x=\"144\" y=\"328\" width=\"224\" height=\"24\" rx=\"12\" fill=\"$DARK\"/>"

svg devices laptop \
  "<rect x=\"112\" y=\"80\" width=\"288\" height=\"208\" rx=\"12\" fill=\"$DARK\"/><rect x=\"128\" y=\"96\" width=\"256\" height=\"176\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/><path d=\"M64 312 L448 312 L416 360 L96 360 Z\" fill=\"$DARK\"/>"

svg devices video-display \
  "<rect x=\"80\" y=\"64\" width=\"352\" height=\"256\" rx=\"16\" fill=\"$DARK\"/><rect x=\"104\" y=\"88\" width=\"304\" height=\"208\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/><rect x=\"208\" y=\"336\" width=\"96\" height=\"40\" rx=\"4\" fill=\"$DARK\"/><rect x=\"160\" y=\"376\" width=\"192\" height=\"16\" rx=\"8\" fill=\"$DARK\"/>"

svg devices phone \
  "<rect x=\"160\" y=\"48\" width=\"192\" height=\"416\" rx=\"24\" fill=\"$DARK\"/><rect x=\"176\" y=\"80\" width=\"160\" height=\"320\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/><circle cx=\"256\" cy=\"432\" r=\"16\" fill=\"$TEAL\"/>"

svg devices drive-harddisk \
  "<rect x=\"80\" y=\"128\" width=\"352\" height=\"256\" rx=\"24\" fill=\"$DARK\"/><circle cx=\"336\" cy=\"320\" r=\"24\" fill=\"$TEAL\"/><rect x=\"136\" y=\"200\" width=\"160\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"136\" y=\"228\" width=\"120\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.3\"/>"

svg devices drive-harddisk-solidstate \
  "<rect x=\"80\" y=\"128\" width=\"352\" height=\"256\" rx=\"24\" fill=\"$DARK\"/><rect x=\"136\" y=\"192\" width=\"240\" height=\"128\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/><text x=\"256\" y=\"276\" font-family=\"sans-serif\" font-size=\"64\" font-weight=\"bold\" fill=\"$TEAL\" text-anchor=\"middle\">SSD</text>"

svg devices drive-optical \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"64\" fill=\"$TEAL\" opacity=\"0.5\"/><circle cx=\"256\" cy=\"256\" r=\"20\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"4\" opacity=\"0.3\"/>"

svg devices drive-removable-media \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$DARK\"/><rect x=\"160\" y=\"64\" width=\"64\" height=\"64\" rx=\"4\" fill=\"$TEAL\"/><rect x=\"288\" y=\"64\" width=\"64\" height=\"64\" rx=\"4\" fill=\"$TEAL\"/><rect x=\"136\" y=\"200\" width=\"240\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"136\" y=\"240\" width=\"180\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.3\"/>"

svg devices media-flash \
  "<rect x=\"144\" y=\"80\" width=\"224\" height=\"352\" rx=\"16\" fill=\"$DARK\"/><rect x=\"192\" y=\"48\" width=\"32\" height=\"64\" rx=\"4\" fill=\"$TEAL\"/><rect x=\"288\" y=\"48\" width=\"32\" height=\"64\" rx=\"4\" fill=\"$TEAL\"/><rect x=\"176\" y=\"176\" width=\"160\" height=\"200\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/>"

svg devices audio-input-microphone \
  "<rect x=\"192\" y=\"64\" width=\"128\" height=\"240\" rx=\"64\" fill=\"$DARK\"/><rect x=\"216\" y=\"88\" width=\"80\" height=\"192\" rx=\"40\" fill=\"$TEAL\" opacity=\"0.5\"/><path d=\"M160 280 A96 96 0 0 0 352 280\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><rect x=\"244\" y=\"360\" width=\"24\" height=\"64\" rx=\"4\" fill=\"$TEAL\"/><rect x=\"200\" y=\"416\" width=\"112\" height=\"16\" rx=\"8\" fill=\"$TEAL\"/>"

svg devices audio-headphones \
  "<path d=\"M128 320 A128 128 0 0 1 384 320\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><rect x=\"96\" y=\"280\" width=\"64\" height=\"120\" rx=\"16\" fill=\"$DARK\"/><rect x=\"352\" y=\"280\" width=\"64\" height=\"120\" rx=\"16\" fill=\"$DARK\"/>"

svg devices audio-speakers \
  "<rect x=\"128\" y=\"64\" width=\"256\" height=\"384\" rx=\"24\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"300\" r=\"96\" fill=\"$TEAL\" opacity=\"0.4\"/><circle cx=\"256\" cy=\"300\" r=\"48\" fill=\"$TEAL\"/><circle cx=\"256\" cy=\"144\" r=\"32\" fill=\"$TEAL\" opacity=\"0.5\"/>"

svg devices input-keyboard \
  "<rect x=\"48\" y=\"160\" width=\"416\" height=\"192\" rx=\"24\" fill=\"$DARK\"/><rect x=\"88\" y=\"192\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"144\" y=\"192\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"200\" y=\"192\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"256\" y=\"192\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"312\" y=\"192\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"368\" y=\"192\" width=\"56\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"88\" y=\"244\" width=\"56\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.4\"/><rect x=\"160\" y=\"244\" width=\"200\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.6\"/><rect x=\"376\" y=\"244\" width=\"48\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.4\"/><rect x=\"88\" y=\"296\" width=\"336\" height=\"32\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.3\"/>"

svg devices input-mouse \
  "<rect x=\"160\" y=\"80\" width=\"192\" height=\"352\" rx=\"96\" fill=\"$DARK\"/><rect x=\"248\" y=\"96\" width=\"8\" height=\"80\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"160\" y=\"200\" width=\"192\" height=\"4\" fill=\"$TEAL\" opacity=\"0.3\"/>"

svg devices input-gaming \
  "<ellipse cx=\"256\" cy=\"280\" rx=\"200\" ry=\"120\" fill=\"$DARK\"/><circle cx=\"176\" cy=\"260\" r=\"32\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"8\"/><circle cx=\"340\" cy=\"240\" r=\"12\" fill=\"$TEAL\"/><circle cx=\"372\" cy=\"272\" r=\"12\" fill=\"$TEAL\"/><circle cx=\"340\" cy=\"304\" r=\"12\" fill=\"$TEAL\"/><circle cx=\"308\" cy=\"272\" r=\"12\" fill=\"$TEAL\"/><rect x=\"220\" y=\"168\" width=\"28\" height=\"60\" rx=\"14\" fill=\"$DARK\"/><rect x=\"264\" y=\"168\" width=\"28\" height=\"60\" rx=\"14\" fill=\"$DARK\"/>"

svg devices network-wired \
  "<rect x=\"208\" y=\"64\" width=\"96\" height=\"80\" rx=\"8\" fill=\"$DARK\"/><rect x=\"248\" y=\"144\" width=\"16\" height=\"80\" fill=\"$TEAL\"/><rect x=\"96\" y=\"224\" width=\"320\" height=\"16\" fill=\"$TEAL\"/><rect x=\"152\" y=\"224\" width=\"16\" height=\"80\" fill=\"$TEAL\"/><rect x=\"344\" y=\"224\" width=\"16\" height=\"80\" fill=\"$TEAL\"/><rect x=\"104\" y=\"304\" width=\"96\" height=\"80\" rx=\"8\" fill=\"$DARK\"/><rect x=\"296\" y=\"304\" width=\"96\" height=\"80\" rx=\"8\" fill=\"$DARK\"/>"

svg devices network-wireless \
  "<circle cx=\"256\" cy=\"380\" r=\"24\" fill=\"$TEAL\"/><path d=\"M176 300 A100 100 0 0 1 336 300\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M120 232 A170 170 0 0 1 392 232\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M72 164 A240 240 0 0 1 440 164\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\" stroke-linecap=\"round\"/>"

svg devices printer \
  "<rect x=\"128\" y=\"64\" width=\"256\" height=\"120\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.4\"/><rect x=\"80\" y=\"184\" width=\"352\" height=\"176\" rx=\"16\" fill=\"$DARK\"/><rect x=\"160\" y=\"312\" width=\"192\" height=\"120\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.3\"/><circle cx=\"384\" cy=\"224\" r=\"12\" fill=\"$TEAL\"/>"

svg devices camera-photo \
  "<rect x=\"80\" y=\"144\" width=\"352\" height=\"272\" rx=\"24\" fill=\"$DARK\"/><rect x=\"184\" y=\"104\" width=\"144\" height=\"56\" rx=\"8\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"296\" r=\"80\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><circle cx=\"256\" cy=\"296\" r=\"40\" fill=\"$TEAL\" opacity=\"0.5\"/>"

svg devices camera-web \
  "<circle cx=\"256\" cy=\"224\" r=\"160\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"224\" r=\"80\" fill=\"$TEAL\" opacity=\"0.4\"/><circle cx=\"256\" cy=\"224\" r=\"32\" fill=\"$TEAL\"/><rect x=\"208\" y=\"384\" width=\"96\" height=\"64\" rx=\"8\" fill=\"$DARK\"/>"

svg devices battery \
  "<rect x=\"80\" y=\"160\" width=\"320\" height=\"192\" rx=\"24\" fill=\"$DARK\"/><rect x=\"400\" y=\"216\" width=\"32\" height=\"80\" rx=\"12\" fill=\"$DARK\"/><rect x=\"104\" y=\"184\" width=\"160\" height=\"144\" rx=\"12\" fill=\"$TEAL\" opacity=\"0.6\"/>"

svg devices bluetooth \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M224 160 L320 256 L224 352 L224 160 M224 352 L320 256 L224 160\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\" stroke-linejoin=\"round\"/><path d=\"M160 192 L320 320 M160 320 L320 192\" stroke=\"$TEAL\" stroke-width=\"16\" opacity=\"0.5\"/>"

# ─────────────────────────────────────────────────────────
# EMBLEMS (new context, 0 existing)
# ─────────────────────────────────────────────────────────
echo "[emblems]"

svg emblems emblem-default \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$TEAL\"/><path d=\"M176 256 L232 320 L360 192\" fill=\"none\" stroke=\"white\" stroke-width=\"40\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg emblems emblem-favorite \
  "<path d=\"M256 96 L296 192 L400 200 L320 272 L344 376 L256 328 L168 376 L192 272 L112 200 L216 192 Z\" fill=\"#FF6B6B\"/>"

svg emblems emblem-important \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"#FFB800\"/><rect x=\"232\" y=\"120\" width=\"48\" height=\"192\" rx=\"16\" fill=\"white\"/><circle cx=\"256\" cy=\"368\" r=\"28\" fill=\"white\"/>"

svg emblems emblem-readonly \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><rect x=\"160\" y=\"200\" width=\"192\" height=\"160\" rx=\"16\" fill=\"$TEAL\" opacity=\"0.5\"/><circle cx=\"256\" cy=\"200\" r=\"56\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><circle cx=\"256\" cy=\"260\" r=\"16\" fill=\"$TEAL\"/>"

svg emblems emblem-shared \
  "<circle cx=\"256\" cy=\"128\" r=\"48\" fill=\"$TEAL\"/><circle cx=\"144\" cy=\"352\" r=\"48\" fill=\"$TEAL\"/><circle cx=\"368\" cy=\"352\" r=\"48\" fill=\"$TEAL\"/><line x1=\"256\" y1=\"176\" x2=\"160\" y2=\"312\" stroke=\"$TEAL\" stroke-width=\"12\"/><line x1=\"256\" y1=\"176\" x2=\"352\" y2=\"312\" stroke=\"$TEAL\" stroke-width=\"12\"/>"

svg emblems emblem-symbolic-link \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M160 280 L320 280\" stroke=\"$TEAL\" stroke-width=\"24\" stroke-linecap=\"round\"/><path d=\"M280 232 L336 280 L280 328\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/><path d=\"M160 200 Q256 120 352 200\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"12\" stroke-dasharray=\"16 12\"/>"

svg emblems emblem-synchronized \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M336 176 A100 100 0 0 1 336 336\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><path d=\"M176 336 A100 100 0 0 1 176 176\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><path d=\"M336 160 L360 200 L312 200 Z\" fill=\"$TEAL\"/><path d=\"M176 352 L152 312 L200 312 Z\" fill=\"$TEAL\"/>"

svg emblems emblem-system \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"24\"/><circle cx=\"256\" cy=\"256\" r=\"24\" fill=\"$TEAL\"/><rect x=\"244\" y=\"64\" width=\"24\" height=\"64\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"244\" y=\"384\" width=\"24\" height=\"64\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"64\" y=\"244\" width=\"64\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"384\" y=\"244\" width=\"64\" height=\"24\" rx=\"8\" fill=\"$TEAL\"/>"

svg emblems emblem-documents \
  "<rect x=\"128\" y=\"64\" width=\"256\" height=\"384\" rx=\"16\" fill=\"$DARK\"/><rect x=\"168\" y=\"128\" width=\"176\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.6\"/><rect x=\"168\" y=\"164\" width=\"140\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.4\"/><rect x=\"168\" y=\"200\" width=\"176\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.6\"/><rect x=\"168\" y=\"236\" width=\"120\" height=\"12\" rx=\"6\" fill=\"$TEAL\" opacity=\"0.4\"/>"

svg emblems emblem-downloads \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><path d=\"M256 112 L256 320\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\"/><path d=\"M176 264 L256 344 L336 264\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/><rect x=\"136\" y=\"380\" width=\"240\" height=\"20\" rx=\"10\" fill=\"$TEAL\"/>"

svg emblems emblem-mail \
  "<rect x=\"64\" y=\"128\" width=\"384\" height=\"280\" rx=\"24\" fill=\"$DARK\"/><path d=\"M80 144 L256 280 L432 144\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\"/>"

svg emblems emblem-photos \
  "<rect x=\"80\" y=\"112\" width=\"352\" height=\"288\" rx=\"16\" fill=\"$DARK\"/><circle cx=\"192\" cy=\"208\" r=\"32\" fill=\"$TEAL\" opacity=\"0.6\"/><path d=\"M96 352 L208 256 L304 336 L352 288 L416 368\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"12\"/>"

svg emblems emblem-unreadable \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><line x1=\"120\" y1=\"120\" x2=\"392\" y2=\"392\" stroke=\"#CC3333\" stroke-width=\"40\" stroke-linecap=\"round\"/><line x1=\"392\" y1=\"120\" x2=\"120\" y2=\"392\" stroke=\"#CC3333\" stroke-width=\"40\" stroke-linecap=\"round\"/>"

# ─────────────────────────────────────────────────────────
# STATUS (additional needed icons)
# ─────────────────────────────────────────────────────────
echo "[status]"

svg status audio-volume-low \
  "<rect x=\"128\" y=\"208\" width=\"96\" height=\"96\" rx=\"8\" fill=\"$TEAL\"/><path d=\"M224 192 L320 128 L320 384 L224 320 Z\" fill=\"$TEAL\"/><path d=\"M352 208 A64 64 0 0 1 352 304\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/>"

svg status audio-volume-medium \
  "<rect x=\"112\" y=\"208\" width=\"96\" height=\"96\" rx=\"8\" fill=\"$TEAL\"/><path d=\"M208 192 L304 128 L304 384 L208 320 Z\" fill=\"$TEAL\"/><path d=\"M336 192 A80 80 0 0 1 336 320\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\"/><path d=\"M368 152 A120 120 0 0 1 368 360\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\" opacity=\"0.5\"/>"

svg status battery-charging \
  "<rect x=\"80\" y=\"160\" width=\"320\" height=\"192\" rx=\"24\" fill=\"$DARK\"/><rect x=\"400\" y=\"216\" width=\"32\" height=\"80\" rx=\"12\" fill=\"$DARK\"/><rect x=\"104\" y=\"184\" width=\"200\" height=\"144\" rx=\"12\" fill=\"$TEAL\" opacity=\"0.6\"/><path d=\"M272 200 L240 264 L280 264 L248 344\" fill=\"none\" stroke=\"#FFB800\" stroke-width=\"16\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg status battery-caution \
  "<rect x=\"80\" y=\"160\" width=\"320\" height=\"192\" rx=\"24\" fill=\"$DARK\"/><rect x=\"400\" y=\"216\" width=\"32\" height=\"80\" rx=\"12\" fill=\"$DARK\"/><rect x=\"104\" y=\"184\" width=\"80\" height=\"144\" rx=\"12\" fill=\"#FFB800\"/>"

svg status battery-empty \
  "<rect x=\"80\" y=\"160\" width=\"320\" height=\"192\" rx=\"24\" fill=\"$DARK\"/><rect x=\"400\" y=\"216\" width=\"32\" height=\"80\" rx=\"12\" fill=\"$DARK\"/><rect x=\"80\" y=\"160\" width=\"320\" height=\"192\" rx=\"24\" fill=\"none\" stroke=\"#CC3333\" stroke-width=\"8\"/>"

svg status network-error \
  "<circle cx=\"256\" cy=\"380\" r=\"24\" fill=\"#CC3333\"/><path d=\"M176 300 A100 100 0 0 1 336 300\" fill=\"none\" stroke=\"#CC3333\" stroke-width=\"20\" stroke-linecap=\"round\" opacity=\"0.5\"/><line x1=\"176\" y1=\"160\" x2=\"336\" y2=\"320\" stroke=\"#CC3333\" stroke-width=\"24\" stroke-linecap=\"round\"/><line x1=\"336\" y1=\"160\" x2=\"176\" y2=\"320\" stroke=\"#CC3333\" stroke-width=\"24\" stroke-linecap=\"round\"/>"

svg status network-idle \
  "<circle cx=\"256\" cy=\"380\" r=\"24\" fill=\"$TEAL\" opacity=\"0.5\"/><path d=\"M176 300 A100 100 0 0 1 336 300\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\" stroke-linecap=\"round\" opacity=\"0.3\"/><path d=\"M120 232 A170 170 0 0 1 392 232\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\" stroke-linecap=\"round\" opacity=\"0.2\"/>"

svg status security-high \
  "<path d=\"M256 64 L416 160 L416 320 Q416 448 256 448 Q96 448 96 320 L96 160 Z\" fill=\"$DARK\"/><path d=\"M176 256 L232 320 L360 192\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg status security-medium \
  "<path d=\"M256 64 L416 160 L416 320 Q416 448 256 448 Q96 448 96 320 L96 160 Z\" fill=\"$DARK\"/><rect x=\"232\" y=\"168\" width=\"48\" height=\"144\" rx=\"16\" fill=\"#FFB800\"/><circle cx=\"256\" cy=\"368\" r=\"28\" fill=\"#FFB800\"/>"

svg status security-low \
  "<path d=\"M256 64 L416 160 L416 320 Q416 448 256 448 Q96 448 96 320 L96 160 Z\" fill=\"$DARK\"/><line x1=\"176\" y1=\"192\" x2=\"336\" y2=\"352\" stroke=\"#CC3333\" stroke-width=\"32\" stroke-linecap=\"round\"/><line x1=\"336\" y1=\"192\" x2=\"176\" y2=\"352\" stroke=\"#CC3333\" stroke-width=\"32\" stroke-linecap=\"round\"/>"

svg status user-available \
  "<circle cx=\"256\" cy=\"192\" r=\"80\" fill=\"$TEAL\"/><path d=\"M128 416 A128 128 0 0 1 384 416\" fill=\"$TEAL\"/><circle cx=\"372\" cy=\"372\" r=\"40\" fill=\"#44CC44\"/>"

svg status user-away \
  "<circle cx=\"256\" cy=\"192\" r=\"80\" fill=\"$DARK\"/><path d=\"M128 416 A128 128 0 0 1 384 416\" fill=\"$DARK\"/><circle cx=\"372\" cy=\"372\" r=\"40\" fill=\"#FFB800\"/>"

svg status user-offline \
  "<circle cx=\"256\" cy=\"192\" r=\"80\" fill=\"$DARK\" opacity=\"0.5\"/><path d=\"M128 416 A128 128 0 0 1 384 416\" fill=\"$DARK\" opacity=\"0.5\"/><circle cx=\"372\" cy=\"372\" r=\"40\" fill=\"#CC3333\"/>"

svg status software-update-available \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$DARK\"/><path d=\"M256 160 L256 340\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\"/><path d=\"M192 280 L256 348 L320 280\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"32\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg status software-update-urgent \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"#CC3333\"/><rect x=\"232\" y=\"152\" width=\"48\" height=\"144\" rx=\"16\" fill=\"white\"/><circle cx=\"256\" cy=\"352\" r=\"28\" fill=\"white\"/>"

svg status mail-unread \
  "<rect x=\"64\" y=\"128\" width=\"384\" height=\"280\" rx=\"24\" fill=\"$DARK\"/><path d=\"M80 144 L256 280 L432 144\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"20\"/><circle cx=\"400\" cy=\"144\" r=\"40\" fill=\"$TEAL\"/>"

svg status mail-read \
  "<rect x=\"64\" y=\"168\" width=\"384\" height=\"240\" rx=\"24\" fill=\"$DARK\"/><path d=\"M80 184 L256 280 L432 184\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"16\" opacity=\"0.5\"/>"

svg status notification-new \
  "<path d=\"M256 80 A120 120 0 0 1 376 200 L376 320 L416 368 L96 368 L136 320 L136 200 A120 120 0 0 1 256 80\" fill=\"$TEAL\"/><circle cx=\"256\" cy=\"416\" r=\"40\" fill=\"$TEAL\"/>"

svg status notification-disabled \
  "<path d=\"M256 80 A120 120 0 0 1 376 200 L376 320 L416 368 L96 368 L136 320 L136 200 A120 120 0 0 1 256 80\" fill=\"$DARK\" opacity=\"0.4\"/><line x1=\"120\" y1=\"120\" x2=\"392\" y2=\"392\" stroke=\"#CC3333\" stroke-width=\"24\" stroke-linecap=\"round\"/>"

svg status user-trash-full \
  "<rect x=\"120\" y=\"160\" width=\"272\" height=\"280\" rx=\"16\" fill=\"$DARK\"/><rect x=\"96\" y=\"128\" width=\"320\" height=\"40\" rx=\"8\" fill=\"$TEAL\"/><rect x=\"216\" y=\"96\" width=\"80\" height=\"40\" rx=\"8\" fill=\"$TEAL\" opacity=\"0.7\"/><rect x=\"200\" y=\"220\" width=\"16\" height=\"160\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.4\"/><rect x=\"248\" y=\"220\" width=\"16\" height=\"160\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.4\"/><rect x=\"296\" y=\"220\" width=\"16\" height=\"160\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.4\"/>"

# ─────────────────────────────────────────────────────────
# PLACES (additional)
# ─────────────────────────────────────────────────────────
echo "[places]"

svg places folder-remote \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$DARK\"/><path d=\"M80 160 L432 160\" stroke=\"$TEAL\" stroke-width=\"8\"/><circle cx=\"256\" cy=\"296\" r=\"20\" fill=\"$TEAL\"/><path d=\"M200 260 A64 64 0 0 1 312 260\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"12\"/><path d=\"M160 228 A108 108 0 0 1 352 228\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"12\" opacity=\"0.5\"/>"

svg places folder-recent \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$DARK\"/><path d=\"M80 160 L432 160\" stroke=\"$TEAL\" stroke-width=\"8\"/><circle cx=\"256\" cy=\"296\" r=\"64\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"12\"/><path d=\"M256 240 L256 296 L296 296\" stroke=\"$TEAL\" stroke-width=\"12\" stroke-linecap=\"round\"/>"

svg places network-server \
  "<rect x=\"112\" y=\"80\" width=\"288\" height=\"96\" rx=\"12\" fill=\"$DARK\"/><rect x=\"112\" y=\"208\" width=\"288\" height=\"96\" rx=\"12\" fill=\"$DARK\"/><rect x=\"112\" y=\"336\" width=\"288\" height=\"96\" rx=\"12\" fill=\"$DARK\"/><circle cx=\"352\" cy=\"128\" r=\"16\" fill=\"$TEAL\"/><circle cx=\"352\" cy=\"256\" r=\"16\" fill=\"$TEAL\"/><circle cx=\"352\" cy=\"384\" r=\"16\" fill=\"$TEAL\"/><rect x=\"152\" y=\"112\" width=\"120\" height=\"8\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"152\" y=\"240\" width=\"120\" height=\"8\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/><rect x=\"152\" y=\"368\" width=\"120\" height=\"8\" rx=\"4\" fill=\"$TEAL\" opacity=\"0.5\"/>"

svg places start-here \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$DARK\"/><circle cx=\"256\" cy=\"256\" r=\"32\" fill=\"$TEAL\"/><circle cx=\"256\" cy=\"256\" r=\"100\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"12\"/><circle cx=\"256\" cy=\"256\" r=\"168\" fill=\"none\" stroke=\"$TEAL\" stroke-width=\"8\" opacity=\"0.4\"/>"

# ─────────────────────────────────────────────────────────
# Update index.theme with new contexts
# ─────────────────────────────────────────────────────────

NEW_DIRS="$(ls -d "$ICON_DIR"/*/ 2>/dev/null | sed "s|$ICON_DIR/||;s|/$||" | sort | tr '\n' ',' | sed 's/,$//')"
if [ -n "$NEW_DIRS" ]; then
    INDEX="image/files/usr/share/icons/LifeOS/index.theme"
    # Count total icons
    TOTAL=$(find "$ICON_DIR" -name "*.svg" | wc -l)
    echo ""
    echo "=== Summary ==="
    echo "Total SVGs now: $TOTAL"
    echo "Directories: $NEW_DIRS"
fi

echo ""
echo "Done! Run 'gtk-update-icon-cache image/files/usr/share/icons/LifeOS/' to refresh cache."
