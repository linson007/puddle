import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import localizations


class LocalizationGuardTests(unittest.TestCase):
    def testScannerIgnoresCommentsAndCodeInsideStrings(self):
        source = '''// Text("comment")
        /* Button("also comment") /* Text("nested comment") */ */
        let source = "Text(\\"not UI\\")"
        Text("Today"); Button("New action") {}
        '''
        self.assertEqual([(call, key) for call, key, _ in localizations.literals(source)],
                         [('Text', 'Today'), ('Button', 'New action')])

    def testScannerIncludesInterpolatedAndMultilineLabels(self):
        source = 'Text("Count: \\(value ?? "unknown")"); Text("""Long\nlabel"""); .help("Hint")'
        values = [(call, key) for call, key, _ in localizations.literals(source)]
        self.assertEqual(values, [('Text', 'Count: \\(value ?? "unknown")'), ('Text', 'Long\nlabel'), ('help', 'Hint')])

    def testNewLiteralsAndExtraOccurrencesFailWhileCatalogKeysResolve(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Localization').mkdir()
            (root / 'Sources/Puddle').mkdir(parents=True)
            catalog = {'strings': {'Today': {'localizations': {
                locale: {'stringUnit': {'state': 'translated', 'value': value}}
                for locale, value in [('en', 'Today'), ('tr', 'Bugün')]
            }}}}
            (root / 'Localization/Localizable.xcstrings').write_text(json.dumps(catalog))
            ui = root / 'Sources/Puddle/Screen.swift'
            ui.write_text('Text("Legacy debt")')
            with patch.object(localizations, 'ROOT', root), \
                 patch.object(localizations, 'BASELINE', root / 'Localization/baseline.json'), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.run_export('--update-baseline')
                ui.write_text('Text("Legacy debt"); Text("Today")')
                self.run_export('--check')
                ui.write_text('Text("Legacy debt"); Text("New untranslated title")')
                with self.assertRaises(SystemExit):
                    self.run_export('--check')
                ui.write_text('Text("Legacy debt"); Text("Legacy debt")')
                with self.assertRaises(SystemExit):
                    self.run_export('--check')
                ui.write_text('L10n.text("Missing lookup key")')
                with self.assertRaises(SystemExit):
                    self.run_export('--check')
                ui.write_text('Text("Today")')
                self.run_export('--check')
                catalog['strings']['Today']['localizations'].pop('tr')
                (root / 'Localization/Localizable.xcstrings').write_text(json.dumps(catalog))
                with self.assertRaises(SystemExit):
                    self.run_export('--check')

    @staticmethod
    def run_export(*arguments):
        with patch('sys.argv', ['localizations.py', *arguments]):
            localizations.main()


if __name__ == '__main__':
    unittest.main()
