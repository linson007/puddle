# Cua browser support

**First-release scope:** page reading, URL navigation and scrolling.
[Earlier live acceptance](live-browser-os-acceptance-2026-10-30.md)
confirmed that CuaDriver 0.38 accepts changed-target clicks and synthetic typing
in password fields. Prompt guidance is not an enforced sensitive-field boundary.
Clicking and typing are now deferred: they are absent from the assistant's tools
and rejected by both the workspace and driver adapter, including old errands.
There is no setting to re-enable them. Handle page interactions manually.
This narrows Puddle's scope; it does not fix the external driver's behavior.

Open **More → Browser** to read pages alongside the assistant.
Puddle connects to the open-source [Cua Driver](https://cua.ai/docs/cua-driver),
using its persistent local MCP connection. Your chosen local server remains the model provider;
no Cua cloud account is needed. A model API key is needed only if your server requires one.

## Setup

1. Install Chrome or Edge and Cua Driver 0.38 or later using the
   [official quickstart](https://cua.ai/docs/cua-driver/quickstart).
2. Follow Cua's setup to start CuaDriver.app and grant it **Accessibility** and
   **Screen & System Audio Recording** in macOS System Settings. Permissions
   belong to CuaDriver.app. Puddle does not grant them or borrow another app's
   permissions. macOS can require a CuaDriver restart after changing a grant.
3. In Puddle → **Browser**, choose the installed `cua-driver` executable if its
   path is not found automatically. Click **Start Cua Browser**. The path is
   saved locally; a browser session is never resumed automatically.
4. Use **Open Page**, or enter a request in **Ask Puddle**, for example:
   “Open https://en.wikipedia.org/wiki/Ada_Lovelace and summarize the page.”
   A running local model supporting function calls is needed for chat tasks.

The integration uses `cua-driver mcp`, with the driver's normal macOS app
identity. It does not use direct mode, attach to a personal profile, or change
the driver's permission mode to unrestricted. A separate, temporary browser
profile belongs to this session. User cookies, extensions and signed-in tabs
are not copied. Sign in yourself inside that window if a task needs an account.

## Controls and behavior

- **Read Page** reads semantic page text and current element references.
  It refreshes the dedicated window's tabs and reads its active tab. Model reads
  can instead select an exact tab ID from the latest inventory. Binding refresh
  replaces opaque capabilities; older refs/tab IDs must not be reused.
- Puddle can navigate to HTTP/HTTPS pages and scroll. It returns fresh page
  state after each action. Page text
  and controls are sent to your chosen local model, rather than screenshots.
- Assistant navigation and scrolling wait for **Allow** or **Decline** in chat.
  Reviews show the exact destination or scroll target. Declining sends nothing
  to Cua. Clicking links, typing and submitting forms require manual takeover.
- The banner stays visible throughout the app. **Show Browser** brings the
  browser forward. **Stop Browser** cancels the chat turn, closes the MCP
  connection and ends its session-owned browser. It does not stop a shared
  Cua daemon or close a personal Chrome window.
- On a failed or cancelled action, inspect before retrying. An action may have
  reached the site even if its response was lost. Pending intent is saved
  before dispatch, and retries of that chat turn can read state but cannot
  repeat attempted browser mutations. Send a new message to continue work.
- Switching profiles stops the current reply and pending action approval.
  The browser remains connected when idle and works across roles. Demo mode
  disconnects it and cannot start a real browser.

The host exposes only these browser operations, with scoped tab IDs and fresh
element refs. There is no model-accessible shell, arbitrary JavaScript,
desktop input, screenshot interpretation, file upload/download, personal-profile
attachment or browser permission control. Handle credentials, authentication
codes, payment details, CAPTCHAs and permission prompts yourself in the browser.
Driver click/type operations are excluded from the adapter's tool allowlist.
Scrolling uses a fixed scroll operation; it cannot be changed into a click.

Reading an action response is not proof of the requested outcome: the assistant
must check fresh page state. Large page results can be incomplete; narrow the
page query. Complex or dynamic pages and multiple tabs need interactive checks.

## Local data and verification

The executable path is an app-local preference, excluded from workspace backups.
Session IDs, tab capabilities, element refs and page snapshots stay in memory.
Chat replies can contain excerpts and action receipts retain action descriptions
and destinations. Historical click/type receipts remain readable but cannot
authorize another dispatch. Chat and receipts follow normal workspace retention.
Cua Driver separately controls its own profile lifecycle and telemetry settings.

**Errands** persist the goal, latest progress and number of turns. Continue
observes fresh page state and starts another bounded turn with the existing
per-action review. It never reconnects a browser or replays old actions on launch.
Interrupted work returns paused. Completion requires you to provide a specific
quote that Puddle finds in a fresh page observation. A site confirmation should
still be inspected for the actual requested result; matching text alone cannot
prove a third-party service fulfilled a booking. Private sessions and external
API pause disable errands. Portable backups keep records, not browser capabilities.

Automated tests use synthetic MCP processes, browser state, model responses and
in-memory credentials. They cover scoped sessions, fresh refs, cancellation,
timeouts, approval, failed saves, uncertain actions and retry behavior. They
also reject fresh/guessed click refs, typing with either replacement choice,
hostile tool calls and resumed typing errands before any driver write.
For an optional real MCP handshake/catalog check without page control:

    PUDDLE_CUA_DRIVER=/absolute/path/to/cua-driver sh scripts/swift.sh test --filter CuaBrowserTests.testInstalledDriverMCPHandshakeAndBrowserCatalog

Set `PUDDLE_CUA_LIVE=1` as well to test a real dedicated browser session and
repeated reads. The loopback fixture and optional navigation check are documented
in the live acceptance report. Clicking and typing require a future driver
contract and a separately reviewed scope change before they can return.

For interactive acceptance, connect the actual driver with macOS permissions,
open a disposable page, navigate by URL and scroll. Confirm fresh results and
visible browser state, manual takeover, decline an action,
stop during work, restart Puddle and verify no automatic reconnect. Test with
your chosen local model; fixture success does not prove live model quality.

## Helper identity and host trust

Puddle currently runs as an unsandboxed macOS application. Its document scopes,
network policy and action review are application checks; they are not an OS
sandbox. The selected Cua Driver runs with the current user's permissions and
manages browser profiles outside encrypted workspace storage. Browser cookies,
downloads and profile state need separate browser review/deletion.

Before distributing a build with browser support, set
`PUDDLE_CUA_DRIVER_REQUIREMENT` to the accepted helper's designated code-signing
requirement, including its identifier and publisher Team ID. Obtain and review it
from the exact supported signed driver with `codesign -d -r- /path/to/cua-driver`;
do not pin a generic “any signed code” requirement. The app verifies that
requirement and strict signature validity immediately before launching the helper
and sending MCP data. No configured requirement means browser launch is disabled.
Tampered/unsigned/other-publisher helpers are refused. Test helper updates against
the same requirement before advertising their versions. Local administrators or
code already executing as the user remain within the host trust boundary; this
check does not provide process containment or protect a compromised host.

The full `make verify-local` browser acceptance path also requires the accepted
`PUDDLE_CUA_DRIVER_REQUIREMENT`, or `--driver-requirement` when invoking
`scripts/verify-local.py` directly. The runner checks the installed helper's
signature/requirement before discovery or browser work; the XCTest helper path
uses the same explicit requirement because its main bundle is the test host.
Missing/mismatched identity is a failure, not an accepted compatibility result.
This test-only injection does not add an environment override to the shipping app.
Use `scripts/verify-models.py` when only the model matrix is being evaluated.

A driver transport failure clears its session and the app's connected state.
Use Start Cua Browser to create a fresh transport, then inspect the page before
repeating any action; Puddle never replays the failed action automatically.
The helper receives only runtime identity/path, locale and temporary-directory
environment values, with standard permission mode forced. Shell-exported API
keys and provider tokens are not inherited.
