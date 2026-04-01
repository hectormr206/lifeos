# NLnet Form — Copia y pega cada campo

> Abre: https://nlnet.nl/propose/
> (o la version traducida si prefieres leer en español, pero LLENA en ingles)
> Deadline: 1 Abril 2026, 12:00 CEST
> Validado contra el HTML del formulario: 2026-03-31

---

## Validacion rapida de limites

- `Your name`: max `100`
- `Email address`: max `100`
- `Phone number`: max `100`
- `Organisation`: max `100`
- `Country`: max `100`
- `Proposal name`: max `100`
- `Website / wiki`: max `100`
- `Abstract`: max `1500`
- `Previous involvement`: max `10000`
- `Budget usage explanation`: max `10000`
- `Comparison with existing efforts`: max `10000`
- `Technical challenges`: max `12500`
- `Ecosystem description`: max `10000`
- `AI details`: max `10000`

## Hallazgos importantes de esta revision

- El `Abstract` original estaba pasado del limite del formulario.
- La seccion `AI details` original **no** cumplia por si sola con la politica de GenAI de NLnet; piden modelo, fechas/horas, prompts y salida sin editar.
- Ajuste varios claims para que sean mas defendibles frente al estado real del repo actual.

## 1. Your name

```
Héctor Martínez Reséndiz
```

## 2. Email address

```
(redacted — private)
```

## 3. Phone number

```
(redacted — private)
```

## 4. Organisation

```
Independent developer
```

## 5. Country

```
Mexico
```

## 6. Please select a call

> Selecciona: **NGI Zero Commons Fund**

## 7. Proposal name

```
LifeOS: An Open-Source, Privacy-First AI Operating System for Sovereign Personal Computing
```

## 8. Website / wiki

```
https://github.com/hectormr206/lifeos
```

## 9. Abstract (campo grande — pegar TODO esto)

```
LifeOS is an open-source, AI-native Linux distribution built on Fedora bootc. It provides a personal assistant, Axi, that runs primarily on the user's own hardware using open-weight language models through llama.cpp/llama-server, encrypted local memory, and a privacy-by-default architecture.

The current implementation already includes: local inference on consumer GPUs or CPU; encrypted local storage for user memory and context; a Rust daemon and CLI; an MCP-based OS control plane with 50+ tools for windows, apps, browser, files, LibreOffice, COSMIC desktop and accessibility; reproducible OS image builds; and reliability features such as watchdog integration, safe mode, config checkpoints and rollback paths. Telegram is the primary remote interaction channel today, with additional bridges under active development.

The requested funding will focus on outcomes that make LifeOS publicly usable and easier to adopt: a downloadable public beta ISO with a first-boot experience, encrypted cross-device sync, stronger accessibility coverage for desktop app control, better user and contributor documentation in English and Spanish, and community infrastructure for external contributors.

LifeOS is implemented mainly in Rust, targets privacy-conscious end users and developers, and is designed as a sovereign alternative to cloud-dependent AI assistants integrated into proprietary operating systems.
```

## 10. Previous involvement (prior projects)

```
I am a software engineer based in Mexico. I started building LifeOS in early 2026 as a solo project, learning Rust along the way with heavy use of AI development tools (Claude Code, OpenAI Codex, Gemini CLI). The project itself is proof of concept for AI-augmented development: a developer without prior Rust experience built an AI-native operating system with 100+ modules and 300+ tests by leveraging the same kind of AI tools that LifeOS aims to provide to end users.

The LifeOS codebase currently includes 100+ Rust source files across the daemon and CLI, 300+ automated tests, a complete OS image pipeline (bootc + Containerfile), 600+ SVG assets, multi-LLM routing, and a privacy-aware architecture with encrypted local storage.

I am an active user of Fedora, bootc, COSMIC Desktop, and the broader immutable Linux ecosystem. My professional background is in web development (Next.js, NestJS, PostgreSQL). LifeOS is my first systems-level project, my first large-scale Rust codebase, and my first open-source operating system.
```

## 11. Requested Amount (en Euro)

```
50000
```

## 12. Budget usage explanation

```
Development (core): EUR 28,000
- 6 months x approx. EUR 4,650/month full-time development
- Scope: encrypted cross-device sync, public beta stabilization, AT-SPI2 accessibility completion, MCP/desktop control improvements, mobile companion app prototype, multi-LLM router hardening

AI development tools: EUR 4,000
- 6 months of AI-assisted development subscriptions (approx. EUR 650/month)
- Claude Max (code generation and architecture), OpenAI Pro (debugging and code review), Google AI Ultra (documentation, UI design, and multimodal tasks)
- These tools directly accelerate development velocity as a solo developer

Documentation: EUR 3,000
- Approx. 75 hours x EUR 40/hour
- Scope: user guides in Spanish and English, contributor onboarding docs, architecture reference, video tutorials for non-technical users

Infrastructure: EUR 5,000
- Approx. EUR 830/month x 6 months
- Scope: CI runners (self-hosted GitHub Actions), build/test infrastructure, OCI image hosting, release automation, domain and website hosting

Testing hardware: EUR 7,000
- Three validation machines or equivalent component budget
- Scope: AMD GPU, NVIDIA GPU, and CPU-only configurations for comprehensive local inference and desktop integration testing

Community and outreach: EUR 3,000
- Project website with real content (hectormr.com)
- Spanish-language video tutorials and development livestreams on YouTube
- Participation in online free software events (virtual FOSDEM, Latin American Linux events)
- Matrix room setup and moderation
```

## 13. Other funding sources

```
Current: Self-funded, approximately $140 USD/month from personal income (AI development tool subscriptions: Claude Code, OpenAI, Google AI).
Past funding: None.
Pending applications: None.

LifeOS has been entirely self-funded by the developer since its inception in 2026.
```

## 14. Comparison with existing efforts

```
LifeOS occupies a unique position — no existing project combines all of: immutable OS + local AI + encrypted memory + OS-level control + self-healing. Here is a comparison:

- Claude Code and similar coding agents: strong for developer workflows, but primarily oriented to terminal and repository interaction rather than operating-system-level personal computing. LifeOS focuses on local inference, encrypted memory, and whole-desktop control.

- OpenClaw: strong agentic workflow ideas, but based on a different architecture and not centered on the combination of immutable OS distribution, local-first inference, and privacy-by-default personal computing that LifeOS is targeting.

- Apple Intelligence: AI integrated into macOS/iOS. Proprietary, requires Apple hardware, processes data through Apple's cloud (even with "Private Cloud Compute"), no user sovereignty. LifeOS is open-source, runs on any x86_64 hardware, and all data stays local.

- Google Gemini: AI assistant with context awareness. Cloud-dependent, deeply tied to Google services, significant privacy concerns. LifeOS provides equivalent capabilities (contextual awareness, memory, habits) without any cloud dependency.

- Fedora Silverblue / Universal Blue: Immutable Linux desktops. Excellent OS foundation but no AI layer, no personal assistant, no personalization. LifeOS builds on the same bootc technology but adds the complete AI runtime.

- postmarketOS / GrapheneOS: Privacy-focused mobile OS projects. Strong privacy stance but mobile-only and not centered on local desktop AI workflows. LifeOS is desktop-focused with planned mobile companion.

Overall, very few open-source projects are attempting to build a complete AI-native desktop operating system where privacy and local control are foundational requirements rather than optional add-ons.
```

## 15. Technical challenges

```
1. Running LLMs on consumer hardware with acceptable latency.
We use quantized models (Q4_K_M, 4-bit) via llama.cpp's llama-server, with automatic GPU layer management that adapts to available VRAM. A privacy-aware multi-LLM router can optionally delegate to cloud providers (with explicit user consent and automatic data sensitivity classification), but the system works fully offline.

2. Making AI control real desktop applications reliably.
Our 4-layer control hierarchy provides graceful degradation: when a structured MCP tool exists (50+ currently), we use it; when not, we try D-Bus native adapters; then AT-SPI2 accessibility trees (implemented with the atspi crate); as last resort, screenshot + OCR + input simulation. The challenge is expanding MCP tool coverage to minimize vision fallback usage.

3. Maintaining system integrity on an immutable OS while allowing AI-driven adaptation.
Fedora bootc provides immutable /usr with ComposeFS + fs-verity, but the AI daemon needs to learn and adapt. We solve this with a mutable /var/lib/lifeos partition, numbered config checkpoints with rollback, a circuit breaker pattern for self-modification (max 3 failures before 6h cooldown), and a safe mode that activates after 3 consecutive boot failures.

4. Privacy-preserving personalization without cloud.
The UserModel, knowledge graph, and procedural memory all use local-only encrypted storage (AES-GCM-SIV with machine-derived keys). The challenge is achieving Apple Intelligence-level personalization quality using only on-device 4B-parameter models, without the training data and compute resources that cloud providers have.

5. Building a sustainable open-source project as a solo developer in Mexico.
Limited budget ($140/month), no institutional backing, Spanish-speaking primary audience. This grant would provide the resources needed to reach a public beta that can attract contributors and build a community.
```

## 16. Ecosystem description

```
Target users (Phase 1): Privacy-conscious developers and Linux enthusiasts who want a personal AI assistant that respects their data sovereignty. These users already run Linux, understand the value of local-first computing, and are willing to try a new distribution.

Target users (Phase 2): Non-technical Spanish-speaking users who want a simple, secure computer with AI capabilities but don't trust cloud services with their personal data. LifeOS aims to be the "it just works" Linux for people who care about privacy but don't want to configure anything.

Community strategy:
- Matrix room for real-time discussion
- GitHub Discussions for feature requests and support
- Spanish-language tutorials on YouTube (reaching the underserved Latin American open source community)
- Participation in FOSDEM, Fedora Flock, and Latin American free software events

Engagement with related projects:
- Fedora / bootc: LifeOS builds directly on Fedora's bootc infrastructure. Improvements to bootc tooling benefit both projects.
- llama.cpp: Primary inference backend. We contribute bug reports and usage patterns from the desktop OS context.
- COSMIC Desktop (System76): LifeOS is one of the first third-party OS projects to deeply integrate with COSMIC via MCP tools.
- AT-SPI2 / Odilia: Our accessibility layer uses the atspi Rust crate from the Odilia project, advancing accessible computing.

Sustainability post-grant:
- GitHub Sponsors for ongoing community support
- Optional premium LLM provider integrations (users pay the provider directly, LifeOS takes no cut)
- Consulting and support contracts for institutional deployments (universities, government offices)
- Potential future: managed LifeOS appliances for privacy-conscious organizations
```

## 17. Attachments

> (Opcional — puedes adjuntar un PDF con screenshots del sistema, el README del repo, o nada)

## 18. Generative AI usage

> Selecciona: **"I have used generative AI..."**

## 19. AI details (campo condicional)

```
Model: Claude Opus 4 (Anthropic) via Claude Code CLI inside VSCodium
Date: 2026-03-31, afternoon-evening (Mexico Central Time, UTC-6)

Use in proposal preparation:
- Drafting and structuring all proposal sections from Spanish development notes
- Translating technical descriptions from Spanish to English
- Condensing existing project documentation to fit form character limits
- Verifying character counts against form field limits

The applicant (Héctor Martínez Reséndiz) directed all content decisions. The AI assistant generated English text based on the applicant's Spanish instructions and the existing codebase documentation. All technical claims were verified against the actual working repository (300+ tests, 100+ Rust source files). The project vision, architecture, and all code are the original work of the applicant.

Full conversation transcript is available on request.
```

## 20. AI prompts file

> (Opcional — puedes omitir)

## 21. Privacy acknowledgment

> Marca el checkbox ✅

## 22. Send copy

> Marca el checkbox ✅ (para que te llegue copia a tu email)

## 23. PGP pubkey

> (Opcional — dejar vacío si no tienes una)

## 24. Submit

> Click en **Submit** 🚀

---

## IMPORTANTE — Antes de enviar

1. Revisa que tu email sea correcto (ahi te contactan)
2. Revisa tu numero de telefono (formato +52)
3. Si el repo de LifeOS es privado, considera hacerlo publico o agregar una nota de que puedes dar acceso
4. El deadline es **1 Abril 2026 a las 12:00 CEST** (5:00 AM hora de Mexico centro)
