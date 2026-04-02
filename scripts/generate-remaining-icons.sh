#!/bin/bash
# Generate ALL remaining freedesktop icons for LifeOS theme
# Continues from generate-missing-icons.sh — fills in every pending icon
set -euo pipefail

ICON_DIR="image/files/usr/share/icons/LifeOS/scalable"
D="#2A2A3E"   # dark
T="#00D4AA"   # teal
R="#CC3333"   # red/error
Y="#FFB800"   # yellow/warning
G="#44CC44"   # green/success
W="white"     # white

COUNT=0
svg() {
    local dir="$1" name="$2" body="$3"
    local path="$ICON_DIR/$dir/$name.svg"
    # [ -f "$path" ] && return 0
    mkdir -p "$ICON_DIR/$dir"
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">\n  %s\n</svg>\n' "$body" > "$path"
    echo "  + $dir/$name"
    COUNT=$((COUNT + 1))
}

echo "=== Generating ALL remaining LifeOS icons ==="

# ═══════════════════════════════════════════════════════════
# ACTIONS — remaining
# ═══════════════════════════════════════════════════════════
echo "[actions — remaining]"

svg actions go-top \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><rect x=\"152\" y=\"132\" width=\"208\" height=\"24\" rx=\"8\" fill=\"$T\"/><path d=\"M256 192 L380 360 L132 360 Z\" fill=\"$T\"/>"

svg actions go-bottom \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><rect x=\"152\" y=\"356\" width=\"208\" height=\"24\" rx=\"8\" fill=\"$T\"/><path d=\"M256 320 L380 152 L132 152 Z\" fill=\"$T\"/>"

svg actions zoom-original \
  "<circle cx=\"224\" cy=\"224\" r=\"140\" fill=\"$D\" stroke=\"$T\" stroke-width=\"20\"/><text x=\"224\" y=\"260\" font-family=\"sans-serif\" font-size=\"120\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">1:1</text><rect x=\"336\" y=\"336\" width=\"112\" height=\"28\" rx=\"8\" fill=\"$T\" transform=\"rotate(45 392 350)\"/>"

svg actions view-sort-ascending \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$D\"/><rect x=\"148\" y=\"128\" width=\"80\" height=\"20\" rx=\"6\" fill=\"$T\"/><rect x=\"148\" y=\"184\" width=\"120\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.8\"/><rect x=\"148\" y=\"240\" width=\"160\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"148\" y=\"296\" width=\"200\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"148\" y=\"352\" width=\"216\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.3\"/>"

svg actions view-sort-descending \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$D\"/><rect x=\"148\" y=\"128\" width=\"216\" height=\"20\" rx=\"6\" fill=\"$T\"/><rect x=\"148\" y=\"184\" width=\"200\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.8\"/><rect x=\"148\" y=\"240\" width=\"160\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"148\" y=\"296\" width=\"120\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"148\" y=\"352\" width=\"80\" height=\"20\" rx=\"6\" fill=\"$T\" opacity=\"0.3\"/>"

svg actions format-justify-right \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$D\"/><rect x=\"176\" y=\"128\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"236\" y=\"184\" width=\"180\" height=\"24\" rx=\"8\" fill=\"$T\" opacity=\"0.7\"/><rect x=\"196\" y=\"240\" width=\"220\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"256\" y=\"296\" width=\"160\" height=\"24\" rx=\"8\" fill=\"$T\" opacity=\"0.7\"/><rect x=\"176\" y=\"352\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$T\"/>"

svg actions format-justify-fill \
  "<rect x=\"96\" y=\"64\" width=\"320\" height=\"384\" rx=\"24\" fill=\"$D\"/><rect x=\"136\" y=\"128\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"136\" y=\"184\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$T\" opacity=\"0.7\"/><rect x=\"136\" y=\"240\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"136\" y=\"296\" width=\"240\" height=\"24\" rx=\"8\" fill=\"$T\" opacity=\"0.7\"/><rect x=\"136\" y=\"352\" width=\"180\" height=\"24\" rx=\"8\" fill=\"$T\"/>"

svg actions media-eject \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M256 128 L380 296 L132 296 Z\" fill=\"$T\"/><rect x=\"148\" y=\"332\" width=\"216\" height=\"40\" rx=\"12\" fill=\"$T\"/>"

svg actions system-suspend \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><circle cx=\"256\" cy=\"200\" r=\"60\" fill=\"$T\" opacity=\"0.8\"/><path d=\"M208 320 L220 280 L292 280 L304 320\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"172\" y=\"340\" width=\"168\" height=\"20\" rx=\"10\" fill=\"$T\" opacity=\"0.3\"/>"

svg actions window-restore \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><rect x=\"160\" y=\"208\" width=\"144\" height=\"144\" rx=\"12\" stroke=\"$T\" stroke-width=\"24\" fill=\"none\"/><rect x=\"208\" y=\"160\" width=\"144\" height=\"144\" rx=\"12\" stroke=\"$T\" stroke-width=\"24\" fill=\"none\" opacity=\"0.6\"/>"

svg actions insert-image \
  "<rect x=\"80\" y=\"112\" width=\"352\" height=\"288\" rx=\"16\" fill=\"$D\"/><circle cx=\"192\" cy=\"208\" r=\"36\" fill=\"$T\" opacity=\"0.6\"/><path d=\"M96 352 L208 256 L304 336 L352 288 L416 368\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/>"

svg actions insert-link \
  "<path d=\"M180 256 A60 60 0 0 1 180 196 L260 196 A60 60 0 0 1 260 256\" fill=\"none\" stroke=\"$T\" stroke-width=\"24\" transform=\"rotate(-45 220 226)\"/><path d=\"M252 256 A60 60 0 0 1 252 316 L332 316 A60 60 0 0 1 332 256\" fill=\"none\" stroke=\"$T\" stroke-width=\"24\" transform=\"rotate(-45 292 286)\"/>"

svg actions contact-new \
  "<circle cx=\"220\" cy=\"180\" r=\"64\" fill=\"$D\"/><path d=\"M128 380 A92 92 0 0 1 312 380\" fill=\"$D\"/><circle cx=\"380\" cy=\"140\" r=\"60\" fill=\"$T\" opacity=\"0.8\"/><rect x=\"368\" y=\"108\" width=\"24\" height=\"64\" rx=\"6\" fill=\"$D\"/><rect x=\"348\" y=\"128\" width=\"64\" height=\"24\" rx=\"6\" fill=\"$D\"/>"

svg actions appointment-new \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$D\"/><rect x=\"96\" y=\"96\" width=\"320\" height=\"64\" rx=\"24\" fill=\"$T\"/><rect x=\"176\" y=\"72\" width=\"24\" height=\"48\" rx=\"8\" fill=\"$T\"/><rect x=\"312\" y=\"72\" width=\"24\" height=\"48\" rx=\"8\" fill=\"$T\"/><text x=\"256\" y=\"330\" font-family=\"sans-serif\" font-size=\"140\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">+</text>"

# COSMIC extras
svg actions application-menu \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$D\"/><rect x=\"152\" y=\"168\" width=\"208\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"152\" y=\"244\" width=\"208\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"152\" y=\"320\" width=\"208\" height=\"24\" rx=\"8\" fill=\"$T\"/>"

svg actions open-menu \
  "<circle cx=\"256\" cy=\"168\" r=\"24\" fill=\"$T\"/><circle cx=\"256\" cy=\"256\" r=\"24\" fill=\"$T\"/><circle cx=\"256\" cy=\"344\" r=\"24\" fill=\"$T\"/>"

svg actions view-more \
  "<circle cx=\"168\" cy=\"256\" r=\"24\" fill=\"$T\"/><circle cx=\"256\" cy=\"256\" r=\"24\" fill=\"$T\"/><circle cx=\"344\" cy=\"256\" r=\"24\" fill=\"$T\"/>"

svg actions view-more-horizontal \
  "<circle cx=\"168\" cy=\"256\" r=\"24\" fill=\"$T\"/><circle cx=\"256\" cy=\"256\" r=\"24\" fill=\"$T\"/><circle cx=\"344\" cy=\"256\" r=\"24\" fill=\"$T\"/>"

svg actions pan-down \
  "<path d=\"M256 360 L380 200 L132 200 Z\" fill=\"$T\"/>"

svg actions pan-up \
  "<path d=\"M256 152 L380 312 L132 312 Z\" fill=\"$T\"/>"

svg actions pan-start \
  "<path d=\"M152 256 L312 132 L312 380 Z\" fill=\"$T\"/>"

svg actions pan-end \
  "<path d=\"M360 256 L200 132 L200 380 Z\" fill=\"$T\"/>"

svg actions pin \
  "<circle cx=\"256\" cy=\"180\" r=\"80\" fill=\"$D\"/><circle cx=\"256\" cy=\"180\" r=\"28\" fill=\"$T\"/><rect x=\"244\" y=\"260\" width=\"24\" height=\"120\" rx=\"4\" fill=\"$T\"/><circle cx=\"256\" cy=\"400\" r=\"16\" fill=\"$T\"/>"

svg actions window-pop-out \
  "<rect x=\"80\" y=\"80\" width=\"256\" height=\"256\" rx=\"16\" fill=\"$D\" stroke=\"$T\" stroke-width=\"12\"/><path d=\"M320 112 L416 112 L416 208\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M416 112 L288 240\" stroke=\"$T\" stroke-width=\"16\" stroke-linecap=\"round\"/>"

svg actions grip-lines \
  "<rect x=\"144\" y=\"144\" width=\"224\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"144\" y=\"200\" width=\"224\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"144\" y=\"256\" width=\"224\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"144\" y=\"312\" width=\"224\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"144\" y=\"368\" width=\"224\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/>"

svg actions notification-alert \
  "<path d=\"M256 80 A120 120 0 0 1 376 200 L376 320 L416 368 L96 368 L136 320 L136 200 A120 120 0 0 1 256 80\" fill=\"$Y\"/><rect x=\"236\" y=\"140\" width=\"40\" height=\"120\" rx=\"12\" fill=\"$D\"/><circle cx=\"256\" cy=\"312\" r=\"20\" fill=\"$D\"/><circle cx=\"256\" cy=\"416\" r=\"32\" fill=\"$Y\"/>"

# ═══════════════════════════════════════════════════════════
# APPS — system, preferences, COSMIC, popular
# ═══════════════════════════════════════════════════════════
echo "[apps — system & preferences]"

svg apps accessories-calculator \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"24\" fill=\"$D\"/><rect x=\"136\" y=\"80\" width=\"240\" height=\"80\" rx=\"8\" fill=\"$T\" opacity=\"0.3\"/><rect x=\"148\" y=\"192\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"220\" y=\"192\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"292\" y=\"192\" width=\"72\" height=\"48\" rx=\"8\" fill=\"$T\"/><rect x=\"148\" y=\"264\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"220\" y=\"264\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"292\" y=\"264\" width=\"72\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"148\" y=\"336\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"220\" y=\"336\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"292\" y=\"336\" width=\"72\" height=\"120\" rx=\"8\" fill=\"$T\"/><rect x=\"148\" y=\"408\" width=\"120\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/>"

svg apps accessories-screenshot-tool \
  "<rect x=\"64\" y=\"64\" width=\"384\" height=\"320\" rx=\"16\" fill=\"$D\"/><rect x=\"88\" y=\"88\" width=\"336\" height=\"272\" rx=\"8\" fill=\"$T\" opacity=\"0.15\"/><rect x=\"80\" y=\"352\" width=\"120\" height=\"120\" rx=\"8\" fill=\"$T\" stroke=\"$D\" stroke-width=\"8\"/><path d=\"M124 352 L80 288\" stroke=\"$T\" stroke-width=\"4\" stroke-dasharray=\"8 4\"/><path d=\"M200 352 L200 288\" stroke=\"$T\" stroke-width=\"4\" stroke-dasharray=\"8 4\"/>"

svg apps help-browser \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"sans-serif\" font-size=\"240\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">?</text>"

svg apps multimedia-volume-control \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><rect x=\"152\" y=\"224\" width=\"64\" height=\"64\" rx=\"8\" fill=\"$T\"/><path d=\"M216 200 L296 152 L296 360 L216 312 Z\" fill=\"$T\"/><path d=\"M328 192 A80 80 0 0 1 328 320\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/><path d=\"M360 152 A120 120 0 0 1 360 360\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\" opacity=\"0.5\"/>"

svg apps system-software-install \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$D\"/><path d=\"M256 152 L256 340\" stroke=\"$T\" stroke-width=\"32\" stroke-linecap=\"round\"/><path d=\"M192 280 L256 348 L320 280\" fill=\"none\" stroke=\"$T\" stroke-width=\"32\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg apps system-software-update \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M200 200 A80 80 0 1 1 200 312\" fill=\"none\" stroke=\"$T\" stroke-width=\"24\"/><path d=\"M200 184 L168 224 L232 224 Z\" fill=\"$T\"/>"

svg apps utilities-system-monitor \
  "<rect x=\"64\" y=\"64\" width=\"384\" height=\"384\" rx=\"24\" fill=\"$D\"/><path d=\"M120 360 L200 280 L260 320 L340 160 L400 240\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/><path d=\"M120 360 L200 280 L260 320 L340 160 L400 240 L400 360 Z\" fill=\"$T\" opacity=\"0.15\"/>"

# Preferences
svg apps preferences-desktop-accessibility \
  "<circle cx=\"256\" cy=\"152\" r=\"48\" fill=\"$T\"/><rect x=\"240\" y=\"200\" width=\"32\" height=\"160\" rx=\"8\" fill=\"$T\"/><path d=\"M160 240 L352 240\" stroke=\"$T\" stroke-width=\"24\" stroke-linecap=\"round\"/><path d=\"M208 360 L240 440\" stroke=\"$T\" stroke-width=\"24\" stroke-linecap=\"round\"/><path d=\"M304 360 L272 440\" stroke=\"$T\" stroke-width=\"24\" stroke-linecap=\"round\"/>"

svg apps preferences-desktop-font \
  "<rect x=\"80\" y=\"64\" width=\"352\" height=\"384\" rx=\"24\" fill=\"$D\"/><text x=\"256\" y=\"340\" font-family=\"serif\" font-size=\"280\" fill=\"$T\" text-anchor=\"middle\">A</text>"

svg apps preferences-desktop-keyboard \
  "<rect x=\"48\" y=\"144\" width=\"416\" height=\"224\" rx=\"24\" fill=\"$D\"/><rect x=\"88\" y=\"176\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"144\" y=\"176\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"200\" y=\"176\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"256\" y=\"176\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"312\" y=\"176\" width=\"40\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"368\" y=\"176\" width=\"56\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"104\" y=\"228\" width=\"56\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"176\" y=\"228\" width=\"168\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"360\" y=\"228\" width=\"56\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"120\" y=\"280\" width=\"280\" height=\"32\" rx=\"4\" fill=\"$T\" opacity=\"0.3\"/>"

svg apps preferences-desktop-wallpaper \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"280\" rx=\"16\" fill=\"$D\"/><circle cx=\"192\" cy=\"176\" r=\"36\" fill=\"$T\" opacity=\"0.6\"/><path d=\"M96 312 L208 232 L304 300 L352 260 L416 320\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\"/><rect x=\"176\" y=\"376\" width=\"160\" height=\"16\" rx=\"8\" fill=\"$D\"/>"

svg apps preferences-desktop-theme \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M256 56 A200 200 0 0 1 256 456\" fill=\"$T\" opacity=\"0.6\"/><circle cx=\"200\" cy=\"200\" r=\"32\" fill=\"$T\"/><circle cx=\"312\" cy=\"200\" r=\"32\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\"/>"

# COSMIC Settings icons
svg apps preferences-about \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><text x=\"256\" y=\"300\" font-family=\"sans-serif\" font-size=\"200\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">i</text>"

svg apps preferences-appearance \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$D\"/><circle cx=\"200\" cy=\"200\" r=\"48\" fill=\"$T\"/><circle cx=\"320\" cy=\"200\" r=\"48\" fill=\"$T\" opacity=\"0.6\"/><circle cx=\"200\" cy=\"320\" r=\"48\" fill=\"$T\" opacity=\"0.4\"/><circle cx=\"320\" cy=\"320\" r=\"48\" fill=\"$T\" opacity=\"0.2\"/>"

svg apps preferences-dock \
  "<rect x=\"64\" y=\"64\" width=\"384\" height=\"384\" rx=\"16\" fill=\"$D\" opacity=\"0.3\"/><rect x=\"112\" y=\"360\" width=\"288\" height=\"64\" rx=\"32\" fill=\"$D\"/><circle cx=\"192\" cy=\"392\" r=\"16\" fill=\"$T\"/><circle cx=\"256\" cy=\"392\" r=\"16\" fill=\"$T\"/><circle cx=\"320\" cy=\"392\" r=\"16\" fill=\"$T\"/>"

svg apps preferences-panel \
  "<rect x=\"64\" y=\"64\" width=\"384\" height=\"384\" rx=\"16\" fill=\"$D\" opacity=\"0.3\"/><rect x=\"64\" y=\"64\" width=\"384\" height=\"48\" rx=\"16\" fill=\"$D\"/><circle cx=\"112\" cy=\"88\" r=\"12\" fill=\"$T\"/><rect x=\"200\" y=\"76\" width=\"100\" height=\"24\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><circle cx=\"400\" cy=\"88\" r=\"12\" fill=\"$T\" opacity=\"0.5\"/>"

svg apps preferences-power-and-battery \
  "<rect x=\"96\" y=\"160\" width=\"288\" height=\"192\" rx=\"24\" fill=\"$D\"/><rect x=\"384\" y=\"216\" width=\"32\" height=\"80\" rx=\"12\" fill=\"$D\"/><rect x=\"120\" y=\"184\" width=\"160\" height=\"144\" rx=\"12\" fill=\"$T\" opacity=\"0.6\"/><path d=\"M296 196 L268 256 L304 256 L276 340\" fill=\"none\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg apps preferences-displays \
  "<rect x=\"56\" y=\"80\" width=\"256\" height=\"192\" rx=\"12\" fill=\"$D\"/><rect x=\"72\" y=\"96\" width=\"224\" height=\"160\" rx=\"8\" fill=\"$T\" opacity=\"0.2\"/><rect x=\"200\" y=\"176\" width=\"256\" height=\"192\" rx=\"12\" fill=\"$D\"/><rect x=\"216\" y=\"192\" width=\"224\" height=\"160\" rx=\"8\" fill=\"$T\" opacity=\"0.3\"/>"

svg apps preferences-sound \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><rect x=\"144\" y=\"224\" width=\"56\" height=\"64\" rx=\"8\" fill=\"$T\"/><path d=\"M200 200 L280 148 L280 364 L200 312 Z\" fill=\"$T\"/><path d=\"M316 192 A80 80 0 0 1 316 320\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/><path d=\"M348 152 A120 120 0 0 1 348 360\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\" opacity=\"0.5\"/>"

svg apps preferences-bluetooth \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M224 160 L320 256 L224 352\" fill=\"none\" stroke=\"$T\" stroke-width=\"24\" stroke-linejoin=\"round\"/><path d=\"M224 160 L224 352\" stroke=\"$T\" stroke-width=\"24\"/><path d=\"M160 192 L320 320 M160 320 L320 192\" stroke=\"$T\" stroke-width=\"12\" opacity=\"0.4\"/>"

svg apps preferences-network-and-wireless \
  "<circle cx=\"256\" cy=\"380\" r=\"24\" fill=\"$T\"/><path d=\"M176 300 A100 100 0 0 1 336 300\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M120 232 A170 170 0 0 1 392 232\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M72 164 A240 240 0 0 1 440 164\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\"/>"

svg apps preferences-workspaces \
  "<rect x=\"80\" y=\"80\" width=\"152\" height=\"152\" rx=\"12\" fill=\"$T\" opacity=\"0.8\"/><rect x=\"280\" y=\"80\" width=\"152\" height=\"152\" rx=\"12\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\"/><rect x=\"80\" y=\"280\" width=\"152\" height=\"152\" rx=\"12\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\"/><rect x=\"280\" y=\"280\" width=\"152\" height=\"152\" rx=\"12\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\"/>"

# Popular apps
svg apps vlc \
  "<path d=\"M256 64 L400 400 L112 400 Z\" fill=\"$Y\"/><path d=\"M256 128 L360 376 L152 376 Z\" fill=\"$D\" opacity=\"0.3\"/>"

svg apps obs-studio \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><circle cx=\"256\" cy=\"256\" r=\"120\" fill=\"none\" stroke=\"$T\" stroke-width=\"24\"/><circle cx=\"256\" cy=\"256\" r=\"40\" fill=\"$R\"/>"

svg apps inkscape \
  "<path d=\"M256 80 L320 320 L256 280 L192 320 Z\" fill=\"$T\"/><ellipse cx=\"256\" cy=\"400\" rx=\"140\" ry=\"32\" fill=\"$D\"/>"

svg apps blender \
  "<circle cx=\"280\" cy=\"260\" r=\"120\" fill=\"$D\" stroke=\"$T\" stroke-width=\"16\"/><circle cx=\"280\" cy=\"260\" r=\"40\" fill=\"$T\" opacity=\"0.5\"/><circle cx=\"160\" cy=\"200\" r=\"48\" fill=\"$T\"/>"

svg apps krita \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><circle cx=\"200\" cy=\"200\" r=\"56\" fill=\"$T\" opacity=\"0.8\"/><circle cx=\"312\" cy=\"200\" r=\"56\" fill=\"#FF6B6B\" opacity=\"0.6\"/><circle cx=\"256\" cy=\"300\" r=\"56\" fill=\"$Y\" opacity=\"0.6\"/>"

svg apps godot \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><circle cx=\"200\" cy=\"200\" r=\"40\" fill=\"$T\"/><circle cx=\"312\" cy=\"200\" r=\"40\" fill=\"$T\"/><path d=\"M200 312 Q256 368 312 312\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\" stroke-linecap=\"round\"/>"

svg apps lutris \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M200 160 L200 352 L340 256 Z\" fill=\"$T\"/>"

svg apps heroic \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$D\"/><text x=\"256\" y=\"310\" font-family=\"sans-serif\" font-size=\"200\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">H</text>"

svg apps bottles \
  "<rect x=\"192\" y=\"64\" width=\"128\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"176\" y=\"112\" width=\"160\" height=\"336\" rx=\"24\" fill=\"$D\"/><rect x=\"200\" y=\"240\" width=\"112\" height=\"176\" rx=\"12\" fill=\"$T\" opacity=\"0.3\"/>"

svg apps element \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><circle cx=\"200\" cy=\"200\" r=\"32\" fill=\"$T\"/><circle cx=\"312\" cy=\"312\" r=\"32\" fill=\"$T\"/><path d=\"M200 256 A56 56 0 0 1 256 200\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/><path d=\"M312 256 A56 56 0 0 1 256 312\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/>"

svg apps signal \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M168 256 Q168 152 256 152 Q344 152 344 256 Q344 360 256 360 L200 408 L216 344 Q168 328 168 256\" fill=\"$T\"/>"

# ═══════════════════════════════════════════════════════════
# STATUS — remaining
# ═══════════════════════════════════════════════════════════
echo "[status — remaining]"

svg status audio-volume-overamplified \
  "<rect x=\"96\" y=\"224\" width=\"56\" height=\"64\" rx=\"8\" fill=\"$T\"/><path d=\"M152\" y=\"200\" L232 148 L232 364 L152 312 Z\" fill=\"$T\"/><path d=\"M264 192 A80 80 0 0 1 264 320\" fill=\"none\" stroke=\"$R\" stroke-width=\"16\"/><path d=\"M296 152 A120 120 0 0 1 296 360\" fill=\"none\" stroke=\"$R\" stroke-width=\"16\"/><path d=\"M328 112 A160 160 0 0 1 328 400\" fill=\"none\" stroke=\"$R\" stroke-width=\"12\"/>"

svg status battery-good \
  "<rect x=\"80\" y=\"160\" width=\"320\" height=\"192\" rx=\"24\" fill=\"$D\"/><rect x=\"400\" y=\"216\" width=\"32\" height=\"80\" rx=\"12\" fill=\"$D\"/><rect x=\"104\" y=\"184\" width=\"240\" height=\"144\" rx=\"12\" fill=\"$G\"/>"

svg status bluetooth-active \
  "<circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"$D\"/><path d=\"M224 168 L312 256 L224 344\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linejoin=\"round\"/><path d=\"M224 168 L224 344\" stroke=\"$T\" stroke-width=\"20\"/>"

svg status bluetooth-disabled \
  "<circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"$D\" opacity=\"0.5\"/><path d=\"M224 168 L312 256 L224 344\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linejoin=\"round\" opacity=\"0.3\"/><path d=\"M224 168 L224 344\" stroke=\"$T\" stroke-width=\"20\" opacity=\"0.3\"/><line x1=\"140\" y1=\"140\" x2=\"372\" y2=\"372\" stroke=\"$R\" stroke-width=\"24\" stroke-linecap=\"round\"/>"

svg status display-brightness-high \
  "<circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"$Y\"/><line x1=\"256\" y1=\"80\" x2=\"256\" y2=\"128\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"256\" y1=\"384\" x2=\"256\" y2=\"432\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"80\" y1=\"256\" x2=\"128\" y2=\"256\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"384\" y1=\"256\" x2=\"432\" y2=\"256\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"132\" y1=\"132\" x2=\"164\" y2=\"164\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"348\" y1=\"348\" x2=\"380\" y2=\"380\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"380\" y1=\"132\" x2=\"348\" y2=\"164\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/><line x1=\"132\" y1=\"380\" x2=\"164\" y2=\"348\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\"/>"

svg status display-brightness-medium \
  "<circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"$Y\" opacity=\"0.6\"/><line x1=\"256\" y1=\"104\" x2=\"256\" y2=\"140\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\" opacity=\"0.6\"/><line x1=\"256\" y1=\"372\" x2=\"256\" y2=\"408\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\" opacity=\"0.6\"/><line x1=\"104\" y1=\"256\" x2=\"140\" y2=\"256\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\" opacity=\"0.6\"/><line x1=\"372\" y1=\"256\" x2=\"408\" y2=\"256\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\" opacity=\"0.6\"/>"

svg status display-brightness-low \
  "<circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"$Y\" opacity=\"0.3\"/><circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"none\" stroke=\"$Y\" stroke-width=\"8\" opacity=\"0.5\"/>"

svg status microphone-sensitivity-high \
  "<rect x=\"200\" y=\"80\" width=\"112\" height=\"200\" rx=\"56\" fill=\"$T\"/><path d=\"M168 260 A88 88 0 0 0 344 260\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/><rect x=\"248\" y=\"340\" width=\"16\" height=\"56\" fill=\"$T\"/><rect x=\"208\" y=\"388\" width=\"96\" height=\"16\" rx=\"8\" fill=\"$T\"/>"

svg status microphone-sensitivity-muted \
  "<rect x=\"200\" y=\"80\" width=\"112\" height=\"200\" rx=\"56\" fill=\"$D\" opacity=\"0.5\"/><path d=\"M168 260 A88 88 0 0 0 344 260\" fill=\"none\" stroke=\"$D\" stroke-width=\"16\" opacity=\"0.3\"/><line x1=\"140\" y1=\"140\" x2=\"372\" y2=\"372\" stroke=\"$R\" stroke-width=\"24\" stroke-linecap=\"round\"/>"

# Weather icons
svg status weather-clear \
  "<circle cx=\"256\" cy=\"256\" r=\"96\" fill=\"$Y\"/><line x1=\"256\" y1=\"80\" x2=\"256\" y2=\"112\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"256\" y1=\"400\" x2=\"256\" y2=\"432\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"80\" y1=\"256\" x2=\"112\" y2=\"256\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"400\" y1=\"256\" x2=\"432\" y2=\"256\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"132\" y1=\"132\" x2=\"156\" y2=\"156\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"356\" y1=\"356\" x2=\"380\" y2=\"380\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"380\" y1=\"132\" x2=\"356\" y2=\"156\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/><line x1=\"132\" y1=\"380\" x2=\"156\" y2=\"356\" stroke=\"$Y\" stroke-width=\"16\" stroke-linecap=\"round\"/>"

svg status weather-clear-night \
  "<path d=\"M280 96 A160 160 0 1 0 416 232 A120 120 0 0 1 280 96\" fill=\"$Y\" opacity=\"0.7\"/>"

svg status weather-few-clouds \
  "<circle cx=\"200\" cy=\"200\" r=\"72\" fill=\"$Y\"/><ellipse cx=\"280\" cy=\"320\" rx=\"140\" ry=\"80\" fill=\"$D\"/><ellipse cx=\"220\" cy=\"296\" rx=\"80\" ry=\"56\" fill=\"$D\"/>"

svg status weather-overcast \
  "<ellipse cx=\"280\" cy=\"280\" rx=\"160\" ry=\"96\" fill=\"$D\"/><ellipse cx=\"200\" cy=\"260\" rx=\"100\" ry=\"64\" fill=\"$D\"/><ellipse cx=\"340\" cy=\"248\" rx=\"80\" ry=\"56\" fill=\"$D\"/>"

svg status weather-showers \
  "<ellipse cx=\"256\" cy=\"200\" rx=\"160\" ry=\"96\" fill=\"$D\"/><line x1=\"192\" y1=\"320\" x2=\"176\" y2=\"384\" stroke=\"$T\" stroke-width=\"12\" stroke-linecap=\"round\"/><line x1=\"256\" y1=\"320\" x2=\"240\" y2=\"400\" stroke=\"$T\" stroke-width=\"12\" stroke-linecap=\"round\"/><line x1=\"320\" y1=\"320\" x2=\"304\" y2=\"384\" stroke=\"$T\" stroke-width=\"12\" stroke-linecap=\"round\"/>"

svg status weather-snow \
  "<ellipse cx=\"256\" cy=\"200\" rx=\"160\" ry=\"96\" fill=\"$D\"/><circle cx=\"192\" cy=\"340\" r=\"12\" fill=\"$W\"/><circle cx=\"256\" cy=\"360\" r=\"12\" fill=\"$W\"/><circle cx=\"320\" cy=\"332\" r=\"12\" fill=\"$W\"/><circle cx=\"224\" cy=\"400\" r=\"12\" fill=\"$W\"/><circle cx=\"288\" cy=\"412\" r=\"12\" fill=\"$W\"/>"

svg status weather-storm \
  "<ellipse cx=\"256\" cy=\"180\" rx=\"160\" ry=\"96\" fill=\"$D\"/><path d=\"M272 280 L240 340 L280 340 L248 420\" fill=\"none\" stroke=\"$Y\" stroke-width=\"20\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg status airplane-mode \
  "<path d=\"M256 80 L280 200 L420 280 L420 312 L280 272 L280 380 L328 416 L328 440 L256 416 L184 440 L184 416 L232 380 L232 272 L92 312 L92 280 L232 200 Z\" fill=\"$T\"/>"

svg status airplane-mode-disabled \
  "<path d=\"M256 80 L280 200 L420 280 L420 312 L280 272 L280 380 L328 416 L328 440 L256 416 L184 440 L184 416 L232 380 L232 272 L92 312 L92 280 L232 200 Z\" fill=\"$D\" opacity=\"0.4\"/><line x1=\"120\" y1=\"120\" x2=\"392\" y2=\"392\" stroke=\"$R\" stroke-width=\"28\" stroke-linecap=\"round\"/>"

svg status checkbox-checked \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"32\" fill=\"$T\"/><path d=\"M176 256 L232 320 L352 192\" fill=\"none\" stroke=\"$W\" stroke-width=\"36\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

svg status checkbox-mixed \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"32\" fill=\"$T\"/><rect x=\"176\" y=\"240\" width=\"160\" height=\"32\" rx=\"12\" fill=\"$W\"/>"

svg status radio-checked \
  "<circle cx=\"256\" cy=\"256\" r=\"160\" fill=\"$T\"/><circle cx=\"256\" cy=\"256\" r=\"64\" fill=\"$W\"/>"

# ═══════════════════════════════════════════════════════════
# PLACES — remaining
# ═══════════════════════════════════════════════════════════
echo "[places — remaining]"

svg places folder-publicshare \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$D\"/><path d=\"M80 160 L432 160\" stroke=\"$T\" stroke-width=\"8\"/><circle cx=\"256\" cy=\"260\" r=\"24\" fill=\"$T\"/><circle cx=\"192\" cy=\"340\" r=\"24\" fill=\"$T\"/><circle cx=\"320\" cy=\"340\" r=\"24\" fill=\"$T\"/><line x1=\"244\" y1=\"280\" x2=\"204\" y2=\"324\" stroke=\"$T\" stroke-width=\"8\"/><line x1=\"268\" y1=\"280\" x2=\"308\" y2=\"324\" stroke=\"$T\" stroke-width=\"8\"/>"

svg places folder-saved-search \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$D\"/><path d=\"M80 160 L432 160\" stroke=\"$T\" stroke-width=\"8\"/><circle cx=\"236\" cy=\"276\" r=\"56\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\"/><rect x=\"280\" y=\"316\" width=\"64\" height=\"16\" rx=\"4\" fill=\"$T\" transform=\"rotate(45 312 324)\"/>"

svg places user-desktop \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"256\" rx=\"16\" fill=\"$D\"/><rect x=\"104\" y=\"104\" width=\"304\" height=\"208\" rx=\"8\" fill=\"$T\" opacity=\"0.2\"/><rect x=\"192\" y=\"352\" width=\"128\" height=\"24\" rx=\"4\" fill=\"$D\"/><rect x=\"160\" y=\"376\" width=\"192\" height=\"16\" rx=\"8\" fill=\"$D\"/>"

svg places user-bookmarks \
  "<path d=\"M128 64 L384 64 L384 448 L256 352 L128 448 Z\" fill=\"$D\"/><path d=\"M128 64 L384 64 L384 448 L256 352 L128 448 Z\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\"/><circle cx=\"256\" cy=\"200\" r=\"40\" fill=\"$T\" opacity=\"0.5\"/>"

# ═══════════════════════════════════════════════════════════
# MIMETYPES — remaining
# ═══════════════════════════════════════════════════════════
echo "[mimetypes — remaining]"

svg mimetypes text-x-python \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"180\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">Py</text>"

svg mimetypes text-x-csrc \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"200\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">C</text>"

svg mimetypes text-x-java \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"140\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">Java</text>"

svg mimetypes text-x-rust \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"180\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">Rs</text>"

svg mimetypes text-css \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"140\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">CSS</text>"

svg mimetypes text-markdown \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"140\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">MD</text>"

svg mimetypes application-javascript \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"180\" font-weight=\"bold\" fill=\"$Y\" text-anchor=\"middle\">JS</text>"

svg mimetypes application-x-shellscript \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"320\" font-family=\"monospace\" font-size=\"140\" font-weight=\"bold\" fill=\"$G\" text-anchor=\"middle\">SH</text>"

svg mimetypes image-jpeg \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><circle cx=\"216\" cy=\"176\" r=\"36\" fill=\"$T\" opacity=\"0.6\"/><path d=\"M128 336 L220 256 L296 320 L340 280 L384 328\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\"/><text x=\"256\" y=\"428\" font-family=\"monospace\" font-size=\"48\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">JPG</text>"

svg mimetypes audio-mpeg \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><circle cx=\"256\" cy=\"280\" r=\"80\" fill=\"$T\" opacity=\"0.3\"/><rect x=\"244\" y=\"140\" width=\"24\" height=\"220\" rx=\"4\" fill=\"$T\"/><text x=\"256\" y=\"428\" font-family=\"monospace\" font-size=\"48\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">MP3</text>"

svg mimetypes video-mp4 \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><path d=\"M208 180 L340 256 L208 332 Z\" fill=\"$T\"/><text x=\"256\" y=\"428\" font-family=\"monospace\" font-size=\"48\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">MP4</text>"

svg mimetypes application-xml \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"300\" font-family=\"monospace\" font-size=\"120\" fill=\"$T\" text-anchor=\"middle\">&lt;/&gt;</text>"

svg mimetypes application-zip \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><rect x=\"240\" y=\"48\" width=\"32\" height=\"416\" fill=\"$T\" opacity=\"0.2\"/><rect x=\"240\" y=\"80\" width=\"32\" height=\"32\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"240\" y=\"144\" width=\"32\" height=\"32\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"240\" y=\"208\" width=\"32\" height=\"32\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"224\" y=\"296\" width=\"64\" height=\"48\" rx=\"8\" fill=\"$T\" opacity=\"0.6\"/>"

svg mimetypes application-x-compressed-tar \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"300\" font-family=\"monospace\" font-size=\"80\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">tar.gz</text>"

svg mimetypes font-x-generic \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"330\" font-family=\"serif\" font-size=\"260\" fill=\"$T\" text-anchor=\"middle\">A</text>"

svg mimetypes package-x-generic \
  "<rect x=\"96\" y=\"128\" width=\"320\" height=\"288\" rx=\"16\" fill=\"$D\"/><path d=\"M256 128 L416 208 L256 288 L96 208 Z\" fill=\"$T\" opacity=\"0.5\"/><path d=\"M256 288 L256 416\" stroke=\"$T\" stroke-width=\"8\"/><path d=\"M256 288 L416 208\" stroke=\"$T\" stroke-width=\"8\"/>"

svg mimetypes text-x-generic \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><rect x=\"160\" y=\"120\" width=\"192\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"160\" y=\"156\" width=\"160\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"160\" y=\"192\" width=\"192\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"160\" y=\"228\" width=\"140\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.3\"/><rect x=\"160\" y=\"264\" width=\"192\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.5\"/>"

svg mimetypes inode-directory \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$D\"/><path d=\"M80 160 L432 160\" stroke=\"$T\" stroke-width=\"8\"/>"

# ═══════════════════════════════════════════════════════════
# CATEGORIES — remaining
# ═══════════════════════════════════════════════════════════
echo "[categories — remaining]"

svg categories applications-accessories \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$D\"/><circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\"/><circle cx=\"256\" cy=\"256\" r=\"24\" fill=\"$T\"/><rect x=\"244\" y=\"100\" width=\"24\" height=\"56\" rx=\"8\" fill=\"$T\"/><rect x=\"244\" y=\"356\" width=\"24\" height=\"56\" rx=\"8\" fill=\"$T\"/><rect x=\"100\" y=\"244\" width=\"56\" height=\"24\" rx=\"8\" fill=\"$T\"/><rect x=\"356\" y=\"244\" width=\"56\" height=\"24\" rx=\"8\" fill=\"$T\"/>"

svg categories applications-graphics \
  "<rect x=\"80\" y=\"80\" width=\"352\" height=\"352\" rx=\"24\" fill=\"$D\"/><circle cx=\"256\" cy=\"220\" r=\"64\" fill=\"$T\" opacity=\"0.6\"/><path d=\"M160 380 L256 260 L300 320 L352 280 L400 380\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\"/>"

svg categories applications-office \
  "<rect x=\"112\" y=\"64\" width=\"288\" height=\"384\" rx=\"16\" fill=\"$D\"/><rect x=\"152\" y=\"120\" width=\"208\" height=\"16\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"152\" y=\"160\" width=\"160\" height=\"16\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"152\" y=\"200\" width=\"208\" height=\"16\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"152\" y=\"240\" width=\"140\" height=\"16\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"152\" y=\"280\" width=\"208\" height=\"16\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/>"

svg categories applications-science \
  "<path d=\"M200 80 L200 240 L96 416 L416 416 L312 240 L312 80\" fill=\"$D\"/><rect x=\"184\" y=\"64\" width=\"144\" height=\"24\" rx=\"8\" fill=\"$T\"/><ellipse cx=\"256\" cy=\"376\" rx=\"120\" ry=\"40\" fill=\"$T\" opacity=\"0.4\"/><circle cx=\"220\" cy=\"360\" r=\"16\" fill=\"$T\"/><circle cx=\"280\" cy=\"380\" r=\"12\" fill=\"$T\" opacity=\"0.7\"/>"

svg categories applications-engineering \
  "<circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"$D\"/><circle cx=\"256\" cy=\"256\" r=\"80\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\"/><circle cx=\"256\" cy=\"256\" r=\"24\" fill=\"$T\"/><rect x=\"232\" y=\"76\" width=\"48\" height=\"56\" rx=\"8\" fill=\"$D\"/><rect x=\"232\" y=\"380\" width=\"48\" height=\"56\" rx=\"8\" fill=\"$D\"/><rect x=\"76\" y=\"232\" width=\"56\" height=\"48\" rx=\"8\" fill=\"$D\"/><rect x=\"380\" y=\"232\" width=\"56\" height=\"48\" rx=\"8\" fill=\"$D\"/><rect x=\"244\" y=\"64\" width=\"24\" height=\"80\" rx=\"6\" fill=\"$T\"/><rect x=\"244\" y=\"368\" width=\"24\" height=\"80\" rx=\"6\" fill=\"$T\"/><rect x=\"64\" y=\"244\" width=\"80\" height=\"24\" rx=\"6\" fill=\"$T\"/><rect x=\"368\" y=\"244\" width=\"80\" height=\"24\" rx=\"6\" fill=\"$T\"/>"

svg categories applications-other \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"24\" fill=\"$D\"/><circle cx=\"200\" cy=\"200\" r=\"36\" fill=\"$T\" opacity=\"0.6\"/><circle cx=\"312\" cy=\"200\" r=\"36\" fill=\"$T\" opacity=\"0.4\"/><circle cx=\"200\" cy=\"312\" r=\"36\" fill=\"$T\" opacity=\"0.4\"/><circle cx=\"312\" cy=\"312\" r=\"36\" fill=\"$T\" opacity=\"0.6\"/>"

echo ""
TOTAL=$(find "$ICON_DIR" -name "*.svg" | wc -l)
echo "=== COMPLETE ==="
echo "New icons generated: $COUNT"
echo "Total SVGs in theme: $TOTAL"
echo "Contexts: $(ls -d "$ICON_DIR"/*/ | sed "s|$ICON_DIR/||;s|/$||" | tr '\n' ', ')"
