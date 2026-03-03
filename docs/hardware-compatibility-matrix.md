# LifeOS Hardware Compatibility Matrix

> Version 0.1.0 — Marzo 2026
> Actualizada por el equipo LifeOS. Reporta incompatibilidades en [GitHub Issues](https://github.com/hectormr/lifeos/issues).

## 1. Requisitos minimos

| Componente | Minimo | Recomendado | Notas |
|---|---|---|---|
| CPU | x86_64, 4 cores | 8+ cores | ARM64 en roadmap (Fase 3) |
| RAM | 8 GB | 16 GB | AI runtime consume ~3 GB con Qwen3.5-4B Q4_K_M |
| Almacenamiento | 64 GB SSD | 128 GB+ NVMe | Btrfs con snapshots requiere ~20% espacio libre |
| GPU (opcional) | — | NVIDIA GTX 1060+ / AMD RX 580+ | Para AI offload. Sin GPU, AI corre en CPU |
| Red | Ethernet o WiFi | Ethernet | Requerida para updates. Offline mode disponible |
| Pantalla | 1280x720 | 1920x1080+ | COSMIC desktop escala a HiDPI |
| TPM | — | TPM 2.0 | Recomendado para Secure Boot + Measured Boot |
| UEFI | Requerido | Secure Boot habilitado | Legacy BIOS no soportado |

## 2. GPUs y AI Runtime

### 2.1 NVIDIA (CUDA)

| GPU | VRAM | AI Offload | Estado | Notas |
|---|---|---|---|---|
| RTX 4090/4080/4070 | 16-24 GB | Full (all layers) | Validado | Rendimiento optimo |
| RTX 3090/3080/3070 | 8-24 GB | Full | Validado | Excelente rendimiento |
| RTX 3060 | 12 GB | Full | Validado | Sweet spot precio/rendimiento |
| RTX 2080/2070/2060 | 6-11 GB | Full/Parcial | Validado | Q4_K_M cabe completo en 6GB |
| GTX 1660/1650 | 4-6 GB | Parcial | Validado | Offload parcial (20-30 layers) |
| GTX 1060 | 6 GB | Parcial | Validado | Funcional con offload parcial |
| GTX 1050 Ti | 4 GB | Minimo | Experimental | Solo 15-20 layers, resto CPU |
| Anteriores | <4 GB | No | No soportado | Usar CPU-only mode |

**Driver requerido:** NVIDIA proprietary >= 535.x (incluido via RPM Fusion/Fedora)
**CUDA:** Detectado automaticamente via `nvidia-smi` en first-boot.

### 2.2 AMD (ROCm/Vulkan)

| GPU | VRAM | AI Offload | Estado | Notas |
|---|---|---|---|---|
| RX 7900 XTX/XT | 20-24 GB | Full | Validado | ROCm 6.x |
| RX 7800 XT/7700 XT | 12-16 GB | Full | Validado | ROCm 6.x |
| RX 6900/6800/6700 | 12-16 GB | Full | Validado | ROCm 5.x+ |
| RX 6600 | 8 GB | Full | Validado | Q4_K_M cabe completo |
| RX 580/570 | 4-8 GB | Parcial | Experimental | Vulkan fallback, no ROCm |
| APU (Ryzen iGPU) | Compartida | Minimo | Experimental | Vulkan, rendimiento limitado |

**Driver requerido:** Mesa + `amdgpu` kernel driver (incluido en Fedora).
**ROCm:** Detectado en first-boot. Vulkan como fallback.

### 2.3 Intel (oneAPI)

| GPU | VRAM | AI Offload | Estado | Notas |
|---|---|---|---|---|
| Arc A770/A750 | 8-16 GB | Parcial | Experimental | oneAPI/SYCL via llama.cpp |
| Arc A580/A380 | 6-8 GB | Parcial | Experimental | Rendimiento limitado |
| iGPU (Iris Xe) | Compartida | No | No soportado | Usar CPU-only |
| iGPU (UHD 7xx) | Compartida | No | No soportado | Usar CPU-only |

**Nota:** Soporte Intel Arc es experimental. llama.cpp con SYCL backend requerido.

### 2.4 NPU (Neural Processing Unit)

| NPU | Estado | Notas |
|---|---|---|
| Intel Meteor Lake NPU | Roadmap (Fase 2) | Driver Linux en desarrollo |
| Intel Lunar Lake NPU | Roadmap (Fase 2) | Mejor soporte esperado |
| Qualcomm Hexagon (ARM) | Roadmap (Fase 3) | Requiere port ARM64 |
| AMD XDNA (Ryzen AI) | Roadmap (Fase 2) | Driver Linux en desarrollo |

## 3. CPUs

### 3.1 AMD

| Procesador | Estado | Notas |
|---|---|---|
| Ryzen 9000/8000/7000 | Validado | Excelente rendimiento AI en CPU |
| Ryzen 5000/3000 | Validado | Buen rendimiento |
| Ryzen 2000/1000 | Compatible | Rendimiento AI limitado |
| Threadripper | Validado | Optimo para cargas pesadas |
| EPYC | Compatible | Server-grade, no es target principal |

### 3.2 Intel

| Procesador | Estado | Notas |
|---|---|---|
| Core Ultra (Meteor/Lunar Lake) | Validado | NPU disponible (roadmap) |
| 14th/13th/12th Gen | Validado | P-cores y E-cores bien soportados |
| 11th/10th Gen | Compatible | Rendimiento adecuado |
| 9th Gen y anteriores | Compatible | Rendimiento AI limitado |
| Xeon | Compatible | Server-grade, no es target principal |

## 4. Storage

| Tipo | Estado | Notas |
|---|---|---|
| NVMe SSD | Validado | Recomendado. Boot <5s |
| SATA SSD | Validado | Funcional, boot algo mas lento |
| HDD | Compatible | No recomendado. Boot lento, snapshots lentos |
| eMMC | Experimental | Solo dispositivos embebidos |
| USB Boot | Experimental | Para live testing |

**Filesystem:** Btrfs obligatorio para `/` y `/home` (snapshots, subvolumenes, compresion zstd).

## 5. Red

| Tipo | Estado | Notas |
|---|---|---|
| Ethernet (Intel/Realtek) | Validado | Soporte nativo en kernel |
| WiFi (Intel AX/BE) | Validado | iwlwifi driver incluido |
| WiFi (Realtek) | Compatible | Algunos modelos requieren firmware adicional |
| WiFi (Broadcom) | Experimental | Requiere `broadcom-wl` o `b43` |
| WiFi (MediaTek) | Compatible | mt76 driver en kernel |
| Bluetooth | Compatible | BlueZ stack incluido |

## 6. Pantallas

| Tipo | Estado | Notas |
|---|---|---|
| Monitor externo (HDMI/DP) | Validado | COSMIC maneja multi-monitor |
| Laptop integrado | Validado | Brightness control via kernel |
| HiDPI (4K) | Validado | COSMIC scaling automatico |
| Ultrawide (21:9, 32:9) | Compatible | COSMIC tiling adaptativo |
| eDP (tablets) | Experimental | Touch support parcial |
| VRR/FreeSync/G-Sync | Compatible | Soporte via kernel DRM |

## 7. Perifericos

| Dispositivo | Estado | Notas |
|---|---|---|
| Teclados USB/BT | Validado | HID estandar |
| Mouse/Trackpad USB/BT | Validado | libinput gestures |
| Webcams USB | Validado | V4L2 estandar |
| Impresoras (CUPS) | Compatible | IPP/CUPS incluido |
| Gamepads (Xbox/PS) | Compatible | xpad/hid-playstation |
| Audio USB | Validado | PipeWire |
| Thunderbolt docks | Compatible | bolt daemon incluido |
| Scanners | Experimental | SANE backend |

## 8. Laptops validados

| Marca | Modelo | Estado | Notas |
|---|---|---|---|
| Lenovo | ThinkPad X1 Carbon (Gen 10+) | Validado | Referencia principal |
| Lenovo | ThinkPad T14/T14s | Validado | AMD y Intel |
| Dell | XPS 13/15 | Compatible | Requiere firmware WiFi |
| Framework | 13/16 | Validado | Excelente soporte Linux |
| System76 | Lemur/Pangolin/Oryx | Validado | Hardware Linux-first |
| HP | EliteBook/ProBook | Compatible | BIOS settings may vary |
| ASUS | ZenBook/ROG | Experimental | Drivers propietarios pueden faltar |

## 9. Maquinas Virtuales

| Hypervisor | Estado | Notas |
|---|---|---|
| VirtualBox 7.x | Validado | GPU passthrough no disponible. AI en CPU-only |
| QEMU/KVM | Validado | GPU passthrough posible con VFIO |
| VMware Workstation | Compatible | vmxnet3 + vmtools |
| Hyper-V Gen 2 | Experimental | Enhanced session mode |
| Parallels (macOS) | No soportado | x86_64 emulation lento |

## 10. Niveles de soporte

| Nivel | Significado |
|---|---|
| **Validado** | Probado por el equipo LifeOS. Funciona out-of-the-box |
| **Compatible** | Esperado funcional basado en soporte del kernel/Fedora. No probado directamente |
| **Experimental** | Puede funcionar pero no garantizado. Reportar issues |
| **Roadmap** | Planeado para una fase futura |
| **No soportado** | No funciona o no sera soportado |

## 11. Reportar incompatibilidades

Si encuentras hardware no listado o problemas con hardware listado como "Validado":

1. Ejecuta `life status --hardware` para generar un reporte.
2. Abre un issue en GitHub con la etiqueta `hardware-compat`.
3. Incluye la salida de `lspci`, `lsusb` y `uname -a`.

---

*Ultima actualizacion: 2026-03-02*
