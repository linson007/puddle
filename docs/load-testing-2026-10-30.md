# Six-month workspace load testing — 30 October 2026

The tested workloads pass after fixing persistence, memory-context and rendering
bottlenecks. This is a synthetic volume and repeated-save test, with native UI
verification. It does not represent six months of continuous wall-clock uptime.

## Workloads and machine

Measured on an Apple M5 Pro, 48 GiB RAM, macOS 26.6 (25G72). Each synthetic message
contains approximately 600 characters plus its identifier. Meeting transcripts
contain approximately 11,000 characters each. No personal workspace, account
credentials, provider writes, microphone or real notifications were used.

| Profile | Archived chats / messages | Active messages at start | Memories | Tasks | Meetings | Snapshot JSON |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Regular | 900 / 21,600 | 1 | 2,001 | 1,500 | 180 | 18.8 MB |
| Heavy archives | 1,800 / 108,000 | 1 | 5,001 | 5,000 | 360 | 84.3 MB |
| Long active chat | 20 / 480 | 108,000 | 5,001 | 5,000 | 60 | 82.7 MB |

The regular profile approximates five conversations a day for 180 days; the heavy
profile uses ten longer conversations a day. Volume, individual-chat length and
saved-memory count are tested independently of the user's actual usage rate.

## Findings and changes

- Saving a task rewrote the entire encrypted transcript history. Heavy saves
  blocked for about half a second. Schema 8 now stores immutable encrypted
  transcript pages of up to 512 messages. Unrelated edits reuse those pages;
  appending replies replaces the tail page. Pages have validated encrypted
  recovery copies. Atomic root commits retain the current and previous
  generations, and obsolete pages are collected without a full scan per reply.
- Prompt preparation repeatedly normalized memory titles in a sort comparator.
  Identity is now computed once per memory. A bounded memory selection and
  queryable memory tool prevent thousands of notes entering every prompt.
  History leaves room for tool results, whose memory JSON remains valid within
  the available context. A real local-model regression retrieves a random old
  fact among 5,000 newer notes after 1,000 long history messages at 8K context.
- Memory and History use lazy lists and cancellable, debounced background search.
  Global search avoids constructing one giant string for each conversation and
  stops after its result limit. Chat initially shows 200 messages and loads
  earlier messages in batches of 200.
- The heavy workspace could not be exported within the old 64 MiB portable-file
  limit. Version-2 backups compress the content with LZFSE before optional
  passphrase encryption. Restore validates checksums, codec and logical size,
  and uses bounded decompression. Version-1 imports remain supported.

## Measurements

P95 uses the sample at `ceil(0.95 × count) − 1` in the sorted samples. Baselines
used 20 task-only saves; final runs use 100 stricter task-edit **and reply-append**
saves. Baseline JSON's old `save_p95_seconds` field contained the maximum; the
table recalculates actual P95 from its saved sample array.

| Operation | Regular before → after | Heavy archives before → after | Long active chat after |
| --- | ---: | ---: | ---: |
| Repeated encrypted save, P95 | 113 → 40 ms | 534 → 83 ms | 61 ms |
| Repeated encrypted save, maximum | 124 → 46 ms | 541 → 92 ms | 70 ms |
| Prompt preparation | 202 → 9 ms | 339 → 16 ms | 16 ms |
| Cold encrypted load | 55 → 162 ms | 230 → 477 ms | 300 ms |
| Portable backup | 25.0 → 1.10 MB | Failed → 4.91 MB | 4.70 MB |

Cold load is slower because it verifies multiple transcript files and recovery
copies. It remained below half a second in these final runs. Initial heavy import
took 2.53 seconds to create 1,801 pages and their recovery copies once. Heavy
backup encode took 894 ms and inspect took 242 ms. Synthetic repetitive content
compresses well; real backup size depends on content.

The heavy late-history search took 236 ms, a late global hit 275 ms, and a global
miss 277 ms. An abundant global query stopped at the result limit in 0.30 ms.
These scans run off the main thread, with cancellation for superseded queries.
Search remains linear in stored text; an indexed search engine was not added.

Repeated-save resident growth from sample six to the final sample was 0.52 MiB
regular, 0.36 MiB heavy, and 26.81 MiB long-chat. A separate **1,000-save** long-chat
run passed with **61.48 ms P95**, 95.57 ms maximum, no net resident growth after
warmup (buffers were reclaimed), full transcript reload and successful backup
restore. This samples process residency, not a heap-leak proof. The test process
also holds fixture JSON, restored workspaces and backup buffers, so its total
residency must not be presented as the app's RAM footprint.

## Native app verification

Computer Use operated a separately signed debug bundle, **Puddle Load Review**,
with isolated synthetic workspaces and file-backed test credentials. The
personal Puddle workspace was not opened by these tests.

- Heavy Memory showed 5,001 facts while only seven visible Forget controls were
  materialized. Searching `4999` returned the correct final preference.
- History showed 1,801 conversations including the current chat. Searching a
  sentinel found archive 1,799; opening it showed its final message.
- A new task was saved after reopening that archive. After quit and restart,
  Tasks retained it and search found its exact title.
- The heavy app process used 292,288 KiB RSS (285.4 MiB) at that checkpoint.
  This is one steady-state sample, not a peak or a cross-device guarantee.
- The separate 108,000-message active chat opened at its final messages. At the
  top of the rendered window it showed “latest 200 of 1,08,000 messages”.
  **Load earlier messages** changed this to 400 and showed message 107,600,
  preserving the total. Native clicks and AX captures completed without a hang;
  automation round-trip timings are not frame-latency benchmarks.

## Regression and build checks

Full suites passed with load, real Splash evaluations and the installed Cua
driver catalog check enabled:

```sh
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test -c release
```

- Debug: **429 tests** (304 core + 125 app), zero failures or skips.
- Release: **427 tests** (304 core + 123 app), zero failures or skips.
- Twenty-one cases added for load/endurance, transcript reuse and durability,
  corruption/replica recovery, migration, failed commits, symlinks, bounded
  memory context, compressed backup compatibility/limits and search.
- Separate heavy, long and 1,000-save long-chat release load runs passed.
- The normal release app was rebuilt successfully. Strict signature verification,
  plist lint and `git diff --check` passed. The release binary rejected the debug
  fixture flag with exit 64 and created no test workspace. The local bundle is
  ad hoc signed; this check does not establish notarization or public release.

Load commands and environment overrides are in [testing.md](testing.md#six-month-load-regression).
Local metrics, raw logs and checksums are retained under
`build/load-testing-2026-10-30/` (gitignored). Source checksums identify the full
tested working tree, including the pre-existing changes; this was not a clean
checkout of a published commit.

## Storage compatibility and remaining limits

Schema 8's roots reference `transcripts/` and `transcripts/recovery/`. Device-bound
recovery requires the **complete workspace directory and its Keychain key**;
copying only `workspace.vault` is insufficient. Use portable backups to transfer
work. Existing single-file workspaces and version-1 backups are readable.
Schema-7 apps cannot read schema 8, and old apps cannot read version-2 exports;
retain a pre-upgrade backup when planning a previous-version rollback.

The logical workspace and backup-content ceiling is 120 MiB. The compressed
portable envelope remains limited to 64 MiB and the passphrase-protected file to
128 MiB. This is bounded storage, not unlimited retention. Workspaces near the
logical ceiling, large document indexes, unusually large single messages, slow
or nearly full disks and lower-memory supported Macs need separate profiles.
The entire logical workspace is still loaded into RAM. These results support
the measured six-month volumes on this Mac; they do not certify all hardware,
all model versions, six months of uptime, or the remaining public-distribution
gates in the [release report](release-regression-2026-10-30.md).
