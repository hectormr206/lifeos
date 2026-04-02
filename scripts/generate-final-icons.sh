#!/bin/bash
# Generate FINAL remaining freedesktop icons — brand-compliant colors
set -euo pipefail

ICON_DIR="image/files/usr/share/icons/LifeOS/scalable"
# LifeOS Brand Palette (official)
D="#2A2A3E"       # Icon Body Body (OBLIGATORIO para visibilidad sobre fondo #161830)
BG="#0F0F1B"      # Noche Profunda (darkest bg)
T="#00D4AA"       # Teal Axi (primary accent)
R="#FF6B9D"       # Rosa Axi (destructive/error)
Y="#F0C420"       # Amarillo Alerta (warning)
G="#2ECC71"       # Success green
B="#3282B8"       # Azul LifeOS (info/links)
P="#5E26CC"       # Purpura Profundo (night/premium)
TXT="#E8E8E8"     # Blanco Suave (primary text)

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

echo "=== Generating FINAL remaining LifeOS icons (brand-compliant) ==="

# ─── ACTIONS remaining ───
echo "[actions]"

svg actions help-contents \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><text x=\"256\" y=\"280\" font-family=\"sans-serif\" font-size=\"200\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">?</text><rect x=\"232\" y=\"320\" width=\"48\" height=\"48\" rx=\"8\" fill=\"$T\"/>"

svg actions address-book-new \
  "<rect x=\"96\" y=\"64\" width=\"288\" height=\"384\" rx=\"16\" fill=\"$D\"/><circle cx=\"240\" cy=\"200\" r=\"48\" fill=\"$T\" opacity=\"0.5\"/><path d=\"M176 340 A64 64 0 0 1 304 340\" fill=\"$T\" opacity=\"0.4\"/><circle cx=\"380\" cy=\"120\" r=\"48\" fill=\"$T\" opacity=\"0.8\"/><rect x=\"368\" y=\"96\" width=\"24\" height=\"48\" rx=\"4\" fill=\"$D\"/><rect x=\"356\" y=\"108\" width=\"48\" height=\"24\" rx=\"4\" fill=\"$D\"/><rect x=\"80\" y=\"160\" width=\"16\" height=\"40\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"80\" y=\"240\" width=\"16\" height=\"40\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"80\" y=\"320\" width=\"16\" height=\"40\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/>"

svg actions window-stack \
  "<rect x=\"160\" y=\"160\" width=\"272\" height=\"272\" rx=\"16\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\"/><rect x=\"120\" y=\"120\" width=\"272\" height=\"272\" rx=\"16\" fill=\"none\" stroke=\"$T\" stroke-width=\"6\" opacity=\"0.5\"/><rect x=\"80\" y=\"80\" width=\"272\" height=\"272\" rx=\"16\" fill=\"none\" stroke=\"$T\" stroke-width=\"4\" opacity=\"0.25\"/>"

svg actions focus-windows \
  "<rect x=\"80\" y=\"80\" width=\"200\" height=\"200\" rx=\"12\" fill=\"$D\" stroke=\"$T\" stroke-width=\"12\"/><rect x=\"232\" y=\"232\" width=\"200\" height=\"200\" rx=\"12\" fill=\"$D\" stroke=\"$T\" stroke-width=\"6\" opacity=\"0.4\"/>"

# ─── APPS remaining ───
echo "[apps]"

svg apps celluloid \
  "<rect x=\"80\" y=\"96\" width=\"352\" height=\"320\" rx=\"16\" fill=\"$D\"/><path d=\"M208 180 L340 256 L208 332 Z\" fill=\"$T\"/>"

svg apps amberol \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><circle cx=\"256\" cy=\"256\" r=\"140\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\" opacity=\"0.3\"/><circle cx=\"256\" cy=\"256\" r=\"100\" fill=\"none\" stroke=\"$T\" stroke-width=\"8\" opacity=\"0.2\"/><circle cx=\"256\" cy=\"256\" r=\"40\" fill=\"$T\"/><rect x=\"248\" y=\"100\" width=\"16\" height=\"80\" rx=\"4\" fill=\"$T\"/>"

svg apps loupe \
  "<circle cx=\"220\" cy=\"220\" r=\"140\" fill=\"$D\" stroke=\"$T\" stroke-width=\"24\"/><rect x=\"330\" y=\"330\" width=\"128\" height=\"32\" rx=\"12\" fill=\"$T\" transform=\"rotate(45 394 346)\"/><rect x=\"160\" y=\"180\" width=\"120\" height=\"80\" rx=\"8\" fill=\"$T\" opacity=\"0.2\"/>"

svg apps papers \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><rect x=\"152\" y=\"112\" width=\"208\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"152\" y=\"148\" width=\"160\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"152\" y=\"184\" width=\"208\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.6\"/><rect x=\"152\" y=\"220\" width=\"140\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"152\" y=\"256\" width=\"208\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"152\" y=\"292\" width=\"180\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.3\"/>"

svg apps apostrophe \
  "<rect x=\"80\" y=\"64\" width=\"352\" height=\"384\" rx=\"24\" fill=\"$D\"/><text x=\"172\" y=\"280\" font-family=\"serif\" font-size=\"280\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">&amp;#8220;</text><rect x=\"200\" y=\"240\" width=\"200\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"200\" y=\"272\" width=\"160\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"200\" y=\"304\" width=\"180\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.5\"/>"

svg apps zoom \
  "<rect x=\"80\" y=\"112\" width=\"352\" height=\"288\" rx=\"24\" fill=\"$D\"/><rect x=\"128\" y=\"168\" width=\"112\" height=\"80\" rx=\"8\" fill=\"$B\" opacity=\"0.7\"/><rect x=\"272\" y=\"168\" width=\"112\" height=\"80\" rx=\"8\" fill=\"$B\" opacity=\"0.5\"/><rect x=\"128\" y=\"272\" width=\"112\" height=\"80\" rx=\"8\" fill=\"$B\" opacity=\"0.5\"/><rect x=\"272\" y=\"272\" width=\"112\" height=\"80\" rx=\"8\" fill=\"$B\" opacity=\"0.3\"/>"

svg apps slack \
  "<rect x=\"96\" y=\"96\" width=\"320\" height=\"320\" rx=\"32\" fill=\"$D\"/><rect x=\"176\" y=\"160\" width=\"24\" height=\"96\" rx=\"12\" fill=\"$T\"/><rect x=\"176\" y=\"160\" width=\"96\" height=\"24\" rx=\"12\" fill=\"$T\"/><rect x=\"312\" y=\"256\" width=\"24\" height=\"96\" rx=\"12\" fill=\"$R\"/><rect x=\"240\" y=\"328\" width=\"96\" height=\"24\" rx=\"12\" fill=\"$R\"/><rect x=\"176\" y=\"256\" width=\"24\" height=\"96\" rx=\"12\" fill=\"$Y\"/><rect x=\"176\" y=\"328\" width=\"96\" height=\"24\" rx=\"12\" fill=\"$Y\"/><rect x=\"312\" y=\"160\" width=\"24\" height=\"96\" rx=\"12\" fill=\"$G\"/><rect x=\"240\" y=\"160\" width=\"96\" height=\"24\" rx=\"12\" fill=\"$G\"/>"

svg apps whatsapp \
  "<circle cx=\"256\" cy=\"256\" r=\"200\" fill=\"$D\"/><path d=\"M256 80 A176 176 0 1 0 136 384 L96 432 L164 404 A176 176 0 0 0 256 80\" fill=\"$G\"/><path d=\"M200 200 Q200 168 232 168 Q264 168 264 200 L264 228 Q264 260 232 260 L220 260 L220 312 L180 276 L220 276\" fill=\"$TXT\" opacity=\"0.9\"/>"

# ─── STATUS remaining ───
echo "[status]"

svg status network-receive \
  "<circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"$D\"/><path d=\"M256 120 L256 320\" stroke=\"$T\" stroke-width=\"28\" stroke-linecap=\"round\"/><path d=\"M192 260 L256 328 L320 260\" fill=\"none\" stroke=\"$T\" stroke-width=\"28\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/><rect x=\"168\" y=\"360\" width=\"176\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/>"

svg status network-transmit \
  "<circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"$D\"/><path d=\"M256 392 L256 192\" stroke=\"$T\" stroke-width=\"28\" stroke-linecap=\"round\"/><path d=\"M192 252 L256 184 L320 252\" fill=\"none\" stroke=\"$T\" stroke-width=\"28\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/><rect x=\"168\" y=\"136\" width=\"176\" height=\"16\" rx=\"8\" fill=\"$T\" opacity=\"0.5\"/>"

svg status network-transmit-receive \
  "<circle cx=\"256\" cy=\"256\" r=\"180\" fill=\"$D\"/><path d=\"M176 200 L176 356\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M136 300 L176 360 L216 300\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/><path d=\"M336 356 L336 200\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\"/><path d=\"M296 256 L336 196 L376 256\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

# WiFi signal strength variants
for level in excellent good ok weak none; do
    case $level in
        excellent) OP1="1" OP2="1" OP3="1" OP4="1" ;;
        good)      OP1="1" OP2="1" OP3="1" OP4="0.2" ;;
        ok)        OP1="1" OP2="1" OP3="0.2" OP4="0.2" ;;
        weak)      OP1="1" OP2="0.2" OP3="0.2" OP4="0.2" ;;
        none)      OP1="0.2" OP2="0.2" OP3="0.2" OP4="0.2" ;;
    esac
    svg status "network-wireless-signal-$level" \
      "<circle cx=\"256\" cy=\"380\" r=\"24\" fill=\"$T\" opacity=\"$OP1\"/><path d=\"M192 316 A80 80 0 0 1 320 316\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\" opacity=\"$OP2\"/><path d=\"M136 252 A150 150 0 0 1 376 252\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\" opacity=\"$OP3\"/><path d=\"M80 188 A220 220 0 0 1 432 188\" fill=\"none\" stroke=\"$T\" stroke-width=\"20\" stroke-linecap=\"round\" opacity=\"$OP4\"/>"
done

svg status mail-attachment \
  "<rect x=\"64\" y=\"128\" width=\"384\" height=\"280\" rx=\"24\" fill=\"$D\"/><path d=\"M80 144 L256 280 L432 144\" fill=\"none\" stroke=\"$T\" stroke-width=\"16\"/><path d=\"M360 200 L360 120 A40 40 0 0 1 440 120 L440 240\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\" stroke-linecap=\"round\"/>"

svg status user-idle \
  "<circle cx=\"256\" cy=\"192\" r=\"80\" fill=\"$D\" opacity=\"0.6\"/><path d=\"M128 416 A128 128 0 0 1 384 416\" fill=\"$D\" opacity=\"0.6\"/><circle cx=\"256\" cy=\"192\" r=\"24\" fill=\"$Y\"/><circle cx=\"256\" cy=\"348\" r=\"12\" fill=\"$Y\" opacity=\"0.5\"/><circle cx=\"256\" cy=\"376\" r=\"8\" fill=\"$Y\" opacity=\"0.3\"/>"

svg status folder-open \
  "<path d=\"M80 144 L200 144 L232 112 L400 112 L400 160 L432 192 L432 416 L80 416 Z\" fill=\"$D\"/><path d=\"M80 192 L144 192 L432 192 L400 416 L80 416 Z\" fill=\"$T\" opacity=\"0.3\"/>"

svg status folder-drag-accept \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\" stroke-dasharray=\"16 8\"/><path d=\"M80 160 L432 160\" stroke=\"$T\" stroke-width=\"8\"/><path d=\"M256 216 L256 360\" stroke=\"$T\" stroke-width=\"24\" stroke-linecap=\"round\"/><path d=\"M200 304 L256 368 L312 304\" fill=\"none\" stroke=\"$T\" stroke-width=\"24\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"

# ─── PLACES remaining ───
echo "[places]"

svg places folder-root \
  "<path d=\"M80 128 L200 128 L232 96 L432 96 L432 416 L80 416 Z\" fill=\"$D\"/><path d=\"M80 160 L432 160\" stroke=\"$T\" stroke-width=\"8\"/><text x=\"256\" y=\"328\" font-family=\"monospace\" font-size=\"120\" font-weight=\"bold\" fill=\"$T\" text-anchor=\"middle\">/</text>"

# ─── MIMETYPES remaining ───
echo "[mimetypes]"

svg mimetypes image-gif \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><circle cx=\"216\" cy=\"176\" r=\"36\" fill=\"$T\" opacity=\"0.6\"/><path d=\"M128 336 L220 256 L296 320 L340 280 L384 328\" fill=\"none\" stroke=\"$T\" stroke-width=\"12\"/><text x=\"256\" y=\"428\" font-family=\"monospace\" font-size=\"48\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">GIF</text><path d=\"M356 96 A20 20 0 1 1 396 96 A20 20 0 1 1 356 96\" fill=\"$T\" opacity=\"0.5\"/>"

svg mimetypes audio-flac \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><circle cx=\"256\" cy=\"280\" r=\"80\" fill=\"$T\" opacity=\"0.3\"/><rect x=\"244\" y=\"140\" width=\"24\" height=\"220\" rx=\"4\" fill=\"$T\"/><text x=\"256\" y=\"428\" font-family=\"monospace\" font-size=\"42\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">FLAC</text>"

svg mimetypes video-x-matroska \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><path d=\"M208 180 L340 256 L208 332 Z\" fill=\"$T\"/><text x=\"256\" y=\"428\" font-family=\"monospace\" font-size=\"42\" fill=\"$T\" text-anchor=\"middle\" opacity=\"0.6\">MKV</text>"

svg mimetypes application-x-deb \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"300\" font-family=\"monospace\" font-size=\"120\" font-weight=\"bold\" fill=\"$R\" text-anchor=\"middle\">DEB</text>"

svg mimetypes application-x-rpm \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><text x=\"256\" y=\"300\" font-family=\"monospace\" font-size=\"120\" font-weight=\"bold\" fill=\"$B\" text-anchor=\"middle\">RPM</text>"

svg mimetypes text-x-generic-template \
  "<rect x=\"112\" y=\"48\" width=\"288\" height=\"416\" rx=\"16\" fill=\"$D\"/><rect x=\"160\" y=\"120\" width=\"192\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.3\"/><rect x=\"160\" y=\"156\" width=\"160\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.2\"/><rect x=\"160\" y=\"192\" width=\"192\" height=\"12\" rx=\"6\" fill=\"$T\" opacity=\"0.3\"/><circle cx=\"352\" cy=\"104\" r=\"32\" fill=\"$T\" opacity=\"0.5\"/><rect x=\"336\" y=\"88\" width=\"32\" height=\"32\" rx=\"4\" fill=\"$D\"/>"

# ─── CATEGORIES remaining ───
echo "[categories]"

svg categories preferences-desktop-peripherals \
  "<rect x=\"64\" y=\"192\" width=\"384\" height=\"160\" rx=\"16\" fill=\"$D\"/><rect x=\"108\" y=\"216\" width=\"36\" height=\"28\" rx=\"4\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"156\" y=\"216\" width=\"36\" height=\"28\" rx=\"4\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"204\" y=\"216\" width=\"36\" height=\"28\" rx=\"4\" fill=\"$T\" opacity=\"0.4\"/><rect x=\"108\" y=\"260\" width=\"200\" height=\"28\" rx=\"4\" fill=\"$T\" opacity=\"0.3\"/><rect x=\"320\" y=\"216\" width=\"80\" height=\"72\" rx=\"40\" fill=\"$D\" stroke=\"$T\" stroke-width=\"8\"/><rect x=\"108\" y=\"380\" width=\"60\" height=\"80\" rx=\"8\" fill=\"$D\"/><rect x=\"344\" y=\"380\" width=\"60\" height=\"80\" rx=\"8\" fill=\"$D\"/>"

echo ""
TOTAL=$(find "$ICON_DIR" -name "*.svg" | wc -l)
echo "=== FINAL RESULT ==="
echo "New icons: $COUNT"
echo "Total SVGs in LifeOS theme: $TOTAL"
echo ""
echo "Brand palette used:"
echo "  Teal Axi:      $T"
echo "  Rosa Axi:      $R"
echo "  Medianoche:    $D"
echo "  Amarillo:      $Y"
echo "  Verde Success: $G"
echo "  Azul LifeOS:   $B"
echo "  Purpura:       $P"
echo "  Blanco Suave:  $TXT"
