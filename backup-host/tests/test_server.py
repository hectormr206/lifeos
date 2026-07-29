"""Behavioural tests for the VPN-only backup host.

Standard library only, on purpose: this service runs on a VPS that has no
project virtualenv, so `python3 -m unittest` must be enough to verify it
anywhere — the VPS, a laptop, or CI.
"""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server import BackupStore, make_handler  # noqa: E402

TOKEN = "test-token-0123456789abcdef"


class ServerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        store = BackupStore(self.root, max_bytes=1024 * 1024)
        handler = make_handler(store=store, token=TOKEN)
        # Port 0: the OS picks a free one, so tests never collide.
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)
        self._tmp.cleanup()

    # ---------------------------------------------------------------- helpers
    def request(self, method, path, *, body=None, token=TOKEN):
        req = urllib.request.Request(f"{self.base}{path}", data=body, method=method)
        if token is not None:
            req.add_header("X-LifeOS-Backup-Key", token)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    # ------------------------------------------------------------------ auth
    def test_upload_without_the_key_is_refused(self):
        status, _ = self.request("PUT", "/v1/backups/a.lifeos", body=b"x", token=None)
        self.assertEqual(status, 401)

    def test_upload_with_a_wrong_key_is_refused(self):
        status, _ = self.request("PUT", "/v1/backups/a.lifeos", body=b"x", token="nope")
        self.assertEqual(status, 401)

    def test_a_refused_upload_writes_nothing(self):
        self.request("PUT", "/v1/backups/a.lifeos", body=b"x", token="nope")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_listing_without_the_key_is_refused(self):
        status, _ = self.request("GET", "/v1/backups", token=None)
        self.assertEqual(status, 401)

    # --------------------------------------------------------------- storage
    def test_uploaded_bytes_round_trip_unchanged(self):
        payload = bytes(range(256)) * 8

        status, _ = self.request("PUT", "/v1/backups/graph.lifeos", body=payload)
        self.assertEqual(status, 201)

        status, body = self.request("GET", "/v1/backups/graph.lifeos")
        self.assertEqual(status, 200)
        self.assertEqual(body, payload)

    def test_listing_reports_name_and_size(self):
        self.request("PUT", "/v1/backups/one.lifeos", body=b"abc")

        status, body = self.request("GET", "/v1/backups")
        self.assertEqual(status, 200)
        entries = json.loads(body)["backups"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["name"], "one.lifeos")
        self.assertEqual(entries[0]["sizeBytes"], 3)
        self.assertIn("modifiedAt", entries[0])

    def test_a_second_upload_replaces_the_first(self):
        self.request("PUT", "/v1/backups/graph.lifeos", body=b"old")
        self.request("PUT", "/v1/backups/graph.lifeos", body=b"new")

        _, body = self.request("GET", "/v1/backups/graph.lifeos")
        self.assertEqual(body, b"new")

    def test_a_failed_upload_leaves_no_partial_file(self):
        # Larger than max_bytes: the request is rejected, and no truncated
        # file may survive to be restored later as if it were whole.
        oversized = b"x" * (1024 * 1024 + 1)

        status, _ = self.request("PUT", "/v1/backups/big.lifeos", body=oversized)

        self.assertEqual(status, 413)
        self.assertEqual(list(self.root.glob("*")), [])

    def test_missing_backup_is_404_not_an_error_page(self):
        status, _ = self.request("GET", "/v1/backups/absent.lifeos")
        self.assertEqual(status, 404)

    # ------------------------------------------------------------- filenames
    def test_path_traversal_is_refused(self):
        for name in ("../escape.lifeos", "..%2Fescape.lifeos", "a/b.lifeos"):
            with self.subTest(name=name):
                status, _ = self.request("PUT", f"/v1/backups/{name}", body=b"x")
                self.assertIn(status, (400, 404))
        # Nothing may exist outside the store root.
        self.assertFalse((self.root.parent / "escape.lifeos").exists())

    def test_absurd_names_are_refused(self):
        # A space cannot even be put on the wire by a conforming client, so it
        # is covered at the store level below rather than over HTTP.
        for name in ("", ".", "..", "x" * 200, "weird$.lifeos"):
            with self.subTest(name=name):
                status, _ = self.request("PUT", f"/v1/backups/{name}", body=b"x")
                self.assertIn(status, (400, 404))

    # ----------------------------------------------------------------- store
    def test_store_rejects_traversal_directly(self):
        store = BackupStore(self.root, max_bytes=1024)
        with self.assertRaises(ValueError):
            store.path_for("../evil")

    def test_store_rejects_names_no_client_could_send(self):
        store = BackupStore(self.root, max_bytes=1024)
        for name in ("sp ace.lifeos", "tab\t.lifeos", "nul\x00.lifeos", "/abs"):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    store.path_for(name)


if __name__ == "__main__":
    unittest.main()
