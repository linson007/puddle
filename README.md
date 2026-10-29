# Puddle

Your personal AI assistant, running locally on your Mac.

Puddle opens to a persistent conversation. Talk about ideas, writing, planning,
or everyday questions; let it remember your preferences and keep local tasks
and reminders. Gmail and Google Calendar are optional connections the assistant
can use when relevant. No Google account is required to chat.

Puddle is a native SwiftUI app using a separately running Splash inference
server. Open source under [Apache 2.0](LICENSE), with no third-party package
dependencies.

See the [complete supported features guide](docs/features.md) for capabilities,
controls, storage recovery, and current limits.

## Build and run

Requirements: macOS 14 or later and Swift 6 command line tools or Xcode. Splash
retains its own Apple silicon and macOS requirements.

    make build
    open build/Puddle.app

Start your existing Splash server separately, for example:

    cd ../splash
    ./splash serve --model unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M

In Puddle, choose **Connect Splash**, enter its address (default
http://127.0.0.1:8000), and select **Save and Test Connection**. An API key is
needed only if your Splash server requires one. Then start a conversation.

## The assistant

- **Puddle:** general conversation, planning, writing, and relevant tool use.
- **History:** see the current chat immediately; search, reopen, and delete saved conversations.
- **Meetings:** open supported join links; automate Google Meet admission in a dedicated Chrome profile (experimental); keep and search notes; import/export transcripts; transcribe microphone and selected-app audio on macOS 26+; extract local summaries, decisions, and action items with source quotes.
- **Memory:** preferences and facts you choose to save, available across
  conversations. Inspect, update, or forget them here.
- **Tasks:** add, edit, complete, delete, reschedule, and snooze local tasks.
  With notifications enabled, macOS schedules reminders while Puddle is closed.
  Due reminders also appear in chat, including after the next launch.
- **Connections:** optional email/calendar context and local model settings.

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

## Optional connections

Choose **Connections → Connect Google** to add Gmail, Calendar, or both.
Google opens in your browser for account selection and consent, then Puddle
loads the services you approved. Use **Manage Google Permissions** to change
access later. Google sign-in is separate from the local model connection.

The app owner provisions one Desktop OAuth client when building Puddle.
`make build` includes a single gitignored `client_secret*.json` from the project
root, or the file selected with `PUDDLE_GOOGLE_CLIENT_FILE`. Puddle imports it
into Keychain on first launch. End users do not create Cloud projects or import
credentials. [Google setup instructions](docs/gmail-setup.md).

The model receives tool descriptions and decides when a tool is relevant. A
general conversation does not automatically load your inbox or calendar.

| Tool | Capability |
| --- | --- |
| Search mail | Read up to 10 messages matching a Gmail query, beyond the cached inbox |
| Read calendar | Read up to 50 upcoming primary-calendar events within 1–14 days |
| Recall memory | Search locally saved preferences and facts |
| Learn a memory | Automatically save or update a personal fact supported by your message |
| Read tasks | List local tasks and reminders |
| Create a reminder | Propose a local task/reminder for approval |

Gmail and Calendar access are read only. Puddle cannot send email or change
events. Optional mail polling checks the 50 most recent inbox messages; the
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

## Data and runtime boundaries

Puddle uses Splash’s HTTP API without importing its internals or modifying its
repository. AI requests accept only loopback addresses and reject redirects.
Google calls go directly to its HTTPS APIs.

Tokens, OAuth client configuration, and an optional Splash key use macOS
Keychain without iCloud synchronization. Conversation, memories, tasks,
preferences, and connection cache use
~/Library/Application Support/Puddle/state.json, with owner-only permissions.
Versioned state has atomic saves, a previous-state backup, and recovery that
preserves unreadable files. Failed writes roll back unsaved changes.
The JSON is not separately encrypted; macOS account and disk protection apply.

External emails and calendar descriptions are untrusted reference data. Email
HTML becomes plain text without loading remote images. The model cannot execute
arbitrary commands or tools outside the implemented tool set.

This MVP supports conversation, the listed tools, reminder scheduling, and
optional mail polling. General autonomous background projects, general browser control,
file tools, calendar editing, scheduled automatic meeting attendance, and continuous chat listening are future work. Inference history and
tool results are bounded; archived conversations remain available in History.
Context budgets respect the model's reported capacity and use text token estimates.

## Test

    make test
    make build

Tests cover chat without accounts, tool-call round trips, unavailable tools,
declined actions, incomplete calls, execution limits, memory/state migration,
reminders, OAuth/PKCE, incremental Gmail, paginated Calendar, streamed replies,
storage recovery, failed writes, cancellation, and local inference boundaries. They use
HTTP fixtures, not real accounts or model inference.
[Manual verification](docs/testing.md) covers native UI and live integration.

Build scripts produce an ad hoc signed local app. Public distribution signing,
notarization, and Google OAuth verification are not configured.

## Source layout

    Sources/Puddle/          Native app, conversation UI, approvals, workers
    Sources/PuddleCore/      Local agent loop, Splash, memory/tasks, connectors
    Tests/PuddleCoreTests/   Isolated core and integration tests
    app/                    App metadata
    scripts/                Build and icon generation
    docs/                   Connection setup and verification

