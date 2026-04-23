# Cifrado de screenshots at rest

LifeOS captura screenshots para el overlay de IA, FollowAlong y documentación de incidentes. Esos archivos pueden contener información sensible (correos, contraseñas en pantalla, fotos personales). Este documento describe cómo se protegen en disco y los límites reales de esa protección.

## Algoritmo y formato

- Cifrado: **AES-256-GCM-SIV** (`aes-gcm-siv = 0.11`), nonce-misuse-resistant y autenticado.
- Nonce: 12 bytes aleatorios por archivo, generados con `rand::thread_rng()` (OsRng).
- Layout del archivo cifrado: `[nonce(12 bytes)][ciphertext + auth tag de 16 bytes]`.
- Extensión: `<nombre>.enc` (ej. `lifeos_screenshot_20260422_143015.png.enc`).

## Key management

- Path: `/var/lib/lifeos/secrets/screenshot.key` (32 bytes, mode `0600`).
- Directorio padre: `/var/lib/lifeos/secrets/` (mode `0700`).
- Generación: en el primer uso, si la key no existe, se generan 32 bytes con la RNG del sistema y se persisten. Loads posteriores devuelven la misma key.
- **No rotamos la key automáticamente.** Rotarla invalida todos los `.enc` previos. Si necesitás rotación, hay que: (1) descifrar todos los `.enc`, (2) borrar la key vieja, (3) re-cifrar con la key nueva. No hay tooling para esto todavía.

Mismo patrón que `workflow-hmac.key` (PR #31, `daemon/src/self_improving.rs`). Ver `docs/operations/self-improving-security.md` para el modelo de threat de las keys persistidas.

## Layout en disco

Después de cada captura, en `/var/lib/lifeos/screenshots/` quedan dos archivos:

```
lifeos_screenshot_20260422_143015.png      # plaintext, mode 0600
lifeos_screenshot_20260422_143015.png.enc  # cifrado AES-GCM-SIV, mode 0600
```

El plaintext NO se elimina inmediatamente porque consumers in-tree (`sensory_pipeline.rs`, `overlay.rs`) le pasan la ruta a binarios externos (`identify`, llava, etc.) que no entienden el formato `.enc`. El plaintext es ephemeral: las rutinas de cleanup (`cleanup_old`, `cleanup_by_count`, `cleanup_by_size` y `storage_housekeeping`) lo purgan junto con el `.enc` por mtime / count / size.

## Self-test al startup

`lifeosd` ejecuta `screenshot_crypt::self_test_at_startup()` en cada boot. Esto:

1. Carga (o genera) la key en `/var/lib/lifeos/secrets/screenshot.key`.
2. Escribe un probe ciphertext en un tempfile via `encrypt_to_file`.
3. Lo descifra via `decrypt_from_file` y valida el round-trip.
4. Loggea `screenshot_crypt: self-test OK` o el error específico.

Si el self-test falla, el daemon sigue arrancando — solo se loggea un warning. El efecto práctico es que las nuevas capturas omitirán el sidecar `.enc` (el plaintext sigue escribiéndose como antes de este PR), comportamiento fail-open.

## Threat model — qué SÍ protege

- **Laptop robada con el disco extraído** y leído offline (cold-disk attack). El atacante ve solo ciphertext; sin la key (que vive en `/var/lib/lifeos/secrets/`, fuera del directorio de screenshots), no puede recuperar las imágenes. Defensa en profundidad sobre LUKS-at-rest.
- **Backup-leak**: si alguien hace `tar cf` de `/var/lib/lifeos/screenshots/` y lo sube a una nube, lo que se filtra son solo `.enc`. La key NO está en ese directorio, por eso un backup del directorio de screenshots no compromete las imágenes.
- **Proceso bajo otro UID** o sandboxed (flatpak, systemd-run scope) con read sobre el directorio de screenshots pero sin acceso a `/var/lib/lifeos/secrets/` (mode 0700).

## Threat model — qué NO protege

- **Atacante same-UID con acceso al daemon en runtime.** Si está corriendo bajo el mismo UID que `lifeosd`, puede leer la key y descifrar todo. Esa amenaza ya gana, este layer no la frena.
- **Ataque online con root.** Quien tiene root puede leer la key, los plaintext frescos, o llamar al daemon API para que descifre por él.
- **Side-channels contra el daemon en runtime** (memory dumps, `/proc/$pid/mem`). Mitigaciones a nivel SO (kernel hardening, ptrace_scope=2) son ortogonales.
- **Plaintexts vivos durante la ventana de retención.** Mientras el archivo `.png` plaintext exista en disco (entre la captura y el siguiente cleanup tick), un atacante que pueda leer ese path lo ve en claro. Para encryption end-to-end (sin plaintext en disco) hay que refactorizar `sensory_pipeline.rs` para consumir bytes vía `decrypt_from_file` — tracked como follow-up.

## Migración de screenshots existentes

**No se migran automáticamente.** Screenshots capturadas antes de esta versión solo existen como `.png`/`.jpg`/`.webp` planos. Las nuevas capturas escriben tanto plaintext como `.enc`. Las rutinas de cleanup van a barrer los archivos viejos por edad (`EPHEMERAL_RETENTION_DAYS`, ~7 días) y count, así que el dataset se "auto-cifra" naturalmente al rotar.

Si querés forzar la migración, podés:

```bash
# Manual one-shot — solo en máquinas con LifeOS instalada
# lifeosd corre en --user scope (no system scope).
systemctl --user stop lifeosd
# (no hay tooling oficial todavía; la opción más simple es borrar
#  los archivos legacy, que se regenerarán cifrados al próximo uso)
sudo find /var/lib/lifeos/screenshots -maxdepth 1 -type f \
    \( -name "*.png" -o -name "*.jpg" -o -name "*.webp" \) -delete
systemctl --user start lifeosd
```

## Tests

- Round-trip plaintext → ciphertext → plaintext (`screenshot_crypt::tests::round_trip_recovers_plaintext`).
- Tamper detection: flip de 1 byte en el ciphertext hace fallar el decrypt (`tamper_detection_fails_decrypt`).
- Persistencia de key entre loads (`key_persists_across_loads`).
- Decrypt con key incorrecta falla (`wrong_key_fails_decrypt`).
- Detección de blob demasiado corto (`short_blob_is_rejected`).

Correr: `cargo test screenshot_crypt --features "dbus,http-api,wake-word,messaging" --locked --manifest-path daemon/Cargo.toml`.

## Limitaciones conocidas

1. **Plaintext sigue en disco hasta el cleanup.** Documentado arriba.
2. **No hay key rotation tooling.** Rotar a mano implica descifrar todo y re-cifrar.
3. **No hay key escrow.** Si el archivo de key se pierde o corrompe (y se regenera), todos los `.enc` previos son irrecuperables.
4. **No protege contra el daemon comprometido.** El daemon tiene la key en memoria al cifrar/descifrar. Un atacante que controle el daemon ya ganó.

## Referencias

- Implementación: `daemon/src/screenshot_crypt.rs`
- Wire-up: `daemon/src/screen_capture.rs::finalize_capture_file` y `daemon/src/main.rs::main` (self-test).
- Patrón de key persistente: `daemon/src/self_improving.rs::load_or_create_hmac_key`
- Crate: `aes-gcm-siv = "0.11"` (ya en `daemon/Cargo.toml`)
