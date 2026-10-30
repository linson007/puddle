# Contributing to Puddle

Thanks for helping improve Puddle. Documentation, bug reproductions, accessibility
feedback, tests, and code contributions are welcome. You can explore the fixture
demo and run the default tests without a model or cloud account.

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md). Puddle is under active
development; the [roadmap](docs/production-roadmap.md) distinguishes implemented
features from open release gates. Check existing issues and pull requests first.
For a larger feature, new dependency, storage change, or new provider integration,
open an issue to discuss the proposed behavior before investing in implementation.

## Development setup

1. Fork the repository on GitHub and clone your fork:

   ```sh
   git clone https://github.com/YOUR-USERNAME/puddle.git
   cd puddle
   git remote add upstream https://github.com/linson007/puddle.git
   git switch -c your-change
   ```

2. Install Xcode 26 or later, or matching command line tools with Swift 6 and
   the macOS 26 SDK. Use a Mac supported by that toolchain. The app deploys to
   macOS 14+, but compiling availability-guarded speech APIs needs the newer SDK.
   Check your selected toolchain:

   ```sh
   xcode-select -p
   swift --version
   xcrun --sdk macosx --show-sdk-version
   ```

3. Build, explore the demo, and run tests from the repository root:

   ```sh
   make build
   make demo
   make test
   ```

`make build` creates `build/Puddle.app` with ad hoc signing. `make demo` opens
labeled, in-memory fixture data. `make run` opens the normal app, which uses your
persistent local workspace. No package dependency installation is required.

For a faster development build or a targeted test:

```sh
PUDDLE_BUILD_CONFIGURATION=debug make build
sh scripts/swift.sh test --filter MeetingSummaryTests
sh scripts/swift.sh test -c release
```

Use `scripts/swift.sh` for Swift package commands so build caches stay in `.build/`.
The package uses a Swift 6 toolchain with Swift 5 language mode. You can also open
`Package.swift` in Xcode; the scripts handle app-bundle metadata, icons, and signing.

### Optional integrations

Most contributions need only fixtures. For integration work, follow the existing
guides and use your own development configuration:

| Integration | Setup |
| --- | --- |
| Local AI | [Build and run](README.md#build-and-run), then guided Splash setup |
| Gmail and Google Calendar | [Google Desktop OAuth setup](docs/gmail-setup.md) |
| Outlook | [Microsoft setup](docs/releases.md#outlook) |
| GitHub, Jira, and Confluence | [Work connectors](docs/work-connectors.md) |
| Cua browser | [Browser setup and current limits](docs/browser-use.md) |
| Website | [Buildless preview and editing](website/README.md) |

A fork needs its own OAuth registration only when testing the corresponding live
connection. Maintainer credentials are not needed for ordinary development.
`make build` automatically bundles a root `client_secret*.json` when present;
keep downloaded client configuration private and use
`PUDDLE_GOOGLE_CLIENT_FILE=/absolute/path/to/client.json` to select a file elsewhere.
Do not attach built apps containing your configuration to an issue or PR.

## Find your way around

| Path | Responsibility |
| --- | --- |
| `Sources/Puddle/` | SwiftUI screens, store coordination, approvals, and OS integration |
| `Sources/PuddleCore/` | Models, persistence, local agent, transports, and connectors |
| `Tests/PuddleCoreTests/` | Core behavior and transport/persistence fixtures |
| `Tests/PuddleAppTests/` | Store, workflow, capture, and UI-state fixtures |
| `app/` and `scripts/` | Bundle metadata, signing, build and release tools |
| `docs/` | Feature contracts, setup guides, roadmap, and verification evidence |
| `website/dist/` | Editable static HTML, CSS, JavaScript, and assets |

Useful first contributions include improving a confusing setup step, reproducing
a bug with synthetic data, adding a focused regression case, or checking keyboard,
VoiceOver, narrow-window, and dark-mode behavior. Describe the observed result
and environment; no claim that an open release gate passed is needed.

## Code and test expectations

Follow the style of nearby Swift code. Keep UI/OS coordination in `Puddle` and
reusable behavior in `PuddleCore`. Prefer small, focused changes and existing
interfaces over new dependencies. Give user-facing strings useful failure and
recovery information. Update the relevant feature/setup docs when behavior changes.

Use injected transports, secret stores, clocks, and disposable directories in
tests. Add regression coverage for behavior changes, especially persistence,
cancellation, account switching, approvals, parsing limits, and recovery. Protect
the existing boundary between untrusted reference content and user authority.
Avoid accessing personal Keychain items or real accounts in default tests.

Before opening a code PR, run:

```sh
make test
sh scripts/swift.sh test -c release
make build
git diff --check
```

For documentation-only changes, check links and formatting. For website changes,
preview the site and check the affected interactions and layout; Swift tests are
needed when app behavior changes. State which checks you ran and any checks you
could not run. CI runs fixture tests in both configurations on macOS 26 and builds
the release app; it does not need provider secrets or a model.

Live model, browser, audio, and synthetic load tests require explicit opt-in.
Expected skips in a normal run are documented in [testing.md](docs/testing.md).
Use disposable data and designated test accounts for manual integration checks.
Read the current browser limits before enabling browser actions. Native permission
prompts and real provider sends/bookings need deliberate human testing.

## Open a pull request

Target `main` from a focused branch in your fork. Explain the problem, resulting
behavior, related issue, and verification. Include synthetic screenshots for
visible changes and migration/recovery notes for storage changes. Draft PRs are
welcome when you want early feedback. Keep unrelated refactors in separate PRs.

Do not commit OAuth files, tokens, signing/notarization material, update private
keys, personal workspaces, real messages/transcripts, or unredacted logs. Inspect
your staged diff and any attachments; `.gitignore` is only a convenience.

Maintainers review scope, behavior, privacy boundaries, and test evidence, and
may request revisions. Review timing is best effort. If you cannot continue,
leave a brief status so someone else can pick up the work.

## License

By submitting a contribution, you provide it under the repository's
[Apache License 2.0](LICENSE). Submit only material you have the right to share,
and preserve relevant copyright and attribution notices.
