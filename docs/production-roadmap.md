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

- A new user can connect a chosen, separately installed local provider through
  clear address/model/key guidance and verify replies and tool support.
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

## Production-readiness assessment follow-up — 8 November 2026

The supplied `production-readiness-assessment.md` reviewed an earlier, dirty
checkout. Its recommendations remain useful, but its claims about English-only
shipping and uncommitted OAuth revocation do not describe the current baseline.
English is shipped; Turkish catalog translations remain work in progress. Current provider disconnects remove local
credentials; they do not establish remote revocation.

| Finding | Repository change | Remaining release evidence |
| --- | --- | --- |
| 1: shutdown | One delegate owns wake/background observers. Quit blocks new work, cancels tracked producers, drains writes, preserves uncertain actions and waits for capture/persistence. A deadline offers Keep Open or explicit Quit Anyway. | Native quit/sleep/wake/multiple-window acceptance with live providers, permissions and helper processes. |
| 2: durability/ownership | Encrypted files/pages use file `fsync` plus `F_FULLFSYNC`, atomic rename and parent-directory `fsync`. Advisory locks serialize processes and digest checks reject stale snapshots. Errors propagate; pages referenced by an uncertain index commit are retained. | Actual power-loss/crash drills and supported-filesystem/hardware validation. Flush requests cannot prove that every storage controller honors them. |
| 3: model contract | Setup uses the production streaming parser for reply, tool call, synthetic tool result and final reply. SSE assembles multiline events; byte framing preserves CRLF delimiters and bounds memory. Idle/first-byte and total deadlines cancel stalled streams. | Each advertised server/model/version, restart and cancellation acceptance. |
| 4: uncertain writes/revocation | Guided provider checks expose stable identities. Read-only Gmail sent-record and new Calendar-event lookups can confirm positive evidence; absent/changed records stay uncertain. No write replays. Consent/disconnect explicitly distinguish local removal from provider revocation. | Real consent, expiry and revoke behavior for each provider. Other write types require the manual check. No retained-token revocation queue is claimed. |
| 5: helper boundary | Cua launch requires a publisher-pinned code-signing requirement and strict signature validation. Builds without a pin disable this optional helper. The current app remains unsandboxed. | Select and accept the intended helper identity/version, including its installation/update path and clean-Mac permissions. Sandboxing is not implemented. |
| 6: release artifact | Release runs bundle verification before notarization and after stapling. Optional manifest generation uses the final archive and checks its embedded version/build/key/signature. A remote hash/signature check is available before feed promotion. | Developer ID, Apple notarization, immutable hosting, feed promotion and clean-Mac install/upgrade/restore drills. |
| 7: failed requests/privacy | Failed initial or answer saves retain the original request with Retry/Copy/Discard and quit-loss review. Provider consent/disconnect surfaces disclose saved-history, model-log and backup retention, with deletion/access routes. | First-time-user comprehension and failure/retry acceptance. In-memory drafts cannot survive process death when storage is unavailable. |
| 8: migration | The decoder retains its source version, dispatches explicit supported-version steps and stamps current only on success. First encrypted rewrite retains the original encrypted generation and its transcript pages. | Real historical-version fixtures and older-binary restore/rollback. Downgrade is restore-from-backup, not in-place reverse migration. |
| 9: capacity | An opt-in 108 MiB deterministic entropy/reopen profile reports save/load time and peak RSS, and checks the separate portable-backup limit. | Low-RAM/slow-disk hardware, genuinely cold OS caches and practical latency/memory budgets. The logical cap is a storage guardrail. |
| 10: connectors | GitHub reads share bounded jittered retry; allowlisted Atlassian MCP reads opt into retry despite POST framing. Work reads coalesce identical requests and cap distinct concurrent reads. Outlook query pages and Calendar-list pages expose completeness/continuations; the assistant receives a completeness warning. | Disposable-account pagination, rate-limit and quota acceptance. Calendar selection fails explicitly if its list is truncated. |
| 11: fleet operations | Previewable diagnostics include bounded redacted operation IDs/timestamps/error codes and recovery flags. Release instructions define cohorts, feed pause and restore steps. | Appoint monitored security/support owners and response targets, configure production hosting/key custody, and rehearse the incident/update-pause runbook. |
| 12: OS/human acceptance | Minimum-OS and accessibility acceptance remain explicit blocking rows in the release checklist; new recovery/privacy controls ship in English. | macOS 14 runtime, first-run, VoiceOver, keyboard, contrast and reduced-motion acceptance. CI compilation and fixtures do not close these rows. |

This follow-up does not change the public-distribution hold. Record exact artifact
hash, OS, hardware, provider/model/helper versions, tester, date and observed
results for every external gate. Do not mark a row accepted from fixture counts.

The follow-ups are split into independent PRs: [storage recovery and crash drills
(#82)](https://github.com/linson007/puddle/pull/82) and [model/helper compatibility
acceptance (#83)](https://github.com/linson007/puddle/pull/83). The
[release acceptance record](releases.md#artifact-bound-acceptance-record) tracks
the remaining environment evidence against the exact final archive. It starts
with every gate pending and prevents the scripted promotion check from passing
without complete evidence and operational ownership. Creating a record or merging
the tooling does not establish live acceptance or lift the distribution hold.

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
| Model/hardware coverage | [Acceptance matrix and evidence contract](model-acceptance.md); real workflows passed with the owner's running model on 2 November. Provider and model hardware requirements are configured outside Puddle. | Cross-provider model runs, lower-resource hardware and first-time-user assessment. |

The following gates need evidence from their actual environments:

| Gate | Required dependency and completion evidence |
| --- | --- |
| Installation and recovery | Actual ENOSPC/read-only recovery passed in disposable HFS+/APFS images; a 9,600-message legacy workspace migrated and its pre-upgrade protected backup restored. Clean supported Mac, signed-app installation and connection to a separately installed provider, unavailable/restarted model server, host-volume/power-loss and signed-app upgrade/rollback remain. |
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
configuration; compatibility and quality with other providers and models remain pending.

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
local model server selected with `PUDDLE_LIVE_INFERENCE_ADDRESS`, configured Cua Driver and installed speech language. It creates
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
| 7 | Local inference provider choice | Implemented; cross-provider live acceptance pending | Provider-neutral server address, optional model ID/API key, synthetic reply/tool verification and diagnostics. Runtime installation, downloads, hardware requirements and server lifecycle belong to the chosen provider. Existing addresses and keys migrate. |
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
| 18 | Real-model quality and reliability | Current running-model workflows verified; provider matrix pending | Live memory/tasks/restart/cancellation/grounding/adversarial checks and warm planning samples passed on M5 Pro/48 GiB. Cross-provider model quality/latency, cold start, lower-resource hardware, sleep/wake and first-time-user acceptance remain required. |

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
