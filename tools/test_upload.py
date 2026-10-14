"""Offline tests. No RPC, wallet, original art, upload or lock is used."""
import unittest
from plan_upload import digest, verify_and_plan


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.data = b"// synthetic tooling test; no artwork\n" * 300
        self.empty = {"uploadVersion": 0, "uploadedBytes": 0, "expectedBytes": 0,
                      "expectedHash": "0x" + "00" * 32, "scriptLocked": False, "chunkCount": 0}

    def state(self, chunks, locked=False):
        return dict(self.empty, uploadVersion=1, expectedBytes=len(self.data), expectedHash=digest(self.data),
                    uploadedBytes=sum(map(len, chunks)), chunkCount=len(chunks), scriptLocked=locked)

    def test_new_plan_and_partial_resume(self):
        p = verify_and_plan(self.data, self.empty, [])
        self.assertEqual(p["transactions"][0]["operation"], "beginUpload")
        self.assertEqual(p["uploadVersion"], 1)
        prefix = [self.data[:8192]]
        resumed = verify_and_plan(self.data, self.state(prefix), prefix)
        self.assertEqual(len(resumed["transactions"]), 1)
        self.assertEqual(resumed["transactions"][0]["index"], 1)
        self.assertEqual(resumed["verifiedPrefixBytes"], 8192)

    def test_exact_complete_and_locked_are_idempotent(self):
        chunks = [self.data[:8192], self.data[8192:]]
        p = verify_and_plan(self.data, self.state(chunks), chunks)
        self.assertEqual(p["transactions"], [])
        self.assertIsNotNone(p["separateLockCandidate"])
        p = verify_and_plan(self.data, self.state(chunks, True), chunks)
        self.assertEqual(p["transactions"], [])
        self.assertIsNone(p["separateLockCandidate"])

    def test_corrupt_prefix_rejected(self):
        with self.assertRaises(ValueError):
            verify_and_plan(self.data, self.state([b"wrong"]), [b"wrong"])

    def test_different_upload_requires_restart(self):
        state = self.state([])
        state["expectedHash"] = digest(b"different")
        with self.assertRaises(ValueError):
            verify_and_plan(self.data, state, [])
        p = verify_and_plan(self.data, state, [], restart=True)
        self.assertEqual(p["uploadVersion"], 2)

    def test_stale_count_and_lengths_rejected(self):
        state = self.state([self.data[:4]])
        with self.assertRaises(ValueError):
            verify_and_plan(self.data, state, [])
        state["uploadedBytes"] += 1
        with self.assertRaises(ValueError):
            verify_and_plan(self.data, state, [self.data[:4]])

    def test_full_size_script_does_not_exceed_process_argument_limit(self):
        data = b"x" * 131072
        p = verify_and_plan(data, self.empty, [])
        self.assertEqual(p["scriptBytes"], 131072)
        self.assertEqual(len(p["transactions"]), 17)
        self.assertEqual(p["transactions"][-1]["bytes"], 8192)
        self.assertEqual(len(p["scriptKeccak256"]), 66)

    def test_excessively_fragmented_upload_rejected(self):
        with self.assertRaises(ValueError):
            verify_and_plan(self.data, self.empty, [], chunk_size=1)

    def test_size_and_lock_mismatch_rejected(self):
        for data in (b"", b"x" * 131073):
            with self.assertRaises(ValueError): verify_and_plan(data, self.empty, [])
        state = self.state([], True)
        with self.assertRaises(ValueError): verify_and_plan(b"different", state, [])
        with self.assertRaises(ValueError): verify_and_plan(self.data, state, [], restart=True)


if __name__ == "__main__":
    unittest.main()
