#!/usr/bin/env python3
"""Require a nearby synchronization invariant for unchecked production Sendable."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
violations = []
for path in (root / 'Sources').rglob('*.swift'):
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        if '@unchecked Sendable' in line and 'Sendable invariant:' not in '\n'.join(lines[max(0, index - 6):index]):
            violations.append(f'{path.relative_to(root)}:{index + 1}: document the Sendable invariant')
if violations:
    raise SystemExit('\n'.join(violations))
print('All unchecked Sendable declarations document their synchronization invariant.')
