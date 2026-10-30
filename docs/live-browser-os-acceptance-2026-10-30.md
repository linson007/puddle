# Live browser and OS acceptance — 30 October 2026

**Public release remains blocked.** The retry now verifies microphone recognition,
review, save and reopen. Selected-app recognition and isolation remain unverified:
the latest diagnostics identified a different source from the intended test app.
The browser write gates also remain open. This pass fixed reproducible application
issues, but also confirmed that CuaDriver 0.38 cannot enforce two required
browser-write safeguards. Browser writes have not silently been removed; the
release scope decision is awaiting the owner.

## Environment and isolation

macOS 26.6, Apple M5 Pro, 48 GB; CuaDriver 0.38.0; local Splash with
`mlx-community/Qwen3.6-35B-A3B-4bit`. Native testing used separately identified
debug bundles and synthetic workspaces. The personal Puddle process was left
alone. No real credentials, provider sends, purchases or bookings were used.
Fixture credentials/keys are files, so this does not certify production Keychain.

The driver initially refused startup and reported unknown permission status.
Its doctor identified two stale LaunchServices registrations. The official
`doctor --fix` unregistered those copies without deleting files. An idle daemon
with zero sessions was restarted through the official permission setup. The
owner completed the grants. The daemon then reported Accessibility and Screen
Recording true, with an explicit direct-capture verification. Standard permission
mode was retained; no unrestricted mode, TCC reset or permission bypass was used.

## Issues fixed

1. **Browser startup lost its opaque tab capability.** Native binding mints new
   target/tab IDs each time. Puddle combined a new binding with an earlier tab
   ID. Initial capture now uses the exact binding that just succeeded. A bounded
   read-only retry handles Chrome's window appearing before its CDP target.
2. **Tab inventory could become stale.** An empty-tab read now refreshes the
   dedicated window's inventory and adopts its matching active-tab capability.
   Explicit tab IDs must come from the latest inventory. Post-action inspection
   stays on the action's tab. No title/URL-based identity guessing is used.
3. **Invalid targets produced meaningless approval.** Unknown refs and refs
   without the requested action are rejected before approval or dispatch intent.
   Errands include exact refs, supported actions and the page address. The review
   shows the resolved label and exact typed text.
4. **Long browser context crashed native chat layout.** A live errand containing
   one long JSON line triggered an AppKit update-constraints exception. Errands
   now use bounded, readable reference lines. User messages render literally with
   constrained horizontal sizing. Reopening the saved triggering conversation
   and completing a new real-model browser turn passed. Arbitrary assistant
   output/layout combinations are not certified by this one reproduction.
5. **Speech downloads ignored external pause.** The installation control and
   store entry point honor pause, lock and private sessions. Pausing cancels a
   running installation; a late completion cannot restore it. Installed languages
   remain usable offline. Native UI shows the disabled download and explanation.

## Observed acceptance

| Check | Evidence / limit |
| --- | --- |
| Dedicated browser | Real startup, blank session, loopback navigation, repeated reads, exact current refs and displayed URL passed. Restart did not reconnect automatically; saved errands returned paused. |
| New-tab link | The synthetic click did not create the fixture's `target=_blank` tab. No trusted-input fallback was used. The attempted live new-tab assertion failed and is retained as diagnostic evidence; tab inventory has fixture regressions, while native multi-tab acceptance remains pending. |
| Normal reviewed input | Real Splash selected the correct ref. Review showed `Test note`, the loopback URL and exact text. Allow produced the single expected `typed:puddle local acceptance` event on the disposable server. An earlier Decline produced no input event. |
| Changed/sensitive targets | **Failed security acceptance:** synthetic-only typing into `input type=password` succeeded. A button relabeled after observation was still clicked; the server recorded `Changed local action`. These were diagnostic reproductions, not passing guardrail assertions. |
| Native chat stability | Retained crash report identifies `NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints`. The rebuilt app reopened the same saved long message and completed a fresh streamed model turn and approved input without repeating that abort. |
| App unlock | The owner completed macOS authentication in Puddle Security Review. The locked Settings view returned to Privacy settings afterward. This proves that fixture's unlock flow, not shipped identity/Keychain ACLs. |
| Speech setup | Missing-language error was useful; explicit Apple speech-language setup returned ready. No microphone was requested until Start transcription. |
| Audio cancellation | Microphone start waited for consent and was canceled. App-only audio reached the application's sharing-picker waiting state and was canceled. Controls returned to idle; no captured transcript was produced. OS picker contents, audio recognition and selected-app isolation remain unverified. |
| Pause | Native pause ended the fixture browser session and disabled speech-language installation. Regression fixtures also prove in-flight install cancellation, ignored late completion and preservation of local capture with an installed language. |

## Owner involvement / remaining gates

- **Choose browser scope for v1.** Recommended: reading/navigation only until the
  driver can atomically bind reviewed target state and enforce sensitive-field
  restrictions. Keeping clicking/typing requires holding the public release.
  Driver refs currently expire on navigation/new snapshots, not every DOM change.
  Its semantic response labels password, card and OTP inputs as editable
  plaintext, without reliable sensitivity metadata. A host-side reread/remap has
  a check-to-action race and is not a complete fix. Prompt instructions and exact
  text approval do not close this gap.
- **Finish supervised app-audio acceptance.** Microphone recognition, review,
  save and reopen passed in the retry below. Select a disposable audio
  application's output and verify other applications are excluded. Denial,
  revocation, sleep/wake and unplugging a
  device still need native checks. System dictation also needs Accessibility,
  original/changed editor focus and secure-field checks.
- **Verify the shipped identity and hardware.** Production Keychain ACLs, clean
  installation, app-background lock with a physical foreground switch,
  notification delivery while quit, login launch and actual Developer ID
  authentication behavior remain pending. A synthetic key file or an ad hoc
  fixture cannot close these gates.
- **Complete the other release gates** in
  [security-testing-2026-10-30.md](security-testing-2026-10-30.md): signing,
  notarization/stapling, signed update hosting/tamper checks, clean-Mac
  install/upgrade/rollback, real public OAuth/provider accounts, supported
  hardware/model/accessibility matrix and filesystem/recovery drills.

## Repeat the live browser check

`scripts/browser-acceptance.py` serves only on IPv4 loopback, on an ephemeral port.
It contains synthetic form fields, links and local event recording. Start it in
one terminal, then use its printed address below. It never contacts providers.

```sh
python3 scripts/browser-acceptance.py

PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver \
PUDDLE_CUA_LIVE=1 PUDDLE_CUA_LIVE_URL=http://127.0.0.1:PORT/ \
sh scripts/swift.sh test --filter CuaBrowserTests
```

`PUDDLE_CUA_LIVE=1` adds a real dedicated-session/read check to the installed-driver
catalog test. Supplying the local fixture URL additionally verifies navigation.
This opt-in uses a temporary driver-owned profile and
closes its connection on success or failure. It does not certify the failed
sensitive-field/changed-target cases above.

## Final verification

**459 debug tests and 457 release tests passed, with zero failures or skips**
(326 core, 133 debug app / 131 release app). Eight regression cases were added;
the existing installed-driver test also gained an opt-in real session/read/
navigation check. The original startup and native layout failures were captured
before corrections; the sensitive-field/changed-target diagnostics remain open.

```sh
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver PUDDLE_CUA_LIVE=1 PUDDLE_CUA_LIVE_URL=http://127.0.0.1:PORT/ PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver PUDDLE_CUA_LIVE=1 PUDDLE_CUA_LIVE_URL=http://127.0.0.1:PORT/ PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test -c release
sh scripts/build.sh
codesign --verify --deep --strict build/Puddle.app
```

Release bundling, strict local signature verification, plist/entitlement lint,
shell syntax and whitespace checks passed. Source checksums match the final
tested sources. The normal release executable rejected fixture mode with exit
64 and created no workspace. It is still an ad hoc local build, not a notarized
public artifact. Both test apps were closed, capture was inactive and the driver
reported zero sessions. The disposable loopback server was stopped afterward.

Implementation changes are in `CuaBrowser.swift`, `Agent.swift`,
`BrowserErrandsView.swift`, the browser handler in `PuddleStore.swift`,
`AssistantWindow.swift`, `PuddleStore+Meetings.swift`, `MeetingCaptureView.swift`
and `PrivacySettingsView.swift`. Regressions are in `CuaBrowserTests.swift`,
`BrowserWorkflowTests.swift` and `MeetingCaptureTests.swift`.

Overall outcome: **blocked for public release**, with the application corrections
above verified. The driver accepts the original sensitive/changed-target triggers;
no partial reread check is presented as a fix for them. Canonical results from the
earlier sealed security scan are unchanged. Live evidence, the crash report,
candidate diff, source hashes and test/build logs are retained in the separate
live-browser/OS artifact collection.

## Retry after OS permissions were available

- Microphone capture started without a pending permission wait. The owner spoke
  the agreed phrase; Puddle recognized “Padil acceptance test, the blue notebook
  is on the table.” Capture stopped, the text was explicitly reviewed/applied
  and saved, and the same text was present after restarting the app. The brand
  substitution is recognition-quality evidence, not an exact transcription pass.
- The owner reported selecting **Puddle Test Audio A** in the native picker and confirmed
  hearing its generated “orange folder” phrase. Puddle's app-only stream produced
  only a provisional period, including after finalization. A repeated selected-app
  run did the same. Audio B was a separate generated “silver compass” canary;
  absence of both phrases does not establish isolation. No captured raw audio was saved.
- The same generated audio file passes through `AnalyzerAudioTrack` and
  `AnalyzerAudioSink` into the installed on-device recognizer. New checks also
  verify sample values survive CMSampleBuffer invalidation and 48 kHz resampling.
  This narrows the live failure; it does not close selected-app capture acceptance.
- Punctuation-only recognition output is now treated as silence, so a lone
  period cannot create a transcript/recovery or block a later real passage.
  Unicode speech and symbols remain supported.
- Reopening the earlier unmarked acceptance copy without CLI arguments used the
  ordinary startup path. Marked debug acceptance bundles now carry their
  disposable workspace path in `PuddleUITestWorkspace`; an icon launch preserves
  synthetic storage and the fixture banner. Invalid marker paths fail closed.
  Release builds reject either fixture arguments or this marker. Native no-argument
  relaunch verified the synthetic banner and saved microphone note.
- The ordinary short-voice flow reported **Siri and Dictation are disabled** on
  this Mac. Global OS settings were left unchanged. Meeting transcription uses a
  different on-device API and the microphone case above passed.
- The installed driver's update check still reports **0.38.0 as latest stable**.
  Its previously reproduced sensitive-field/changed-target browser failures
  remain open; permission grants are not a remediation for them.

The diagnostic build records only selected application identities, audio buffer
counts/formats and peak signal values in its synthetic workspace, capped at 1 MiB.
These diagnostics are debug-fixture-only and do not store audio samples. macOS
unified logging did not expose the initial diagnostic messages, so the later
attempt uses this bounded local file. A debugger attach did not complete and was
abandoned without granting broader access.

The first file-diagnostic attempt remained at the macOS app-selection picker. It was
canceled before capture started; consequently no selected-app/signal trace was
collected from that attempt. Capture is idle, the synthetic players are stopped
and closed, and the marked acceptance app remains available with the saved
microphone note. The next necessary step is a supervised recapture with Audio A
selected, followed by controlled A/B playback and inspection of
`audio-diagnostics.log`. The app-audio failure has not been presented as fixed.

Retry verification: **464 debug / 460 release tests passed**, with zero failures
or skips (327 core, 137 debug app / 133 release app). Five cases were added in the
retry; two exercise the debug-only fixture launcher. Full suites enabled live
Splash, the installed-driver catalog, load tests and the generated-audio
recognition check. They did not substitute file recognition for live app-audio
acceptance.

To reproduce the optional recognizer check, generate a synthetic file, then set
`PUDDLE_LIVE_AUDIO_FILE` for both full-suite configurations:

```sh
say -o /tmp/puddle-audio-fixture.aiff "Selected audio acceptance. The orange folder is ready."
PUDDLE_LIVE_AUDIO_FILE=/tmp/puddle-audio-fixture.aiff sh scripts/swift.sh test --filter MeetingAudioPipelineTests
```

The final normal release bundle was rebuilt and passed strict local signature,
plist and whitespace checks. Both the fixture CLI flag and a marker-only
release-bundle launch exited 64 without creating a workspace. Native icon launch
of the marked **debug** bundle showed the synthetic banner. Test/build logs,
the retry source delta, generated fixture source/audio and verification records
are retained separately from the earlier sealed security scan.

Retry changes: `UITestWorkspace.swift` and `PuddleApp.swift` enforce marked
fixture startup; `MeetingTranscript.swift` rejects silence punctuation;
`MeetingAudioCapture.swift` and `MeetingStreamOutput.swift` provide the bounded
debug-fixture signal diagnostics. New cases are in `UITestWorkspaceTests.swift`,
`MeetingTranscriptTests.swift` and `MeetingAudioPipelineTests.swift`.

## Follow-up with selected-source diagnostics

After the delayed picker confirmation, a fresh start reported an installed
speech model as unavailable. The production preflight now explicitly reserves
the resolved locale before checking asset status. Reservation does not initiate
an asset download; the explicit installation control and external-pause policy
remain in force. Apple's [asset reservation API](https://developer.apple.com/documentation/speech/assetinventory/reserve(locale:))
tracks an app's reservations. The opt-in generated-audio regression now calls
the production preflight rather than reserving the locale only in test code.
The rebuilt app reached the sharing picker with external connections paused.

The first collected trace identified **ChatGPT (`com.openai.codex`)**, rather than
Audio A, and thousands of 48 kHz float PCM buffers with peak amplitude **0.0**.
Capture was stopped when this mismatch was discovered. The previous intended-A
runs did not record selected-app identities, so their silent result cannot prove
that Audio A itself fails capture. They also cannot prove isolation.

Puddle now shows the selected application's name while capture is active, and
refuses a filter that identifies zero or multiple applications. A new controller
regression checks that this source label clears on stop/cancel and cannot be
restored by a late start. Another checks single-app selection and the separate
microphone label. Native UI verified the new label: a subsequent selection again
displayed **Source: ChatGPT** and was stopped without a transcript. No captured
raw audio was retained. This closes a source-visibility gap, not the live
Audio A/B acceptance gate; the cause of the selection mismatch is unresolved.

Final follow-up verification: **466 debug / 462 release tests passed**, zero
failures or skips (327 core, 139 debug app / 135 release app). Live Splash,
installed-driver catalog, load tests and the generated-audio recognizer check
were enabled. The latter now exercises the production offline preflight. Two
source-selection/controller regressions were added. This follow-up did not rerun
the earlier real-browser security diagnostics; their open results remain valid.

The final release bundle was rebuilt, its strict local signature and plists
verified, and all tested source hashes matched. Release launches with fixture
arguments or a fixture marker again exited 64 without creating a workspace.
It remains an ad hoc local build. Capture is stopped, both synthetic audio
players are closed, and the marked acceptance app is idle with its saved
microphone note. Public release remains blocked by confirmed-source Audio A/B
acceptance, browser-write safeguards and the remaining distribution/provider/OS
gates listed above. Another picker attempt needs supervised selection and
verification of **Source: Puddle Test Audio A** before playback; no capture is
left active for that next attempt.
