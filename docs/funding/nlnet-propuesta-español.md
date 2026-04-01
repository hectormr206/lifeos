# Propuesta NLnet — Traduccion al Español

> Lo que se envio a NLnet el 1 de Abril de 2026 (en ingles).
> Este archivo es la traduccion para referencia de Hector.

---

## 1. Nombre

Héctor Martínez Reséndiz

## 2. Email

(redactado — privado)

## 3. Telefono

(redactado — privado)

## 4. Organizacion

Desarrollador independiente

## 5. Pais

Mexico

## 6. Convocatoria

NGI Zero Commons Fund

## 7. Nombre de la propuesta

LifeOS: Un Sistema Operativo AI de Codigo Abierto, Privacidad Primero, para Computacion Personal Soberana

## 8. Sitio web

https://github.com/hectormr206/lifeos

## 9. Resumen

LifeOS es una distribucion Linux nativa de AI, de codigo abierto, construida sobre Fedora bootc. Proporciona un asistente personal, Axi, que corre principalmente en el hardware del usuario usando modelos de lenguaje de pesos abiertos a traves de llama.cpp/llama-server, memoria local encriptada, y una arquitectura de privacidad por defecto.

La implementacion actual ya incluye: inferencia local en GPUs de consumo o CPU; almacenamiento local encriptado para memoria y contexto del usuario; un daemon y CLI en Rust; un plano de control del OS basado en MCP con mas de 50 herramientas para ventanas, aplicaciones, navegador, archivos, LibreOffice, escritorio COSMIC y accesibilidad; builds de imagen OS reproducibles; y funcionalidades de confiabilidad como integracion con watchdog, modo seguro, checkpoints de configuracion y rutas de rollback. Telegram es el canal principal de interaccion remota hoy, con bridges adicionales en desarrollo activo.

El financiamiento solicitado se enfocara en resultados que hagan a LifeOS publicamente usable y mas facil de adoptar: una ISO beta publica descargable con experiencia de primer arranque, sincronizacion encriptada entre dispositivos, mayor cobertura de accesibilidad para control de aplicaciones de escritorio, mejor documentacion para usuarios y contribuidores en ingles y español, e infraestructura comunitaria para contribuidores externos.

LifeOS esta implementado principalmente en Rust, dirigido a usuarios finales y desarrolladores conscientes de la privacidad, y esta disenado como una alternativa soberana a los asistentes AI dependientes de la nube integrados en sistemas operativos propietarios.

## 10. Participacion previa en proyectos relevantes

Soy ingeniero de software basado en Mexico. Empece a construir LifeOS a principios de 2026 como proyecto en solitario, aprendiendo Rust en el camino con uso intensivo de herramientas de desarrollo AI (Claude Code, OpenAI Codex, Gemini CLI). El proyecto mismo es una prueba de concepto del desarrollo aumentado por AI: un desarrollador sin experiencia previa en Rust construyo un sistema operativo nativo de AI con mas de 100 modulos y mas de 300 tests aprovechando el mismo tipo de herramientas AI que LifeOS busca proporcionar a los usuarios finales. Actualmente uso LifeOS como mi sistema operativo diario en mi laptop, donde el propio proyecto se sigue desarrollando.

El codebase de LifeOS actualmente incluye mas de 100 archivos fuente en Rust entre el daemon y el CLI, mas de 300 tests automatizados, un pipeline completo de imagen OS (bootc + Containerfile), mas de 600 assets SVG, enrutamiento multi-LLM, y una arquitectura consciente de la privacidad con almacenamiento local encriptado.

Mi experiencia profesional es en desarrollo web (Next.js, NestJS, PostgreSQL). LifeOS es mi primer proyecto a nivel de sistemas, mi primer codebase grande en Rust, y mi primer sistema operativo de codigo abierto.

## 11. Monto solicitado

EUR 50,000

## 12. Explicacion del presupuesto y fuentes de financiamiento

**Desarrollo (core): EUR 28,000**
- 6 meses x aprox. EUR 4,650/mes desarrollo a tiempo completo
- Alcance: sincronizacion encriptada entre dispositivos, estabilizacion de beta publica, completar accesibilidad AT-SPI2, mejoras en control de escritorio/MCP, prototipo de app movil companion, endurecimiento del router multi-LLM

**Herramientas AI de desarrollo: EUR 4,000**
- 6 meses de suscripciones de desarrollo asistido por AI (aprox. EUR 650/mes)
- Claude Max (generacion de codigo y arquitectura), OpenAI Pro (debugging y revision de codigo), Google AI Ultra (documentacion, diseno de UI, y tareas multimodales)
- Estas herramientas aceleran directamente la velocidad de desarrollo como desarrollador solo

**Documentacion: EUR 3,000**
- Aprox. 75 horas x EUR 40/hora
- Alcance: guias de usuario en español e ingles, documentacion de onboarding para contribuidores, referencia de arquitectura, video tutoriales para usuarios no tecnicos

**Infraestructura: EUR 5,000**
- Aprox. EUR 830/mes x 6 meses
- Alcance: CI runners (GitHub Actions self-hosted), infraestructura de build/test, hosting de imagenes OCI, automatizacion de releases, dominio y hosting web

**Hardware de pruebas: EUR 7,000**
- Tres maquinas de validacion o presupuesto equivalente en componentes
- Alcance: configuraciones AMD GPU, NVIDIA GPU, y solo-CPU para testing integral de inferencia local e integracion con escritorio

**Comunidad y difusion: EUR 3,000**
- Sitio web del proyecto con contenido real (hectormr.com)
- Video tutoriales y livestreams de desarrollo en español en YouTube
- Participacion en eventos online de software libre (FOSDEM virtual, eventos Linux latinoamericanos)
- Configuracion y moderacion de sala Matrix

---

**Fuentes actuales:** Autofinanciado, aproximadamente $140 USD/mes de ingresos personales (suscripciones a herramientas AI de desarrollo: Claude Code, OpenAI, Google AI).
**Financiamiento pasado:** Ninguno.
**Aplicaciones pendientes:** Ninguna.

LifeOS ha sido completamente autofinanciado por el desarrollador desde su inicio en 2026.

## 14. Comparacion con esfuerzos existentes

LifeOS ocupa una posicion unica — ningun proyecto existente combina todo esto: OS inmutable + AI local + memoria encriptada + control a nivel OS + auto-reparacion. Aqui una comparacion:

- **Claude Code y agentes de codigo similares:** fuertes para flujos de trabajo de desarrollo, pero orientados principalmente a interaccion en terminal y repositorio en vez de computacion personal a nivel de sistema operativo. LifeOS se enfoca en inferencia local, memoria encriptada, y control de todo el escritorio.

- **OpenClaw:** ideas fuertes de flujo de trabajo agentico, pero basado en una arquitectura diferente y no centrado en la combinacion de distribucion OS inmutable, inferencia local-first, y computacion personal con privacidad por defecto que LifeOS busca.

- **Apple Intelligence:** AI integrada en macOS/iOS. Propietaria, requiere hardware Apple, procesa datos a traves de la nube de Apple (incluso con "Private Cloud Compute"), sin soberania del usuario. LifeOS es de codigo abierto, corre en cualquier hardware x86_64, y todos los datos se quedan locales.

- **Google Gemini:** Asistente AI con conciencia de contexto. Dependiente de la nube, profundamente atado a servicios de Google, preocupaciones significativas de privacidad. LifeOS proporciona capacidades equivalentes (conciencia contextual, memoria, habitos) sin ninguna dependencia de la nube.

- **Fedora Silverblue / Universal Blue:** Escritorios Linux inmutables. Excelente base OS pero sin capa AI, sin asistente personal, sin personalizacion. LifeOS se construye sobre la misma tecnologia bootc pero agrega el runtime AI completo.

- **postmarketOS / GrapheneOS:** Proyectos de OS movil enfocados en privacidad. Postura fuerte de privacidad pero solo movil y no centrados en flujos de trabajo de AI de escritorio local. LifeOS esta enfocado en escritorio con companion movil planeado.

En general, muy pocos proyectos de codigo abierto estan intentando construir un sistema operativo de escritorio completo nativo de AI donde la privacidad y el control local son requisitos fundacionales en vez de complementos opcionales.

## 15. Retos tecnicos significativos

**1. Correr LLMs en hardware de consumo con latencia aceptable.**
Usamos modelos cuantizados (Q4_K_M, 4-bit) via llama-server de llama.cpp, con gestion automatica de capas GPU que se adapta a la VRAM disponible. Un router multi-LLM consciente de la privacidad puede opcionalmente delegar a proveedores cloud (con consentimiento explicito del usuario y clasificacion automatica de sensibilidad de datos), pero el sistema funciona completamente offline.

**2. Hacer que la AI controle aplicaciones de escritorio reales de forma confiable.**
Nuestra jerarquia de control de 4 capas proporciona degradacion graceful: cuando una herramienta MCP estructurada existe (50+ actualmente), la usamos; cuando no, probamos adaptadores nativos D-Bus; luego arboles de accesibilidad AT-SPI2 (implementado con el crate atspi); como ultimo recurso, screenshot + OCR + simulacion de entrada. El reto es expandir la cobertura de herramientas MCP para minimizar el uso del fallback de vision.

**3. Mantener la integridad del sistema en un OS inmutable mientras se permite adaptacion dirigida por AI.**
Fedora bootc proporciona /usr inmutable con ComposeFS + fs-verity, pero el daemon AI necesita aprender y adaptarse. Lo resolvemos con una particion mutable /var/lib/lifeos, checkpoints de configuracion numerados con rollback, un patron circuit breaker para auto-modificacion (max 3 fallos antes de cooldown de 6h), y un modo seguro que se activa despues de 3 fallos consecutivos de arranque.

**4. Personalizacion que preserva privacidad sin nube.**
El UserModel, knowledge graph, y memoria procedural todos usan almacenamiento local encriptado (AES-GCM-SIV con claves derivadas de la maquina). El reto es lograr calidad de personalizacion nivel Apple Intelligence usando solo modelos de 4B parametros on-device, sin los datos de entrenamiento y recursos de computo que los proveedores cloud tienen.

**5. Construir un proyecto de codigo abierto sostenible como desarrollador solo en Mexico.**
Presupuesto limitado ($140/mes), sin respaldo institucional, audiencia principal hispanohablante. Este grant proporcionaria los recursos necesarios para alcanzar una beta publica que pueda atraer contribuidores y construir una comunidad.

## 16. Ecosistema del proyecto

**Usuarios objetivo (Fase 1):** Desarrolladores conscientes de la privacidad y entusiastas de Linux que quieren un asistente AI personal que respete su soberania de datos. Estos usuarios ya usan Linux, entienden el valor de la computacion local-first, y estan dispuestos a probar una nueva distribucion.

**Usuarios objetivo (Fase 2):** Usuarios hispanohablantes no tecnicos que quieren una computadora simple y segura con capacidades AI pero que no confian en servicios cloud con sus datos personales. LifeOS busca ser el Linux "que simplemente funciona" para personas que les importa la privacidad pero no quieren configurar nada.

**Estrategia comunitaria:**
- Sala Matrix para discusion en tiempo real
- GitHub Discussions para solicitudes de funcionalidades y soporte
- Tutoriales en español en YouTube (llegando a la comunidad latinoamericana de codigo abierto desatendida)
- Participacion en FOSDEM, Fedora Flock, y eventos latinoamericanos de software libre

**Engagement con proyectos relacionados:**
- Fedora / bootc: LifeOS se construye directamente sobre la infraestructura bootc de Fedora. Mejoras al tooling de bootc benefician ambos proyectos.
- llama.cpp: Backend principal de inferencia. Contribuimos reportes de bugs y patrones de uso desde el contexto de OS de escritorio.
- COSMIC Desktop (System76): LifeOS es uno de los primeros proyectos OS de terceros en integrarse profundamente con COSMIC via herramientas MCP.
- AT-SPI2 / Odilia: Nuestra capa de accesibilidad usa el crate atspi en Rust del proyecto Odilia, avanzando la computacion accesible.

**Sostenibilidad post-grant:**
- GitHub Sponsors para soporte comunitario continuo
- Integraciones opcionales de proveedores LLM premium (usuarios pagan al proveedor directamente, LifeOS no toma comision)
- Contratos de consultoria y soporte para despliegues institucionales (universidades, oficinas de gobierno)
- Futuro potencial: appliances LifeOS gestionados para organizaciones conscientes de la privacidad

## 19. Detalles de uso de AI generativa

Modelo: Claude Opus 4 (Anthropic) via Claude Code CLI dentro de VSCodium
Fecha: 2026-03-31, tarde-noche (Hora Central de Mexico, UTC-6)

Uso en la preparacion de la propuesta:
- Redaccion y estructuracion de todas las secciones de la propuesta desde notas de desarrollo en español
- Traduccion de descripciones tecnicas de español a ingles
- Condensacion de documentacion existente del proyecto para ajustar a limites de caracteres del formulario

El solicitante (Héctor Martínez Reséndiz) dirigio todas las decisiones de contenido. El asistente AI genero texto en ingles basado en las instrucciones en español del solicitante y la documentacion existente del codebase. Todas las claims tecnicas fueron verificadas contra el repositorio de trabajo actual (300+ tests, 100+ archivos fuente Rust). La vision del proyecto, decisiones de arquitectura, y todo el codigo son trabajo original del solicitante.

Transcripcion completa de la conversacion disponible bajo solicitud.
