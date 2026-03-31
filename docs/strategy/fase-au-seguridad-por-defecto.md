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

### AU.1 — Critico (maximo impacto, minimo esfuerzo)

- [ ] **Firewall activo por defecto** — `firewalld` habilitado con zona LifeOS: bloquear todo inbound excepto DHCP/mDNS, permitir todo outbound. SSH bloqueado por default (el usuario lo abre si lo necesita)
- [ ] **Kernel hardening sysctl** — archivo `/etc/sysctl.d/90-lifeos-hardening.conf` con: ASLR, SYN flood protection, ICMP redirects bloqueados, martian logging, ptrace restriction, kernel pointer hiding, symlink/hardlink protection
- [ ] **SSH hardened de fabrica** — `/etc/ssh/sshd_config.d/50-lifeos.conf`: PermitRootLogin no, PasswordAuthentication no, MaxAuthTries 3, X11Forwarding no (sshd no esta habilitado por default, pero si el usuario lo activa, ya esta seguro)
- [ ] **Core dumps deshabilitados** — sysctl + systemd coredump + limits.conf. Evita que datos sensibles se escriban a disco en crashes

### AU.2 — Importante (hardening fuerte)

- [ ] **auditd** — framework de auditoria del kernel. Reglas para: acceso a /etc/shadow, cambios en sudoers, carga de modulos, operaciones de mount. Da el "ledger inmutable" del threat model
- [ ] **Rate limiting de login** — pam_faillock: bloqueo temporal despues de 5 intentos fallidos (15 min)
- [ ] **DNS encriptado system-wide** — systemd-resolved con DoT a Quad9 (no solo Firefox, TODO el sistema)
- [ ] **Notificaciones de actualizaciones** — timer diario que ejecuta `bootc upgrade --check`, notifica via Axi si hay update disponible (sin auto-aplicar)
- [ ] **USBGuard o politica udev** — permitir dispositivos conectados al boot, alertar sobre nuevos USB HID (previene BadUSB/rubber ducky)

### AU.3 — Polish (cumplimiento CIS completo)

- [ ] **Password de GRUB** — proteger edicion de parametros de boot (previene `init=/bin/bash`)
- [ ] **Banner de login** — `/etc/issue` con aviso de uso autorizado (requisito CIS)
- [ ] **AIDE para /etc** — monitoreo de integridad de archivos mutables. Timer semanal
- [ ] **Complejidad de password** — pam_pwquality: minlen=12, al menos 1 mayuscula, 1 numero, 1 especial
- [ ] **Servicios minimizados** — libvirtd solo socket-activated, spice-vdagent solo en VMs
- [ ] **Modulos de kernel blacklisted** — cramfs, freevxfs, hfs, hfsplus, udf bloqueados (ataque por filesystem)

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
