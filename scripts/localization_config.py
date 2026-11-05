"""Single locale manifest shared by export, build and verification tools."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def supported_locales(root=ROOT):
    locales = json.loads((root / 'Localization/locales.json').read_text())
    if (not isinstance(locales, list) or not locales or
            any(not isinstance(value, str) or not re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z0-9]+)*', value) for value in locales) or
            len(set(locales)) != len(locales)):
        raise ValueError('Localization/locales.json must contain unique locale identifiers.')
    return locales


if __name__ == '__main__':
    print('\n'.join(supported_locales()))
