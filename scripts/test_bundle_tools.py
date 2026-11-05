import json
import importlib.util
from pathlib import Path
import tempfile
import shutil
import subprocess
import unittest
from unittest.mock import patch

import bundle_tools
import localization_config

spec = importlib.util.spec_from_file_location('verify_bundle', Path(__file__).with_name('verify-bundle.py'))
verify_bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_bundle)


class BundleToolsTests(unittest.TestCase):
    def testLocaleManifestAllowsAnotherLocaleAndRejectsDuplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Localization').mkdir()
            manifest = root / 'Localization/locales.json'
            manifest.write_text(json.dumps(['en', 'tr', 'fr']))
            self.assertEqual(localization_config.supported_locales(root), ['en', 'tr', 'fr'])
            for values in [[], ['en', 'en'], ['../outside'], ['en', 7]]:
                manifest.write_text(json.dumps(values))
                with self.assertRaises(ValueError):
                    localization_config.supported_locales(root)

    def testDuplicatePlistKeysAreRejected(self):
        with self.assertRaises(ValueError):
            bundle_tools.read_plist(b'<plist><dict><key>CFBundleDevelopmentRegion</key><string>en</string><key>CFBundleDevelopmentRegion</key><string>tr</string></dict></plist>')

    def testPublishingReplacesStaleResourcesAndFailureRestoresPreviousBundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, staged = root / 'Puddle.app', root / 'staging/Puddle.app'
            (old / 'Contents/Resources/stale.lproj').mkdir(parents=True)
            staged.mkdir(parents=True)
            (staged / 'fresh.txt').write_text('fresh')
            original_replace = bundle_tools.os.replace

            def fail_publish(source, destination):
                if source == staged:
                    raise OSError('Injected publication failure')
                original_replace(source, destination)

            with patch.object(bundle_tools.os, 'replace', side_effect=fail_publish):
                with self.assertRaises(OSError):
                    bundle_tools.publish_bundle(staged, old)
            self.assertTrue((old / 'Contents/Resources/stale.lproj').exists())
            bundle_tools.publish_bundle(staged, old)
            self.assertTrue((old / 'fresh.txt').exists())
            self.assertFalse((old / 'Contents').exists())

    def testInventoryRejectsStaleResourcesAndNestedLocales(self):
        with tempfile.TemporaryDirectory() as directory:
            resources = Path(directory)
            (resources / 'en.lproj').mkdir()
            package = resources / 'Puddle_PuddleCore.bundle'
            package.mkdir()
            verify_bundle.verify_resource_inventory(resources, ['en'])
            (resources / 'obsolete.txt').touch()
            with self.assertRaises(RuntimeError):
                verify_bundle.verify_resource_inventory(resources, ['en'])
            (resources / 'obsolete.txt').unlink()
            (package / 'obsolete.lproj').mkdir()
            with self.assertRaises(RuntimeError):
                verify_bundle.verify_resource_inventory(resources, ['en'])

    def testBuildRejectsStaleExportsBeforeCompilingOrReplacingAnApp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            for name in ['build.sh', 'localizations.py', 'localization_config.py']:
                shutil.copy(Path(__file__).with_name(name), scripts / name)
            (root / 'Localization').mkdir()
            (root / 'Localization/locales.json').write_text('["en"]')
            (root / 'Localization/Localizable.xcstrings').write_text('{"strings":{}}')
            (root / 'build/Puddle.app').mkdir(parents=True)
            marker = root / 'build/Puddle.app/keep.txt'
            marker.write_text('Existing usable app')
            result = subprocess.run(['/bin/sh', str(scripts / 'build.sh')], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Outdated resource', result.stdout + result.stderr)
            self.assertEqual(marker.read_text(), 'Existing usable app')


if __name__ == '__main__':
    unittest.main()
