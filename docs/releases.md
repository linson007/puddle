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

The script verifies hardened signing, submits a ZIP, requires Apple's Accepted
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

Settings → Updates & Diagnostics verifies the pinned signature, newer build,
OS compatibility and SHA256 before offering Open Installer. Downloads cap128MB;
installation is manual. There is no background updater/automatic rollback.
Keep a previous signed installer and passphrase-encrypted workspace export.
Future schemas are preserved and rejected by incompatible older apps.

Before public distribution, test clean-Mac onboarding without developer tools,
Splash installation/download/offline restart, OAuth, permissions, capture,
dictation, upgrades, backup and rollback. Test wrong key/hash, interrupted
downloads, old builds and incompatible OS. Diagnostics are copy-only; no upload.
