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
            (root / 'Localization/locales.json').write_text('["en"]')
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
                (root / 'Sources/PuddleCore').mkdir(exist_ok=True)
                (root / 'Sources/PuddleCore/Notice.swift').write_text('L10n.text("Missing core notice")')
                with self.assertRaises(SystemExit):
                    self.run_export('--check')
                catalog['strings']['Today']['localizations'].pop('en')
                (root / 'Localization/Localizable.xcstrings').write_text(json.dumps(catalog))
                with self.assertRaises(SystemExit):
                    self.run_export('--check')

    @staticmethod
    def run_export(*arguments):
        with patch('sys.argv', ['localizations.py', *arguments]):
            localizations.main()

    def testAdditionalShippingLocaleCannotUseUntranslatedBaselineDebt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Localization').mkdir()
            (root / 'Localization/locales.json').write_text('["en", "tr"]')
            (root / 'Localization/Localizable.xcstrings').write_text(json.dumps({'strings': {}}))
            (root / 'Sources/Puddle').mkdir(parents=True)
            (root / 'Sources/Puddle/Screen.swift').write_text('Text("Untranslated screen")')
            with patch.object(localizations, 'ROOT', root), patch.object(localizations, 'BASELINE', root / 'baseline.json'):
                with self.assertRaisesRegex(SystemExit, 'complete UI coverage'):
                    self.run_export('--update-baseline')

    def testRawStringsDoNotConfuseCoverage(self):
        source = 'let json = #"{"name":"Text(ignored)"}"#; Text(#"Visible raw title"#); L10n.text("Core notice")'
        self.assertEqual([(call, key) for call, key, _ in localizations.literals(source)],
                         [('Text', 'Visible raw title'), ('L10n.text', 'Core notice')])

    def testExporterUsesNewLocaleFromManifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Localization').mkdir()
            (root / 'Localization/locales.json').write_text('["fr"]')
            (root / 'Localization/Localizable.xcstrings').write_text(json.dumps({'strings': {
                'Today': {'localizations': {'fr': {'stringUnit': {'state': 'translated', 'value': "Aujourd’hui"}}}}
            }}))
            with patch.object(localizations, 'ROOT', root), patch.object(localizations, 'BASELINE', root / 'baseline.json'), contextlib.redirect_stdout(io.StringIO()):
                self.run_export()
                self.run_export('--check')
            self.assertIn('Aujourd’hui', (root / 'Sources/PuddleCore/Resources/fr.lproj/Localizable.strings').read_text())


if __name__ == '__main__':
    unittest.main()
