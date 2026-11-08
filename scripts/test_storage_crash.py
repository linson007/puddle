"""Abrupt child-process exit drills for the production durability/lock primitives."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(sys.platform == 'darwin', 'macOS durability primitives')
class StorageCrashTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix='puddle-storage-tools-')
        cls.binary = Path(cls.tools.name) / 'probe'
        main = Path(cls.tools.name) / 'main.swift'
        main.write_text('''import Darwin
import Foundation
struct PuddleError: Error { let message: String; init(_ message: String) { self.message = message } }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard root.lastPathComponent.hasPrefix("puddle-storage-crash-") else { exit(64) }
let ownership = try WorkspaceFileLock(directory: root)
let phase = CommandLine.arguments[2], file = root.appendingPathComponent("generation")
if phase == "read" { print(String(decoding: try Data(contentsOf: file), as: UTF8.self)); exit(0) }
try DurableFile.write(Data((phase == "initial" ? "old" : "new").utf8), to: file) { stage in
    if (phase == "before" && stage == .beforeRename) || (phase == "after" && stage == .afterRename) { _exit(73) }
}
''')
        subprocess.run(['swiftc', '-module-cache-path', str(ROOT / '.build/module-cache'),
                        str(ROOT / 'Sources/PuddleCore/DurableFile.swift'), str(main), '-o', str(cls.binary)],
                       check=True, capture_output=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def test_abrupt_exit_keeps_whole_generation_and_releases_process_lock(self):
        for phase, expected in [('before', 'old'), ('after', 'new')]:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory(prefix='puddle-storage-crash-') as folder:
                subprocess.run([str(self.binary), folder, 'initial'], check=True, capture_output=True, timeout=10)
                crash = subprocess.run([str(self.binary), folder, phase], capture_output=True, timeout=10)
                self.assertEqual(crash.returncode, 73, crash.stderr)
                reopened = subprocess.run([str(self.binary), folder, 'read'], check=True,
                                          capture_output=True, text=True, timeout=10)
                self.assertEqual(reopened.stdout.strip(), expected)
                # Before rename, abrupt exit deliberately skips temporary cleanup.
                leftovers = list(Path(folder).glob('.puddle-write-*'))
                self.assertEqual(len(leftovers), 1 if phase == 'before' else 0)


if __name__ == '__main__':
    unittest.main()
