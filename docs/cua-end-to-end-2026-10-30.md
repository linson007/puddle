# Native Cua acceptance — 30 October 2026

Puddle was run and operated through Cua on this Mac, beginning with guided
Splash setup. Subsequent provider mutations used an explicit isolated debug
workspace and synthetic HTTP responses. Local model calls used the real running
Splash server. This is a native acceptance pass with the limits below, not a
claim that every OS permission, provider tenant, device or failure variant passed.

## Environment and boundaries

- Apple M5 Pro, 48 GB RAM, macOS 26.6; Asia/Kolkata timezone.
- Splash: `mlx-community/Qwen3.6-35B-A3B-4bit`, reported context 262144.
- Personal accounts were limited to read/draft/review. No real email, calendar
  mutation or unsubscribe was dispatched.
- The user chose controls-only audio testing and deferred permission-dependent
  Cua Driver browser checks. No live microphone/system audio was captured and
  no macOS permission or authentication prompt was automated.
- The debug fixture uses two synthetic Google and two synthetic Outlook
  accounts. Its transport only forwards loopback requests; fixed provider hosts
  return fixtures and other external destinations are rejected. Browser control
  is a separate driver integration, not covered by this HTTP fixture.
- Fixture secrets and the workspace encryption key are in an owner-only local
  test file, explicitly labeled in the app. This mode does **not** establish
  production Keychain acceptance. Normal Puddle continues to use Keychain.

## Native results

| Feature | Observed result |
| --- | --- |
| Guided Splash | Today/setup entry, hardware/disk preflight, executable discovery, real reply and required-tool probe, model/context display, and Use This Connection passed. Existing independent server was retained. |
| Tasks and daily navigation | Quick capture, priority, daily repeat, completing into exactly one next-day task, and saved task after restart passed. Today showed local agenda times. |
| Review and actions | Draft editing, invalid-recipient rejection with retained draft, exact-content review, synthetic Gmail/Outlook send receipts, follow-up task, and restart without action replay passed. Outlook acceptance was labeled as distinct from delivery. |
| Mail | Synthetic inbox/thread reading, two-message thread, text attachment preview and real-model question, reply drafting, snooze/bring-back, newsletter review and synthetic unsubscribe passed. Google/Outlook provider and two-account selection passed; full account-race/cache-isolation variants remain fixture tests. |
| Calendar | Agenda/week/month navigation, secondary-calendar selection, working hours/buffers/slots and focus entry points, synthetic create/edit, reviewed undo and final receipt passed. Month screenshot showed every date after the layout fix. |
| Meetings | Saved note, VTT preview/import, floating companion, companion note save, transcript search, real-model literal summary and reviewed local action-to-task passed. Owner `I` and timing `Friday` remained traceable to the action quote. Classification still requires human review. |
| Privacy | External pause blocked provider refresh while retaining cache; local chat continued. Private task existed only during the session, then disappeared when the saved workspace returned. Encrypted export, passphrase review and idempotent merge passed through native file dialogs. Locking concealed both main-window and Settings content; macOS unlock was left manual. |
| Profiles/history/memory | Shared conversation reopened, manual memory saved, CXO/Developer switching retained shared work, and contextual assistant panel beside Tasks passed. Profile and test task persisted across app restart. |
| Routines | Saved disabled schedule, manual read-only run, inspectable history and result passed. After correction, real-model output showed 10:00/14:00 Asia/Kolkata instead of relabeled UTC clock times. |
| Knowledge | Native folder selection, indexing, literal passage search, real-model answer, persistent clickable file/line receipt, and source availability after restart passed. |
| Work context | Project objective/success, manual person/VIP, decision options/rationale/evidence/review date, and command search opening the exact saved decision passed in the first isolated run. |
| Developer | Native folder connection, source list, literal search and opening matching numbered lines passed using synthetic source. Existing automated Git/work-connector tests also passed. |
| Dictation/startup | Voice, language, speed, vocabulary and disabled systemwide-dictation controls inspected; vocabulary saved. Live capture, text insertion into other apps and login launch were not enabled. |
| Cua errands | Browser destination and explicit startup exercised. Driver refused `start_session` (`request_refused`), with daemon permission status unknown. Live browser/errand checks remain pending by the user's choice. |
| Release controls | Unconfigured signed-feed error was clear. Prepared diagnostics contained OS/chip/RAM/schema and connection booleans, without chats, accounts, tokens, URLs or file paths. No update was published or installed. |

## Fixes made during the run

1. Calendar month cells and weekday headers had overlapping SwiftUI identities,
   which hid dates 1–4. Use one unique identity space and a two-row toolbar.
2. Completed calendar undo still offered another Undo. Link reversal proposals
   to their original action and suppress duplicate/recursive undo, including
   while a reversal is saved or pending.
3. A generated mail reply invented completed work. Strengthen source-grounding
   instructions and reject common unsupported first-person completion claims
   before replacing the editable draft. This bounded check is not a general
   factual verifier; the full draft still needs review.
4. Meeting extraction rejected an owner outside its own quote. Clarify literal
   owner/timing instructions and allow one local repair through the same strict
   validator. Unsupported extracts still fail without replacing the summary.
5. A routine labeled UTC clock values as local. Add explicit local start/end
   fields and timezone rules to calendar and brief context.
6. Knowledge selection now holds scoped access while creating the read-only
   bookmark and gives a useful source error. Answers retain source receipts.
7. Paused connections no longer advertise fresh provider tools to the model;
   cached briefs and local tools remain available. Clarify privacy wording and
   synthetic-workspace storage labels.
8. Disable the contextual-panel action when chat already fills the workspace,
   improve mail-toolbar layout, and surface bounded Cua refusal reasons.

The calendar, undo, summary, local-time, draft, citation and persistence fixes
were rechecked in the rebuilt native app. Focused regression tests cover the
behavioral changes.

## Automated and bundle verification

Final regression: **373 tests executed, 365 passing, eight opt-in skips, zero
failures** (252 core, 121 app). The live Splash setup/tool check and installed
Cua MCP catalog check had also passed separately. The native flows above used
real model inference beyond those opt-in checks.

Debug bundling and native relaunch passed. Release bundling, strict ad hoc
signature verification, plist validation and whitespace checks passed. The
release executable rejected the fixture argument with status 64 without opening
personal state. Puddle was quit before replacing the bundle; the final release
artifact is `build/Puddle.app`. The fixture app was left closed.

## Remaining acceptance

These are deliberately pending, not successful end-to-end results:

- Live Cua browser/model errands until the user grants/verifies driver access.
- Live microphone/app-audio transcription, speech assets, system dictation and
  third-party editor insertion, per the user's controls-only choice.
- Production Keychain ACL/authentication after rebuild and macOS app-lock
  unlock; authentication remains manual. Early ad hoc rebuilds caused a
  Keychain access stall, so the repeatable fixture uses synthetic file secrets.
- Fresh-Mac Splash/Homebrew install, large model download, owned-server
  lifecycle, offline/hardware matrix and permission/revocation variants.
- Real provider sends/organization/unsubscribe/event changes, OAuth consent,
  tenant differences, delivery, multi-account races and exhaustive attachment
  formats. Fixture success does not establish these live behaviors.
- Hosted signed update feed, Developer ID signing/notarization, clean-Mac
  install/upgrade/rollback, actual notification delivery and login launch.

The full variant checklist remains in [testing.md](testing.md).

## Reproduce the isolated native run

Quit Puddle before replacing its app bundle. Keep the personal app closed while
using a fixture build with the same bundle identifier.

```sh
PUDDLE_BUILD_CONFIGURATION=debug sh scripts/build.sh
open -n "$PWD/build/Puddle.app" --args \
  --ui-test-workspace /tmp/puddle-ui-acceptance/workspace
```

Choose a new disposable directory to start fresh, or the same directory to test
persistence. Connect an existing loopback Splash server through guided setup.
The banner must say **UI test workspace**. Do not enter real tokens, account
credentials or personal documents. The workspace remains encrypted, but its
synthetic test key is intentionally in `fixture-secrets.json` (mode 600) so ad
hoc signatures cannot interrupt the test with Keychain ACL prompts. The
directory is mode 700. The journal records provider method/host/path only.
Synthetic provider-side event/label state resets on launch; workspace snapshots,
drafts, receipts and routine history persist.

To return to the normal build, quit the fixture app and run `sh scripts/build.sh`.
`--ui-test-workspace` is debug-only; release refuses it with exit status 64.
Never use this harness to claim real-provider or production credential testing.
