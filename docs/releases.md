# Release and Microsoft connection setup

`make build` creates an ad hoc signed local app. It does not publish or notarize
without owner configuration.

## Outlook

Register a Microsoft Entra public/native desktop application with the intended
account audience and `http://localhost/oauth/callback` mobile/desktop redirect.
Puddle uses an ephemeral port, IPv4-loopback listener, PKCE/state and no client
secret. See Microsoft's [redirect URI rules](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).
Request delegated `User.Read`, `Mail.Read`, `offline_access`, `openid`, `profile`;
optional `Mail.Send` and `Mail.ReadWrite` are separately selected in Puddle.
Organization policy may require administrator consent. Do not grant application-wide mailbox access.

Supply `PUDDLE_MICROSOFT_CLIENT_ID` at build time, or enter the public UUID in
Settings → Connections → Outlook. Tenant accepts common/organizations/consumers
or a directory UUID. Accounts are explicitly switched; Google remains the
calendar provider. Test personal/organizational accounts, denied/partial consent,
refresh, revocation and disconnect. Graph202 means send accepted, not delivered.

## Developer ID release

Provision a Developer ID Application identity and a `notarytool` Keychain profile:

```sh
PUDDLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
PUDDLE_NOTARY_PROFILE='puddle-notary' \
PUDDLE_VERSION=0.2.0 PUDDLE_BUILD_NUMBER=2 sh scripts/release.sh
```

The script runs the full bundle verifier before notarization and after stapling,
verifies hardened signing, submits a ZIP, requires Apple's Accepted
result, staples/validates, runs Gatekeeper assessment and creates an archive plus
SHA256SUMS in a new build/releases/VERSION-BUILD directory. Existing outputs are
preserved. See [Apple notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Signed manual update feed

Generate an Ed25519 key outside the repository; output prints the public key only:

```sh
swift scripts/release-manifest.swift --generate-key /private/secure/puddle-update-key
```

Build with `PUDDLE_UPDATE_MANIFEST_URL` (HTTPS) and `PUDDLE_UPDATE_PUBLIC_KEY`
(base64 public key). Keep the private key out of source control/support bundles.
After notarization, sign metadata for the final archive:

```sh
PUDDLE_UPDATE_SIGNING_KEY_FILE=/private/secure/puddle-update-key \
  swift scripts/release-manifest.swift \
  build/releases/0.2.0-2/Puddle-0.2.0.zip 0.2.0 2 \
  https://your-domain.example/releases/Puddle-0.2.0.zip /private/output/manifest.json
```

Publish the archive before the manifest in a separate owner-controlled step.
Scripts do not upload them. Protect/back up the private key; changing the pinned
key needs a separately trusted application update.

Alternatively set `PUDDLE_UPDATE_SIGNING_KEY_FILE` and
`PUDDLE_RELEASE_DOWNLOAD_URL` when running `release.sh` to generate
`manifest.json` alongside the final stapled archive. The manifest tool extracts
the archive, checks its version/build and embedded update public key against the
requested release and signing key, verifies the archived app signature, then
signs and checks the manifest. A mismatched archive/key/version fails closed.
Use an immutable URL containing both version and build; never replace its bytes.

After uploading that archive, smoke-test its public URL before promoting the feed:

```sh
swift scripts/verify-release.swift \
  build/releases/0.2.0-2/Puddle-0.2.0.zip \
  build/releases/0.2.0-2/manifest.json BASE64_PINNED_PUBLIC_KEY
```

This checks the manifest signature, local checksum and an independently fetched,
bounded HTTPS archive without credentials or redirects. Promote the exact tested
manifest only after the remote bytes match and the acceptance record is complete.

## Pilot, pause and recovery runbook

Keep separate owner-controlled pilot and stable manifest URLs. The URL pinned in
each app chooses its channel. Start with a small invited pilot; advance to stable
only after reviewing install, setup, provider, save/restore and accessibility
acceptance. No automatic cohort assignment or telemetry is implemented.

For a bad update, stop promotion immediately. At the affected manifest URL, restore
the last known-good signed manifest (old builds will not be offered as an update),
or make the feed unavailable while investigating. Preserve immutable installers,
manifests, notarization records and checksums. Already downloaded installers cannot
be recalled; notify affected testers through the established support channel.

Rollback is manual: quit, retain the complete workspace directory, install the
previous signed app, and restore a backup that its schema can read. Never ask an
older binary to rewrite a newer workspace. Rehearse this on a disposable clean Mac
before promotion. Name a release operator and a monitored security/support owner,
publish supported versions and response targets, and confirm private reporting is
enabled. Those are owner prerequisites, not services this repository provisions.

Settings → Updates & Diagnostics verifies the pinned signature, newer build,
OS compatibility and SHA256 before offering Open Installer. Downloads cap128MB;
installation is manual. There is no background updater/automatic rollback.
Check/download work can be cancelled and ends when the Updates view is dismissed
or external connections become unavailable. A failed check clears an earlier
offer; downloads are also gated while locked or paused. The checksum is checked
again immediately before opening an installer. Failed/cancelled downloads do not
produce an offered installer, and a changed file requires another download.
Keep a previous signed installer and passphrase-encrypted workspace export.
Future schemas are preserved and rejected by incompatible older apps.

Before public distribution, test clean-Mac onboarding without developer tools,
connection to a separately installed local model provider and offline restart, OAuth, permissions, capture,
dictation, upgrades, backup and rollback. Test wrong key/hash, interrupted
downloads, old builds and incompatible OS. Diagnostics are copy-only; no upload.
Local bundle-pinned feed/signature/hash, interruption, pause, stale-result,
changed-installer and retry workflows run in `ReleaseUpdateWorkflowTests` with
synthetic metadata and a disposable download folder. `make verify-local` covers
these alongside the live local checks; actual HTTPS hosting, Developer ID,
notarization and clean-Mac install/upgrade remain owner-environment gates.
