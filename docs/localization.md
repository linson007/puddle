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
resource bundle. The build also copies the same `.strings` exports into the main
app's `en.lproj` and `tr.lproj`, where SwiftUI's literal `Text`, `Button`, `Label`
and other `LocalizedStringKey` initializers look them up. Both lookup paths use
the same catalog keys. `scripts/verify-bundle.py` requires identical catalog
exports in the main and package bundles. A bare `swift run` executable does not
have the assembled main app resources; use `make build` to review SwiftUI locale
behavior, or `L10n.text` for code that also needs SwiftPM-only lookup.

`scripts/localizations.py --check` also scans direct literals in SwiftUI view
initializers, navigation titles, alerts, help and accessibility labels, plus
`L10n.text` calls under `Sources/Puddle`. It reports untranslated occurrences
against [the committed baseline](../Localization/ui-literals-baseline.json).
Baseline identities contain file, call, English key and occurrence count, so a
new key or another use of existing untranslated text fails CI without depending
on line numbers. Add translated English/Turkish catalog entries and regenerate
the exports for new UI strings. Use explicit format/plural keys for interpolated
labels; do not add source interpolation syntax as a catalog key.

The baseline records existing translation debt, not completed translation. The
scanner is a guard for direct call-site literals, not a Swift type checker:
dynamic strings, custom view APIs and provider text still need code review.
When deliberately accepting or reducing existing debt, run
`python3 scripts/localizations.py --update-baseline` and review the baseline diff.
Do not regenerate it simply to pass CI for new untranslated labels. Scanner and
negative CI cases run with `python3 -m unittest discover -s scripts -p 'test_*.py'`.

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
