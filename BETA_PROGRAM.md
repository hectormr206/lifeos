# LifeOS Beta Testing Program

Welcome to the LifeOS Beta Testing Program! Help us build the best AI-native Linux distribution by testing pre-release versions and providing feedback.

## 🎯 Program Overview

### What is the Beta Program?

The Beta Testing Program gives early access to new LifeOS features before public release. Beta testers help identify bugs, suggest improvements, and shape the future of LifeOS.

### Benefits of Joining

- **Early Access**: Try new features before anyone else
- **Direct Communication**: Talk directly with the development team
- **Recognition**: Featured in release notes and documentation
- **Swag**: Exclusive Beta Tester stickers and merchandise
- **Shape the Future**: Your feedback directly influences development

### Beta Tester Levels

| Level | Requirements | Benefits |
|-------|--------------|----------|
| 🥉 **Explorer** | Join and install beta | Access to beta builds |
| 🥈 **Tester** | File 3+ quality bug reports | Beta Tester badge |
| 🥇 **Contributor** | Submit PRs or detailed feedback | Direct dev channel access |
| 💎 **Champion** | Consistent high-quality contributions | Lifetime swag, name in credits |

## 🚀 Getting Started

### Prerequisites

- Spare computer or VM for testing
- Basic Linux knowledge
- Time to test and report issues
- GitHub account

### Join the Program

1. **Fill out the application**
   ```bash
   life beta join
   ```
   Or apply online: https://lifeos.io/beta

2. **Join the community**
   - Discord: https://discord.gg/lifeos-beta
   - Matrix: #lifeos-beta:matrix.org
   - Forum: https://forum.lifeos.io/c/beta

3. **Download the beta**
   ```bash
   life beta download
   ```

4. **Start testing!**

## 📋 Testing Guidelines

### What to Test

#### Core System
- [ ] Installation process
- [ ] Boot and shutdown
- [ ] Updates and rollbacks
- [ ] Recovery mode
- [ ] Hardware detection

#### AI Features
- [ ] Model installation and management
- [ ] Chat interface
- [ ] Voice commands
- [ ] Screen understanding
- [ ] Natural language actions

#### Desktop Environment
- [ ] GNOME/COSMIC integration
- [ ] Theme switching
- [ ] Notifications
- [ ] Settings

#### Applications
- [ ] Flatpak apps from Store
- [ ] Built-in applications
- [ ] System utilities

### Testing Schedule

| Phase | Focus | Duration |
|-------|-------|----------|
| Alpha | Core stability | 2 weeks |
| Beta 1 | Feature completeness | 2 weeks |
| Beta 2 | Polish and bugs | 2 weeks |
| RC | Release preparation | 1 week |

## 🐛 Reporting Issues

### Bug Reports

Use the built-in tool:
```bash
life feedback bug
```

Or file on GitHub using our template.

**Good bug reports include:**
- Clear title and description
- Steps to reproduce
- Expected vs actual behavior
- System info (`life system info`)
- Screenshots or logs
- Severity assessment

### Feature Requests

```bash
life feedback feature
```

**Good feature requests include:**
- Use case description
- Proposed solution
- Alternatives considered
- Mockups (if applicable)

### Feedback Surveys

Weekly surveys are sent via email. Complete them for:
- Usage statistics
- Feature prioritization
- Satisfaction ratings
- Open feedback

## 📊 Feedback Channels

### Real-time Chat
- **Discord**: #beta-general, #bug-reports
- **Matrix**: Same channels bridged

### Structured Feedback
- GitHub Issues (bugs/features)
- Discourse forum (discussions)
- Weekly surveys (email)

### Private Feedback
- Email: beta@lifeos.io
- For security issues or sensitive topics

## 🏆 Recognition Program

### Monthly Awards

| Award | Criteria | Prize |
|-------|----------|-------|
| Bug Hunter | Most bugs reported | $50 credit |
| Quality Tester | Best bug report quality | $50 credit |
| Feature Champion | Best feature suggestion | $50 credit |
| Community Helper | Most helpful in Discord | $50 credit |

### Hall of Fame

Top contributors are recognized:
- In-app credits
- Release notes mentions
- Website listing
- Annual awards

## 📅 Beta Timeline

### Current Beta: v0.2.0-beta

**Focus Areas:**
- AI model management improvements
- New theme system
- App Store launch
- Mobile API preview

**Known Issues:**
- See [KNOWN_ISSUES.md](./KNOWN_ISSUES.md)

### Upcoming Milestones

| Date | Milestone | Features |
|------|-----------|----------|
| 2026-03-15 | Beta 1 | Theme system, Store v1 |
| 2026-03-29 | Beta 2 | Mobile API, AI improvements |
| 2026-04-12 | RC 1 | Bug fixes, polish |
| 2026-04-19 | v0.2.0 Release | Stable release |

## 🔒 Privacy & Data

### What We Collect

- System info (hardware, OS version)
- Bug reports and feedback
- Usage statistics (anonymized)
- Crash logs

### What We Don't Collect

- Personal files or data
- Browsing history
- Application content
- Location data

### Opt-out

```bash
life beta telemetry off
```

All data collection is optional and transparent.

## ⚠️ Beta Disclaimer

**Beta software may:**
- Contain bugs and crashes
- Lose data (backup regularly!)
- Change significantly before release
- Not be suitable for daily use

**By joining, you acknowledge:**
- This is pre-release software
- Features may change or be removed
- Data loss is possible
- You will report issues constructively

## 🛠️ Tools for Beta Testers

### Built-in Commands

```bash
# Join beta program
life beta join

# Download latest beta
life beta download

# Check for updates
life beta update

# Submit feedback
life feedback bug
life feedback feature
life feedback general

# View known issues
life beta known-issues

# System diagnostics
life system diagnose

# Generate report
life beta report
```

### External Tools

- [LifeOS Beta Dashboard](https://lifeos.io/beta/dashboard)
- [Issue Tracker](https://github.com/hectormr/lifeos/issues)
- [Test Cases](https://lifeos.io/beta/tests)

## 📚 Resources

### Documentation
- [BETA_TESTING.md](./docs/BETA_TESTING.md) - Detailed testing guide
- [TEST_PLAN.md](./docs/TEST_PLAN.md) - Official test plans
- [KNOWN_ISSUES.md](./KNOWN_ISSUES.md) - Current known issues

### Community
- [Discord Server](https://discord.gg/lifeos-beta)
- [Matrix Room](https://matrix.to/#/#lifeos-beta:matrix.org)
- [Forum Category](https://forum.lifeos.io/c/beta)

## 🤝 Code of Conduct

1. **Be respectful** - Treat all testers and developers with respect
2. **Be constructive** - Criticize ideas, not people
3. **Be thorough** - Test completely before reporting
4. **Be patient** - Fixes take time
5. **Be helpful** - Assist other testers

## ❓ FAQ

**Q: Can I use beta as my daily driver?**  
A: Not recommended. Use a VM or spare machine.

**Q: How do I leave the beta program?**  
A: Run `life beta leave` or email beta@lifeos.io

**Q: Will beta data carry to stable?**  
A: Usually yes, but not guaranteed. Backup important data.

**Q: Can I downgrade to stable?**  
A: Yes, using `life rollback` or fresh install.

**Q: Is there compensation?**  
A: We offer recognition and monthly awards. No paid positions.

## 📞 Contact

- **General Questions**: Discord #beta-general
- **Bug Reports**: GitHub Issues or `life feedback bug`
- **Private**: beta@lifeos.io
- **Emergency**: Security issues to security@lifeos.io

---

Thank you for helping make LifeOS better! 🚀

*Last updated: 2026-02-24*
