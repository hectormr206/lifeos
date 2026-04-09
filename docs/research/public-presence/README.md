# Research: Public Presence, Landing, and Domain Strategy

> Context: post-NLnet submission, founder solo, Spanish-first communication, need to make LifeOS easier to discover and support.
> Validation date: `2026-04-01`

---

## 1. Recommendation Summary

The next step to make LifeOS more visible should be:

1. launch a **public landing page**
2. put it in a **separate public repo**
3. publish it first on **`lifeos.hectormr.com`**
4. connect it to:
   - GitHub
   - newsletter / waitlist
   - YouTube
   - Twitch
   - support links

This should **not** become a new core product phase yet.
It should live as:

- a **research + go-to-market track**
- and as a practical extension of **Fase AV**

The goal is not to build a huge website. The goal is to create a clean public front door for the project.

Public messaging should keep two truths together:

- LifeOS is built in Mexico.
- LifeOS is open to users, contributors, and supporters anywhere.

The public front door should avoid sounding region-exclusive or turning the brand into tourism or folklore.

Public-facing copy should also inherit the repo maturity taxonomy:

- **validated on host**
- **integrated in repo**
- **experimental**
- **shipped disabled / feature-gated**

That keeps the landing honest about what is already defendable versus what is still a strong foundation in progress.

---

## 2. Why This Matters Now

After applying to NLnet, the next bottleneck is no longer "having a proposal".
The next bottleneck is **public clarity**:

- what is LifeOS?
- why does it matter?
- what already works?
- where should people follow it?
- how can they support it?

Right now the main repo is useful for developers, but it is not the best first-touch surface for:

- grants reviewers
- potential sponsors
- future users
- newsletter subscribers
- YouTube / Twitch audience
- press or collaborators

So the next move should be a public-facing landing page, not a giant site.

---

## 3. Do We Need a New Phase?

### Short answer

**No new core product phase yet.**

### Better structure

- keep this as **research**
- extend **Fase AV: Financiamiento y Sostenibilidad**
- only convert it into a larger roadmap phase later if the site becomes:
  - docs platform
  - download portal
  - launch surface
  - newsletter / sponsor hub
  - public release infrastructure

For now, this is a **distribution and visibility problem**, not a product-core problem.

---

## 4. Repo Strategy

### Recommendation

Create a **separate public repo** for the website.

Suggested repo name:

- **`lifeos-site`** (recommended)

Other acceptable names:

- `lifeos-web`
- `lifeos-landing`

### Why a separate repo?

- avoids mixing OS/runtime work with marketing/web work
- faster deploys
- easier previews
- easier to iterate design/copy without touching the main product repo
- clearer for future contributors

### Public or private?

**Public**.

Reason:

- the purpose of the site is public discovery
- it benefits from public previews, feedback, and easy sharing
- the private tactical planning should stay elsewhere, not in the site repo

---

## 5. Domain Strategy

### Recommendation

Start with:

- **`lifeos.hectormr.com`**

Do **not** block launch on buying a new domain.

### Why this is the right first move

- zero extra cost
- immediate launch
- keeps creator attribution visible
- easy to move later to a dedicated domain

### What about buying a domain now?

Not necessary yet.

The better order is:

1. launch on `lifeos.hectormr.com`
2. validate message + traffic + newsletter signups
3. decide if buying a dedicated domain is worth it

### Domain notes from quick checks

On `2026-04-01`, quick DNS resolution checks suggested:

- `lifeos.ai` resolves
- `lifeos.dev` resolves
- `lifeos.app` resolves
- `axi.life` resolves
- `lifeos.so` did not resolve
- `getlifeos.com` did not resolve
- `lifeos.mx` did not resolve
- `lifeos.lat` did not resolve

Important:

- DNS unresolved does **not** guarantee domain availability
- DNS resolved strongly suggests the domain is already in use

### Practical recommendation on future domain purchase

If later you buy one, prioritize:

1. `getlifeos.com`
2. `lifeos.mx`
3. `lifeos.lat`
4. `lifeos.so`

I would **not** assume `lifeos.ai` is available or worth chasing first.

---

## 6. Hosting Recommendation

### Best default recommendation

- **Vercel** for fast deployment and future flexibility

Why:

- easy custom domain support
- preview deployments
- good fit if the site grows beyond a pure static page
- easy for a separate public repo

### Strong alternative

- **GitHub Pages**

Why:

- simple
- free
- works very well for a static landing
- supports custom domains on public repos

### My recommendation for LifeOS

If the goal is **one-page landing fast**:

- GitHub Pages is enough

If the goal is **landing now, expansion later**:

- Vercel is better

### Final choice

For LifeOS, I recommend:

- **separate public repo**
- **simple static site**
- **deploy on Vercel**
- **point `lifeos.hectormr.com` to it**

Reason:

it gives you a fast launch today and less migration pain later.

---

## 7. Site Scope

### Do not build yet

- giant docs portal
- user auth
- download center with full release automation
- blog CMS
- complex product site

### Build now

A **single landing page** with strong positioning.

That page should answer:

1. what is LifeOS?
2. why is it different?
3. what works today?
4. who is it for?
5. how do I follow/support it?

---

## 8. Information Architecture for v1

Recommended page structure:

### 1. Hero

- one-sentence positioning
- subheadline
- primary CTA
- secondary CTA

### 2. Why LifeOS

Three short pillars:

- local-first AI
- privacy-first by default
- AI-native operating system

### 3. What Works Today

Only claims that are already real enough to defend:

- local inference (`validated on host`)
- encrypted local memory foundations (`integrated in repo`)
- desktop control plane foundations (`integrated in repo`)
- Telegram remote loop (`validated on host`)
- voice / vision / automation foundations (`experimental`)

### 4. Why It Matters

Short framing against cloud assistants and locked ecosystems.

### 5. Follow the Project

- GitHub
- newsletter
- YouTube
- Twitch

### 6. Support LifeOS

- GitHub Sponsors
- donations / support link
- "contact for setup / sponsorship"

### 7. Road to Public Beta

Short 3-step roadmap, not giant roadmap dump.

### 8. Footer

- attribution
- repo
- privacy statement
- contact / creator link

---

## 9. Initial Copy Direction

### Hero recommendation

**Headline**

`A local-first AI operating system for sovereign personal computing.`

**Subheadline**

`LifeOS is an AI-native Linux distribution where your assistant runs on your own machine, remembers locally, and helps across your desktop without sending your life to the cloud.`

Safer variant if you want tighter truth alignment:

`LifeOS is an AI-native Linux distribution exploring a local-first assistant that runs on your own machine, keeps core data local, and is being hardened across desktop control and remote interaction.`

**Primary CTA**

`Follow the project`

**Secondary CTA**

`Support LifeOS`

### Three-pillar block

**Local-first**
- open-weight models on your hardware

**Private by default**
- encrypted memory and local control

**AI-native OS**
- not just an app, but a system built around the assistant

### Support block

`LifeOS is being built in public. If you want to help this become a real public beta, follow the project, subscribe for updates, and support its development.`

---

## 10. Visual Direction

The landing should follow the existing LifeOS brand:

- dark-first
- Teal Axi as primary accent
- Pink Axi only as secondary accent / alert accent
- strong contrast
- no generic SaaS look
- no purple-on-white startup cliche

Use existing branding as source of truth:

- `docs/branding/brand-guidelines.md`

### Mood

- sovereign
- intelligent
- calm
- technical
- not corporate-boring
- not gamer-chaotic

---

## 11. What the Landing Must Connect To

The landing only works if it connects to real rails:

- GitHub repo
- newsletter / waitlist
- YouTube
- Twitch
- support / sponsor links

Without these rails, the site is just a poster.

---

## 12. Launch Checklist

### Before launch

- pick repo name
- pick host
- create subdomain
- prepare logo and favicon
- define 3 real CTAs
- decide newsletter tool

### v1 launch

- publish landing
- add site URL to GitHub repo
- add site URL to YouTube/Twitch bios
- add site URL to NLnet / sponsor-facing materials

### First 30 days after launch

- publish at least 1 demo post
- publish at least 1 YouTube update
- run 1 technical stream
- capture signups / clicks
- refine the copy based on what people actually ask

---

## 13. Concrete Recommendation

If we optimize for speed and leverage, the best next move is:

1. create **public repo** `lifeos-site`
2. build **one strong landing page**
3. deploy it on **Vercel**
4. publish it on **`lifeos.hectormr.com`**
5. connect it to:
   - GitHub
   - newsletter
   - YouTube
   - Twitch
   - support links

That is the highest-leverage next step after NLnet.

---

## 14. Sources

- GitHub Pages custom domains: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/about-custom-domains-and-github-pages
- Vercel domains: https://vercel.com/docs/getting-started-with-vercel/domains
- Vercel custom domain setup: https://vercel.com/docs/domains/set-up-custom-domain
- Cloudflare Pages custom domains: https://developers.cloudflare.com/pages/configuration/custom-domains/

---

## 15. Next Operational Document

For the exact v1 execution brief, see:

- [landing-v1-brief.md](landing-v1-brief.md)
