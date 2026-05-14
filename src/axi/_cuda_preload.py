"""Preload NVIDIA CUDA libs shipped via pip wheels.

ctranslate2 (used by faster-whisper) uses dlopen at runtime to find CUDA libs.
The pip wheels install them under site-packages/nvidia/*/lib/ which is not on
the system loader path. Preloading via ctypes registers them globally so the
later dlopen calls resolve correctly. This avoids requiring LD_LIBRARY_PATH
or a system-wide CUDA install.

Import this module before importing faster_whisper.
"""
from __future__ import annotations

import ctypes
import sys
from pathlib import Path

# Order matters: cuBLAS depends on cuBLASLt and the NVRTC runtime.
_LIB_ORDER = [
    ("nvidia/cublas/lib", "libcublasLt.so.12"),
    ("nvidia/cublas/lib", "libcublas.so.12"),
    ("nvidia/cuda_nvrtc/lib", "libnvrtc.so.12"),
    ("nvidia/cudnn/lib", "libcudnn.so.9"),
]


def preload() -> None:
    site_packages = Path(sys.prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages"
    for subdir, libname in _LIB_ORDER:
        path = site_packages / subdir / libname
        if path.exists():
            ctypes.CDLL(str(path), mode=ctypes.RTLD_GLOBAL)


preload()
