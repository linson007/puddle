# Six-month production review — 15 November 2026

**Scope:** how Puddle behaves after six months of real use, which user segments
stress which parts of the app, and which gaps were closed before this review.

**Reviewed checkout:** `main` at `76910b7` plus the changes in this review.
The earlier [production readiness assessment](../production-readiness-assessment.md)
covers distribution, signing, provider acceptance and release operations. This
review focuses on **six-month runtime behaviour, storage growth and chat history**.

## Executive verdict

Puddle is a local-first, single-user macOS app. There is no multi-tenant backend,
so "production scale" means one Mac, one Keychain, one workspace and an optional
local inference server. The architecture is sound for that model, and the
existing transcript paging keeps a large chat history out of the hot write path.

The remaining six-month risks are not correctness failures in the common path.
They are **resource-growth and hardware-tier risks**:

1. Large indexed document text and cached mail bodies were re-encoded and
   re-encrypted on every chat or task save. A pro user with a large knowledge base
   paid this cost on every message. **Fixed** by the encrypted derived-cache
   sidecar described below.
2. Completed/declined action receipts grew without bound. **Bounded** to the 300
   newest resolved receipts; drafts, in-flight and uncertain actions are kept.
3. macOS caps pending local notifications at 64. Puddle scheduled every future
   task, so a long task list could silently lose reminders. **Fixed** by
   scheduling the nearest 60 and rolling the window forward.
4. History search rescanned all conversations on every workspace mutation, and
   global search allocated an array of every message body per conversation.
   **Fixed** by keying history search to the query/conversation list and scanning
   message content directly with early exit.
5. The six-month performance budgets are calibrated to an M5 Pro/48 GiB host. On
   an M4/24 GiB host the heavy profile still passes every correctness check but
   exceeds the 100 ms save and 64 MiB resident-growth budgets. This is a
   **hardware-tier gap in the budget**, not a regression from these changes.

## User segments and six-month workloads

| Segment | Typical six-month state | What matters | Current assessment |
| --- | --- | --- | --- |
| **Casual personal** | ≈900 chats / 22k messages, 2k memories, 1.5k tasks, no accounts | Fast first launch, simple setup, no model required for tasks | Good. Small hot set; saves are milliseconds. |
| **Pro knowledge worker** | ≈1,800 chats / 108k messages, 5k memories, 5k tasks, 360 meetings, Gmail/Calendar, routines | Save latency while chatting, mail cache size, reminder reliability, retention | Good after these fixes. Transcript pages keep chat out of each save; derived cache keeps inbox/document text out. |
| **Power user with one huge active chat** | One conversation of 100k+ messages plus archives | Chat rendering, "load earlier", append cost, cold start | Bounded. UI shows 200 messages and pages by 200. Cold load is linear and was 0.74 s for 108k messages on the M4 test host. Each append still copies the active chat array once or twice; acceptable at the 120 MiB ceiling but not O(1). |
| **Heavy researcher** (Knowledge) | Up to 20 sources and 10M indexed characters | Every-save cost, search cost, cache repair | Fixed. Document text lives in `derived-cache.vault` and is not rewritten when unchanged. Search remains linear in indexed text, off the main thread. |
| **Developer** | Project folder, git status/diffs, saved sessions | Read-only scope, diff size, session growth | Good. Project reads are bounded and read-only. Development sessions are bounded to 500 on backup import but not pruned in the live workspace. |
| **Privacy / private-session user** | No persistence for new work; lock on background | Memory-only isolation, no external calls | Good. Private sessions keep chat in memory and pause provider work. |
| **Low-memory / older Mac** | macOS 14+, 8–16 GiB, slower disk | Peak RSS, cold load, backup export | **Monitor.** The whole logical workspace is materialized in memory. A 120 MiB workspace can exceed 500 MiB RSS during load and backup. Minimum-OS and 8 GiB acceptance remain open gates. |
| **Accessibility user** | VoiceOver, keyboard, reduced motion, high contrast | Setup, chat, recovery prompts | Not re-verified here; remains an explicit release gate. |

## What scales and what does not

| Property | Six-month behaviour |
| --- | --- |
| Archived chat storage | Immutable encrypted pages of up to 512 messages. Unrelated saves reuse pages and only rewrite the tail page. |
| Index size | Proportional to memories, tasks, meetings, settings and metadata, not to archived message text. |
| Hot save payload | Knowledge text and cached mail bodies are now in a separate sidecar and skipped when unchanged. |
| Active chat | Fully held in memory; appending copies the array when another snapshot retains it. Bounded by the 120 MiB workspace ceiling. |
| Search | Linear in stored text, cooperative and cancellable, off the main thread, capped at 80 results. |
| Cold start | Reads and verifies every transcript page and its recovery copy. 0.74 s for 108k messages on the M4 host. |
| Portable backup | LZFSE-compressed, checksummed, 64 MiB file ceiling. A near-limit, high-entropy pro workspace cannot always be exported. |
| Workspace ceiling | 120 MiB logical, including transcript pages, index and derived cache. |
| Reminders | Nearest 60 future commitments scheduled with macOS; the rest roll forward as reminders fire or on the next launch. |
| Actions | 300 newest completed/declined receipts retained; unresolved actions never pruned automatically. |
| Routines | At most 500 run records; missed runs are recorded once and never replayed. |

## Changes in this review

### 1. Encrypted derived-cache sidecar (`derived-cache.vault`)

`knowledgeDocuments`, `messages` and `outlookMessages` are removed from the
index before it is encoded and stored in an AES-256-GCM sidecar encrypted with
the workspace key. A structural signature over the in-memory caches means a save
does **not** encode, encrypt or write the sidecar when it is unchanged.

- Legacy workspaces that still carry these fields inline migrate on their next
  save.
- An unreadable cache is preserved as
  `derived-cache-unreadable-<uuid>.vault`, logged, and ignored. Mail cursors are
  reset so the next sync establishes a clean baseline instead of marking the
  whole inbox new.
- The sidecar is written before the index. If the index commit fails, the cache
  may be newer than the index; both are derived data and reconcile on refresh.
- The 120 MiB logical ceiling includes the sidecar.

### 2. Bounded resolved action receipts

`AppSnapshot.pruneResolvedActions` keeps the 300 newest completed or declined
proposals. Drafts, dispatching and uncertain proposals are never removed, because
their provider outcome may still need review.

### 3. Reminder scheduling window

`ReminderScheduler` schedules the nearest 60 future commitments, ordered by due
date, and reconciles again after due reminders are delivered. This avoids the
platform's pending-notification cap silently dropping reminders in a workspace
with hundreds of dated tasks.

### 4. Search allocation and history rescanning

- `WorkspaceSearch` scans conversation lines directly instead of building an
  array of every message body. Terms may match across separate messages, and the
  scan stops at the 80-result cap or cancellation.
- Conversation history search now re-runs only when the query, current
  conversation or conversation count changes — not on every appended message.
- `persist()` no longer rewrites the activity array (and bumps the workspace
  revision) when it is already within its 100-item bound.

### 5. Portable backup for a single very long conversation

`WorkspaceBackup.validate` rejected any conversation above 10,000 messages, so a
pro user whose active chat exceeded that limit could not export or move their
work at all. The per-conversation cap is now 250,000 messages, still bounded by
the 120 MiB logical payload and 64 MiB compressed-file limits.

## Verification

- Full suite: **637 tests**, 26 skipped (opt-in live/load tests), **0 failures**.
- Guards: localization coverage, Python script tests and concurrency check pass.
- Targeted new tests cover sidecar reuse, sidecar rewrite, sidecar deletion,
  legacy inline migration, unreadable-cache recovery, action pruning, reminder
  windowing and conversation search.
- The opt-in heavy six-month profile was run on this review host (Apple M4,
  24 GiB, macOS 27.0.1): 108,000 archived messages, 5,001 memories, 5,000 tasks,
  360 meetings.
  - Save P50 ≈ 122 ms, P95 ≈ 125–126 ms, maximum ≈ 129 ms.
  - Cold load ≈ 0.74 s; JSON encode ≈ 0.30 s; initial paged save ≈ 17 s.
  - Late-history search ≈ 0.28 s; global late hit ≈ 0.34 s; global miss ≈ 0.35 s.
  - The same profile on unmodified `HEAD` measured the same P95 (≈126 ms) and
    222 MiB resident growth versus 188–316 MiB with these changes, i.e. run-to-run
    variance rather than a regression from the cache sidecar.
  - The hard-coded 100 ms save and 64 MiB resident-growth budgets fail on this
    hardware. They match the documented M5 Pro/48 GiB baseline, not an M4/24 GiB
    tier. Treat them as hardware-specific regression budgets and add a slower
    tier before publishing fleet-wide latency claims.
- The opt-in long active-chat profile (108,000 messages in one conversation) on
  the same host: save P50 ≈ 93 ms, P95 ≈ 95 ms, cold load ≈ 0.38 s, and portable
  backup now succeeds at ≈ 4.7 MiB after the 10,000-message export cap was
  removed. Resident growth plateaued ≈ 118 MiB above the early warmup sample,
  still above the 64 MiB budget but stable across the run.

## Remaining gaps before public production

These are not introduced by this review and still need an explicit decision or a
separate change.

1. **Hardware-tier performance budgets (P1).** Re-baseline save, cold-load and
   peak-RSS budgets for 8–16 GiB Macs and the minimum supported macOS runtime.
   Do not claim M5 Pro numbers as fleet-wide guarantees.
2. **Portable backup ceiling (P1 for device migration).** A near-limit,
   incompressible workspace can still exceed the 64 MiB compressed export
   ceiling even though individual long conversations are now supported. Test a
   documented split/export path or state the limit at the point of use.
3. **Workspace ceiling recovery (P2).** When the 120 MiB logical limit is hit,
   the user sees a save error. Add storage usage visibility and a guided
   "remove old archives / export first" path instead of expecting the user to
   infer it from the error.
4. **In-memory workspace architecture (P2).** All archived messages are
   materialized at startup and retained. Page-backed history or an indexed store
   would lower peak RSS; it is a larger change than this review.
5. **Platform acceptance (P1).** Clean-Mac install, notarized update/rollback,
   real provider consent/write tests, supported local-model matrix, macOS 14
   runtime, VoiceOver/keyboard/reduced-motion acceptance and a support/incident
   process remain release gates. Fixtures do not replace them.
6. **Stale build resources (P3).** Removing a locale leaves the old `.lproj` in
   `.build/.../Puddle_PuddleCore.bundle`, which makes `LocalizationTests` fail
   until the bundle is cleaned. Clean stale resource directories in the build
   script or test from a clean `.build`.

## Operating expectations after six months

For a pro user with roughly 10 conversations a day, 5,000 memories, 5,000 tasks,
360 meetings, a 10M-character knowledge base and a full cached inbox, the
workspace should remain responsive because:

- chat history is paged and reused across saves;
- the knowledge and inbox caches are not rewritten unless they change;
- the hot index stays small;
- search and backup run off the main thread with cancellation and bounds.

The user should still be told, in the app, that retention is bounded and that a
portable backup is the supported way to move or preserve work. Six months of
heavy use is a resource-curation problem, not an unlimited-storage promise.
