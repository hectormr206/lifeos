# NLnet Proposal Draft — LifeOS: Sovereign Personal Computing with Local AI

> Fund: **NGI0 Commons Fund**
> Deadline: **1 April 2026, 12:00 CEST**
> Amount requested: **EUR 50,000**
> Applicant: Héctor Martínez Reséndiz (hectormr.com)

---

## Contact Information

- **Name:** Héctor Martínez Reséndiz
- **Email:** hector@hectormr.com
- **Organisation:** Independent developer (solo founder)
- **Country:** Mexico
- **Website:** https://hectormr.com

---

## Proposal Name

**LifeOS: An Open-Source, Privacy-First AI Operating System for Sovereign Personal Computing**

---

## Abstract

LifeOS is an open-source, AI-native Linux distribution built on Fedora bootc (immutable) that provides a complete personal AI assistant — Axi — running entirely on the user's hardware. Unlike cloud-dependent AI assistants (Siri, Alexa, Google Assistant, Copilot), LifeOS processes all data locally using open-weight LLMs (Qwen, LLaMA), encrypted local memory, and a privacy-by-default architecture where no personal data ever leaves the device.

The project addresses a critical gap in the current technology landscape: there is no open-source, privacy-respecting AI operating system that gives users full sovereignty over their digital lives. Apple, Google, and Microsoft are embedding AI deeply into their operating systems, but always routed through their cloud infrastructure, creating permanent dependencies and privacy risks.

**What LifeOS delivers:**

1. **Local AI runtime** — llama-server (llama.cpp) runs open-weight models locally on consumer GPUs (4GB+ VRAM) or CPU-only. No cloud API required for core functionality.

2. **Encrypted personal memory** — All user data (conversations, habits, knowledge graph, procedural memory) is encrypted with AES-GCM-SIV using machine-specific keys derived from `/etc/machine-id`. Data never leaves the device.

3. **OS Control Plane** — 53 MCP (Model Context Protocol) tools let the AI control the operating system: windows, apps, clipboard, browser, files, LibreOffice, COSMIC desktop — with a 4-layer hierarchy (MCP > D-Bus > AT-SPI2 Accessibility > Vision fallback).

4. **Multi-channel communication** — Telegram, Slack, Discord bridges let users interact with their personal AI from any device, while all processing stays on the home machine.

5. **Self-healing infrastructure** — 5-layer reliability (systemd watchdog, independent sentinel, circuit breaker, safe mode, config rollback) ensures the system recovers from failures without user intervention.

6. **Zero-config security** — CIS Benchmark-level hardening out of the box: firewalld, auditd, kernel sysctl, SSH hardening, DNS-over-TLS (Quad9), AIDE file integrity, password complexity, kernel module blacklist, core dump protection. Users never need to follow a "post-install hardening guide."

**Current state:** LifeOS is a working system with 341 passing tests, 65 AI tools exposed via Telegram, a Rust daemon (lifeosd) with 50+ modules, and a complete OS image buildable via `podman build`. The project has been in active development since 2025 by a solo developer.

**What this funding would enable:**
- Stabilize the core for a public beta release (ISO downloadable)
- Complete the AT-SPI2 accessibility integration for universal app control
- Implement the cross-device sync layer (Tailscale-based, end-to-end encrypted)
- Build the visual onboarding experience (COSMIC-native first-boot wizard)
- Create documentation and tutorials in Spanish and English
- Cover infrastructure costs (CI runners, OCI image hosting, testing hardware)

---

## Relevance to NGI0 Commons Fund

LifeOS directly advances the NGI mission of an **open, trustworthy, and human-centric internet**:

- **Digital sovereignty:** Users own their AI, their data, and their computing environment. No vendor lock-in, no cloud dependency.
- **Privacy as infrastructure:** Not a feature toggle — the entire architecture is built so data cannot leave the device by accident.
- **Open standards:** MCP (Model Context Protocol), AT-SPI2, D-Bus, OCI containers, systemd, Wayland — LifeOS builds on and contributes to existing open standards.
- **Accessibility:** The AT-SPI2 integration means LifeOS's AI can operate any accessible application, advancing universal access.
- **Interoperability:** The multi-LLM router supports 13+ providers, and the MCP server exposes a standard interface for any AI model to control the OS.
- **Commons contribution:** All code is Apache-2.0 (daemon) / GPL-3.0 (OS image), ensuring the work remains in the commons.

---

## Significant Technical Challenges

1. **Running LLMs on consumer hardware with acceptable latency.** We use quantized models (Q4_K_M) via llama.cpp, with automatic GPU layer management and a privacy-aware router that can optionally delegate to cloud providers (with user consent and data classification).

2. **Making AI control real applications reliably.** The 4-layer control hierarchy (MCP → D-Bus → AT-SPI2 → Vision) provides graceful degradation. When a structured API exists, we use it; when not, we fall back to accessibility trees; as last resort, screenshot+OCR+input simulation.

3. **Maintaining system integrity on an immutable OS.** Fedora bootc provides an immutable `/usr` with ComposeFS + fs-verity, but the AI daemon needs to learn and adapt. We solve this with a mutable `/var/lib/lifeos` partition, numbered config checkpoints with rollback, and a circuit breaker for self-modification.

4. **Privacy-preserving personalization.** The UserModel, knowledge graph, and procedural memory all use local-only encrypted storage. The system learns user preferences without any data leaving the machine.

---

## Budget Breakdown (EUR 30,000)

| Category | Amount | Description |
|----------|--------|-------------|
| Development (core) | 18,000 | 6 months part-time: cross-device sync, public beta stabilization, accessibility completion |
| Documentation | 3,000 | User guides (ES/EN), contributor docs, architecture docs |
| Infrastructure | 3,000 | CI runners (GitHub Actions self-hosted), OCI image hosting (GHCR), testing hardware |
| Testing hardware | 4,000 | 2 test machines (AMD + NVIDIA GPU) for real-hardware validation |
| Community building | 2,000 | Website, video tutorials, conference travel (FOSDEM, Fedora Flock) |

---

## Task Breakdown

| Task | Effort | Deliverable |
|------|--------|-------------|
| T1: Public beta ISO + installer | 6 weeks | Downloadable ISO with first-boot wizard, tested on 3+ hardware configs |
| T2: Cross-device sync (Tailscale E2E) | 4 weeks | Encrypted sync of memory, config, and notifications between LifeOS + phone |
| T3: AT-SPI2 universal app control | 3 weeks | AT-SPI2 working with Firefox, COSMIC apps, LibreOffice; documented coverage |
| T4: Documentation (ES + EN) | 3 weeks | User guide, contributor guide, architecture reference |
| T5: Security audit + hardening | 2 weeks | External review of threat model, fix findings |
| T6: Community infrastructure | 2 weeks | Website, Matrix room, contribution workflow, CI for external PRs |

---

## Comparison with Existing Efforts

| Project | Similarity | Key difference |
|---------|-----------|----------------|
| **OpenClaw** | AI assistant in terminal | Cloud-only (Claude API), terminal-only, no OS integration, no privacy |
| **Devin / Replit Agent** | AI coding assistant | Cloud-only, coding-focused, not a general OS |
| **Apple Intelligence** | AI integrated in OS | Proprietary, cloud-dependent, Apple hardware only |
| **Google Gemini** | AI assistant with context | Cloud-only, Google services dependent, privacy concerns |
| **postmarketOS** | Privacy-focused mobile OS | Mobile-focused, no AI integration |
| **Fedora Silverblue** | Immutable Linux desktop | No AI layer, no assistant, no personalization |

**LifeOS is unique** as the only open-source project combining: immutable OS + local AI + encrypted memory + OS-level control + multi-channel access + self-healing + zero-config security.

---

## Prior Involvement

- **Héctor Martínez Reséndiz** — Software engineer with experience in systems programming (Rust, Go), Linux systems administration, and AI/ML integration. Solo developer of LifeOS since 2025. Active contributor to the Fedora/bootc ecosystem.
- **Open source contributions:** LifeOS codebase (50+ Rust modules, 341 tests, 657 custom SVG icons, complete OS image pipeline).

---

## Ecosystem and Engagement Strategy

- **Target users (Phase 1):** Privacy-conscious developers and Linux enthusiasts who want a personal AI that respects their data sovereignty.
- **Target users (Phase 2):** Non-technical Spanish-speaking users who want a simple, secure computer that just works.
- **Community:** Matrix room, GitHub Discussions, Spanish-language tutorials on YouTube.
- **Sustainability post-grant:** GitHub Sponsors, optional premium LLM provider integrations (user pays provider directly), consulting/support for institutional deployments.

---

## Other Funding

- **Current:** Self-funded (~$60 USD/month)
- **Past:** None
- **Pending:** None

---

## Generative AI Disclosure

This proposal was drafted with assistance from Claude (Anthropic), used for:
- Structuring the proposal sections
- Summarizing technical capabilities from the existing codebase
- Translating from Spanish development notes to English proposal text

All technical claims are based on the actual codebase (verifiable at the project repository). The project vision, architecture decisions, and all code are the original work of the applicant.

---

## Notes for Hector

**Antes de enviar, necesitas:**

1. **Verificar/crear cuenta** en https://nlnet.nl/propose/ (si no tienes)
2. **Adaptar el tono** — NLnet valora honestidad y claridad sobre hype. Este draft es directo pero revisalo
3. **Agregar URL del repo** — cuando sea publico o compartir acceso privado
4. **Decidir el monto** — EUR 30,000 es conservador. NLnet da hasta EUR 50,000 para primeras propuestas
5. **Elegir el fund** — NGI0 Commons Fund es la mejor opcion. Si no aplica, usar Open Call
6. **PGP key** — opcional pero recomendado para comunicacion cifrada con NLnet
7. **Deadline:** 1 Abril 2026, 12:00 CEST — **MANANA**
