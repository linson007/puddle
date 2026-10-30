# First public release regression — 30 October 2026

**Release decision: HOLD public distribution.** The briefing accuracy finding
below is now resolved by the [verified follow-up fix](briefing-regression-fix-2026-10-30.md),
with 408 debug and 406 release tests passing and native verification. The
original pass below records the earlier results and failure evidence. Public
signing, clean-Mac installation, live provider consent and OS/device acceptance
still need evidence; they are not certified by these tests.

## Tested state and results

Tested the current working tree, preserving the owner's existing uncommitted
implementation. No commits, pushes, publication or real provider writes were
performed. Native testing used a separately identified `Puddle Regression.app`
and disposable encrypted workspaces; the personal app remained separate.

Environment: Apple M5 Pro, 48 GB RAM, macOS 26.6, Asia/Kolkata. The existing
loopback Splash server served `mlx-community/Qwen3.6-35B-A3B-4bit` with reported
262144-token capacity. This is one Mac/model combination, not an OS/model matrix.

| Check | Final result |
| --- | --- |
| Debug XCTest suite, all live opt-ins enabled | **395 passed; 0 failed; 0 skipped** — 271 core + 124 app |
| Optimized release XCTest suite, all live opt-ins enabled | **393 passed; 0 failed; 0 skipped** — 271 core + 122 app |
| Real local-model evaluations | Eight passed within each full suite: setup/tool probe, memory learning/recall, task tools, hostile email instructions, source reading and briefing times |
| Installed Cua Driver | Real MCP handshake and browser tool catalog passed |
| App packaging | Debug and release bundling passed |
| Final release artifact | `build/Puddle.app`, arm64, 0.1.0 (1), minimum macOS 14.0 |
| Bundle checks | Strict signature verification, plist/entitlement validation and shell syntax passed |
| Fixture exclusion | Release executable rejected `--ui-test-workspace` with exit 64 and created no workspace |
| Public signing | **Pending** — the tested bundle is ad hoc signed, with no TeamIdentifier |
| Patch hygiene | `git diff --check` passed |

The two debug-only tests cover the synthetic provider boundary and disconnected
first-run workspace. Nine tests were added in this regression pass. The initial
baseline had 386 cases, including eight optional skips; the final runs enabled
the local-model and installed-driver checks.

## Corrections and remaining finding

| Issue reproduced | Correction and protection |
| --- | --- |
| A public release inherited `PUDDLE_BUILD_CONFIGURATION=debug`, allowing debug-only fixture mode into a distributable archive. | `release.sh` now forces release configuration. A subprocess test runs the actual orchestrator against disposable signing/notary tools and proves the override. Other packaging tests verify rejected notarization produces no distributable and existing releases/ad hoc identities are rejected before building. |
| Availability interpreted date-only busy events in the Mac's timezone even when planning with another calendar timezone. | Date parsing now accepts the requested timezone. Honolulu/Kiritimati regressions verify the entire busy day is excluded and its exclusive end is respected. |
| Work hours shifted from 09:00–10:00 to 10:00–11:00 on a weekday daylight-saving transition. | Set wall-clock hours instead of adding elapsed hours to midnight. A Cairo transition regression verifies exact local start/end hours. |
| A real routine displayed a UTC refresh clock as local, guessed the current time from the agenda, and later supplied the wrong weekday. | Briefs now provide local as-of, refresh and deadline fields; model context supplies local time and explicit weekday. Raw ISO timestamps remain available. Unit tests cover provider-specific freshness, rollover, bounded JSON and deadlines; a real-model evaluation requires Friday and the three expected local times. This reduces a demonstrated failure and does not make generated prose a factual guarantee. |

The UI harness also gained `--ui-test-empty` for account/model-free acceptance.
It uses an isolated notification scheduler, so fixture startup and edits cannot
reconcile real macOS notifications. An automated restart test verifies no seeded
Google/Microsoft tokens, no provider requests and persisted local commitments.

**P1 — generated brief invents relative timing and a scheduled deadline
(resolved in the follow-up).**
On the final native run, the saved routine's default daily-brief prompt used
the real local Qwen model and synthetic saved sources. At Friday 30 October,
12:43 IST, its 14:00 event was described as “coming up in ~3h 17m”; the correct
interval was 1h 17m. A task titled “Alex will review the release checklist by
Friday.” had `due_at: undated`, yet the prose said “this is the day it's due”
and later “due today”. No task/date was actually mutated, but a user could plan
against the incorrect claims. This was a **failed native acceptance result**,
despite passing timestamp-field and targeted model tests.

The local clock, weekday and refresh timestamps were correct in that final
run; their fixes alone did not remediate generated arithmetic or deadline
inference. The follow-up now renders those claims in code, accepts only
validated model selections of saved source IDs, and tests the complete routine
scenario including persistence and native output. See the linked fix record
for current evidence. Advertised model/runtime acceptance remains a separate
distribution gate.

## Coverage and native acceptance

“Automated” includes injected HTTP/audio/OS fixtures unless explicitly marked
live. “Native” means operated through computer use in this pass.

| Feature | Automated evidence | Native result in this pass / remaining boundary |
| --- | --- | --- |
| First run, Today and setup | Store/setup/hardware/probe, empty workspace and persistence tests; real Splash probe | Fresh disconnected Today; setup guidance; no-model chat disabled; empty Mail/Calendar; task capture and restart passed. Actual first installation/download on a clean Mac remains pending. |
| Profiles, chat, history and memory | Profile migration/validation, conversation/history, streaming/cancellation, memory grounding; live learning/recall/tool tests | Switched Personal → Developer; task-tool reply and receipt; current chat in History; manual memory saved. Shared work/profile survived restart. |
| Tasks, priorities and repetition | Validation, priority/day boundaries, atomic completion, daily/weekly/monthly and DST, reminder reconciliation | Quick capture; waiting owner rejection with retained draft; corrected owner save; Unicode paste/save/reopen and disconnected restart passed. Actual system notification delivery remains pending. |
| Mail and Outlook | Gmail/Graph decoding, accounts, threading, attachments, snooze/newsletters, scope/race/error/refresh tests | Synthetic Gmail inbox, two-message thread and text attachment preview passed. Invalid recipient blocked review and retained draft; exact reviewed fixture send showed a completed receipt. No real email was sent. Outlook live consent/delivery remains pending. |
| Calendar and reviewed writes | Availability/timeline/date-only/DST, provider actions, stale ETags and undo workflows | Agenda and week/month switching; complete October date grid inspected in light appearance. Provider booking/undo is covered by fixtures, not a live booking in this run. |
| Actions and restart recovery | Exact-content review, dispatch persistence, edits invalidating review, uncertainty/no replay and undo tests | Reviewed synthetic send completed; receipt survived restart; provider journal had exactly one POST both before and after restart. |
| Meetings, import/export and summaries | Note drafts/search/export/import, literal extraction, stale summaries, task provenance, failed saves and late callbacks | Saved synthetic note; real-model decision/action/question extraction; reviewed action-to-task with owner/source quote; duplicate action control changed to “Task added”. Live audio was not captured. |
| Voice, audio and system dictation | PCM conversion/lifetime, capture deadlines, cancellation, provisional/final text, speech playback, focus/password-field safeguards | Controls inspected through the app. Actual permissions, recognition quality, app-audio selection, editor insertion and device/sleep recovery remain pending. |
| Meet attendance | Browser protocol/DOM fixtures, admission states, camera/mic restrictions, cancellation and verified owned-tab cleanup | No real call was joined. Actual Chrome/Meet admission and cleanup compatibility remain pending. |
| Browser and errands | Cua protocol/refs/review/freshness, declined/uncertain actions, interrupted errands; real installed-driver catalog | Driver handshake passed; no permission grant or live errand was performed. End-to-end driver session/takeover/model acceptance remains pending. |
| Routines | Schedules, DST/timezone, missed/interrupted history, read-only tools and persistence | Execution, history and restart passed. The initial prose accuracy failure on countdown/deadline is now resolved and rechecked in the linked follow-up. |
| Knowledge | Source bounds/exclusions, text/PDF/DOCX parsing, stale/deleted sources and passages | Explicitly selected a synthetic folder, indexed text, searched a literal term and inspected the file/line passage. No personal document was indexed. |
| Developer | Real temporary repositories, paths/credentials/exclusions, Git reads, sessions, revoked access and live source-grounded model evaluation | Chose a synthetic folder, found source, searched `maximumRetries`, opened exact `Main.swift:2` evidence. |
| GitHub, Jira and Confluence | Work connector/provider/OAuth fixtures, scope/allowlists, partial results, expiry/disconnect and source receipts | Disconnected entry points inspected. Real accounts/tenants, organization approvals and provider response compatibility remain pending. |
| Work context and command search | Projects/people/decisions/relations, restore and read tools | Project objectives/success saved. CmdK searched task owner, meeting, document and conversation; selected result opened the exact task. People/decision variants remain automated in this pass. |
| Privacy, encryption and recovery | Migration/corruption/missing-key, encrypted backup wrong-password/integrity, failed persistence, private sessions, lock and in-flight policy tests | Private task existed only within the session; ending restored two saved tasks. Encrypted export had no task plaintext; native review/merge added zero duplicate items. Lock concealed main and Settings windows. Production Keychain ACL and macOS unlock remain pending. |
| Updates and diagnostics | Signed manifest/key/hash/build/OS rejection; new release orchestrator tests | Unconfigured-feed error displayed. Diagnostics showed only version/OS/chip/RAM/schema/connection booleans. No chats, addresses, tokens or paths. Hosted feed and signed installer acceptance remain pending. |
| Appearance and accessibility | Native labels/navigation exposed to computer use; workflow tests | Light calendar and dark disconnected tasks visually inspected; Unicode and CmdK passed. Minimum-window, full keyboard-only, VoiceOver and supported display/OS matrix are not certified. |

## Gates before public distribution

1. **Distribution:** provision Developer ID, notarize/staple the actual release,
   install under Gatekeeper on a clean supported Mac, and exercise upgrade plus
   rollback with a protected workspace backup. Current ad hoc verification is
   insufficient. Confirm the advertised architecture/OS/hardware requirements.
2. **Onboarding/model:** install Splash and a supported advertised preset with
   no developer checkout or prior model cache; test download failure/cancel,
   resource limits, offline restart and owned-server lifecycle. The tested live
   model differs from the advertised guided presets, which need their own
   chat/tool/grounding/long-context acceptance. Generated brief classification
   and relevance still require human evaluation.
3. **Provider setup:** provision the public Google/Microsoft application setup
   and any required consent verification; test genuine Google, Microsoft,
   GitHub and Atlassian consent/partial scopes, refresh, revoke, account switch
   and disconnect using designated test accounts. Perform separately reviewed
   test sends/bookings/unsubscribes and verify provider outcomes.
4. **OS integrations:** finish microphone/speech/system-audio, system dictation,
   notification delivery while quit, login launch, sleep/wake/device loss,
   production Keychain and macOS authentication acceptance. No permission or
   authentication dialog was bypassed by this run.
5. **Experimental/browser features:** verify an actual dedicated Cua session
   and a disposable Meet conference, including admission, takeover, interrupted
   sessions and verified leave. Handshake/DOM fixtures alone do not establish
   live compatibility.
6. **UX/recovery matrix:** complete keyboard-only/VoiceOver, narrow windows,
   long content, large workspace, disk-full/interrupted writes and representative
   upgrade/restore drills on each supported OS family. Fixtures cover many
   failure contracts but do not replace system acceptance.

Close each gate with evidence before claiming a complete public-release pass.
If a feature is deferred from v1, explicitly reduce its exposed/advertised scope
and test that reduced release instead of treating its pending checks as passed.

## Reproduction and evidence

From the repository, offline fixture regressions:

```sh
sh scripts/swift.sh test
sh scripts/swift.sh test -c release
```

With the existing loopback Splash server and installed Cua Driver:

```sh
PUDDLE_LIVE_SPLASH=1 \
PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver \
  sh scripts/swift.sh test
PUDDLE_LIVE_SPLASH=1 \
PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver \
  sh scripts/swift.sh test -c release
sh scripts/build.sh
codesign --verify --deep --strict build/Puddle.app
```

For native fixtures, use a debug bundle with a distinct bundle identity so the
personal app remains separate. Start with `--ui-test-workspace` and a disposable
directory. Add `--ui-test-empty` for no seeded accounts and an unavailable local
AI address; add `--ui-test-dark-appearance` for dark appearance. Reuse the same
directory and flags to check restart persistence. Notification delivery is
deliberately excluded from this fixture. Follow [testing.md](testing.md) for
live acceptance; the earlier [native run](cua-end-to-end-2026-10-30.md) records
additional historical coverage, not results newly established by this run.

Local full logs, before/after failure evidence, bundle checks and SHA-256 source
and artifact manifests are retained under `build/regression-2026-10-30/`.
They describe an uncommitted working tree rather than an immutable release tag.
