"""Self-test for the relay's housekeeping: python3 relay/test_relay.py

Runs without Apple keys or the relay's dependencies (httpx and jwt are stubbed),
and checks that counters, rejected tokens and the revoked list really expire.
"""
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_tmp = tempfile.mkdtemp()
_key = os.path.join(_tmp, "key.p8")
open(_key, "w").write("not a real key")
os.environ.update(APNS_KEY_PATH=_key, APNS_KEY_ID="TEST", APNS_TEAM_ID="TEST", STATE_DIRECTORY=_tmp)

httpx = types.ModuleType("httpx")
httpx.Client = lambda **kw: None
httpx.HTTPError = Exception
sys.modules["httpx"] = httpx
sys.modules["jwt"] = types.ModuleType("jwt")
sys.path.insert(0, HERE)
import relay


class Housekeeping(unittest.TestCase):
    def setUp(self):
        relay._recent.clear()
        relay._overall.clear()
        relay._rejected.clear()

    def test_rate_windows_expire_after_a_minute(self):
        relay._recent["token-a"] = [1000.0]
        relay._recent["token-b"] = [1050.0]
        relay._overall[:] = [1000.0, 1050.0]
        relay.sweep(now=1070.0)
        self.assertNotIn("token-a", relay._recent)
        self.assertIn("token-b", relay._recent)
        self.assertEqual(relay._overall, [1050.0])

    def test_rejected_tokens_expire_after_a_day(self):
        relay._rejected["old"] = 0.0
        relay._rejected["new"] = 24 * 3600 - 10.0
        relay.sweep(now=24 * 3600 + 1.0)
        self.assertNotIn("old", relay._rejected)
        self.assertIn("new", relay._rejected)

    def test_revoked_list_keeps_one_year(self):
        now = relay.CREDENTIAL_SECONDS * 3.0
        data = {"expired": now - relay.CREDENTIAL_SECONDS - 1, "recent": now - 60}
        self.assertEqual(relay.prune_revoked(data, now=now), {"recent": now - 60})

    def test_revoke_writes_a_pruned_file(self):
        relay._revoked.clear()
        relay._revoked["ancient"] = 0.0
        relay.revoke_token("fresh")
        self.assertNotIn("ancient", relay._revoked)
        self.assertIn("fresh", relay._revoked)
        self.assertEqual(set(relay._load_revoked()), {"fresh"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
