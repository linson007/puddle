# Puddle: a local personal assistant

The product is a private personal assistant that helps someone plan their day,
remember what matters and follow through. Everyday use must be understandable
without learning a set of specialist workspaces or connecting company accounts.
Work, meeting and developer capabilities are optional extensions of that core.

This document separates implemented capabilities from work still required
before public distribution. The capability inventory below is not a request
to keep expanding the feature set.
The current application is native to macOS; cross-platform availability is not
implemented. “Local” means model inference and workspace storage stay on this
Mac. Optional Google, GitHub and Atlassian connections communicate with their services.

## Current product focus

Prioritize quality of the existing personal-assistant loop before adding more
features: ask Puddle, use saved context, capture a task and follow through.
The everyday navigation is Today, Puddle, Tasks and Memory. Additional
workspaces live under More; pending action reviews must remain discoverable.

The next milestone should demonstrate:

- A new user reaches a working local assistant through guided setup without
  needing a terminal or understanding model-server configuration.
- Everyday questions and planning requests produce useful, grounded answers
  on advertised hardware, with clear progress and working cancellation.
- Memories are easy to inspect, correct and forget, and remain useful across
  conversations. Users can understand what the assistant has saved.
- A reminder can be captured, reviewed, delivered and completed reliably,
  including after restarting the app.
- First-time users can complete those flows without being taught the sidebar,
  and optional connections and specialist tools stay out of their way.

Verify these flows with real local models and first-time users. Use the
existing release gates for installation, privacy, recovery and accessibility.
Defer new providers, profiles and automation breadth until the core passes;
new work should solve an observed failure or a repeated user need.

## Work before live-model acceptance

The owner chose page reading, URL navigation and scrolling for the first release
on 1 November 2026. Clicking and typing are deferred: assistant tools omit them,
and the workspace and driver adapter reject them before dispatch. Historical
receipts remain readable; retries and resumed errands cannot restore writes.
This narrows Puddle's scope without claiming to fix the external driver.

| Pending item | Current implementation / evidence route | Remaining dependency |
| --- | --- | --- |
| Browser scope and enforcement | Direct-driver, injected-controller, hostile-tool and retry/Continue regressions; [current scope](browser-use.md). | Native read/navigation/scroll compatibility on supported browsers/OS versions. |
| Repeatable pre-model checks | `make verify-premodel`: debug/release fixtures, regular/heavy loads, 1,000-save long-chat endurance, release build and bundle checks. | Run on each advertised hardware/OS family. |
| Application performance budgets | Save P95 <100 ms; resident growth ≤64 MiB; cold load/search <2 s; prompt preparation <0.5 s; backup encoding <5 s and inspection <2 s. Recorded with host resources in synthetic metrics. | Real-model latency and lower-resource/near-capacity hardware acceptance. |
| Release fixture isolation | Shared local/CI bundle check rejects fixture arguments and marker-only launch before workspace creation; verifies plist/signature. | Actual Developer ID identity, notarization and clean-Mac acceptance. |
| Model/hardware coverage | [Acceptance matrix and evidence contract](model-acceptance.md); real workflows passed with the owner's running model on 2 November. Balanced eligibility corrected to ≥36 GiB. | Actual compact/balanced preset runs, lower-resource hardware and first-time-user assessment. |

The following gates need evidence from their actual environments:

| Gate | Required dependency and completion evidence |
| --- | --- |
| Installation and recovery | Actual ENOSPC/read-only recovery passed in disposable HFS+/APFS images; a 9,600-message legacy workspace migrated and its pre-upgrade protected backup restored. Clean supported Mac, actual installer, interrupted model download, cached model restart, host-volume/power-loss and signed-app upgrade/rollback remain. |
| Optional accounts | Owner OAuth registrations and designated Google/Microsoft/GitHub/Atlassian test accounts; denied/partial grants, revoke/refresh, switching and disconnect. Real writes need separately reviewed exact test content. |
| Native privacy and devices | File-based on-device recognition passed. Live app-audio A/B selection/isolation remains deferred by the owner on 2 November; source label, denial/revocation, sleep/wake/device loss, dictation target, shipped Keychain/app-lock identity and notification delivery still need acceptance. |
| Accessibility and usability | Core keyboard capture/search/open/cancel, light/dark minimum-window and long-task/notes checks passed here; 14 declared text/background palette pairs passed 4.5:1. First-time users, VoiceOver, high-contrast/reduced-motion settings and other advertised OS versions need human/environment acceptance. |
| Distribution | Bundle-configured signing-key, invalid manifest/archive, cancellation/pause and changed-installer regressions passed. Owner Developer ID/notary credentials, actual hosted pinned feed and clean-Mac signed install/upgrade/rollback remain. |

These dependencies stay pending until observed. Do not substitute fixture
results for native/provider evidence. Further developer patch/command/indexing,
provider and platform expansion stay deferred from this personal-assistant milestone.

The pre-model command passed locally on 1 November 2026: **479 debug / 475 release
tests executed, 14 expected optional skips in each, zero failures**, plus heavy
archives, 1,000-save long-chat endurance, release packaging and both fixture-launch
refusals. [Current verification and limits](testing.md#pre-model-verification).

## Live acceptance on 2 November 2026

The owner's running `mlx-community/Qwen3.6-35B-A3B-4bit` passed synthetic
memory learning/recall/correction/forgetting, reviewed reminder creation and
completion after restart, named-task lookup, cancellation, bounded-context
retrieval and hostile-source evaluations. This is a separately tested
configuration; the two advertised setup presets remain pending.

Observed issues were corrected: saved-task requests now explicitly read current
task IDs, streaming text publishes at a bounded rate without reparsing Markdown,
browser errands show the user's short request with source context disclosed on
demand, and paused errands cannot reuse an unrelated earlier answer. Native
decline/navigation/scroll flows completed after the rendering fix.

The [dated acceptance report](roadmap-acceptance-2026-11-02.md) records the host,
runtime, checks, timing samples, fixes and remaining dependencies. These checks
close specific local failures; public distribution still depends on the gates
above. The owner will supply designated account and release details.
The initial live-enabled suites passed **488 debug / 484 release tests**. The
independent follow-up passed **498 debug / 494 release tests**, zero failures or
skips. Native app-audio acceptance remains deferred by the owner.

## Independent follow-up coverage

These checks are complete on the available M5 Pro/macOS 26.6 host. Re-run the
automated portion with `make verify-local`; it requires the already running
Splash server, configured Cua Driver and installed speech language. It creates
only synthetic test state, a speech file and a disposable browser page. Native
permission/device and provider checks are excluded.

| Roadmap work | Completed without owner input | Evidence |
| --- | --- | --- |
| Failed edits and saves | Memory, chat and browser goal drafts clear only after acceptance by storage; failed memory correction preserves the saved value and retries without duplication. Native memory/chat save obstruction and retry passed. | Store/browser regressions and dated native report. |
| Keyboard and small-window use | Command search now has selected-result feedback, Up/Down and Return; background search cannot reset an arrow selection. Capture/Return, search/open/cancel, long titles/notes and offline task capture passed at the 960 × 640 content minimum in light/dark appearance. | Native review and [acceptance report](roadmap-acceptance-2026-11-02.md). |
| Storage and data upgrade | Bounded actual full/read-only HFS+ and APFS drills; large legacy migration, encrypted reopen and protected pre-upgrade backup restore with idempotent merge. | `FilesystemRecoveryAcceptanceTests`. |
| Manual update reliability | Cancellable work, pause/lock gating, stale-result rejection, earlier-offer clearing on failed check, hash rejection and checksum recheck before opening a downloaded installer. | `ReleaseUpdateWorkflowTests`, using a bundle-pinned synthetic feed/key. |
| Repeatable local gates | Full live-enabled debug/release, regular/heavy/1,000-save loads, generated-file speech recognition, actual installed browser driver, normal release build and fixture-isolation bundle checks. Source patch/checksums and per-build outputs retained. | `make verify-local`; [test instructions](testing.md#independent-local-verification). |

The remaining gates above require designated accounts/registrations, signing and
hosting credentials, clean/additional hardware, an agreed device-test window or
human evaluation. They remain unverified. The owner chose to defer live app
audio and browser clicking/typing; developer/provider/platform expansion also
stays outside this milestone.

## Product requirements and implementation order

| Order | Capability | Current state | Completion criteria |
| --- | --- | --- | --- |
| 1 | Role profiles and personal work context | Implemented | Personal and Developer presets, custom profiles, independent role context/guidance, shared personal workspace, profile switching, migration, validated saves and backup support. |
| 2 | Daily executive workspace | Implemented | Today shows three chosen priorities, overdue work, due-today actions, waiting count, agenda overlaps, flagged unread mail, source timestamps and incomplete-result notices. Available without a model or account. |
| 3 | Commitments and follow-ups | Implemented | Owner, active/waiting status, priority, notes, due/follow-up reminder, search, open/waiting/completed filters, daily focus, provenance, delete confirmation; failed edits remain open. No implied communication to owners. |
| 4 | Meeting preparation | Implemented | Calendar details, exact-ID/full-title note matches, saved agendas, current extracted decisions/questions, linked open actions, source links and workspace handoff. Available from Today and Meetings. |
| 5 | Conversational executive brief | Implemented | Read-only tool returns bounded saved priorities, commitments, cached agenda/conflicts and flagged mail with counts and freshness. Work context is reference data. Fixture round-trip tested without Google. |
| 6 | Portable workspace recovery | Implemented | Passphrase encryption by default, preview/atomic/idempotent merge, current content preserved, work context/routines/errand records, no grants/caches/credentials, no action replay. |
| 7 | Frictionless local inference setup | Implemented; existing-server native setup verified | Guided checks, discovery/install/model selection, managed start/stop, reply/tool verification and diagnostics. Native connection/probes/save/restart passed with the running server. Clean-Mac install/download and actual preset acceptance remain. |
| 8 | Inbox and communication drafts | Implemented; account acceptance pending | Gmail/Outlook, explicit account switching, VIP reasons, editable compose/reply/forward, reviewed sends/organization, follow-ups, local snooze, newsletter cleanup, bounded threads and attachments. |
| 9 | Calendar and time protection | Implemented; account acceptance pending | Week/month and secondary calendars, attendees/timezones, preferences/slots/focus proposals, reviewed create/edit/undo with ETags. Google Calendar remains the provider. |
| 10 | Meeting lifecycle | Implemented; native acceptance pending | Floating companion, source-quoted summaries/actions, checkpoints/recovery, project links, provider-scoped recurring-series links and recurring commitments. Live hardware/permissions/sleep acceptance remains. Browser attendance stays experimental. |
| 11 | Decisions, projects and goals | Implemented | Manual decision owner/options/rationale/evidence/review/outcome; goals and linked commitments/meetings; read tools and portable backup. |
| 12 | People and relationship context | Implemented | User-controlled people/VIPs, roles, interaction/promises/talking points/source, correction/deletion. No inferred sensitive profiles. |
| 13 | Local knowledge and documents | Implemented with limits | Selected folders/files, incremental text/PDF/DOCX extraction, citations/deletion propagation/permissions/limits. OCR, legacy Office and spreadsheets excluded. |
| 14 | Durable routines | Implemented | Scheduled read-only briefing/review, saved runs, missed/interrupted handling, pause, explicit login launch. Execution requires the app/menu-bar process; catch-up on next launch. |
| 15 | Voice and accessibility | Implemented; native acceptance pending | Opt-in system dictation, original-field validation/copy fallback, vocabulary/punctuation, visible/reduced-motion activity. Real devices, VoiceOver/keyboard/contrast acceptance remain. |
| 16 | Privacy and workspace lifecycle | Implemented | AES-GCM workspace/legacy migration, encrypted portable backups, retention, private sessions, optional macOS lock and external-API pause with documented limits. |
| 17 | Distribution and operations | Tooling and local bundle checks verified; owner setup pending | Developer ID/notary/stapling script, pinned signed manual update feed, hash checks, redacted diagnostics and migration/rollback guidance. Release-fixture launch guards verified locally and added to CI. Public credentials/hosting and clean-Mac acceptance still required. |
| 18 | Real-model quality and reliability | Current running-model workflows verified; preset matrix pending | Live memory/tasks/restart/cancellation/grounding/adversarial checks and warm planning samples passed on M5 Pro/48 GiB. Actual preset quality/latency, cold start, lower-resource hardware, sleep/wake and first-time-user acceptance remain required. |

Developer-profile work now has a separate [implementation plan](developer-assistant-plan.md):
explicit project connections, scoped source tools, Git text comparisons and
persistent development sessions are implemented. Reviewed patch application,
approved build/test execution and semantic indexing remain subsequent stages.
[GitHub, Jira and Confluence read connectors](work-connectors.md) provide search,
source details and local chat tools. Their real-account acceptance remains a
release gate. Further developer work stays deferred from the current milestone.

## UX contract

- Start with Today. Chat remains one click away and retains its history.
- Keep Today, Puddle, Tasks and Memory visible. Put specialist destinations
  under More, expand it when navigating to one, and surface pending reviews.
- Keep first-run Today focused on local setup and priorities. Show optional
  mail/calendar cards only with a connection or cached content, and omit
  empty overdue/waiting counters and unavailable briefing controls.
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
Mac work and current limits. Complete the acceptance dependencies above and the
supported-model evaluation next. Additional platform breadth stays deferred.
