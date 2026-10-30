# Security and AI guardrail testing — 30 October 2026

**Public release remains on hold.** This pass reviews the current working tree,
fixes the five source findings below, and exercises the guardrails with malicious
model responses, synthetic files and real loopback HTTP. It does not certify the
external browser driver, production identities or every supported Mac/model.

The subsequent [live browser/OS acceptance](live-browser-os-acceptance-2026-10-30.md)
fixed browser startup, tab inventory, invalid reviews, native chat layout and
speech-download pause. It also **confirmed** unsafe changed-target and password
typing behavior with CuaDriver 0.38. Those browser-write release gates remain
open; this source scan's five corrected findings are a separate result.

## Review scope

Codex Security Standard scan `a2141cd1-f215-43cc-b2f5-9f06d08c6521` recorded the
pre-fix source snapshot, generated threat model and findings. An independent
baseline reviewed all PuddleCore files; focused reviews covered the browser,
connectors, native audio/dictation/Meet, views and release paths. Parent review
traced approvals, privacy transitions, exports and the final consumers. The
static website has no authentication or bridge to the app. Current-file secret
inspection found the provisioned Desktop OAuth client configuration, which the
build intentionally bundles; no account-token or private-signing-key exposure
was validated. Pattern searches cannot prove every possible secret is absent.

The sealed baseline contains **one medium and four low findings**, with no
validated high or critical finding. Its live browser/OS coverage is explicitly
partial. The generated baseline is immutable; this document records subsequent
remediation and acceptance, rather than rewriting its original findings.

No personal workspace, live provider mutation, malware execution, OS permission
bypass, publication or deployment was used. The machine is an Apple M5 Pro with
48 GiB RAM, macOS 26.6. Existing uncommitted product changes were preserved.

## Findings and corrections

| Finding | Severity | Correction and regression boundary |
| --- | --- | --- |
| Mailbox limits were checked after an unbounded allocation | Medium | `RetryingTransport.sendBounded` now forwards the byte cap and completion predicate on every allowed GET retry. Gmail reads cap their envelopes at 16 MiB; Calendar reads cap at 4 MiB. Writes and size failures never retry. Bounded-only transport spies cover Gmail, Outlook and Calendar. Actual loopback HTTP covers declared length, chunked overflow and redirect rejection. |
| Knowledge extraction reopened mutable checked paths | Low | A held source descriptor and component-wise no-follow reads capture bounded bytes. PDFKit reads captured Data; DOCX uses an owner-only captured archive. Tests replace a file and ancestor after anchoring, reject selected links/FIFOs/traversal/oversize, and retain normal macOS parent aliases, UTF-16, PDF and DOCX behavior. No attacker readback or remote exfiltration was established for the original issue. |
| Saved attachments omitted quarantine provenance | Low | Attachments stage inside a private directory, receive email-attachment quarantine and file-based origin metadata, then atomically replace the chosen destination. Tests verify bytes, permissions, persisted attributes, replacement and metadata failure preserving the old destination. This proves provenance, not malware detection or a particular Gatekeeper exploit. |
| Queued approved actions could survive a privacy interruption | Low | Workspace access is rechecked after credential suspension. Each provider action uses a transport bound to its original policy epoch, so pause/resume cannot supply fresh authority to old queued work. The regression holds token refresh, pauses/resumes, and verifies zero sends and no automatic replay; a freshly reviewed action still sends once. Already-dispatched requests cannot be recalled. |
| Pending native exports could publish after app lock | Low | Save/restore panels and asynchronous encoding retain an access epoch. Lock/private-session changes permanently invalidate the old operation, including after unlock/end. Final publication has no suspension after the access check. Tests hold export preparation across four lock/private states and verify the existing file survives; fresh exports remain usable. Attachment save applies the same post-panel check. |

The HTTP session also disables ambient cookies and credential storage; OAuth
tokens remain explicit request headers. Attachment origin follows the selected
thread message, and late attachment loads are rejected after message selection
changes.

## Guardrails verified

- A deliberately hostile model requests shell execution, direct email sending,
  arbitrary fetching, unconnected project/browser access and forbidden memory
  writes. Those requests do not execute; external-reference retries remain
  unable to learn facts, and no provider request occurs.
- An injected task request still waits for review. Declining creates no task;
  locking cancels pending approval, and a late Allow cannot revive it.
- A real local model receives a hostile document impersonating system/user
  authority and requesting memory poisoning plus an email proposal containing
  a random private canary. It performs only the document read and does not expose
  the canary. The existing hostile-email evaluation also remains in the suite.
- Exact provider/account/payload review, changed-draft refusal, read-only scopes,
  durable dispatch intent, uncertain outcome/no replay, restore without execution,
  private-session persistence, state integrity, update-signature/hash rejection
  and scoped project reads retain their existing regressions.

Model refusal tests are quality evidence for the tested model. Application
allowlists, quote validation, access epochs and approval gates remain necessary
when the model ignores its instructions.

## Verification

**451 debug tests and 449 release tests passed**, with zero failures or skips
(322 core + 129 debug app / 127 release app). **Twenty-two cases were added.**
The suite ran with
`PUDDLE_LIVE_SPLASH=1`, the installed `PUDDLE_CUA_DRIVER` catalog check, and
`PUDDLE_LOAD_TESTS=1`; load tests are not silently skipped.

```sh
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test
PUDDLE_LIVE_SPLASH=1 PUDDLE_CUA_DRIVER=/Applications/CuaDriver.app/Contents/MacOS/cua-driver PUDDLE_LOAD_TESTS=1 sh scripts/swift.sh test -c release
```

The new mailbox tests were run against the original HTTP/Gmail/Calendar files
and failed on unbounded reads. The suspended-send regression was run against the
original Actions implementation and reproduced an actual fixture send after
pause/resume. Original files were restored to the fixed candidate afterward.
These checks use synthetic credentials and record the rejected side effect.

The independent candidate review found two remaining document-reader concerns:
a canonical ancestor could change before root acquisition, and Finder-hidden
files needed their original exclusion. The final reader walks every canonical
parent component with no-follow descriptors and preserves `UF_HIDDEN`, package
and bundle exclusions. Both have regressions in the passing final suites.

Computer Use operated **Puddle Security Review**, a separately identified debug
bundle with a new synthetic workspace. A normal meeting draft exported correctly.
For a second export, the native destination panel was kept open, **Lock Puddle**
was invoked from the app's menu, and Save was completed. The app showed **Puddle
is locked** and `/tmp/puddle-native-explicit-lock-export.md` did not exist.
No macOS authentication was attempted or bypassed. Automatic background locking
was not established by the automation's focus changes; that remains native
acceptance work. Unit tests independently cover lock/unlock and private-session
restoration during pending export preparation.

Focused reproduction, test/build logs, the isolated candidate diff and source
checksums are retained with the security artifacts. The final normal release
bundle is rebuilt separately from the native debug fixture. A count of passing tests
does not close the manual gates below.

The normal release build passed strict signature verification, plist/entitlement
lint, shell syntax and `git diff --check`. Its executable rejected the debug
fixture flag with exit 64 and created no workspace. This remains a local ad hoc
signed artifact; notarization and public release were not performed.

## Gates still blocking public distribution

| Gate | Required evidence / release choice |
| --- | --- |
| Signed installation, updates and rollback | Developer ID sign, notarize/staple the actual artifact; install under Gatekeeper on a clean supported Mac; verify a configured signed update feed, tampered download refusal and schema-8 upgrade/recovery/rollback with a pre-upgrade portable backup. Current local ad hoc signing is insufficient. |
| Real provider consent and account boundaries | Designated Google, Microsoft, GitHub and Atlassian accounts: public OAuth setup/verification, partial scopes, revoke/refresh, account/site/repository switching, disconnect and separately reviewed test sends/bookings. HTTP fixtures cannot establish real provider outcomes. |
| Browser action safety | Live CuaDriver 0.38 accepted synthetic password-field typing and a click after the target label changed. Its API has no atomic reviewed-state/sensitivity guard. Hold release or explicitly defer browser writes from exposed/advertised v1 scope; see the live acceptance report. Native multi-tab/site compatibility also remains pending. |
| Production OS privacy and capture | Verify shipped Keychain access, macOS app unlock, microphone/speech/selected-app audio, dictation target changes, notification delivery while quit and sleep/wake/device loss. No authentication or permission prompt was bypassed. |
| Clean first-run and supported matrix | No developer checkout, cached credentials or model: install/setup/offline recovery and model download failure; advertised model/hardware/OS combinations, keyboard/VoiceOver, narrow windows and resource constraints. One Mac/model is not a support matrix. |
| Filesystem/recovery behavior | Native disk-full/read-only/interrupted writes and representative large schema-8 upgrade/restore drills, including filesystems that cannot retain quarantine metadata. Protected attachment publication must fail clearly instead of silently dropping metadata. |

## Explicit boundaries and residual questions

- This is a Developer ID-style native app with **no App Sandbox entitlement**.
  Source selection and path constraints are enforced in code; they are not an
  application-wide OS sandbox. Enabling App Sandbox requires a separate
  compatibility design for browser drivers, Git, local inference and capture;
  it was not silently enabled by this patch.
- App lock is an in-process access gate. It does not erase already loaded RAM,
  authenticate every Keychain read, stop other applications or recall requests
  already sent. The OS session lock is a separate control.
- Chrome-owned Meet profiles, external Cua/Splash processes, exports and system
  notifications sit outside encrypted snapshot storage. Their privacy behavior
  must be documented and accepted in the shipped configuration.
- Newsletter DNS prechecks are not bound to the final network peer. No concrete
  private-target exploit survived HTTPS certificate, port, redirect, anonymous
  body and exact-review constraints, so this remains hardening work rather than
  a reported SSRF vulnerability.
- Apple's explicit speech-language download uses its asset service outside
  Puddle's provider transport. The live follow-up now disables installation while
  paused and cancels an installation already in progress. Installed speech
  languages remain usable offline.
- Finite adversarial cases do not prove universal prompt-injection resistance.
  Add attacks and the final side-effect assertions whenever a new tool, source,
  provider, parser or autonomous workflow is introduced.
