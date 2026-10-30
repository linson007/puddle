# Security Policy

## Report a vulnerability

Please avoid putting vulnerability details, credentials, or personal workspace
data in a public issue or pull request.

Use [GitHub's private vulnerability reporting](https://github.com/linson007/puddle/security)
if **Report a vulnerability** is available. If it is unavailable, open a
[minimal issue](https://github.com/linson007/puddle/issues/new) asking the maintainer
for a private reporting channel, without reproduction steps or sensitive details.
There is no dedicated security email or guaranteed response time documented yet.

Include the affected commit or version, macOS version, required configuration,
expected and observed behavior, impact, and a minimal reproduction using synthetic
data. Coordinate disclosure with the maintainer while a report is investigated.

## Development status

Puddle is under active development. Reproduce on the current `main` branch when
possible; a backport or long-term support schedule has not been established.
Public distribution remains subject to the gates in the
[production roadmap](docs/production-roadmap.md#current-verification-and-release-gates).

## Scope and expected protections

Reports can cover the native app, core library, connectors, build/release scripts,
and product website. Important assets include account tokens, workspace data,
selected documents and source files, action approvals, and update integrity.

Expected protections include loopback-only model requests; scoped document and
project access; explicit review before provider or browser actions; no automatic
replay of uncertain actions; and protection of stored credentials and workspace
data. Model output, mail, calendar entries, documents, and browser pages must not
grant themselves authority to bypass these controls.

See [data and runtime boundaries](README.md#data-and-runtime-boundaries) and the
[security testing report](docs/security-testing-2026-10-30.md) for implementation
context and known limitations. The [browser guide](docs/browser-use.md) records
open browser-write release gates. These reports are evidence for their tested
configurations, not a security certification or an exclusion of further reports.
