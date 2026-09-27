# shellcheck shell=bash
# Check the shipped Dart AOT payload, not just the Flutter build arguments.
# The versioned frame is consumed by UpdateSourceConfig.fromEnvironment.
# Presence checks are a publication gate, not proof of server reachability.
lifeos_guard_baked_config() {
  local artifact="$1" update_base_url="$2"
  # The key is supplied by the publisher's environment, never in Python argv.
  # No diagnostic below prints either expected value or binary contents.
  UPDATE_ACCESS_KEY="${UPDATE_ACCESS_KEY-}" python3 - "$artifact" "$update_base_url" <<'PY'
import os
import re
import struct
import sys
import zipfile
import zlib
from urllib.parse import urlsplit

artifact, url = sys.argv[1:]
key = os.environ.get('UPDATE_ACCESS_KEY', '')
problems = []

# Validate before searching: b'' is present in every binary. Do not normalize
# away the final slash: a /lifeos/embed URL is not the /lifeos root URL.
parts = urlsplit('')
try:
    parts = urlsplit(url)
    host = parts.hostname or ''
    labels = host.split('.')
    valid_host = bool(host) and all(
        re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label)
        for label in labels
    )
    valid_port = parts.port is None or parts.port > 0
except ValueError:
    valid_host = valid_port = False
if (not url or any(not 0x21 <= ord(c) <= 0x7e for c in url)
        or parts.scheme != 'https' or not valid_host or not valid_port
        or parts.username is not None or parts.password is not None
        or parts.query or parts.fragment or '?' in url or '#' in url
        or re.search(r'placeholder|change.?me|replace.?me|your.?url|<|>', url, re.I)):
    problems.append('invalid expected update URL')

if (not key or any(not 0x21 <= ord(c) <= 0x7e for c in key)
        or re.search(r'placeholder|change.?me|replace.?me|your.?access|dummy|<|>', key, re.I)):
    problems.append('invalid expected update key')

payloads = []
try:
    if artifact.endswith('.apk'):
        with zipfile.ZipFile(artifact) as archive:
            entries = [name for name in archive.namelist()
                       if re.fullmatch(r'lib/[^/]+/libapp\.so', name)]
            if 'lib/arm64-v8a/libapp.so' not in entries:
                problems.append('APK missing supported arm64 Dart binary')
            if not entries or len(entries) != len(set(entries)):
                problems.append('APK has missing or duplicate Dart binaries')
            for name in entries:
                payloads.append((name.split('/')[1], archive.read(name)))
    else:
        with open(artifact, 'rb') as source:
            payloads.append((None, source.read()))
except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, zlib.error, EOFError):
    problems.append('artifact cannot be read or is corrupt')

# Supported: little-endian ELF64 ARM64/X64, ELF32 ARM; unknown APK ABIs
# fail closed. The ELF header alone cannot attest provenance or execution.
ABI = {'arm64-v8a': (183, 64), 'armeabi-v7a': (40, 32), 'x86_64': (62, 64)}


def elf_layout(data, abi):
    if len(data) < 52 or data[:4] != b'\x7fELF' or data[5:7] != b'\x01\x01':
        return None
    bits = {1: 32, 2: 64}.get(data[4])
    if bits is None or len(data) < (64 if bits == 64 else 52):
        return None
    machine = struct.unpack_from('<H', data, 18)[0]
    kind = struct.unpack_from('<H', data, 16)[0]
    version = struct.unpack_from('<I', data, 20)[0]
    header_size = struct.unpack_from('<H', data, 52 if bits == 64 else 40)[0]
    if kind != 3 or version != 1 or header_size != (64 if bits == 64 else 52):
        return None
    layout = {62: (62, 64), 183: (183, 64), 40: (40, 32)}.get(machine)
    if layout != (machine, bits) or (abi is not None and ABI.get(abi) != layout):
        return None
    return bits


# Only the exact, versioned constant compiled from the two existing defines
# counts. Individual unframed strings and prefixes cannot satisfy this gate.
expected_frame = (b'LIFEOS_OTA_CONFIG_V1\n' + url.encode('ascii', errors='replace')
                  + b'\n' + key.encode('ascii', errors='replace')
                  + b'\nEND_LIFEOS_OTA_CONFIG_V1')

for abi, data in payloads:
    if not data:
        problems.append('empty Dart binary')
        continue
    if elf_layout(data, abi) is None:
        problems.append('unsupported or invalid Dart ELF layout (ARM32/ARM64/X64 only)')
        continue
    if ('invalid expected update URL' not in problems
            and 'invalid expected update key' not in problems
            and expected_frame not in data):
        problems.append('Dart binary missing exact OTA configuration frame')
    # Match only known configuration defaults, not unrelated UI/library text.
    if (re.search(rb'https://(?:updates|models)\.PLACEHOLDER\.example/', data, re.I)
            or b'PLACEHOLDER_UPDATE_ACCESS_KEY' in data):
        problems.append('Dart binary contains placeholder configuration')

if problems:
    print('⛔ El build no sabría actualizarse:', file=sys.stderr)
    for problem in dict.fromkeys(problems):
        print('   · ' + problem, file=sys.stderr)
    print('   ¿Se compiló sin los --dart-define? No se publica.', file=sys.stderr)
    sys.exit(1)
print('→ Configuración horneada: URL y clave presentes, sin marcadores.')
PY
}
