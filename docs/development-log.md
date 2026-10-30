# Voice and meetings development log

Work began on 29 October 2026 at 05:47 UTC, with a five-hour work window ending
at 10:47 UTC. Features are implemented and tested in sequence. The source before
this work is saved under `build/checkpoints/` without account credentials.

| Order | Feature | Status | Verification |
| --- | --- | --- | --- |
| 1 | Read replies aloud and stop playback | Implemented | 104 tests, five live checks skipped, no failures; release build passed |
| 2 | On-device microphone dictation and voice chat controls | Implemented | 109 tests, five live checks skipped, no failures; strict concurrency and release build passed |
| 3 | Meeting links from Calendar and manual join links | Implemented | 116 tests, five live checks skipped, no failures; release build passed |
| 4 | Persistent meeting notes | Implemented | 123 tests, five live checks skipped, no failures; release build passed |
| 4b | Transcript import with subtitle support | Implemented | 131 tests, five live checks skipped, no failures; strict concurrency and release builds passed |
| 5 | Local summaries, decisions, and action items | Implemented | 141 tests, five live checks skipped, no failures; strict concurrency and release builds passed |
| 5b | Review meeting actions before creating tasks | Implemented | 145 tests, five live checks skipped, no failures; release build passed |
| 6 | Meeting transcription with explicit capture controls | Not implemented; API research completed | Hardware and permissions remain untested |
| 7 | Export and meeting search | Not implemented | Pending |

The baseline is 98 tests: 93 passed and five optional live-model tests skipped.
Real meeting attendance and microphone capture are not started during unattended
development. Hardware, permissions, and provider behavior require interactive
verification in the built app.

Final automated verification: 145 tests total, 140 passed, five optional
live-model checks skipped, and no failures. Release build, strict concurrency
build, and bundle signature verification passed. The isolated demo UI verified
meeting summary layout, action review, and adding an undated task with its
source quote. The updated release app was restarted and its History and Meetings
screens verified; existing conversations remained available. No real meeting was joined, microphone activated, or speech played
during this work.

At approximately 06:40 UTC, launching the isolated native review app stalled.
The computer-use tool returned at 11:59 UTC, despite a requested 120-second
timeout. This consumed the remaining work window; no feature development took
place during that wait. Final delivery checks were completed afterward. Live
meeting audio capture, automatic attendance, export, and meeting search remain
future work. Existing joining support opens the provider's join screen for the
user to complete joining.

The next audio implementation should use Apple's on-device SpeechAnalyzer on
macOS 26 or later for long recordings. The older SFSpeechRecognizer has a
documented one-minute audio limit and is used only for bounded chat dictation.
Research references: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
and [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer).

## Continued development

Work resumed on 29 October 2026 at 12:12 UTC. The feature catalog in
`docs/features.md` remains the record of existing capabilities; the earlier work
and verification counts above are retained as history.

| Order | Feature | Status | Verification |
| --- | --- | --- | --- |
| 6a | Long-form on-device microphone transcription | Implemented | 160 tests, five optional live checks skipped, no failures; strict concurrency build checked |
| 6b | Audio from a selected meeting app, with optional microphone | Implemented | 163 tests, five optional live checks skipped, no failures; strict concurrency and release builds passed; hardware checks pending |
| 7a | Search meeting notes and transcripts | Implemented | 167 tests, five optional live checks skipped, no failures; draft and cancellation tests passed |
| 7b | Export meeting notes and transcripts | Implemented | 172 tests, five optional live checks skipped, no failures; release build passed |
| 8 | Local Google Meet browser attendance assistant | Implemented, experimental | Final suite: 187 tests, five optional live checks skipped, no failures; strict concurrency and release builds passed |

Audio tests use generated PCM buffers and injected capture sessions. Real audio
capture and OS permissions still need an interactive test in the built app.

The user selected Google Meet and then chose a local browser attendance
assistant after the official API availability check. Google's Meet Media API
is discontinued and will shut down on 15 January 2027, so it is not the basis of
this integration. Chrome uses a dedicated owner-only profile and a random
loopback control port; camera and microphone are blocked before navigation.
Actual admission, browser sign-in, speech downloads, and OS permission prompts
were not exercised. The computer-use service failed to initialize during this
continuation. Feature documentation preserves the earlier capabilities and
records these manual verification limits.

Current follow-up work: scheduled attendance, Zoom/Teams/Webex automation,
per-person speaker identification, raw audio export, JSON re-import, and browser
session recovery after an app crash. Graceful quitting attempts to close the
managed tab and requires acknowledgement if closing could not be verified.

Final verification: 182 tests passed and five optional live-model tests skipped;
no failures or compiler warnings. Native app connection was retried and again
failed to initialize. The running app was not restarted through another UI
automation mechanism. Quit and reopen the release bundle to use these changes.

## Executive assistant product work

The product direction now targets a production local assistant for a CXO and
other individual users. [The production roadmap](production-roadmap.md)
records the complete feature scope, implementation sequence, acceptance
criteria and outstanding public release gates.

The following capabilities were implemented in sequence on 29 October 2026:

1. Optional persistent work profile with role, organization and objectives,
   available as reference context to the local assistant.
2. Today as the default workspace, with daily priorities, overdue/due-today and
   waiting-on commitments, calendar overlaps, flagged unread mail and source
   freshness. Calendar reads include the whole current local day.
3. Commitment metadata, waiting-owner validation, search/filters, daily focus
   limits, source preservation, explicit deletion and draft retention on errors.
4. Source-based meeting preparation from calendar events and saved notes, with
   current decisions/questions and open source-linked actions. Meeting actions
   can retain a reviewed owner and waiting status.
5. A read-only executive briefing tool, scope/count limits and conversation
   entry points for day planning and end-of-day review.
6. Portable workspace export, corruption checks, restore preview and an atomic,
   idempotent merge preserving current work. Account caches and stored credentials
   are excluded. Exported files are explicitly unencrypted.

Schema 4 adds defaulted task fields, work context and calendar refresh time.
Legacy schema-3 tasks retain identity, completion, due dates and provenance.
The automated suite reports 210 tests: 205 passed, five optional live-model
tests skipped and no failures. A complete strict-concurrency build with warnings
as errors passed. A release app build and signature verification passed.

Native visual review was attempted in an isolated, credential-free demo bundle.
The computer-use service returned a ScreenCaptureKit stream-start failure after
approximately ten minutes despite a twenty-second tool timeout. No visual
acceptance result, real-model inference, real-account action, meeting admission,
microphone or system-audio validation is claimed for this work. The manual
acceptance steps and the remaining production release gates remain explicit.

## Multiple role profiles in a shared workspace

The user chose a shared personal workspace for CXO, developer and other role
profiles. The initial implementation included five presets: Personal, CXO,
Developer, Product Manager and Researcher. Custom profiles, editing, duplication
and removal of
inactive profiles are supported. Each retains its own work context and
additional guidance; all workspace data, connections and general preferences
remain shared. The sidebar and menu bar switch profiles; Settings and Today
open the profile manager.

Role-specific guidance, chat starters and daily planning prompts now replace
the formerly universal executive framing. New replies retain the producing
profile's display name. Changing the active profile or its guidance cancels
unfinished inference and pending approvals without archiving the current chat
or undoing completed work. Role selection grants no additional tools or access.

Schema 5 migrates the earlier work profile into the role library, preserving
saved fields and workspace data. Portable backups include profiles; schema-4
single-profile backups remain readable. Restores preserve edited profiles and
count name/limit conflicts. Profile mutations use atomic persistence and leave
failed edits open for retry.

Automated verification: 226 tests, 221 passed and five optional live-model tests
skipped, with no failures. Strict concurrency compilation with warnings as
errors passed. Native visual acceptance and live-model quality remain outside
these fixture results; the earlier ScreenCaptureKit failure remains recorded.

## Project-aware Developer assistant

The Developer profile was analyzed as a development workflow rather than a
prompt preset. [The implementation plan](developer-assistant-plan.md) records
the capability gaps, priorities, implemented flows and acceptance criteria for
reviewed patch application and approved test execution as subsequent work.

Implemented explicit project folder connections, editable project context,
scoped source inventory/search/numbered reads, local Git status and captured
working/staged text comparisons, source tool receipts, and persistent debugging,
implementation and review sessions. Source tools are available to the Developer
role only when a project is selected. Project source is read-only; the model
cannot execute project code or apply changes. Saved sessions distinguish user
verification notes from actual test-run evidence.

Source reads use directory-relative descriptors with no-follow opens, bounded
traversal and UTF-8 output, private/generated path rules, credential heuristics,
and cancellation. Git uses fixed arguments with helpers/hooks/fsmonitor disabled,
no lazy object fetches or allowed remote protocols, literal paths and bounded
timeouts/output. Text diffs compare private captured snapshots and exclude Git
symlink/submodule blobs. Tests include a missing partial-clone object configured
with a remote helper, confirming that helper does not execute.

Schema 6 adds project connections and development sessions. Portable backups
include session evidence and former project names but exclude bookmarks/folder
grants. Removing a connection preserves session notes and drafts; stale editors,
failed persistence, switched projects and late inspection results are tested.

Verification: 251 tests total, 245 passed, six optional live tests skipped, no
failures. The separate synthetic-source local-model test passed against Splash:
it inspected a temporary file and reported an unpredictable source value with
its filename. The first attempt was blocked by the command sandbox's loopback
policy; the authorized rerun passed. Strict concurrency with warnings as errors,
release build and signature verification passed.

Native review reached the previously running app, but computer-use timed out
while checking its note selector. A normal quit request to load the new build
returned “User cancelled”; the existing app was left running. No force quit or
second instance against the live workspace was started. The new Developer screen
and folder picker therefore still need an interactive acceptance pass after the
user quits/reopens the updated app. Live project access was not granted or
exercised; automated tests use synthetic folders and temporary repositories.

## Connected Developer work: GitHub, Jira and Confluence

The user prioritized connected work over additional development-session
features, and selected GitHub.com plus Atlassian Cloud. Implemented GitHub
fine-grained-token setup with repository/issue/PR access verification, and
shared Jira/Confluence browser sign-in through Atlassian's official MCP v2
public-client OAuth flow. Discovery is issuer-bound, registration uses no
client secret, PKCE/state and the temporary loopback callback are validated,
and read/search scopes are the only requested product permissions.

Connections and Developer now expose cross-source search, scoped result lists,
source links, fetched timestamps, readable details and Ask Puddle handoff.
GitHub PRs add patch excerpts and reported check runs. Two assistant tools
search/read this context; receipts retain links and report partial provider
failures. Results and errors are bounded. No provider write operation is
available; an explicit remote tool allowlist is independent of catalog content.

Credentials and connection configuration use Keychain only, without a workspace
schema change or portable export. Refresh rotation is coalesced; disconnect
invalidates stale refresh/sign-in/verification writes. Built-in HTTP reads cap
response memory and terminate SSE on the matching result; expired MCP sessions
are initialized again for one read retry. Failed credential replacement keeps
the earlier connection. Demo mode does not expose work-account tools.

Verification: 270 automated tests total, 264 passed, six optional live tests
skipped, no failures. Nineteen new connector/core-chat workflow tests cover
scope/permission checks, hostile metadata/redirects, PKCE/state, JSON/SSE,
session expiry, token rotation, stale persistence, source receipts, provider
failures and secret exclusion. Offscreen native hosting renders of the empty
and connected/search-result screens were inspected at an 800-point width;
the source picker label was adjusted to avoid truncating its selection.
Strict concurrency compilation with warnings as errors, the release bundle
build and ad hoc signature verification passed.

Public Atlassian authorization metadata and current primary provider docs were
checked. No real user GitHub/Atlassian account was accessed. Interactive browser
consent, organization policy, live MCP response compatibility, credential-form
accessibility and supported-model quality remain acceptance work; fixture
success does not establish public production readiness. The existing running
app was left untouched after the earlier cancelled quit request. Setup and
data boundaries are documented in [work-connectors.md](work-connectors.md).

## GitHub repository URL validation fix

The user reported the combined token/repository validation error while entering
a correct GitHub repository URL. The form accepted only `owner/repository` and
rejected URLs before making any GitHub request. A regression test reproduced the
exact error with `https://github.com/owner/repository`.

The form and connector now share repository parsing: HTTPS GitHub root URLs,
trailing slashes, HTTPS `.git` clone URLs, and plain names normalize to lowercase
`owner/repository`. Newline/comma-separated lists deduplicate before the ten-repo
limit. Query/fragment data is discarded; authenticated requests still target
the fixed GitHub API host. Credentials in URLs, unexpected hosts/ports, decoded
control characters, traversal and nested issue/branch/file URLs are rejected
before network access, without repeating pasted values in error messages.

The form previews the normalized scope, labels accepted formats, and clears
stale errors on editing. Missing/invalid tokens, missing repositories, invalid
entries and the repository limit now have distinct messages. Existing saved
connections survive rejected replacements. Regression coverage exercises the
same raw text submission used by the form, expected API paths, canonical scope
after restart, and secret-free validation errors. All 25 connector workflow
tests passed; the full suite also passed. Real-account authentication was not
used for this input-validation fix.
The final full run passed 278 tests with six optional live tests skipped.
Strict concurrency compilation with warnings as errors, release bundling and
ad hoc signature verification passed; the rebuilt executable contains the new
validation messages. The running app was not interrupted to replace its form.

## Calendar and Mail navigation

Added dedicated Calendar and Mail destinations under Work. Main contains Today
and Puddle; Workspace contains Developer, History and Memory. The navigation
scrolls at shorter window heights while Connections and Settings stay pinned.
The menu bar and Today also link to the new destinations. Connections retains
Google account management instead of embedded mail/calendar content previews.

Mail has local cache search, All/Unread/Important filters, message selection and
a reading pane, summaries, source links, Ask Puddle and review-before-save local
task drafts. Reading does not change Gmail read status. Email reference turns
and retries disable personal-memory extraction and the memory-save tool; demo
responses do not interpret the email body as demo commands.

Calendar offers Today/Next 7 days, cache search, daily agenda sections and an
event detail pane with joining, preparation, local notes and source links.
All-day exclusive ends, overnight events and local daylight-saving boundaries
are handled explicitly. Undated events stay visible. Both destinations expose
connection setup, independent refresh progress, timestamps and bounded-cache
notices. Google access remains read-only; no new permissions are requested.

Verification: make test completed 284 tests: 278 passed, six optional live-model
checks skipped, no failures. Eight new tests cover cached filtering/search,
agenda date boundaries, draft provenance, demo behavior and email-reference
learning exclusion on retries. Offscreen native hosting renders of both views,
empty/disconnected states and the sidebar were inspected at normal and minimum
window sizes (1180 × 820 and 960 × 640; sidebar at 225 points). The disconnected
layout was adjusted to keep its heading anchored at the top. The release app
bundle built successfully. Real Google consent, live-account refresh and
interactive keyboard/VoiceOver acceptance remain covered by docs/testing.md.

## Profile-aware Developer navigation

The Developer sidebar entry was included in a fixed navigation list for every
role. It now appears only when the active profile uses the Developer approach,
including custom-named Developer profiles. The menu bar follows the same rule.
Switching from the Developer page to another role opens Today; shared pages
keep their selection. Creating a new active profile or editing its approach
also updates navigation, after persistence succeeds. Saved project connections,
sessions and unsaved development notes remain available when switching back.

Verification: all 288 tests completed with 282 passing, six optional live-model
checks skipped and no failures. Four new regression tests cover role visibility,
navigation fallback, profile creation/editing, failed writes and draft retention.
The release app rebuilt and passed ad hoc signature verification. An isolated
native demo confirmed Developer appears on selecting Developer and disappears
on switching from its page to CXO, with Today selected. The running personal
workspace was left open; quit and reopen Puddle to load the rebuilt executable.

## Cua browser support

Added Browser to the shared sidebar and menu bar, backed by Cua Driver's typed
browser tools over one persistent stdio MCP connection. The local Splash model
can read semantic page text and current refs, navigate HTTP/HTTPS pages, click,
type and scroll. The driver launches an isolated session-owned Chrome or Edge
profile; Puddle does not attach to personal browser profiles or expose native
desktop input, arbitrary scripts, file transfer or screenshot reasoning.

Browser has explicit start/show/stop controls and an app-wide connected banner.
Assistant mutations are reviewed in chat, with current element labels and exact
typing text. Intent is persisted before dispatch; failed saves cannot operate
the browser. Completed, pending and uncertain action receipts suppress repeat
mutations on a chat retry. Driver output is bounded and compacted for local
text models. Stop/cancellation and stale sessions reject late results. Page
snapshots, refs and connection authority remain in memory; only the chosen
executable path is retained locally.

Verification: the full suite completed 301 tests, with 294 passing and seven
optional checks skipped. Thirteen new tests cover MCP transport/framing,
capability discovery, isolated profiles, scoped tabs/refs, read-after-action,
timeouts, cancellation, approval, failed saves, retry behavior and demo isolation.
Separately, the real Cua Driver 0.38.0 MCP handshake and browser tool catalog
check passed. The official release archive checksum and installed developer
signature were verified; CuaDriver.app is installed at /Applications/CuaDriver.app
with the command at ~/.local/bin/cua-driver. Native demo interaction verified
the Browser destination and that demo cannot operate a real browser. Release
bundling succeeded. The driver's permission status was unknown; granting and
verifying macOS Accessibility and Screen Recording, then running live browser
tasks with Splash, remain acceptance work. The personal Puddle instance was
left running. Setup and manual checks are in [browser-use.md](browser-use.md).

## 2026-10-30 — Underdog comparison implementation

Implemented guided Splash setup first, then shared exact-content action review,
mail/calendar workflows, daily interaction, meeting companion/recovery, privacy,
system dictation, Cua errands/routines, account breadth, knowledge/work context
and release tooling. Existing Cua/developer/work-source changes were retained;
no commit or external message/event/release was produced. Full scope and limits
are in [improvement-implementation.md](improvement-implementation.md).

The final regression suite executed 365 tests: 247 core and 118 app tests, with
eight optional tests skipped and zero failures (357 passing). Two skipped checks
were run separately and passed against real local services: Splash chat plus
required-tool verification (synthetic prompts only), and the installed Cua
Driver MCP handshake/browser catalog (no page control). Real-model quality on
other models/hardware and live account/capture flows remain acceptance work.

Release script shell validation, exclusive mode600 signing-key creation with
existing-file preservation, synthetic signed manifest generation, bundle metadata
and plist validation passed using disposable files. Local release app bundling
passed. Public signing/notarization and update-feed publishing were not run.
Native inspection of the isolated Puddle Review app was denied Computer Use
access; that permission was not bypassed. The native acceptance matrix remains
pending in [testing.md](testing.md); owner setup is in [releases.md](releases.md).

Late integration checks corrected selected-provider routine search/brief context,
portfolio backup/search coverage, account-change attachment handling, meeting
series links across title changes, recurrence duplicate/DST/month-end behavior,
and rejection of external responses that outlive a privacy-policy change.
Workspace snapshots are now encrypted by default; legacy plaintext migration
and passphrase backups have fixture coverage. Keep external backups/passphrases
and finish upgrade/rollback acceptance before public distribution.

## 2026-10-30 — Native Cua end-to-end run and fixes

Ran Puddle through Cua, starting with guided Splash hardware inspection, real
reply/required-tool verification and saved connection. Then exercised the
native workflows against isolated synthetic Google/Outlook providers and the
real local Qwen model. The full observed results, environment, reproduction
steps and pending variants are in
[the Cua acceptance report](cua-end-to-end-2026-10-30.md).

Fixed overlapping month-grid identities that hid dates, duplicate calendar
undo, unsupported first-person claims in generated email drafts, strict meeting
extract repair, UTC/local-time confusion in routine output, scoped knowledge
access and persistent source receipts, paused-provider tool availability, and
small toolbar/privacy/error-message issues. Rebuilt and rechecked the affected
native flows. Private-session restoration, task/profile persistence, reviewed
action receipts without replay, floating companion notes, VTT import, routine
history, encrypted backup export/review/merge, and source search passed.
Locking hid both main-window and Settings content; OS unlock was not automated.

Added explicit DEBUG-only `--ui-test-workspace` support. Its provider transport
forwards loopback inference only, stubs fixed provider hosts, rejects other
external API requests, and records only method/host/path. After a normal ad hoc
rebuild caused a Keychain ACL stall in the early fixture, synthetic secrets and
the synthetic encryption key moved to an owner-only fixture file; the UI labels
that difference. Production still uses Keychain. Never enter real credentials
in this harness. The release binary was tested to refuse the flag with exit 64.

Final regression: **373 tests, 365 passing, eight optional skips, zero failures**
(252 core and 121 app). Log: `/tmp/puddle-cua-regression-final.log`.
Release build completed; strict ad hoc codesign verification, Info.plist lint
and `git diff --check` passed. Build log:
`/tmp/puddle-cua-release-build.log`. Final bundle: `build/Puddle.app`.
The test app was quit before the final build and left closed. No commit,
external provider mutation, permission grant, or release publication occurred.

The user limited live accounts to read/draft/review, skipped live audio, and
deferred Cua Driver permissions. The installed driver refused browser startup
with `request_refused` and unknown permission status, so live errands remain
pending. Actual sends/event changes/unsubscribe were only synthetic fixtures.
Keychain/LA authentication, fresh-Mac model installation, real provider consent,
live capture, notification delivery, login launch and publisher signing/feed
acceptance remain as documented; fixture success does not substitute for them.

## 2026-10-30 — Meet command rejection and cleanup follow-up

The reported generic Chrome rejection was confirmed in the running Puddle UI.
The old code discarded the CDP command, code and reason, so that earlier
failure's exact cause cannot be recovered from the displayed message. It was
not evidence that Chrome needed an update. Protocol errors now retain a bounded
reason plus command/code, without including request arguments; only a missing
method recommends updating Chrome.

Reworked Meet cleanup to verify that the owned target is absent from a fresh
target list. An already-closed tab can be verified despite a close-command
error; the deprecated success field alone is no longer treated as proof.
See the [official Chrome protocol schema](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json).
Concurrent leave requests share cleanup. Cancellation during tab creation waits
for its identity, then closes it without navigating. A lost creation reply or
unavailable/malformed target evidence stays uncertain. Navigation errorText is
reported instead of being silently ignored. Private sessions also stop managed
Meet activity.

Added **Check browser setup** beside Meet attendance. It exercises version,
permission denial, target/session creation, blank-page navigation/evaluation
and verified cleanup without opening a meeting. The store enforces privacy and
storage guards. Diagnostic failure does not masquerade as an active call.

Regression: **382 tests, 374 passing, eight opt-in skips, zero failures**
(259 core, 123 app). New cases cover specific protocol errors, missing close
fields, already-closed targets, delayed/failed closure, malformed/disconnected
evidence, concurrent leave, cancellation/lost replies during creation,
navigation failure and the privacy-guarded blank-page check.
Log: `/tmp/puddle-meet-command-regression.log`.

An isolated native review build was staged, but Computer Use did not approve
access to it. No alternative UI control was used; the live blank-page Chrome
check and real Meet retry remain pending. The review process was stopped.
The user's running Puddle and dedicated Meet tab were left untouched because
attendance remained uncertain. The corrected release is staged separately as
`build/Puddle Meet Fix.app`; close the dedicated Meet tab and quit the old
Puddle before opening that bundle. No real meeting was joined during this fix.
The separate release build completed; strict ad hoc signature verification,
Info.plist validation and `git diff --check` passed. Release log:
`/tmp/puddle-meet-command-release.log`. The primary running bundle was not
replaced, and the dedicated Chrome profile/tabs were not closed by this run.

## 2026-10-30 — Remove prompt-only role presets

Product Manager and Researcher had tailored guidance, conversation starters,
goal labels and planning prompts, with no dedicated tools or workflows. They
have been removed from the built-in profile choices. Personal, CXO and Developer
remain, alongside Custom profiles.

Older workspaces and backups discard empty retired presets and convert edited
or user-created profiles to Custom, preserving IDs, names, work context,
additional guidance and timestamps. A removed active preset selects Personal
or another remaining profile; an otherwise empty library creates Personal.
The remaining preset IDs and shared workspace data are preserved.

Regression: **386 tests, 378 passing, eight opt-in skips, zero failures**
(263 core, 123 app). New cases exercise both retired roles, saved-workspace
migration, edited and user-created profiles, selection fallback, unknown-kind
rejection and repeated legacy-backup restores. Log:
`/tmp/puddle-role-removal.ovovov/tests.log`.

## 2026-10-30 — Remove the CXO preset

CXO also provided only role guidance, goal labels and conversation prompts.
Daily briefs, decisions, commitments and meeting preparation are shared
features, so CXO has been removed as a separate built-in choice. Personal and
Developer remain, alongside Custom. Developer retains its original preset ID.

The existing migration now also removes empty CXO presets and preserves edited
or user-created CXO profiles as Custom. Older single-profile work context loads
under Personal with its saved fields intact. Backup migration fixtures exercise
each of the three retired roles as the saved active profile.

Regression: **386 tests, 378 passing, eight opt-in skips, zero failures**
(263 core, 123 app). Log: `/tmp/puddle-cxo-removal.BiidlH/tests.log`.
