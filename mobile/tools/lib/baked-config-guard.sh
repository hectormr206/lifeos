# shellcheck shell=bash
#
# Que lo que se publica sepa actualizarse.
#
# La 0.19.1 (939) se publicó compilada SIN los --dart-define: su código traía
# https://updates.PLACEHOLDER.example/lifeos, así que cada aparato que la
# instaló concluyó "actualizaciones no configuradas" y dejó de preguntar para
# siempre (el Pixel de Héctor, del 23-09 en adelante: cero peticiones al
# servidor). Ninguna comprobación lo vio, porque el APK instalaba y abría bien.
#
# Esta función abre el binario Dart ya compilado (libapp.so) y exige que traiga
# la URL real de actualizaciones y ningún marcador de posición de actualizaciones
# ni de modelos. Si falla, NO se publica: ese build no podría recibir el
# siguiente.
lifeos_guard_baked_config() {
  local artifact="$1" update_base_url="$2"
  python3 - "$artifact" "$update_base_url" <<'PY'
import re, sys, zipfile
artifact, url = sys.argv[1], sys.argv[2].rstrip('/')
if artifact.endswith('.apk'):
    with zipfile.ZipFile(artifact) as z:
        data = z.read('lib/arm64-v8a/libapp.so')
else:
    data = open(artifact, 'rb').read()
text = data.decode('latin-1')
problems = []
if url.encode() not in data:
    problems.append(f'no trae la URL de actualizaciones {url}')
for placeholder in sorted(set(re.findall(r'https://(?:updates|models)\.PLACEHOLDER\.example/[a-z/]*', text))):
    problems.append(f'trae el marcador {placeholder}')
if problems:
    print('⛔ El build no sabría actualizarse:', file=sys.stderr)
    for p in problems:
        print('   · ' + p, file=sys.stderr)
    print('   ¿Se compiló sin los --dart-define? No se publica.', file=sys.stderr)
    sys.exit(1)
print('→ Configuración horneada: URL de actualizaciones presente, sin marcadores.')
PY
}
