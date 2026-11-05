# Localization

English is the source language. Turkish is the first additional locale. The
initial scope covers primary navigation, common buttons, local AI setup,
settings, meeting capture controls and common recovery errors. Detailed provider
instructions, specialist screens, dynamic provider errors and generated text may
still use English. This is an incremental translation, not a claim that every
screen is fully translated. User content, persistent enum values, protocol keys
and model identifiers must retain their original values.

Edit [Localizable.xcstrings](../Localization/Localizable.xcstrings) in Xcode or a
JSON editor. Each scoped key needs translated English and Turkish string units.
Run:

```sh
python3 scripts/localizations.py
python3 scripts/localizations.py --check
sh scripts/swift.sh test --filter LocalizationTests
```

The exporter commits `.strings` resources for SwiftPM builds that do not invoke
Xcode's catalog compiler. CI rejects missing translations and stale exports.
`L10n.text` resolves strings from the package resource bundle; unknown keys keep
the readable English key. The app bundle includes both locales and the package
resource bundle. `scripts/verify-bundle.py` checks the shipped resources.

To review Turkish, select it for Puddle in macOS System Settings → General →
Language & Region → Applications, or launch a separate demo instance:

```sh
open -n build/Puddle.app --args --demo -AppleLanguages '(tr)'
```

Check sidebar, Settings, task actions, local AI setup, meeting controls and error
layout. Switching language must not rename saved tasks, memories or profiles.
Add new locales to the exporter, package resources and app's
`CFBundleLocalizations` together. Before translating interpolated text, define
format/plural keys in the catalog rather than concatenating translated fragments.
