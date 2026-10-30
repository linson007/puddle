# Developer assistant: analysis, implementation and next steps

## Product assessment

The original Developer profile provided role guidance, two chat starters and a
focus-planning prompt. It shared useful personal-assistant capabilities, but it
could not inspect a project or distinguish an actual code observation from a
generic suggestion. Debugging context disappeared into chat history, and there
was no dedicated way to retain reproduction steps or verification evidence.

A useful local developer assistant needs a continuous workflow: choose a
project, establish evidence, investigate a problem, compare changes, decide
what to do, and verify the outcome. Each step must preserve the user's work,
show its source and make clear which actions actually happened.

## Implementation sequence

| Priority | Capability | State | Result / acceptance criteria |
| --- | --- | --- | --- |
| 1 | Project connection and context | Implemented | Explicit native folder selection, persistent read-only bookmark, project picker, editable stack/goals/constraints, reconnect/remove controls, up to 25 projects. Removing a connection never deletes project files or investigation notes. |
| 2 | Source evidence | Implemented | Path browsing, literal source search, numbered UTF-8 excerpts, references in tool receipts, source path/line citations requested in prompts, visible exclusions and incomplete-result labels. |
| 3 | Local change awareness | Implemented | Branch/commit and source-change status; captured working/index and staged/HEAD text comparisons. Fixed Git read commands disable hooks, fsmonitor, external diff and text conversion. Repository scripts never execute. |
| 4 | Persistent engineering sessions | Implemented | Debugging, implementation and review sessions; expected/observed behavior, reproduction, findings/decisions and user-recorded verification; investigating/blocked/resolved status; drafts survive navigation and failed saves. |
| 5 | Project-aware conversations | Implemented | Developer-only tools read saved context and the selected project; Explain project, Review changes and Save & Ask hand off to local chat. Project changes cancel stale inference/inspection. Other profiles keep their existing tool set. |
| 6 | Recovery and honest verification | Implemented | Schema-5 migration, atomic state updates, portable session backup/merge, detached folder references on restore, fixture tests and an optional synthetic-source live-model evaluation. Reading a diff never counts as a test run. |
| 7 | Reviewed code changes | Planned next | Model proposes a patch with exact base hashes and cited rationale. User reviews affected files/hunks. Apply only after approval, with root-bound path checks, stale-file detection, backups and rollback. Never stage/commit implicitly. |
| 8 | Approved build/test checks | Planned | User-configured executable and argv with exact folder/command review; explicit approval, scrubbed environment, bounded output/time, process-group cancellation and durable exit-code receipts. Repository code can execute arbitrary behavior, so this requires a separate permission design. |
| 9 | Deeper diagnostics | Planned | User-selected logs and stack traces, structured failed-check results, local source/test correlation, and a feedback loop from verified outcome to the investigation session. |
| 10 | Semantic project navigation | Planned | Gitignore-aware incremental indexing, symbol references and dependency navigation, language-aware chunks, invalidation after edits, explicit indexing limits and local-only storage. Current search is literal and applies the documented filename/directory policy, not gitignore rules. |
| 11 | Delivery and collaboration context | Read connectors implemented | GitHub.com issues/PR details, patch excerpts and reported checks; Jira Cloud search/read; Confluence Cloud search/read; shared source search and local assistant tools with links, bounds, timestamps and partial errors. [Setup and acceptance limits](work-connectors.md). Reviewed external writes and links to local commitments remain future work. |
| 12 | Multi-project execution and release quality | Planned | Worktrees, dependency/resource checks, crash recovery for approved jobs, supported-model evaluations, large-repository performance and keyboard/VoiceOver review. |

## Current workflow

1. Open **Developer** and select the Developer profile if prompted.
2. Choose one project folder. Optionally describe the architecture, stack,
   current goals and constraints in **Edit Project Context**.
3. Find a file, search a literal string, read its numbered excerpt, or inspect
   Git status. Working Diff compares the index to captured working text; Staged
   Diff compares HEAD to the index. Text comparisons do not represent mode,
   rename or binary changes.
4. Choose **Explain this project** or **Review current changes** to start a
   source-based conversation. Only the active project is available to tools.
5. Create a debugging, implementation or review session. Save the problem,
   expected/observed behavior and reproduction; choose **Save & Ask Puddle**.
   Record findings and actual verification evidence as the work progresses.
6. Keep saved sessions across restarts and backups. A restored session retains
   its previous project name but needs a newly selected folder for source access.

## Runtime and data boundaries

- Source content goes only to the configured loopback model. Folder connection
  does not automatically send or persist an entire repository.
- Files are opened relative to a held directory descriptor, refusing symlinks
  at every relative path component. Absolute paths, traversal, control-character
  paths, special files and common private/generated directories are refused.
- Filename filters and recognizable credential checks are conservative
  heuristics, not a complete secret detector. Do not place secrets in source or
  saved session notes. A `.gitignore` rule alone is not an exclusion here.
- Reads accept regular UTF-8 source files up to 512 KB. Excerpts return at most
  120 lines and 14,000 characters. Inventory visits at most 20,000 entries, depth
  20, and returns 200 matches. Search examines at most 2,000 files / 8 MB and
  returns 30 matching lines. Results expose their limits.
- Git inspection needs the repository root. Read commands have a five-second
  timeout and bounded output. Remote protocols and lazy object fetching are
  disabled, pathspecs are literal, and status skips submodule recursion, using
  [Git's documented environment controls](https://git-scm.com/docs/git).
  Missing partial-clone objects must be downloaded separately in the user's Git
  client. Diffs compare private temporary source snapshots;
  they do not ask Git to reopen mutable working files or run external drivers.
- Repository text, README/AGENTS files, comments and logs are reference data.
  They cannot grant tools, authorize writes or override assistant instructions.
- Project grants and bookmarks stay in local state and are excluded from
  portable backups. Saved session text is included; exports remain unencrypted.
- Source snippets can remain in assistant replies and conversation archives.
  Removing a folder connection does not erase past conversations.
- No patch application, project command execution, network repository actions,
  staging, commits or automatic test execution are implemented in this release.

## Verification contract

Automated checks exercise real temporary Git repositories, source-policy and
descriptor boundaries, private/historic credential withholding, line references,
staged versus working comparisons, cancellation, state migration, persistence
failures, stale editors, project switches and portable restore without grants.

The optional `DeveloperLiveEvaluationTests` generates an unpredictable value in
a synthetic source file and requires the real local model to read that source
before reporting the value and identifying its file. It has no account access
and does not inspect the user's project.

Native acceptance must also exercise the folder picker, context editing,
session drafts, narrow-window layout, source navigation and a real project on
each advertised macOS/model combination. These checks do not establish that a
model's review is exhaustive or that suggested code has passed verification.
