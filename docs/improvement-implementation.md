# Product improvements: implementation and verification

Implementation followed the requested order, starting with guided Splash setup
and shared action review. Existing developer/work connectors and the user's Cua
integration are retained. Fixture success is not public-release acceptance.

| Stage | Implemented | Evidence and limits |
| --- | --- | --- |
| 1. Guided Splash | Hardware/OS/memory/disk preflight, executable discovery/selection, Homebrew install, compact/balanced presets, managed launch/stop, logs, real chat/tool probes, saved connection; Today/chat/Settings entry points | Hardware/process/HTTP fixtures and real synthetic Splash probe. Chat success survives unsupported tools. Clean-Mac install/download and hardware matrix need acceptance. Only owned processes are stopped. |
| 2. Shared review | Editable proposals, provider/account binding, exact-content digest, saved dispatch intent, receipts, uncertain recovery, no replay | Changed content/account, permission denial, failed persistence, lost response, retries and restore covered. No real email/events sent during development. |
| 3. Mail | Compose/reply/forward, local draft generation, reviewed send/organization, follow-ups, VIP explanations, local snooze, reviewed RFC8058 unsubscribe, threads/attachments, local PDF/text analysis | Gmail/Graph fixtures. Inbox50/search10; Gmail threads250, Outlook500/10M body characters; partial results labeled. Attachment10MB. Unsubscribe fixed anonymous POST/no redirects/retries, public destinations only. Snooze affects Puddle. |
| 4. Calendar | Agenda/week/month, selected secondary calendars, attendees, working hours/buffers, slots/focus proposals, reviewed create/edit and undo | Calendar math, pagination, write/ETag fixtures. Partial results cannot be booked from suggestions. Scope is selected calendars/fetched window. Calendar provider remains Google. Undo reviews cancellation/restoration and may notify attendees. |
| 5. Daily use | Compact Today/next agenda, commands/global search, quick capture, contextual panel, reduced-motion activity states, repeating commitments and reviewed task changes in chat | Search/day-boundary/recurrence/DST/month-end/duplicate/review-race fixtures. Native capture/repeat, command search and contextual-panel flows passed; exhaustive keyboard/VoiceOver/layout variants remain. |
| 6. Meetings | Floating companion, quick notes, visible capture, transcript search/summaries, encrypted checkpoints and explicit recovery, project and provider-scoped recurring-series links | Capture/cancellation/extraction/recovery/series fixtures. No raw audio saved. Live device/permissions/language/sleep acceptance remains. Meet attendance stays experimental and separate from Cua. |
| 7. Privacy | AES256-GCM/Keychain workspace, legacy migration, encrypted portable backups, private in-memory sessions, macOS app lock, archive retention, external-API pause | Migration/corruption/missing-key/passphrase/private/lock fixtures. App policy is not a system firewall; independently running Splash/driver behavior is outside its control. An unlocked Mac/user process can access authorized data. |
| 8. Dictation | Opt-in hold CmdShiftSpace, on-device recognition, vocabulary/punctuation, original AX field validation, copy fallback | Synthetic capture/target/hotkey tests. Real app compatibility and Accessibility/mic/speech grants need acceptance. Password fields excluded; focus changes prevent insertion. |
| 9. Cua errands | Saved goals/progress, bounded continuation from fresh state, pause/takeover, user-confirmed fresh evidence, restart pause | Existing Cua tests retained; recovery/evidence tests added; installed-driver catalog check. No automatic reconnect, click replay or approval bypass. Live browser/model tasks need acceptance. |
| 10. Routines | Schedule/timezone/weekdays, read-only briefs/reviews, history/results, durable intent, missed/interrupted handling, pause, optional login launch | Schedule/DST/persistence/cancellation/restart fixtures. Runs while app/menu bar is open; catch-up after next launch when quit. Never automatically sends/books. |
| 11. Accounts | Multiple explicitly switchable Google/Outlook mail accounts in Keychain, optional grants, expected-account token checks, separate caches | OAuth/PKCE/identity/Graph fixtures. Owner registration/verification and live consent/revocation/tenant tests remain. |
| 12. Knowledge/work context | Explicit files/folders, incremental text/PDF/DOCX index, cited passages/deletion propagation; project goals/links, manual people/VIPs, decision options/rationale/evidence/owner/review/outcome; read-only tools and backup support | File/symlink/size/change/deletion and portfolio/search/restore fixtures. No OCR, legacy Office or spreadsheet extraction. Refresh is explicit. No automatic sensitive profiles. |
| 13. Release operations | Version/build/config injection, hardened Developer ID path, notarization/stapling, SHA256, pinned Ed25519 manual update feed, copy-only diagnostics | Crypto fixtures/script validation/local build. Owner signing/notary credentials, hosted feed and clean-Mac upgrade/rollback acceptance remain. No release published. |

## Verification

Run `make test` and `make build`. Optional real checks use synthetic model prompts
and the installed driver's MCP catalog, without page control:

```sh
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/absolute/path/to/cua-driver \
  sh scripts/swift.sh test --filter 'LocalAISetupTests.testLiveSetupAgainstRunningSplash|CuaBrowserTests.testInstalledDriverMCPHandshakeAndBrowserCatalog'
```

Latest regression after the Meet follow-up: **382 tests, 374 passing, eight
optional skips, zero failures**.
The live Splash and Cua catalog checks also passed separately. The
[native Cua acceptance report](cua-end-to-end-2026-10-30.md) records guided setup,
mail/calendar review, meetings, privacy, routines, knowledge and persistence,
including bugs fixed and rechecked in the rebuilt app. Live audio and
permission-dependent browser checks remain pending by the user's choice; live
providers were restricted to read/draft/review. Build/script evidence is in
[development-log.md](development-log.md). Local final logs:
`/tmp/puddle-cua-regression-final.log`, `/tmp/puddle-cua-release-build.log`.
Meet follow-up: `/tmp/puddle-meet-command-regression.log` and
`/tmp/puddle-meet-command-release.log`. That fix adds command-specific errors,
verified tab cleanup and a blank-page setup check. Computer Use did not approve
the separate review app, so its native Chrome check remains pending. The fixed
release is staged as `build/Puddle Meet Fix.app` without replacing the running
app while its attendance state is uncertain.
See [testing.md](testing.md) for remaining interactive variants and
[releases.md](releases.md) for owner setup.

## Outside this Mac implementation

Windows/mobile clients, cross-device sync, other inference runtimes, screen/image
understanding, generalized desktop automation, OCR/legacy Office import and work
while fully quit are not implemented. Developer patch/build execution remains in
the separate roadmap. Public production readiness still requires the acceptance
and owner configuration above.
