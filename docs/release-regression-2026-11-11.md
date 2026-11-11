# Release regression — 11 November 2026

**Decision: hold public release.** Local regression checks passed after the fixes
below, but signed distribution, supported-OS, live-model/provider, hardware and
human acceptance remain open. The existing [production readiness tracker
#85](https://github.com/linson007/puddle/issues/85) lists those dependencies.

## Scope and environment

- Base: `ab5e19d` plus the working-tree changes accompanying this report.
- macOS 26.6 (25G72), Apple M5 Pro, 48 GiB RAM; Xcode 27.2 (27B52).
- Native walkthrough: a separately identified, ad hoc signed debug application
  with a disposable encrypted workspace and synthetic credentials. Personal
  workspaces and provider accounts were not used.
- Debug/release fixture suites, disposable APFS/HFS+ disk-full and read-only
  recovery, six-month synthetic storage load, concurrency and packaging checks.

This is local engineering evidence, not acceptance of a final notarized archive.

## Release-blocking defects fixed

| ID | Reproduction and previous result | Corrected behavior and verification |
| --- | --- | --- |
| R1 · P1 | Edit meeting notes, then Quit. The app exited without a warning; the new text was absent after relaunch. Development-session drafts had the same missing quit check. | Quit offers **Keep Puddle open** or **Quit anyway** for unsaved meeting/development drafts, including drafts outside the current selection. Keep Open preserves editing; saved or reverted drafts do not prompt. Reproduced before and verified after in the native app, with deterministic lifecycle tests. |
| R2 · P1 | Begin saving a meeting/development session, then type more text while the disk write is pending. Completion unconditionally deleted the draft and replaced the newer text with the earlier saved version. | Save acknowledges only the captured draft. Newer text stays unsaved and can be saved separately; meeting recovery acknowledgments also use the captured recovery. Two blocked-write regressions failed before the fix and pass after it. |
| R3 · P1 | Start and end a private session while existing meeting notes have unsaved edits. Ending the session reset the original draft. | Starting private mode requires saving or discarding existing meeting/development drafts. The check runs after asynchronous cleanup, immediately before entering private mode. Native error/retained-text observation and regression tests cover the behavior. |
| R4 · P1 | Edit a development-session draft in private mode, end the session, then save that retained draft in the normal workspace. Private text survived and could be persisted. | Ending private mode clears development drafts as well as meeting drafts before restoring saved work. Regression verifies a later normal save contains none of the private text. |

Seven new regression tests cover these defects, keep-open/save/retry, explicit
quit, and reverted drafts. Six reproduced failures against the original code;
the reverted-draft control already passed. Before/after logs are preserved locally.

## Verification

| Check | Result |
| --- | --- |
| Script, localization and synchronization guards | Passed; 36 Python tests, synchronized English resources, no new localization coverage debt |
| Full debug suite with filesystem/load opt-ins | 613 tests discovered: 593 passed, 20 intentionally skipped, zero failures |
| Full release suite with filesystem/load opt-ins | 609 tests discovered: 589 passed, 20 intentionally skipped, zero failures |
| Final privacy-check placement refinement | Full debug suite passed (613 discovered, 26 opt-in skips); all 22 focused release privacy/lifecycle tests passed |
| Actual bounded filesystem recovery | All five APFS/HFS+ full-volume/read-only/migration-and-restore checks passed in debug and release; host disk was not filled |
| Synthetic six-month workload | Passed in debug/release: 900 conversations, 21,600 archived messages, 1,500 tasks and 180 meetings |
| Swift 6 complete concurrency build | Passed |
| Final release app and bundle verification | Passed: release build, plist/resources, strict code signature, fixture-argument and marker-only launch refusal before workspace creation |

The release workload measured about 0.166 s to reopen, 0.058 s p95 for repeated
saves (0.100 s fixture budget), 0.060 s for a late global search, and 0.166 s for
portable backup encoding. Initial publication of the synthetic workspace took
about 7.58 s. These are observations on this 48 GiB Mac; they do not establish
cold-filesystem-cache or minimum-hardware performance.

Native checks observed task capture, required-owner validation, priority and
owner persistence across restart, keyboard command search, unsaved-note quit
protection, saving/reopening notes, private-session entry/exit and temporary-task
discard, and actionable local-AI connection failure without a running server.
This was a limited interaction pass, not complete VoiceOver or device acceptance.

Skipped tests require live models, provider/helper/audio integration or a separate
near-capacity profile. They are not counted as passes. No model server responded
on the documented default loopback ports 8000, 8080, 11434 or 1234 during this run.

## Must-haves before public release

| Priority | Gate and concrete completion requirement | Existing tracking |
| --- | --- | --- |
| P1 | Name actual release/security/support/key-custody owners, monitored channels, response target, incident runbook and previous installer; rehearse feed pause and recovery. | [#88](https://github.com/linson007/puddle/issues/88) |
| P1 | Produce one immutable Developer ID-signed, notarized/stapled candidate; verify Gatekeeper, clean install, hosted update bytes, upgrade and rollback. No valid code-signing identity was available on this Mac. | [#89](https://github.com/linson007/puddle/issues/89) |
| P1 | Create the artifact-bound acceptance record for that archive, retain every required gate, and require the completed check before promotion. Tooling/script regressions pass; a real release artifact has not been accepted. | [#86](https://github.com/linson007/puddle/issues/86), [release instructions](releases.md#artifact-bound-acceptance-record) |
| P1 | Test every advertised runtime/model through actual streaming, tool/result/final response, grounding, cancellation and server restart. Verify the accepted signed browser helper if that feature ships. | [#90](https://github.com/linson007/puddle/issues/90) |
| P1 | Use designated Google/Microsoft/GitHub/Atlassian accounts for consent, partial/denied grants, refresh/revoke, account switching, pagination/rate limits and reviewed disposable writes. | [#91](https://github.com/linson007/puddle/issues/91) |
| P1 | Verify native lifecycle, multiple windows, sleep/wake, production Keychain, notifications, microphone/system audio, device loss and permission denial/recovery on supported Macs. | [#87](https://github.com/linson007/puddle/issues/87) |
| P1 | Accept advertised macOS 14 runtime support and the other supported OS families with the signed candidate; complete keyboard/VoiceOver, contrast/reduced motion and uncoached first-run/privacy recovery. | [#93](https://github.com/linson007/puddle/issues/93) |
| P1 | Exercise actual historical workspaces, failed migrations, older signed binary restore and acknowledged-save recovery under power interruption on designated disposable equipment. Disk-image fixtures do not establish these outcomes. | [#92](https://github.com/linson007/puddle/issues/92) |
| P2 | Select minimum-RAM/slower-disk hardware and practical latency/memory budgets; run cold/warm, endurance and incompressible near-capacity profiles separately before making broad hardware/scale claims. | [#94](https://github.com/linson007/puddle/issues/94) |

For v1, either complete acceptance of each exposed feature or explicitly defer it
and verify the reduced release scope. Do not clear gates using unit-test success.

## Reproduction and local evidence

```sh
make guards
PUDDLE_FILESYSTEM_TESTS=1 PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test
PUDDLE_FILESYSTEM_TESTS=1 PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test -c release
sh scripts/swift.sh build -Xswiftc -strict-concurrency=complete
make build
python3 scripts/verify-bundle.py
git diff --check
```

Logs, failing/passing regression evidence, workload JSON, source hashes and the
working-tree patch are under the ignored `build/regression-2026-11-11/` directory.
The initial baseline debug log is `build/regression-2026-11-11-debug.log`.
Native fixture state is disposable and must not be shipped in a release app.
