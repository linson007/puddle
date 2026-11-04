# Roadmap acceptance, 2 November 2026

> Historical verification record. Engine-specific installers, presets and process management described here have since been removed. Current Puddle connects to any compatible local provider; see [current setup](../README.md#build-and-run). Results below apply only to the recorded configuration.


This pass tests the existing personal-assistant loop with the owner's running
local model. It fixes observed failures without adding specialist features.
Public distribution remains gated by the dependencies below.

## Configuration and evidence

| Item | Observed configuration |
| --- | --- |
| Host | Apple M5 Pro, 48 GiB unified memory, macOS 26.6 (25G72) |
| App source | Base commit `accf2644e3cfd6234da66ce0efd6b8930d0d28d7` plus the retained working changes and new acceptance tests |
| Splash | Source checkout; build `src-fd6da6335162b2cedd9af319b9019017c58aa6381f9bd122c0727028b366907c`; loopback port 8000 |
| Model | `mlx-community/Qwen3.6-35B-A3B-4bit`; cached revision `38740b847e4cb78f352aba30aa41c76e08e6eb46` |
| Runtime model fingerprint | `fa5d0582588c7792bf4488f9d5c51f54a49bb121adeaed2fe1958d2970fea5eb` |
| Context | Runtime reports 262,144 maximum tokens; app workflow tests use an 8,192-token budget |
| Browser | Installed CuaDriver 0.38.0, dedicated Chrome session, disposable loopback page |
| Isolation | Synthetic encrypted workspace and in-memory test secrets; app transport permits only loopback Splash; provider connections and notifications disabled |

Local evidence is under `build/roadmap-acceptance-2026-11-02/`: final suite/build/
bundle logs, source checksums and patch, runtime status, per-build workflow
prompts/replies/timings and regular-load metrics. Native review used a separate
debug bundle and synthetic workspace, without personal account credentials.
The user's running model server was retained.

The model is different from both [configured setup presets](model-acceptance.md).
These results do not certify those presets, lower-memory Macs or another OS.
The server was already warm and other desktop apps were open; this is not an
isolated cold-start, peak-runtime-memory or sustained-throughput benchmark.

## Observed failures and corrections

- Native chat remained in Thinking after the server completed a browser turn.
  A process sample showed heavy native rendering synchronization. Streaming now
  uses plain text, publishes changed partials at most 20 times per second and
  clears obsolete tool preambles. Final saved replies retain Markdown. The
  repeating symbol pulse was removed; visible activity labels remain.
- Browser errands exposed a large internal prompt as the user message. They now
  show the short goal, with full inference context in a disclosure. Copy/draft
  and conversation titles use the short request; full source/retry data remains
  saved. Old records decode without the optional display field; backup bounds
  and archive/restore compatibility have regression coverage.
- A paused errand could copy an unrelated earlier assistant answer as progress.
  Pause now saves an explicit inspection instruction; completed progress uses
  only a reply after the current request. A regression covers the old failure.
- One full live run failed to find a persisted task for completion. Tool and
  system guidance now require reading the current task list and using its exact
  UUID before updating or claiming absence. The original completion case and
  three natural-language variants after restart pass; decline still leaves all
  tasks unchanged. The failed run is retained as `debug-full.log`.
- Balanced setup previously allowed 32 GiB although Splash's preset requires
  36 GiB. Eligibility, recommendation, labels, documentation and boundary tests
  now agree on 36 GiB; 32 GiB falls back to compact.

An early missing-context assertion rejected an honest equivalent phrase. The
reply was inspected and the test accepts equivalent admissions of missing
information. This was a test correction, not a model-quality improvement.

## Initial verified flows

Final full runs passed with live Splash, installed-driver/session, synthetic
audio-file, bounded filesystem and regular-load opt-ins enabled:

| Build | Core tests | App tests | Total | Failures / skips |
| --- | --- | --- | --- | --- |
| Debug | 332 | 156 | 488 | 0 / 0 |
| Release | 332 | 152 | 484 | 0 / 0 |

Five warm planning samples per build at the 8,192-token budget gave first-text
P95 **0.89 s debug / 0.75 s release**, and total P95 **1.98 s / 1.67 s**, below
the initial 5 s / 30 s budgets. These small samples exclude user action-review
waits and do not predict arbitrary requests. Release regular-load save P95 was
41 ms and cold workspace load 172 ms; all existing storage budgets passed.
The 1 November heavy/1,000-save endurance results retain their earlier scope.
The normal release app rebuilt successfully. Plist/strict signature validation,
fixture-argument refusal and marker-only fixture refusal passed before workspace
creation; script syntax and whitespace checks also passed. The signature is
local/ad hoc and does not establish Developer ID or notarization acceptance.

| Flow | Evidence and limits |
| --- | --- |
| Local setup | Native existing-server address, chat/tool probes, save and relaunch passed. No clean install or model download was performed. |
| Memory | Live introduction/preference extraction, new-chat recall, name correction, disabled learning, explicit forgetting and encrypted restart passed. |
| Tasks | Live exact reminder title/time review, decline without mutation, approval, encrypted restart, current-ID lookup, reviewed completion and retry without duplication passed. OS notification delivery was deliberately disabled. |
| Conversation | Five short planning prompts returned useful steps; an unknown dentist's name produced an admission of missing information. Outputs retained for review; finite samples do not establish general quality. |
| Cancellation | Stop followed by new chat rejects late stream content; the next turn completes. Existing profile-switch and generation-boundary regressions remain. |
| Grounding | Live bounded-context old-memory retrieval, grounded daily brief/timestamps and hostile email/document cases passed with synthetic sources and canaries. |
| Browser | Native read, declined navigation, fresh reviewed navigation, summary, reviewed scrolling and explicit Stop passed. After the rendering fix, decline returned Ready in about 2.6 s, navigation/summary in 7.7 s and scrolling in 3.2 s. These are observations, not model-latency samples. The page recorded no click/type events. Multi-tab and other browser/OS compatibility remain pending. |
| Storage | Actual ENOSPC and read-only saves failed without changing the committed encrypted root; reopen, subsequent writable save and protected backup/idempotent restore passed in disposable 32 MiB HFS+ images. APFS and the larger upgrade rehearsal were completed in the follow-up below. |
| Speech | All 14 file/pipeline/short-speech checks passed with generated synthetic speech and the on-device recognizer. Live selected-app isolation was not started; the owner chose to leave it pending. |
| Native layout | Today and the revised conversation/browser flow were initially inspected at approximately 961 logical pixels wide. The minimum-height, dark appearance and keyboard follow-up is below; VoiceOver and first-time-human acceptance remain pending. |

Browser clicking and typing remain deferred for v1. Assistant tools, workspace
and adapter reject them before dispatch. Historical receipts remain readable;
they cannot restore writes through retry or Continue.

## Independent follow-up

The owner then requested completion of all work that does not need their input.
The existing feature scope was retained. Local fixes and checks now include:

- Command search previously did nothing on Return. It now supports Up/Down,
  selected-row feedback and Return activation for both commands and saved
  results. Query changes clear stale matches, and delayed search completion
  preserves the current arrow selection. Native capture → search → open/edit →
  cancel passed, including a fast Down immediately after opening the palette.
- Memory, chat and browser-goal forms now retain drafts if the initial save
  fails. Native review inserted a reversible obstacle at the fixture's backup
  path: memory/chat stayed editable with their exact text and no saved mutation.
  After restoring the path, retry saved one memory and one conversation turn.
  The error cleared and the fields cleared only after success. Failed correction
  and browser-goal retry have app regressions as well.
- Manual updates now own cancellable work, discard late results, clear an older
  offer on a failed check and gate check/download/open consistently while locked
  or connections are paused. The policy transport already blocked paused
  external requests; this also fixes inconsistent controls and operation lifetime.
  The archive checksum is rechecked before opening, so a changed file is rejected.
  Five workflow tests use a real bundle-pinned synthetic key/feed and disposable
  download folder; they cover wrong key/hash, truncation, cancellation/pause,
  stale results, old builds, invalid configuration, file change and retry.
  Native unconfigured-feed handling displayed an actionable setup message.
- All five actual filesystem tests passed: ENOSPC and read-only HFS+ (32 MiB)
  and APFS (128 MiB) images, plus migration of 120 archived conversations with
  9,600 messages and 501 tasks from legacy storage, encrypted reopen and protected
  pre-upgrade backup restore. Merge remained idempotent. The APFS image reported
  ENOSPC after 129,499,136 filler bytes; the host volume was not filled. This is a
  data recovery rehearsal, not acceptance of an older signed app or power loss.
- Native Today, task editor, wrapped long title/notes, search and offline task
  capture passed at the app's 960 × 640 content minimum. The outer native capture
  was 960 × 692 logical pixels including title/toolbar, 1,920 × 1,384 at 2×.
  Light/dark appearance was checked in isolated apps; OS-wide preferences were
  unchanged. Fourteen declared text/background palette pairs meet 4.5:1
  (minimum 4.60:1). This does not certify system text, high-contrast settings,
  every screen or VoiceOver comprehension.

`make verify-local` now repeats the independent automated gates using an already
running Splash server, configured Cua Driver and installed speech language. It
generates a speech file without playback, owns/cleans up its loopback browser
fixture, runs all suites and load profiles, and captures source hashes/patch and
per-build evidence in a new directory. It does not install models, access accounts,
record live audio, change permissions, stop the owner's server or publish.

The complete runner passed. Evidence:
`build/roadmap-independent-2026-11-02/`, with native fixture state and
`palette-contrast.json`; the console log is
[regenerable fixture evidence](testing.md#reproducible-evidence).

| Follow-up build | Core | App | Total | Failures / skips |
| --- | --- | --- | --- | --- |
| Debug | 335 | 163 | 498 | 0 / 0 |
| Release | 335 | 159 | 494 | 0 / 0 |

Both full suites enabled live model/driver, file recognition, actual filesystem
and regular load checks. Heavy load, 1,000-save endurance, normal release build,
bundle fixture refusals and whitespace also passed. Five warm planning samples
gave first-text P95 **0.98 s debug / 0.91 s release**, total P95 **2.07 s / 1.87 s**.
One separate native retry after idle took 5.6 s to first text; cold-start and
lower-resource performance are still separate acceptance work.

## Remaining release dependencies

- Run both advertised presets on their eligible hardware, including cold start,
  resource pressure, cached offline restart and interrupted installation.
- Perform first-time-user and VoiceOver evaluation, high-contrast/reduced-motion
  settings and additional app/keyboard variants on advertised OS versions.
- Complete supervised live app-audio A/B isolation, permission denial/revocation,
  sleep/wake/device-loss, dictation-target and notification-delivery checks.
- Use owner-designated test accounts and OAuth registrations for real consent,
  partial grants, revoke/refresh, switching and disconnect. No real provider
  writes were performed; exact content and destination need separate review.
- Supply a Developer ID Application identity, notary profile, hosted signed
  update feed and clean test Mac. No Developer ID identity is installed here.
  Verify shipped-config tamper rejection, install/upgrade and rollback with a
  pre-upgrade backup. No release was published.

The owner will provide account/release details. Update support remains a signed,
pinned **manual** check/download flow; this build has no hosted feed/key
configuration. Automatic checking, update notifications and automatic
installation are not implemented.
