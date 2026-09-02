---
title: "lazysite - the documentation index"
subtitle: "Every document in this repository, what it is for, and where the ones that live elsewhere are. Generated: run tools/gen-doc-index.pl --write after adding or removing a document."
brand: plain
standard-margins: true
---

# How to use this

**Generated file - do not edit by hand.** `tools/gen-doc-index.pl --write`
produces it, and `t/lint/110-the-doc-index-matches-the-tree.t` fails when it and
the tree disagree.

It exists so that an agent can find out what is written down without reading it.
The repository carries about 4.3MB of markdown; this file is the map.

## What is NOT listed here

**The feature requests.** There are several hundred, and they have their own
lister already:

    perl tools/backlog.pl            # open work only
    perl tools/backlog.pl --all      # everything, shipped and superseded
    perl tools/backlog.pl --json     # the same, for tooling

Every one carries a machine-readable `status`, enforced by `t/lint/09`. Search
them by name - the filenames are sentences - or by content with `grep -rl`.

## Documentation that lives outside this repository

- **A site's own published docs.** `starter/docs/` installs into every site and
  is served at `/docs/`. A running site publishes around thirty pages; ask it
  with `describe_capabilities` (under "docs") or read `/docs/` rather than
  assuming a feature is undocumented.
- **The layouts catalogue**, in its own repository, documents layouts and themes.
- **Field practice** is maintained by the site agent and lives here under
  `docs/practice/` - see the README there for who maintains what.

# docs

Top-level references: the manuals an operator, developer or implementor reads end to end.

| Document | What it is |
| --- | --- |
| [`ACCESSIBILITY.md`](ACCESSIBILITY.md) - lazysite - accessibility statement | Conformance target and known state for the manager UI and shipped themes |
| [`DECLARATION-OF-CONFORMITY.md`](DECLARATION-OF-CONFORMITY.md) - lazysite - Declaration of Conformity | EU declaration of conformity per Regulation (EU) 2024/2847 (Cyber Resilience Act) - draft for the 0.8.0 stable release |
| [`DEVELOPER.md`](DEVELOPER.md) - lazysite - Developer guide | For someone changing lazysite's code. |
| [`FEATURES.md`](FEATURES.md) - Lazysite - Complete Feature Reference | Everything lazysite has and does, and why - as of v0.11.10 |
| [`IMPLEMENTOR.md`](IMPLEMENTOR.md) - lazysite - Implementor guide | For someone installing or integrating lazysite. |
| [`MANUAL-CHECKS-WALKTHROUGH.md`](MANUAL-CHECKS-WALKTHROUGH.md) - Four checks on the site manager | A guided walk through four things that must work when a person clicks them. About 20 minutes. No technical knowledge needed - if you can sign in, you ... |
| [`MANUAL-CHECKS.md`](MANUAL-CHECKS.md) - lazysite - What the test suite cannot check | The areas where a green gate proves nothing, why each one is out of reach, and the manual pass that covers it |
| [`OPERATOR.md`](OPERATOR.md) - lazysite - Operator guide | For someone running lazysite in production. |
| [`PATH-TO-STABLE.md`](PATH-TO-STABLE.md) - lazysite - the path to a promotable stable | One release with maximal fixes, tested in one pass, cut when the inbox has been evaluated |
| [`POLICY.md`](POLICY.md) - lazysite - Policy and compliance posture | The project's regulatory posture and the artefacts the chosen regime requires. |
| [`RELIABILITY.md`](RELIABILITY.md) - lazysite - Reliability and resilience declaration | SLOs, error budget, RTO/RPO, evidence mapping, and restore rehearsals (eight-dimension review D5) |
| [`SECURITY.md`](SECURITY.md) - lazysite - threat model | Structured security assessment for the Commercial regime (eight-dimension review D6). |
| [`USER.md`](USER.md) - lazysite - User guide | For the person using a running lazysite site: an operator or author managing content, and the AI publishing partners that an operator authorises. |
| [`development.md`](development.md) - Development | Developer-facing notes for the lazysite repo. |
| [`gate-register.md`](gate-register.md) - lazysite - gate register | What the full gate has actually returned, when, and on which commit. A pass nobody wrote down has to be repeated. |
| [`manual-check-register.md`](manual-check-register.md) - Manual check register | What has actually been walked, when, and on which version. A pass nobody wrote down has to be repeated. |

# docs/adr

Architecture decision records. What was decided, and what it rules out.

| Document | What it is |
| --- | --- |
| [`0001-capability-resolution.md`](0001-capability-resolution.md) - 0001 - Capability resolution: one shared helper, one recorded local copy | Status: Accepted Date: 2026-07-02 Tags: auth, capabilities, sm095, architecture |
| [`0002-uncommitted-tree-release-contract.md`](0002-uncommitted-tree-release-contract.md) - 0002 - Releases are tags cut from main; the working tree is unstable | Status: Accepted Date: 2026-07-02 (retrospective; practice since SM063, 2026-06) Tags: release, process, versioning |
| [`0003-channel-action-capability-model.md`](0003-channel-action-capability-model.md) - 0003 - Capabilities are channel x action, carried by groups only | Status: Accepted Date: 2026-07-02 (retrospective; shipped as SM095, 0.5.15-0.5.25) Tags: auth, capabilities, groups, sm095 |
| [`0004-install-classification-and-provenance.md`](0004-install-classification-and-provenance.md) - 0004 - Two-bucket install classification + content provenance stamp | Status: Accepted Date: 2026-07-02 (retrospective; D021 classification, 0.5.33 preservation fix, 0.5.35 provenance stamp) Tags: install, upgrade, class... |
| [`0005-release-channels.md`](0005-release-channels.md) - 0005 - Edge and stable release channels | Status: Accepted Date: 2026-07-02 (retrospective; shipped 0.5.x "update channel" work) Tags: release, channels, deployment |
| [`0006-raw-mode-for-artifacts-only.md`](0006-raw-mode-for-artifacts-only.md) - 0006 - Raw mode is for self-contained artifacts, never content pages | Status: Accepted Date: 2026-07-02 (retrospective; doctrine since the building-sites briefing, 0.5.23) Tags: rendering, content-model, raw-mode, ai-par... |
| [`0007-pentest-deferral.md`](0007-pentest-deferral.md) - 0007 - Pentest gate declared; first engagement deferred with expiry | Status: Accepted Date: 2026-07-10 Tags: security, pentest, waiver, launch |
| [`0008-stable-compatibility-freeze.md`](0008-stable-compatibility-freeze.md) - 0008 - Compatibility freeze for the stable line | Status: Proposed Date: 2026-07-18 Tags: release, stable, compatibility, support |
| [`0009-plugin-contract.md`](0009-plugin-contract.md) - 0009 - Plugins declare what they own, and disabled means off | Date: 2026-08-19 Status: DRAFT - direction accepted; ratified when the data plugin ships as its first conforming implementation Tags: plugins, archite... |
| [`0010-the-certified-channel.md`](0010-the-certified-channel.md) - 0010 - A certified channel above stable; the conformity gates attach there | Date: 2026-08-20 Status: Accepted Tags: release, channels, compliance Amends: 0005 (release channels), 0007 (pentest deferral - the gate's home) |

# docs/architecture

How a part of the system is shaped, and why it is shaped that way.

| Document | What it is |
| --- | --- |
| [`access-control-model.md`](access-control-model.md) - Access control: who may see what | The reference. Two mechanisms, which question each answers, and the grammar of both. The analysis that settled the design is the appendix. |
| [`code-quality.md`](code-quality.md) - Code quality | and closure state. - Functional style throughout. No object-oriented Perl. |
| [`manager-behaviour-rules.md`](manager-behaviour-rules.md) - The manager's behaviour rules: scope and rulesets | An inventory of every rule the manager already obeys - colour semantics, vocabulary, component choice, interaction, presentation, input - with where e... |
| [`performance.md`](performance.md) - Performance | lazysite runs as a CGI application by default. |
| [`permissions-and-secrets.md`](permissions-and-secrets.md) - lazysite - permissions and secrets | Who a caller is, what they may do, what enforces it on each surface, and where every secret lives |
| [`render-path-separation.md`](render-path-separation.md) - Render-path separation | At its core, lazysite is a Markdown-to-HTML renderer. |
| [`security.md`](security.md) - Security | lazysite's security model has three layers. |
| [`test-coverage.md`](test-coverage.md) - Test coverage | The suite is pure core-Perl. |

# docs/reference

Generated references. Do not edit by hand - each names its generator.

| Document | What it is |
| --- | --- |
| [`capability-map.md`](capability-map.md) - lazysite - capability map | What a connected partner may do, and how |
| [`control-api-actions.md`](control-api-actions.md) - lazysite - control API actions | Every action the control API dispatches, what it requires, and what it takes |
| [`coverage-series.md`](coverage-series.md) - Coverage series | One row per release cut. Started 2026-08-12 because a drift rate cannot be measured backwards. |
| [`host-dependencies.md`](host-dependencies.md) - lazysite - host dependencies | The OS packages a host needs, beyond core Perl |
| [`manager-colour-contrast.md`](manager-colour-contrast.md) - Manager colour contrast standard | WCAG targets for the manager token system, light and dark |
| [`quickstarts.md`](quickstarts.md) - lazysite - agent quickstarts | The sanctioned path for common jobs |
| [`webserver-wiring.md`](webserver-wiring.md) - lazysite - webserver wiring | One reference for fronting lazysite from any web server |

# docs/manager-ui-guide

The manager, page by page, as an operator meets it.

| Document | What it is |
| --- | --- |
| [`00-how-to-use-this-guide.md`](00-how-to-use-this-guide.md) - Lazysite manager - the walkthrough guide | Every menu item, what to do with it, what to expect, and what a user without the capability should see. |
| [`10-files.md`](10-files.md) - Files | Governing capability: manage_content. |
| [`20-navigation.md`](20-navigation.md) - Navigation | Governing capability: manage_nav. |
| [`30-appearance.md`](30-appearance.md) - Appearance | Governing capabilities: manage_themes or manage_layouts - either opens the page, and the controls inside are gated separately. |
| [`40-plugin-manager.md`](40-plugin-manager.md) - Plugin Manager and Plugin Config | Two adjacent menu items with a deliberate split: Plugin Manager decides what runs, Plugin Config decides how it behaves. |
| [`45-data-tables.md`](45-data-tables.md) - Data tables | A table holds site data -- a product list, an events calendar, a directory. |
| [`50-users.md`](50-users.md) - Users | Governing capability: manage_users. |
| [`60-groups.md`](60-groups.md) - Groups | Governing capability: manage_users. |
| [`70-sessions-and-keys.md`](70-sessions-and-keys.md) - Sessions and keys | Governing capability: manage_users. |
| [`80-site-settings.md`](80-site-settings.md) - Site settings | Governing capability: manage_config. |
| [`85-domains.md`](85-domains.md) - Domains | Governing capability: manage_domains, carved out of manage_config precisely so it can be delegated separately. |
| [`90-cache-backups-audit-stats.md`](90-cache-backups-audit-stats.md) - Cache, Backups, Audit log, Visitor statistics | Governing capability: manage_config. |
| [`95-agents-and-connectors.md`](95-agents-and-connectors.md) - Agents and connectors | Not a menu item - the surfaces an agent reaches instead of the menu. |

# docs/practice

Field notes, maintained by the site agent. Source of the briefing that ships to every site.

| Document | What it is |
| --- | --- |
| [`README.md`](README.md) - Field practice: what lives here and who maintains it | The two source documents from which starter/docs/ai-briefing-practice.md is built and shipped to every site. The site agent maintains them; the releas... |
| [`app-foundation.md`](app-foundation.md) - The app foundation: from a visual prototype to an integrated app | This is the foundational approach for building an application on lazysite. |
| [`app-practice.md`](app-practice.md) - Building apps on lazysite | is about pages: content, layout, theme, HTML and styling. |
| [`authoring-practice.md`](authoring-practice.md) - Authoring practice on lazysite | The purpose of everything below is one thing: a site should stay maintainable by someone who has only a text editor and the site itself - no build ste... |

# docs/plans

Multi-release workplans: what is sequenced, and what each phase unlocks.

| Document | What it is |
| --- | --- |
| [`apps-portability-workplan.md`](apps-portability-workplan.md) - Apps portability and the marketplace: workplan | SM715-SM723, sequenced. Eight core phases chipped away alongside ordinary releases until the round trip passes, which is critical mass; the marketplac... |
| [`next-release.md`](next-release.md) - The next release: what is queued, and what stable needs after it | 0.11.11 beta, then a stable. What each item is, what decides it, and what is deliberately held back. Kept here rather than in a conversation, because ... |

# docs/compliance

The regulatory record. Several are gated by lazysite-compliance.pl at a cut.

| Document | What it is |
| --- | --- |
| [`COMPLIANCE-MAINTENANCE-TEMPLATE.md`](COMPLIANCE-MAINTENANCE-TEMPLATE.md) - Compliance maintenance schedule - {{operator_legal_name}} | The recurring half of operating {{service_name}} compliantly. Authored from COMPLIANCE-MAINTENANCE-TEMPLATE; kept by the operator. |
| [`HANDOVER.md`](HANDOVER.md) - lazysite - compliance handover to the operator | What the project hands you, what stays ours, and what only you can produce. Read this before filling in the templates. |
| [`OBLIGATIONS.md`](OBLIGATIONS.md) - lazysite - dated obligations register | Every obligation with a date or a version anchor, in one place. Reviewed at every release. |
| [`OPERATIONS-TEMPLATE.md`](OPERATIONS-TEMPLATE.md) - Operations declaration - {{operator_legal_name}} | Per-instance operations record for {{service_name}}, running lazysite {{lazysite_version}}. Authored from OPERATIONS-TEMPLATE; kept by the operator, n... |
| [`SIGNOFF.md`](SIGNOFF.md) - lazysite - human sign-off switch | Whether the release gate blocks on records that only a person can close. Set by the release manager, not by the engine. |
| [`TECHNICAL-FILE.md`](TECHNICAL-FILE.md) - lazysite - technical documentation (CRA Annex VII) | An index over evidence that already exists, kept current as a by-product rather than assembled later. |

# docs/review

Review registers: one row per piece of feedback, with what was done or why not.

| Document | What it is |
| --- | --- |
| [`2026-06-23-seven-dimension-review.md`](2026-06-23-seven-dimension-review.md) - lazysite — seven-dimension review | Date: 2026-06-23 · Branch claude/hestia-install-fixes = main @ 8642ed9 (building 0.3.38) Reviewer: Claude (manual run; projkit not yet built). |
| [`2026-07-11-field-validation.md`](2026-07-11-field-validation.md) - Field validation checklist - the 0.7.x line | Human review of everything shipped 0.7.0-0.7.4, on real infrastructure - 2026-07-11 |
| [`2026-08-31-manager-review-register.md`](2026-08-31-manager-review-register.md) - Manager review, 2026-08-30/31: every item the release manager raised, and where it got to | One row per piece of feedback from the live-manager review sessions, with what was done or why it was not. Ninety-four done, two open. The done rows l... |
| [`README.md`](README.md) - lazysite - non-functional review record | Where the eight-dimension reviews live, and how they are named |

# docs/releases

What each release was gated on.

| Document | What it is |
| --- | --- |
| [`GATE-LOG.md`](GATE-LOG.md) - lazysite - release gate record | Which commit each release was validated at, newest last. Appended by tools/release.sh. |

# starter/docs

SHIPPED. Installed into every site and served at /docs/. Written for the site owner and their agent.

| Document | What it is |
| --- | --- |
| [`ai-briefing-authoring.md`](ai-briefing-authoring.md) - AI briefing - content authoring | Guide for AI assistants helping users write content on a lazysite site. |
| [`ai-briefing-building-sites.md`](ai-briefing-building-sites.md) - AI briefing - building sites | Best practice for AI agents creating or maintaining sites on the lazysite engine - the separation-of-concerns model and the failure modes to avoid. |
| [`ai-briefing-configuration.md`](ai-briefing-configuration.md) - AI briefing - configuration | Guide for AI assistants helping users configure a lazysite installation. |
| [`ai-briefing-data.md`](ai-briefing-data.md) - AI briefing - data tables | Guide for AI assistants declaring tables, loading records, and rendering them on a page. |
| [`ai-briefing-development.md`](ai-briefing-development.md) - AI briefing - development | Guide for AI assistants working on the lazysite processor, scripts, and tools. |
| [`ai-briefing-layouts.md`](ai-briefing-layouts.md) - AI briefing - layouts and themes | Guide for AI assistants helping users author or modify a lazysite layout or theme. |
| [`ai-briefing-practice.md`](ai-briefing-practice.md) - AI briefing - field practice | One agent's field notes from building and breaking real sites and apps on this engine - a companion to the reference briefings, not a specification. |
| [`ai-briefing-publishing.md`](ai-briefing-publishing.md) - AI briefing - publishing | Guide for an automated partner publishing to a lazysite site over WebDAV and the control API. |
| [`ai-briefing-stats.md`](ai-briefing-stats.md) - AI briefing - visitor analytics | Guide for AI assistants analysing a lazysite's visitor traffic for trend reporting. |
| [`ai-connector-setup.md`](ai-connector-setup.md) - Connect an AI assistant | This site exposes an MCP connector so an AI assistant can maintain it through tools (list, read, write, move, delete pages; set permissions; activate ... |
| [`ai-connector-tools.md`](ai-connector-tools.md) - AI connector - tools reference | The full reference for the lazysite MCP connector: how it authenticates, the capability model, and every tool it exposes. |
| [`api.md`](api.md) - API and raw mode | JSON endpoints, content fragments, and query string variables. |
| [`auth-upgrade.md`](auth-upgrade.md) - Upgrading to external auth | Replace built-in auth with Authentik, Authelia, or another proxy. |
| [`auth.md`](auth.md) - Authentication | Protect pages with built-in auth or an external proxy. |
| [`authoring.md`](authoring.md) - Authoring | How to create and edit pages - the short version. |
| [`configuration.md`](configuration.md) - Configuration | Layouts, navigation, site variables, forms, auth, and plugins. |
| [`data-tables.md`](data-tables.md) - Data tables | Tables a site declares and holds - a product list, an events calendar, a directory - read on a page like any other variable. |
| [`development.md`](development.md) - Development | Local development server, build tools, and troubleshooting. |
| [`forms-helpers.md`](forms-helpers.md) - Form helpers | Write custom dispatch targets for lazysite forms. |
| [`forms-smtp.md`](forms-smtp.md) - SMTP configuration | Configure email delivery for lazysite forms. |
| [`forms.md`](forms.md) - Forms | Add contact forms and data collection to any page. |
| [`frontmatter.md`](frontmatter.md) - Front matter | The YAML metadata block at the top of every page. |
| [`index.md`](index.md) - Documentation | Everything this site publishes about how lazysite works, and which question each page answers. |
| [`install.md`](install.md) - Installation | Requirements, server setup, and getting started. |
| [`layouts.md`](layouts.md) - Layouts and Themes | How lazysite wraps page content in HTML layouts. |
| [`manager.md`](manager.md) - Manager | Web-based admin and content manager for lazysite. |
| [`onboard-ai-agent.md`](onboard-ai-agent.md) - Onboard an AI agent | Give an AI assistant a scoped account to manage your site - in a few steps, fully under your control. |
| [`onboarding-brief-template.md`](onboarding-brief-template.md) - Onboarding brief template (operator) | This is the operator's template for the out-of-band onboarding brief. |
| [`payment.md`](payment.md) - Payment | Gate content behind x402 payments with member bypass. |
| [`reference.md`](reference.md) - Reference | Front matter keys, TT variables, configuration keys, and file locations. |
| [`remote-content.md`](remote-content.md) - Remote content | Using JSON indexes and .url files for remote-sourced pages. |
| [`troubleshooting.md`](troubleshooting.md) - Troubleshooting & migrating | Diagnosing problems, and moving content in from other tools. |

---

*103 documents indexed, across 11 trees. The feature-request corpus is listed by `tools/backlog.pl`.*
