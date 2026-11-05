#!/usr/bin/env python3
"""Export catalog strings and reject new untranslated UI literals against a baseline."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
from localization_config import supported_locales

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / 'Localization/ui-literals-baseline.json'
UI_CALLS = {
    'Text', 'Button', 'Label', 'Toggle', 'Picker', 'Section', 'GroupBox',
    'ContentUnavailableView', 'TextField', 'SecureField', 'ProgressView',
    'LabeledContent', 'Menu', 'Link', 'Window', 'WindowGroup',
    'navigationTitle', 'navigationSubtitle', 'help', 'accessibilityLabel',
    'accessibilityHint', 'alert', 'confirmationDialog',
}


def swift_string(source, start):
    """Read a quoted literal, including strings nested inside interpolation."""
    prefix = re.match(r'(#+)?("""|")', source[start:])
    if not prefix:
        raise ValueError('Expected Swift string literal')
    hashes = prefix.group(1) or ''
    quote = prefix.group(2) + hashes
    escape = '\\' + hashes
    index = start + prefix.end()
    content = index
    while index < len(source):
        if source.startswith(quote, index):
            return source[content:index], index + len(quote)
        if source.startswith(escape + '(', index):
            depth = 1
            index += len(escape) + 1
            while index < len(source) and depth:
                if source[index] == '"' or re.match(r'#+"', source[index:]):
                    _, index = swift_string(source, index)
                    continue
                if source[index] == '(':
                    depth += 1
                elif source[index] == ')':
                    depth -= 1
                index += 1
        elif source.startswith(escape, index):
            index += len(escape) + 1
        else:
            index += 1
    raise ValueError('Unterminated Swift string literal')


def literals(source):
    """Scan direct UI/L10n literals; ignore comments and strings containing code."""
    index = 0
    while index < len(source):
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end + 1
        elif source.startswith('/*', index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith('/*', index):
                    depth += 1
                    index += 2
                elif source.startswith('*/', index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        elif source[index] == '"' or (source[index] == '#' and re.match(r'#+"', source[index:])):
            _, index = swift_string(source, index)
        elif source[index].isalpha() or source[index] == '_':
            token = re.match(r'[\w]+', source[index:]).group()
            call = 'L10n.text' if token == 'text' and source[max(0, index - 5):index] == 'L10n.' else token
            end = index + len(token)
            if call in UI_CALLS or call == 'L10n.text':
                argument = re.match(r'\s*\(\s*(?:title:\s*)?', source[end:])
                if argument:
                    start = end + argument.end()
                    if source[start:start + 1] == '"' or re.match(r'#+"', source[start:]):
                        value, stop = swift_string(source, start)
                        if source[start] != '#' and '\\(' not in value:
                            try:
                                value = json.loads('"' + value + '"')
                            except ValueError:
                                pass
                        yield call, value, source.count('\n', 0, index) + 1
                        index = stop
                        continue
            index = end
        else:
            index += 1


def coverage(catalog, root=None):
    root = root or ROOT
    missing, locations = Counter(), {}
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = str(path.relative_to(root))
        for call, key, line in literals(path.read_text()):
            if key and key not in catalog['strings']:
                identity = (relative, call, key)
                missing[identity] += 1
                locations.setdefault(identity, line)
    return missing, locations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--update-baseline', action='store_true', help='Explicitly accept current untranslated UI debt')
    args = parser.parse_args()
    catalog = json.loads((ROOT / 'Localization/Localizable.xcstrings').read_text())
    locales = supported_locales(ROOT)
    for locale in locales:
        lines = ['/* Generated from Localization/Localizable.xcstrings. Run scripts/localizations.py. */']
        for key, entry in sorted(catalog['strings'].items()):
            unit = entry.get('localizations', {}).get(locale, {}).get('stringUnit', {})
            if unit.get('state') != 'translated' or not unit.get('value'):
                raise SystemExit(f'Missing {locale} translation: {key}')
            lines.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(unit["value"], ensure_ascii=False)};')
        expected = '\n'.join(lines) + '\n'
        target = ROOT / f'Sources/PuddleCore/Resources/{locale}.lproj/Localizable.strings'
        if args.check:
            if not target.exists() or target.read_text() != expected:
                raise SystemExit(f'Outdated resource: {target.relative_to(ROOT)}; run python3 scripts/localizations.py')
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(expected)
    missing, locations = coverage(catalog)
    if args.update_baseline:
        entries = [dict(path=path, call=call, key=key, count=count)
                   for (path, call, key), count in sorted(missing.items())]
        BASELINE.write_text('[\n' + ',\n'.join('  ' + json.dumps(entry, ensure_ascii=False) for entry in entries) + '\n]\n')
    baseline = Counter({(entry['path'], entry['call'], entry['key']): entry['count']
                        for entry in json.loads(BASELINE.read_text())}) if BASELINE.exists() else Counter()
    additions = missing - baseline
    print(f'Localization coverage: {sum(missing.values())} untranslated UI literal occurrences '
          f'({len(missing)} distinct sites); {sum(additions.values())} above baseline.')
    if additions:
        for (path, call, key), count in sorted(additions.items()):
            print(f'{path}:{locations[(path, call, key)]}: {call}({key!r}) missing from catalog (+{count})')
        raise SystemExit('Add catalog translations for new UI strings and run scripts/localizations.py.')
    print(f'Translations for {", ".join(locales)} are complete and synchronized; UI coverage baseline passed.')


if __name__ == '__main__':
    main()
