# Puddle: a local executive assistant

The product is a private assistant for someone responsible for many decisions,
relationships, meetings, and commitments. Its job is to help the user decide
what needs attention, arrive prepared, and follow through. It must also work for
an individual contributor or personal user without requiring company accounts.

The production target is broader than a chat app. This document separates
implemented capabilities from work still required before public distribution.
The current application is native to macOS; cross-platform availability is not
implemented. “Local” means model inference and workspace storage stay on this
Mac. Optional Google, GitHub and Atlassian connections communicate with their services.

## Product requirements and implementation order

| Order | Capability | Current state | Completion criteria |
| --- | --- | --- | --- |
| 1 | Role profiles and personal work context | Implemented | Personal and Developer presets, custom profiles, independent role context/guidance, shared personal workspace, profile switching, migration, validated saves and backup support. |
| 2 | Daily executive workspace | Implemented | Today shows three chosen priorities, overdue work, due-today actions, waiting count, agenda overlaps, flagged unread mail, source timestamps and incomplete-result notices. Available without a model or account. |
| 3 | Commitments and follow-ups | Implemented | Owner, active/waiting status, priority, notes, due/follow-up reminder, search, open/waiting/completed filters, daily focus, provenance, delete confirmation; failed edits remain open. No implied communication to owners. |
| 4 | Meeting preparation | Implemented | Calendar details, exact-ID/full-title note matches, saved agendas, current extracted decisions/questions, linked open actions, source links and workspace handoff. Available from Today and Meetings. |
| 5 | Conversational executive brief | Implemented | Read-only tool returns bounded saved priorities, commitments, cached agenda/conflicts and flagged mail with counts and freshness. Work context is reference data. Fixture round-trip tested without Google. |
| 6 | Portable workspace recovery | Implemented | Passphrase encryption by default, preview/atomic/idempotent merge, current content preserved, work context/routines/errand records, no grants/caches/credentials, no action replay. |
| 7 | Frictionless local inference setup | Implemented; native acceptance pending | Guided hardware/resource checks, discovery/install/model selection, managed start/stop, reply/tool verification and diagnostics. Real synthetic Splash probe passed. Additional runtimes remain future scope. |
| 8 | Inbox and communication drafts | Implemented; account acceptance pending | Gmail/Outlook, explicit account switching, VIP reasons, editable compose/reply/forward, reviewed sends/organization, follow-ups, local snooze, newsletter cleanup, bounded threads and attachments. |
| 9 | Calendar and time protection | Implemented; account acceptance pending | Week/month and secondary calendars, attendees/timezones, preferences/slots/focus proposals, reviewed create/edit/undo with ETags. Google Calendar remains the provider. |
| 10 | Meeting lifecycle | Implemented; native acceptance pending | Floating companion, source-quoted summaries/actions, checkpoints/recovery, project links, provider-scoped recurring-series links and recurring commitments. Live hardware/permissions/sleep acceptance remains. Browser attendance stays experimental. |
| 11 | Decisions, projects and goals | Implemented | Manual decision owner/options/rationale/evidence/review/outcome; goals and linked commitments/meetings; read tools and portable backup. |
| 12 | People and relationship context | Implemented | User-controlled people/VIPs, roles, interaction/promises/talking points/source, correction/deletion. No inferred sensitive profiles. |
| 13 | Local knowledge and documents | Implemented with limits | Selected folders/files, incremental text/PDF/DOCX extraction, citations/deletion propagation/permissions/limits. OCR, legacy Office and spreadsheets excluded. |
| 14 | Durable routines | Implemented | Scheduled read-only briefing/review, saved runs, missed/interrupted handling, pause, explicit login launch. Execution requires the app/menu-bar process; catch-up on next launch. |
| 15 | Voice and accessibility | Implemented; native acceptance pending | Opt-in system dictation, original-field validation/copy fallback, vocabulary/punctuation, visible/reduced-motion activity. Real devices, VoiceOver/keyboard/contrast acceptance remain. |
| 16 | Privacy and workspace lifecycle | Implemented | AES-GCM workspace/legacy migration, encrypted portable backups, retention, private sessions, optional macOS lock and external-API pause with documented limits. |
| 17 | Distribution and operations | Tooling implemented; owner setup pending | Developer ID/notary/stapling script, pinned signed manual update feed, hash checks, redacted copy-only diagnostics, migration/rollback guidance. Public credentials/hosting and clean-Mac acceptance still required. |
| 18 | Real-model quality and reliability | Partial | Automated HTTP/OS fixtures and optional live tests exist. Still needed: supported hardware/model matrix, tool-call and source-grounding evaluations, adversarial imported-content tests, performance budgets, endurance/sleep/restart tests and human acceptance of executive workflows. |

Developer-profile work now has a separate [implementation plan](developer-assistant-plan.md):
explicit project connections, scoped source tools, Git text comparisons and
persistent development sessions are implemented. Reviewed patch application,
approved build/test execution and semantic indexing remain subsequent stages.
The user prioritized useful cloud work context next: [GitHub, Jira and
Confluence read connectors](work-connectors.md) now provide search, source
details and local chat tools. Real-account acceptance remains a release gate.

## UX contract

- Start with Today. Chat remains one click away and retains its history.
- Let users capture work before connecting a model or an account.
- Ask what matters through a short optional work profile. Do not demand a job
  title, Google account, microphone access, or cloud project to organize tasks.
- Show three user-chosen daily priorities. Suggestions from the model do not
  silently become commitments or priorities. Yesterday's stars expire, while
  unfinished commitments remain available.
- Treat “waiting on” as a distinct workflow with a person and optional follow-up
  date. An owner field never implies that someone was contacted.
- Show exact sources, timestamps, known gaps, stale extracts and actionable
  errors. A partial inbox or primary-calendar cache is never a complete view of
  the user's work.
- Keep a failed edit open. A persistence failure cannot be reported as success.
- Review imported work before merging it. Keep current content and settings;
  restoring a backup must not initiate account access or replay old actions.
- Request OS permissions at the point the user starts the corresponding flow.
- Review concrete content before any future external send, booking or write.

## Current verification and release gates

Implementation has automated coverage for schema-3 migration, task provenance,
validation, daily limits and day boundaries, overlap rules, date-only timezones,
briefing scope, tool receipts, failed persistence, workspace integrity and
idempotent restore. See [testing.md](testing.md) for native acceptance steps.

Public production readiness is **not established** by these automated checks.
Before distributing the app to general users, complete at least:

1. A signed, notarized installation and upgrade on a clean supported Mac.
2. Onboarding with no existing state, credentials, installed model, or developer
   tooling, with a tested route to a working local model.
3. Real-model tests of chat, extraction, tool use, cancellation, refusal, source
   grounding and long-context behavior for each advertised model/runtime.
4. Interactive Gmail/Calendar and GitHub/Jira/Confluence permission, refresh,
   partial-result, site/repository selection, revoked-token and disconnect tests.
5. Live microphone/system-audio, installed-language, capture cancellation and
   sleep/wake validation on each supported OS family.
6. Keyboard/VoiceOver, narrow window, long-content, first-run, empty, offline,
   read-only disk, full-disk, corrupted-state and interrupted-save checks.
7. Backup/restore of representative large workspaces, upgrade/rollback drills,
   and a user-approved privacy/retention design for public distribution.

There is no universal production-ready claim until these gates have evidence.
The [implementation ledger](improvement-implementation.md) records the completed
Mac work and current limits. The next milestone is owner-configured live and
clean-Mac acceptance, followed by the deliberately excluded platform breadth.
