import unittest
from pathlib import Path


class SharedTestSupportTests(unittest.TestCase):
    def test_async_gate_copies_stay_identical(self):
        root = Path(__file__).resolve().parent.parent
        self.assertEqual((root / 'Tests/PuddleAppTests/AsyncTestGate.swift').read_bytes(),
                         (root / 'Tests/PuddleCoreTests/AsyncTestGate.swift').read_bytes())
