# Localization

English is the only shipping locale. Turkish translations remain in the catalog
as work in progress and are not advertised or bundled until the remaining UI
literal debt is translated. This avoids presenting a mostly English application
as a supported Turkish localization.

Edit [Localizable.xcstrings](../Localization/Localizable.xcstrings) in Xcode or a
JSON editor. Shipping keys need complete English string units; preserve Turkish draft translations in the catalog.
Run:

```sh
python3 scripts/localizations.py
python3 scripts/localizations.py --check
sh scripts/swift.sh test --filter LocalizationTests
```

The exporter commits `.strings` resources for SwiftPM builds that do not invoke
Xcode's catalog compiler. CI rejects missing translations and stale exports.
`L10n.text` resolves strings from the package resource bundle; unknown keys keep
the readable English key. The app bundle includes the shipping locales and the package
resource bundle. The build also copies the same `.strings` exports into the main
app's shipping `.lproj` folders, where SwiftUI's literal `Text`, `Button`, `Label`
and other `LocalizedStringKey` initializers look them up. Both lookup paths use
the same catalog keys. `scripts/verify-bundle.py` requires identical catalog
exports in the main and package bundles. A bare `swift run` executable does not
have the assembled main app resources; use `make build` to review SwiftUI locale
behavior, or `L10n.text` for code that also needs SwiftPM-only lookup.

`scripts/localizations.py --check` also scans direct literals in SwiftUI view
initializers, navigation titles, alerts, help and accessibility labels, plus
`L10n.text` calls throughout `Sources`, including `PuddleCore`. It reports untranslated occurrences
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

Add supported locales to `Localization/locales.json` only after translating the catalog
entries and eliminating untranslated UI literals, then run the exporter. Export, build and verification read that manifest;
the build generates `CFBundleLocalizations` from it. `make build` checks exports
before compiling, assembles a fresh app, and replaces the previous bundle only
after signing succeeds. Verification rejects stale resources and locale folders.
Before translating interpolated text, define
format/plural keys in the catalog rather than concatenating translated fragments.

The exporter refuses any additional shipping locale while direct UI literals
remain untranslated, even if that debt appears in the baseline. Catalog work may
continue without adding a language to the shipping manifest.
