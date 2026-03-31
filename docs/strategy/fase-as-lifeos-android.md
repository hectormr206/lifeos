# Fase AS — LifeOS Mobile: Android Companion para Pixel (Vision Futura)

> Vision a largo plazo. No para desarrollo inmediato. Documentada para no perder la idea.

**Objetivo:** Extender LifeOS a telefonos Pixel como asistente AI hibrido (local + servidor) que sincroniza con el LifeOS de escritorio.

**Investigacion (2026-03-31):** Analisis de GrapheneOS, CalyxOS, LineageOS, llama.cpp en Android, Whisper/Piper movil, arquitectura hibrida phone+server.

**Dispositivo target:** Pixel 7 Pro (Tensor G2, 12GB RAM, GrapheneOS)

---

## Recomendacion: App primero, ROM despues

| Approach | Esfuerzo | Valor | Riesgo |
|----------|----------|-------|--------|
| **Android app** (sobre GrapheneOS) | 2-3 meses | 80% | Bajo |
| Custom ROM (fork GrapheneOS) | 6-9 meses | 100% | Alto |

**Empezar con app.** Cubre 80% del valor con 20% del esfuerzo. El ROM es opcional para mas adelante.

## Base OS recomendado: GrapheneOS

- Soporte first-class para Pixel 7 Pro
- Privacidad y seguridad alineadas con LifeOS
- Apache 2.0 / MIT — legal para fork
- Google Play sandboxeado (opcional)
- Patches de seguridad rapidos

## AI Local en Pixel 7 Pro

| Componente | Modelo | RAM | Velocidad |
|-----------|--------|-----|-----------|
| LLM local | Qwen2.5-3B Q4_K_M | ~2.5 GB | 3-8 tok/s |
| STT | whisper.cpp base | ~142 MB | Tiempo real |
| TTS | Piper es_MX | ~15-80 MB | Instantaneo |
| Wake word | Modelo custom ~2MB | Minimo | Siempre activo |

**Bateria:** Idle + wake word ~3%/hr. Uso activo ~15%/hr. Aceptable.

## Arquitectura Hibrida

```
Pixel (local)                    Desktop (lifeosd)
├── Wake word detection          ├── LLM grande (4B+)
├── Whisper STT                  ├── Memory/RAG completo
├── Piper TTS                   ├── Task execution
├── LLM 3B (quick responses)    ├── Workers asincronos
├── Sensors (GPS, health)        ├── Knowledge graph
├── Offline queue (SQLite)       └── Dashboard
└── Notification filtering
         ↕ WebSocket (ya existe en lifeosd)
```

---

## AS.1 — Android Companion App (MVP)

- [ ] Proyecto Android (Kotlin + Rust/NDK para inferencia)
- [ ] whisper.cpp para STT on-device
- [ ] Piper TTS on-device
- [ ] llama.cpp con Qwen2.5-3B para inferencia local rapida
- [ ] "Hey Axi" wake word detection
- [ ] WebSocket client a lifeosd (puerto 8081, ya existe)
- [ ] Cola offline (SQLite) para cuando no hay conexion
- [ ] Sync de sensores (ubicacion, actividad, bateria) al servidor
- [ ] Notification listener (filtrado inteligente con modelo local)
- [ ] Quick capture (notas de voz, fotos, texto → sync al servidor)
- [ ] Widget para home screen (comando de voz rapido, status)
- [ ] Quick settings tile (toggle escucha de Axi)
- [ ] Build y test en Pixel 7 Pro con GrapheneOS
- [ ] Publicar en F-Droid / distribuir como APK

## AS.2 — Integracion Profunda Android

- [ ] Accessibility service: leer cualquier pantalla, extraer texto, entender contexto
- [ ] Comandos screen-aware: "Resume esta pagina", "Responde este mensaje"
- [ ] Integracion de camara: apuntar y preguntar con vision model
- [ ] Health data (Google Fit / Health Connect API)
- [ ] Location-aware context switching (geofencing)
- [ ] Sync encriptado end-to-end (usando Titan M2)
- [ ] Battery management adaptativo (throttle inference por nivel de bateria)

## AS.3 — LifeOS ROM (Opcional, largo plazo)

- [ ] Fork GrapheneOS para Pixel 7 Pro
- [ ] LifeOS system service nativo (daemon al boot)
- [ ] Voice commands system-wide (en cualquier app)
- [ ] Custom audio pipeline para escucha always-on
- [ ] LifeOS launcher personalizado
- [ ] Boot animation + theming LifeOS
- [ ] OTA update server propio
- [ ] CI/CD para builds de ROM

## Metricas de exito

| Metrica | Target |
|---------|--------|
| Latencia voz (local) | < 2 segundos |
| Latencia voz (servidor) | < 5 segundos |
| Bateria idle | < 3% por hora |
| Bateria activo | < 15% por hora |
| Funciona offline | STT + TTS + LLM local |

## Legal

- AOSP: Apache 2.0 ✅
- GrapheneOS: MIT ✅
- Distribuir ROM: Legal ✅
- Pixel drivers: Redistributable ✅
- Sin Google Play Services propietarios en la distribucion

## Prerequisitos

- Desktop LifeOS estable (fases A-AP completadas ✅)
- WebSocket gateway funcionando (Fase AB ✅)
- Session store (Fase AB.2 ✅)
- LLM router con providers multiples (ya implementado ✅)
