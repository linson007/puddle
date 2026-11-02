# Puddle

[![CI](https://github.com/linson007/puddle/actions/workflows/ci.yml/badge.svg)](https://github.com/linson007/puddle/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Your personal AI assistant, running locally on your Mac.

Explore the [product website and interactive demo](https://linson007.github.io/puddle/).

Puddle opens to **Today**: your priorities, commitments, follow-ups and agenda.
The sidebar keeps **Today**, **Puddle**, **Tasks** and **Memory** within reach.
Expand **More** for optional workspaces such as mail, calendar and meetings;
use the pin beside an item to keep it in the main sidebar across launches.
Unpin it to move it back to More. Actions needing review remain visible when More is collapsed.
Keep your role and objectives in a local work profile, prepare for meetings,
or open a persistent conversation to think through decisions and plans. Gmail,
Outlook and Google Calendar are optional. You can organize work without an account or
running model; conversations use your preferred local AI server.

Puddle is a native SwiftUI app supporting local inference servers through an
OpenAI-compatible API. Splash installation and managed launch are optional. Open source under [Apache 2.0](LICENSE), with no third-party package
dependencies.

**Development status:** Puddle is under active development. Public distribution
is on hold pending the documented [release gates](docs/production-roadmap.md#current-verification-and-release-gates),
including native/provider and distribution acceptance. Browser clicking and
typing are deferred from the first-release scope. Source builds
and the fixture demo are available for development and evaluation.

[Getting started](#build-and-run) · [Contributing](CONTRIBUTING.md) ·
[Getting help](SUPPORT.md) · [Security policy](SECURITY.md) ·
[Report a bug](https://github.com/linson007/puddle/issues/new/choose)

See the [complete supported features guide](docs/features.md) for capabilities,
controls, storage recovery, and current limits.
The [production roadmap](docs/production-roadmap.md) records the executive
assistant requirements, implementation order, and outstanding release gates.

Choose **Personal** or **Developer**
from the sidebar profile menu. Each has role guidance and relevant conversation
starters. **Manage Profiles** lets you edit work context and guidance, create
custom profiles, or duplicate an existing one. Profiles share your conversations,
memory, tasks, meetings and connections. Switching stops an unfinished reply;
it keeps your current chat. Developer source tools additionally require a
project folder you explicitly connect. The Developer sidebar and menu bar entry
appear only for Developer profiles. Switching away while viewing Developer
returns to Today.

## Build and run

The app's deployment target is **macOS 14 or later**. Building from source requires
**Xcode 26 or later**, or matching command line tools with Swift 6 and the macOS 26
SDK, because the source includes newer speech APIs behind runtime availability
checks. Your build Mac must meet the selected toolchain's requirements. Your chosen
inference server has its own hardware, model and operating system requirements.

```sh
git clone https://github.com/linson007/puddle.git
cd puddle
make build
open build/Puddle.app
```

No model, cloud account, OAuth client file, or paid signing identity is needed to
build, run the fixture demo (`make demo`), or run the default tests (`make test`).
The build uses ad hoc signing. AI conversations require a separately running
local AI server; optional connections require their own setup below.

Choose **Set Up Local AI** from Today, chat, or Settings to connect and verify
an existing server. In **Settings → Local AI**, enter its address, optional exact
**Model ID**, and an API key if required, then select **Save and Test Connection**.
Leave Model ID blank to use the first model listed by the server.

| Local server | Common address |
| --- | --- |
| [Ollama](https://docs.ollama.com/api/openai-compatibility) | `http://127.0.0.1:11434` |
| [LM Studio](https://lmstudio.ai/docs/developer/openai-compat) | `http://127.0.0.1:1234` |
| [llama.cpp](https://github.com/ggml-org/llama.cpp/tree/master/tools/server) | `http://127.0.0.1:8080` |
| [Splash](https://github.com/incoai/splash) | `http://127.0.0.1:8000` |

The address may include `/v1`. Servers must provide `GET /v1/models` and
`POST /v1/chat/completions`, including streaming for chat. Assistant tools also
require compatible function calling and a model configured for tools. Guided
setup tests a synthetic reply and required tool call without accessing your data.
Configure context capacity and reasoning in your server; Puddle sends portable
chat parameters without runtime-specific overrides. A loopback server can itself
forward requests elsewhere, so choose a local model and disable any cloud routing
in that server.

The optional **Install and manage Splash** section provides hardware checks,
discovery/installation, two model presets, and managed start/stop. Installation
and initial model downloads need internet. Splash's Apple silicon and macOS
requirements apply only to that optional engine; Puddle's workspace works on
macOS 14+. Puddle stops only processes it starts.

## The assistant

- **Today:** three daily priorities, overdue and due-today work, waiting-on
  counts, cached agenda conflicts, flagged unread mail, and local model setup.
  **Brief me on today** and **End-of-day review** open a conversation with your
  saved work context.
- **Puddle:** general conversation, planning, writing, and relevant tool use.
- **History:** see the current chat immediately; search, reopen, and delete saved conversations.
  Chat opens the latest 200 messages; load earlier messages in batches without losing history.
- **Calendar:** agenda, week and month views, selected secondary calendars,
  working-hour/buffer preferences, candidate slots and focus-time proposals.
  Review event creation/editing and undo with provider revision checks.
- **Mail:** search and filter up to 50 recent inbox messages, read messages,
  summarize, ask Puddle, and review an email as a local task. Compose/reply/forward,
  review exact sends and organization, track follow-ups, snooze locally, maintain
  VIPs, review newsletter unsubscribe, and inspect threads and attachments.
  Reading does not mark mail read. Gmail and Outlook accounts are optional.
- **Developer:** connect a project folder, browse/search numbered source,
  inspect Git status and working/staged text diffs, and keep debugging,
  implementation and review sessions. The local assistant can read this context
  through scoped tools. Project files stay read-only; verification notes are
  user-recorded. [Developer implementation and next steps](docs/developer-assistant-plan.md).
  Search GitHub issues/PRs, Jira work and Confluence documentation, read details
  with source links, and ask the local assistant about them.
  [Connect your work sources](docs/work-connectors.md).
- **Meetings:** open supported join links; automate Google Meet admission in a dedicated Chrome profile (experimental); keep and search notes; import/export transcripts; transcribe microphone and selected-app audio on macOS 26+; extract local summaries, decisions, and action items with source quotes. A floating companion keeps notes/transcription visible; saved capture checkpoints can be recovered after interruption.
- **Memory:** preferences and facts you choose to save, available across
  conversations. Search, inspect, update, or forget them here.
- **Tasks:** track owners, waiting-on follow-ups, priority, notes and daily
  focus; search, filter, edit, complete, delete, reschedule and snooze local work.
  Daily/weekly/monthly commitments create their next occurrence once after completion.
  Chat can propose reviewed creation, completion, renaming and rescheduling.
  With notifications enabled, macOS schedules reminders while Puddle is closed.
  Due reminders also appear in chat, including after the next launch.
- **Connections:** GitHub, Jira/Confluence, optional email/calendar context and local model settings.
- **Actions:** editable proposals and exact-content review, durable dispatch intent,
  provider receipts, and an uncertain state that prevents automatic replay.
- **Work Context:** project goals, linked commitments/meetings, explicit people/VIP
  records and decision owners/options/rationale/evidence/review dates/outcomes.
- **Knowledge:** incremental local search over selected text, PDF and DOCX sources,
  with cited extracted passages and deletion propagation on refresh.
- **Routines:** scheduled read-only briefs/reviews with persisted execution history,
  missed/interrupted-run handling, pause and optional launch at login.
- **Browser:** use Cua Driver to open a separate Chrome or Edge window and let
  your local assistant read pages, navigate by URL and scroll. Click and type manually. Start a
  session explicitly; assistant actions wait for your review in chat. See
  [Cua browser setup](docs/browser-use.md). Errands retain goals/progress across
  turns; Continue inspects fresh state and completion requires observed evidence.
- **Settings → Backups:** export saved work and all profiles, then review a merge into another
  workspace. Current work is preserved; account caches and Keychain secrets
  are excluded. Passphrase encryption is the default; restore never executes
  actions, reconnects browser sessions, or enables imported routines.

Puddle automatically learns useful personal facts, preferences, and ongoing
projects from what you say. Introduce yourself with “My name is…” or say “I
prefer short, practical answers.” No save command or approval dialog is needed.
Learned information appears in **Memory** and carries into new conversations.
You can review its source quote or forget it there. Saying “don’t remember this”
prevents learning from that message. Automatic saves require extracts from your
own words and exclude messages containing recognized credential patterns.
Disable automatic learning in Settings → Assistant at any time.

Learning uses your messages, not assistant replies, email, or calendar content.
Local reminders still show their exact contents for **Allow** or **Decline**
before creation. You can also add memories and tasks directly from the sidebar.

**New Conversation** (⌘N) archives the conversation while retaining saved memory,
tasks, and connections. Replies stream into chat; messages support copying,
reuse as a draft, and retries with durable tool receipts. Settings → Assistant
controls response preferences and notifications. The menu bar item keeps Puddle
available after its window closes.

Use the microphone or Command-Shift-M to dictate on this Mac, then review and
send the draft. **Read aloud** plays a reply using a macOS voice. Settings →
Assistant offers automatic reply playback, voice language, and speed; automatic
playback is off by default. Voice input requires microphone permission and a
supported installed on-device recognition language, with no cloud fallback.
Opt into **System Dictation** in Settings for hold-to-talk ⌘⇧Space, vocabulary
corrections, optional punctuation and insertion into the original accessible
text field. Unsupported/changed targets retain the transcript for manual copy.
⌘K searches saved work and commands; ⌘⇧N captures a commitment and ⌘⇧L opens
the assistant beside the current workspace.

## Optional connections

Choose **Connections → Connect Google** to add Gmail, Calendar, or both.
Google opens in your browser for account selection and consent, then Puddle
loads the services you approved. Use **Manage Google Permissions** to change
access later. Google sign-in is separate from the local model connection.
Multiple Google accounts can be retained in Keychain and explicitly switched;
caches clear on switching. Sending, organization and calendar writing each need
their optional grants and a fresh exact-content review. Outlook uses a separate
Microsoft public-client registration: see [release and connection setup](docs/releases.md).

The app owner provisions one Desktop OAuth client when building Puddle.
`make build` includes a single gitignored `client_secret*.json` from the project
root, or the file selected with `PUDDLE_GOOGLE_CLIENT_FILE`. Puddle imports it
into Keychain on first launch. End users do not create Cloud projects or import
credentials. [Google setup instructions](docs/gmail-setup.md).

The model receives tool descriptions and decides when a tool is relevant. A
general conversation does not automatically load your inbox or calendar.

| Tool | Capability |
| --- | --- |
| Search mail | Read up to 10 messages from the selected Gmail/Outlook provider |
| Read calendar | Read up to 50 primary-calendar events from the start of today within 1–14 days |
| Recall memory | Search locally saved preferences and facts |
| Learn a memory | Automatically save or update a personal fact supported by your message |
| Read tasks | List local tasks and reminders |
| Read daily brief | Saved priorities, overdue/waiting work, cached agenda conflicts and flagged mail, with freshness and scope limits |
| Create/update a reminder | Review a new task or completion, reopening, title or due-date change |
| Prepare email/event | Save a local editable proposal; sending/booking requires separate exact-content review |
| Read work context/documents | Bounded user-maintained project/people/decision context or cited indexed passages |
| Read browser | Read page text and current element refs from an explicitly started Cua browser |
| Use browser | Review URL navigation and scrolling in a dedicated browser session; clicking and typing are deferred |

Connections start with read permissions. Reviewed sends, organization and calendar
writes require optional grants. The model cannot directly dispatch them.
Optional mail polling checks the 50 most recent inbox messages; the
first sync establishes a baseline, and subsequent checks reuse unchanged bodies
through Gmail history. Failed checks back off before retrying.

Disconnecting Google clears its tokens and cached connection data, retaining
your conversation, memory, and tasks. Previously retrieved data can remain in
conversation archives and local backups; see [storage and recovery](docs/features.md#local-storage-and-recovery).

## Demo

    make demo

The demo uses labeled fixture responses, sample connections, and in-memory
state. It accesses neither your Google account nor your real app cache.
Explore general chat, automatically save a memory, create a demo reminder,
and inspect Tasks, Memory, and Connections. Demo replies are not model inference.

This is the quickest way to explore the interface before configuring local AI
or accounts. See [contributor setup](CONTRIBUTING.md#development-setup) for debug
builds and focused tests.

## Data and runtime boundaries

Puddle uses the local server’s OpenAI-compatible HTTP API without importing an
inference engine or its internals. AI requests accept only loopback addresses and reject redirects.
Google calls go directly to its HTTPS APIs.

Tokens, OAuth client configuration, and an optional local AI server key use macOS
Keychain without iCloud synchronization. Conversation, memories, tasks,
preferences, and connection cache use AES-GCM encrypted storage under
`~/Library/Application Support/Puddle/`, with owner-only permissions
and a separate workspace key in Keychain. `workspace.vault` and its rolling backup
reference encrypted transcript pages and recovery copies in `transcripts/`.
Keep the complete directory for device-bound recovery; use Settings → Backups
to transfer work. Existing JSON is migrated into encrypted
recovery copies before plaintext originals are removed. Versioned state has atomic saves, a previous-state backup, and recovery that
preserves unreadable files. Failed writes roll back unsaved changes.
Private sessions keep changes only in memory. Optional app lock uses macOS
authentication; retention controls remove selected old conversation archives.
External API pause allows loopback inference and stops managed browser/capture
work. It does not firewall other apps or independently running model servers.

External emails and calendar descriptions are untrusted reference data. Email
HTML becomes plain text without loading remote images. The model cannot execute
arbitrary commands or tools outside the implemented tool set.

The current runtime supports conversation, the listed tools, reminder scheduling,
optional Cua browser errands, scoped read-only document/project tools, reviewed
mail/calendar actions, routines and mail polling. Routines run while Puddle or
its menu-bar process is open; after Quit, catch-up happens at the next launch.
General native desktop control, cross-device sync and automatic scheduled meeting
attendance remain outside this implementation. Inference history and
tool results are bounded; archived conversations remain available in History.
Context budgets respect the model's reported capacity and use text token estimates.

## Test

    make test
    make build

The default suite uses fixtures. Live Splash, installed browser-driver, audio,
and load evaluations are opt-in and are skipped unless explicitly configured.
CI runs the default suite in debug and release on macOS 26 and packages an ad hoc
release app without account credentials. CI does not establish the manual release
gates or run live provider actions.

`make verify-local` repeats the independent roadmap checks with an already
running Splash server, configured Cua Driver and installed speech language. It
uses synthetic state, generated-file recognition and disposable browser/disk
fixtures; it does not grant permissions or use provider accounts. See
[local verification](docs/testing.md#independent-local-verification) and the
[2 November acceptance report](docs/roadmap-acceptance-2026-11-02.md).

Tests cover chat without accounts, tool-call round trips, unavailable tools,
declined actions, incomplete calls, execution limits, memory/state migration,
reminders, OAuth/PKCE, incremental Gmail, paginated Calendar, streamed replies,
storage recovery, failed writes, cancellation, and local inference boundaries. They use
HTTP fixtures, not real accounts or model inference.
[Manual verification](docs/testing.md) covers native UI and live integration.
The [native Cua acceptance report](docs/cua-end-to-end-2026-10-30.md) records the
guided Splash walkthrough, tested feature flows, fixes and remaining checks.
The [six-month load report](docs/load-testing-2026-10-30.md) records tests with
108,000 messages, 5,001 memories, native UI checks and a 1,000-save endurance run.
The [security and guardrail report](docs/security-testing-2026-10-30.md) records
the security fixes, adversarial tests and remaining public-release gates.
The [live browser/OS follow-up](docs/live-browser-os-acceptance-2026-10-30.md)
records additional fixes, macOS unlock, browser acceptance and the historical
browser-write findings. The [current browser scope](docs/browser-use.md) defers
clicking and typing from v1.

Build scripts default to an ad hoc signed local app. Release scripts support
Developer ID signing/notarization and a pinned signed update feed, but require
owner credentials, hosting and OAuth verification. General-public
production readiness also requires clean-Mac onboarding and live integration,
hardware, accessibility and supported-model validation; see the roadmap.
See [implementation and verification status](docs/improvement-implementation.md)
for the feature-by-feature record and [release instructions](docs/releases.md).

## Source layout

    Sources/Puddle/          Native app, conversation UI, approvals, workers
    Sources/PuddleCore/      Local agent loop, inference client, memory/tasks, connectors
    Tests/PuddleCoreTests/   Isolated core and integration tests
    Tests/PuddleAppTests/    App workflow and native integration fixtures
    app/                    App metadata
    scripts/                Build and icon generation
    docs/                   Connection setup and verification
    website/dist/           Buildless product website and interactive demo
    .github/                CI, website deployment, and contribution templates

## Contributing and community

Contributions are welcome: clearer docs, reproducible bug reports, accessibility
feedback, test coverage, and focused fixes all help. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, code conventions,
and useful first contributions. Discuss larger changes in an issue before
starting implementation, and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

Use [GitHub Issues](https://github.com/linson007/puddle/issues/new/choose) for bugs,
feature requests, and questions. [SUPPORT.md](SUPPORT.md) explains what to include
and how to keep personal data out of reports. Community support is best effort.
For suspected vulnerabilities, follow the [security reporting policy](SECURITY.md#report-a-vulnerability).

## License

Puddle is licensed under the [Apache License 2.0](LICENSE). Contributions are
provided under the same license. Splash, Cua Driver, browsers, models, and other
optional external tools retain their own licenses and terms; they are not
included in Puddle's Swift package.

