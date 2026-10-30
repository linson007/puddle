# Getting help with Puddle

Puddle is an actively developed macOS application. Community help is best effort;
there is no guaranteed response time or commercial support commitment.

## Start here

- [Build and run](README.md#build-and-run) for toolchain and runtime requirements.
- [Demo](README.md#demo) to explore with fixtures and no accounts or model.
- [Feature guide](docs/features.md) for supported behavior, storage, and recovery.
- [Google setup](docs/gmail-setup.md), [Outlook setup](docs/releases.md#outlook),
  [work connectors](docs/work-connectors.md), and [browser setup](docs/browser-use.md).
- [Testing guide](docs/testing.md) for fixture tests and manual integration checks.
- [Roadmap and release gates](docs/production-roadmap.md) for current limitations.

## Bugs, ideas, and questions

Search [existing issues](https://github.com/linson007/puddle/issues) first, then
[open an issue](https://github.com/linson007/puddle/issues/new/choose). Use the bug
form for a reproducible failure, feature form for a proposal, or question form
for setup and usage help. Include:

- App version or commit (`git rev-parse --short HEAD` for a source build).
- macOS version, Mac architecture, and the affected feature.
- For build problems, `swift --version` and the selected SDK/toolchain.
- Minimal steps, expected behavior, actual behavior, and any relevant error.
- For AI/integration problems, runtime/model or driver version and whether the
  problem reproduces in demo, fixture tests, or a live connection.

Use synthetic examples. Remove account addresses, access/refresh tokens, OAuth
JSON, API keys, private paths, message bodies, meeting transcripts, and personal
data from logs and screenshots. Never upload a workspace vault, Keychain export,
or backup to a public issue. Copy only the smallest relevant diagnostic excerpt.

## Sensitive reports

For a suspected vulnerability, follow the
[security reporting policy](SECURITY.md#report-a-vulnerability). It describes
private reporting and how to request a channel if one is unavailable.
For community conduct, see the
[Code of Conduct](CODE_OF_CONDUCT.md#reporting-a-concern).

Public-release acceptance is still in progress. A successful local build or CI
run does not establish production readiness; the roadmap records the open gates.
