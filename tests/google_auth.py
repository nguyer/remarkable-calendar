#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import stat
import tempfile
import unittest
import urllib.parse

spec = importlib.util.spec_from_file_location('google_auth', pathlib.Path(__file__).resolve().parents[1]/'scripts/google-auth.py')
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)

class AuthTests(unittest.TestCase):
    def test_pkce_scope_and_state(self):
        # RFC 7636 Appendix B known S256 test vector.
        verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
        url = auth.authorization_url('client', 'http://127.0.0.1:1234/callback', 'nonce', verifier)
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
        self.assertEqual(q['code_challenge'], ['E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'])
        self.assertEqual(q['state'], ['nonce'])
        self.assertEqual(q['scope'], [auth.SCOPE])
        self.assertEqual(q['access_type'], ['offline'])
    def test_private_file_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)/'google.json'
            auth.save_credentials(path, {'refresh_token':'test-only'})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                auth.save_credentials(path, {})
            self.assertEqual(json.loads(path.read_text()), {'refresh_token':'test-only'})

if __name__ == '__main__':
    unittest.main()
