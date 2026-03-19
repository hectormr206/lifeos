#!/bin/bash

set -euo pipefail

if ! command -v grim >/dev/null 2>&1; then
    echo "grim no esta instalado" >&2
    exit 1
fi

if ! command -v slurp >/dev/null 2>&1; then
    echo "slurp no esta instalado" >&2
    exit 1
fi

if ! command -v wl-copy >/dev/null 2>&1; then
    echo "wl-copy no esta instalado" >&2
    exit 1
fi

selection="$(slurp)"
if [[ -z "${selection}" ]]; then
    echo "Captura cancelada" >&2
    exit 1
fi

grim -g "${selection}" - | wl-copy --type image/png
