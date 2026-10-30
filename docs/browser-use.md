# Cua browser support

**Public-release gate:** [live acceptance](live-browser-os-acceptance-2026-10-30.md)
confirmed that CuaDriver 0.38 accepts changed-target clicks and synthetic typing
in password fields. Prompt guidance is not an enforced sensitive-field boundary.
Browser writes remain in the development build; public distribution is on hold
until writes are deferred from v1 or the driver provides enforceable safeguards.

Open **Browser** in Puddle's sidebar to use a browser alongside the assistant.
Puddle connects to the open-source [Cua Driver](https://cua.ai/docs/cua-driver),
using its persistent local MCP connection. Splash remains the model provider;
no Cua cloud account or model API key is needed.

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
   “Open Wikipedia, search for Ada Lovelace, and summarize the page.”
   A running Splash model supporting function calls is needed for chat tasks.

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
- Puddle can navigate to HTTP/HTTPS pages, click current refs, type in editable
  fields, and scroll. It returns fresh page state after each action. Page text
  and controls are sent to your local Splash model, rather than screenshots.
- Assistant navigation, clicks, typing and scrolling wait for **Allow** or
  **Decline** in chat. Typing reviews show the exact text; element reviews show
  the current target label when available. Declining sends nothing to Cua.
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
Synthetic DOM clicks can be ignored by sites requiring trusted input; Puddle
reports the result instead of silently switching input methods or taking focus.

Reading an action response is not proof of the requested outcome: the assistant
must check fresh page state. Large page results can be incomplete; narrow the
page query. Complex or dynamic pages and multiple tabs need interactive checks.

## Local data and verification

The executable path is an app-local preference, excluded from workspace backups.
Session IDs, tab capabilities, element refs and page snapshots stay in memory.
Chat replies can contain excerpts and action receipts retain action descriptions
and destinations. Typed text is shown during review; receipts store its length,
not the typed contents. Chat and receipts follow normal workspace retention.
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
timeouts, approval, failed saves, uncertain actions and retry behavior.
For an optional real MCP handshake/catalog check without page control:

    PUDDLE_CUA_DRIVER=/absolute/path/to/cua-driver sh scripts/swift.sh test --filter CuaBrowserTests.testInstalledDriverMCPHandshakeAndBrowserCatalog

Set `PUDDLE_CUA_LIVE=1` as well to test a real dedicated browser session and
repeated reads. The loopback fixture and optional navigation check are documented
in the live acceptance report. They do not close the failed browser-write gates.

For interactive acceptance, connect the actual driver with macOS permissions,
open a disposable page, navigate, click a link, fill a non-sensitive field and
scroll. Confirm fresh results and visible browser state, decline an action,
stop during work, restart Puddle and verify no automatic reconnect. Test with
your supported Splash model; fixture success does not prove live model quality.
