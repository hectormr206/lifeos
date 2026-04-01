# Fase AU — Seguro Desde el Primer Boot (Zero-Config Hardening)

> Objetivo: que el usuario NUNCA tenga que seguir un tutorial de "que hacer despues de instalar Linux" para estar seguro. LifeOS viene blindado de fabrica.

**Investigacion (2026-03-31):** Analisis de CIS Benchmarks para Fedora, STIG hardening, guias "post-install" de Ubuntu/Fedora, comparativa con GrapheneOS.

---

## Lo que LifeOS YA tiene (impresionante)

| Capa | Que tiene | Estado |
|------|-----------|--------|
| **OS inmutable** | bootc + ComposeFS + fs-verity, rollback atomico | ✅ |
| **Boot seguro** | Secure Boot validado + LUKS2 check + TPM 2.0 | ✅ |
| **Firma de imagen** | Cosign/TUF, cadena de confianza OCI | ✅ |
| **SELinux** | Enforcing (heredado de Fedora) | ✅ |
| **Servicios hardened** | NoNewPrivileges, ProtectSystem, ProtectHome en todos | ✅ |
| **AI security daemon** | 6 detectores, auto-isolation, Telegram alerts | ✅ |
| **Sudo least-privilege** | 65 lineas de comandos especificos, nunca ALL | ✅ |
| **Firefox hardened** | 50+ prefs, uBlock locked, DoH Quad9, anti-fingerprint | ✅ |
| **DNS en Firefox** | DoH via Quad9 (network.trr.mode=2) | ✅ |
| **Loopback-only AI** | llama-server y lifeosd solo en 127.0.0.1 | ✅ |
| **Integridad verificada** | lifeos-integrity-check.sh + security-baseline-check.sh | ✅ |
| **Btrfs snapshots** | Timer automatico | ✅ |
| **Sentinel independiente** | Watchdog out-of-band para lifeosd | ✅ |

---

## Lo que FALTA — Lo que Ubuntu/Fedora piden hacer manual

### AU.1 — Critico (maximo impacto, minimo esfuerzo) ✅ COMPLETADO

- [x] **Firewall activo por defecto** — `firewalld` con zona `lifeos.xml`: bloquea todo inbound excepto DHCP/mDNS, SSH bloqueado, todo outbound permitido
- [x] **Kernel hardening sysctl** — `/etc/sysctl.d/90-lifeos-hardening.conf`: ASLR, SYN flood, ICMP redirects, martian logging, ptrace, kernel pointer hiding, symlink/hardlink protection
- [x] **SSH hardened de fabrica** — `/etc/ssh/sshd_config.d/50-lifeos-hardening.conf`: PermitRootLogin no, PasswordAuthentication no, MaxAuthTries 3, X11Forwarding no
- [x] **Core dumps deshabilitados** — `91-lifeos-coredump.conf` + `systemd/coredump.conf.d/lifeos.conf`

### AU.2 — Importante (hardening fuerte) ✅ COMPLETADO

- [x] **auditd** — `/etc/audit/rules.d/50-lifeos.rules`: shadow, sudoers, modulos, mount, time, network, login, lifeos config. Inmutable con `-e 2`
- [x] **Rate limiting de login** — `faillock.conf`: 5 intentos, lockout 15 min
- [x] **DNS encriptado system-wide** — `systemd-resolved` con DoT a Quad9 (9.9.9.9) + fallback Cloudflare (1.1.1.1). DNSSEC allow-downgrade
- [x] **Notificaciones de actualizaciones** — `lifeos-update-check.timer` (diario) ejecuta `bootc upgrade --check`, notifica via desktop notification + Axi REST API
- [x] **USBGuard** — `usb_guard.rs` en daemon: whitelist persistente, deteccion de BadUSB HID

### AU.3 — Polish (cumplimiento CIS completo) ✅ COMPLETADO

- [x] **Password de GRUB** — `lifeos-grub-password.sh set/remove/status` protege edicion de boot params (previene `init=/bin/bash`)
- [x] **Banner de login** — `/etc/issue` con aviso de uso autorizado (requisito CIS)
- [x] **AIDE para /etc** — monitoreo de integridad con `aide.conf` + timer semanal (`lifeos-aide-check.timer`)
- [x] **Complejidad de password** — `pwquality.conf`: minlen=12, 1 mayuscula, 1 numero, 1 especial, maxrepeat=3
- [x] **Servicios minimizados** — libvirtd con `ConditionPathExists=/var/lib/libvirt`, spice-vdagent con `ConditionVirtualization=vm`
- [x] **Modulos de kernel blacklisted** — cramfs, freevxfs, hfs, hfsplus, udf, jffs2 en `/etc/modprobe.d/lifeos-blacklist.conf`

---

## Comparativa: Lo que el usuario debe hacer manual vs LifeOS

| Paso | Ubuntu/Fedora | LifeOS (con AU) |
|------|--------------|-----------------|
| Habilitar firewall | `sudo ufw enable` | Ya activo desde boot |
| Instalar ad blocker | Manual en Firefox | uBlock Origin pre-instalado y locked |
| Configurar DNS privado | Editar resolv.conf | Quad9 DoH en Firefox + DoT system-wide |
| Habilitar cifrado de disco | Elegir al instalar o reinstalar | Validado en cada boot |
| Hardear SSH | Editar sshd_config | Drop-in hardened de fabrica |
| Kernel hardening | Investigar valores sysctl | Archivo sysctl shipped de fabrica |
| Monitoreo de seguridad | Instalar fail2ban, AIDE | security_ai.rs corre desde el primer boot |
| Snapshots automaticos | Configurar Timeshift | Btrfs snapshots en timer |
| Verificar integridad del OS | No se hace | ComposeFS + fs-verity en cada boot |

**Mensaje al usuario: "LifeOS es el unico Linux desktop donde booteas en un sistema hardened CIS-level con deteccion AI de amenazas, DNS encriptado, base inmutable, y CERO configuracion requerida."**

---

## Esfuerzo estimado

| Fase | Items | Esfuerzo | Impacto |
|------|-------|----------|---------|
| AU.1 (Critico) | 4 items | ~2-3 horas | Cierra los gaps mas grandes |
| AU.2 (Importante) | 5 items | ~4-6 horas | auditd, PAM, DNS, USB |
| AU.3 (Polish) | 6 items | ~4-6 horas | Cumplimiento CIS completo |

AU.1 solo ya hace a LifeOS significativamente mas seguro que Ubuntu o Fedora recien instalados.
