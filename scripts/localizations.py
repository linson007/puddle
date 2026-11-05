#!/usr/bin/env python3
"""Export portable SwiftPM strings from the String Catalog; CI checks completeness."""
import argparse
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
catalog = json.loads((root / 'Localization/Localizable.xcstrings').read_text())
for locale in ('en', 'tr'):
    lines = ['/* Generated from Localization/Localizable.xcstrings. Run scripts/localizations.py. */']
    for key, entry in sorted(catalog['strings'].items()):
        unit = entry.get('localizations', {}).get(locale, {}).get('stringUnit', {})
        if unit.get('state') != 'translated' or not unit.get('value'):
            raise SystemExit(f'Missing {locale} translation: {key}')
        lines.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(unit["value"], ensure_ascii=False)};')
    expected = '\n'.join(lines) + '\n'
    target = root / f'Sources/PuddleCore/Resources/{locale}.lproj/Localizable.strings'
    if args.check:
        if not target.exists() or target.read_text() != expected:
            raise SystemExit(f'Outdated resource: {target.relative_to(root)}; run python3 scripts/localizations.py')
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(expected)
print('English and Turkish translations are complete and synchronized.')
