from __future__ import annotations

import hashlib
import http.client
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from collections.abc import Iterator
from contextlib import contextmanager, redirect_stderr
from io import StringIO
from pathlib import Path

SCRIPT = Path(__file__).with_name("oracle_login_fixture.py")
SPEC = importlib.util.spec_from_file_location("firestorm_oracle_login_fixture", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
fixture_server = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = fixture_server
SPEC.loader.exec_module(fixture_server)


def _manifest_bytes(index_html: bytes, **overrides: object) -> bytes:
    manifest: dict[str, object] = {
        "schema": 1,
        "fixture_id": fixture_server.EXPECTED_FIXTURE_ID,
        "fixture_revision": fixture_server.EXPECTED_FIXTURE_REVISION,
        "assets": [
            {
                "path": "index.html",
                "bytes": len(index_html),
                "sha256": hashlib.sha256(index_html).hexdigest(),
            }
        ],
    }
    manifest.update(overrides)
    return json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _write_fixture(
    directory: Path, index_html: bytes = b"<p>fixture</p>\n", **overrides: object
) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "index.html").write_bytes(index_html)
    (directory / "manifest.json").write_bytes(_manifest_bytes(index_html, **overrides))


@contextmanager
def _running_server(fixture: object) -> Iterator[object]:
    server = fixture_server.build_server(fixture, port=0)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def _request(
    server: object, method: str, path: str
) -> tuple[int, dict[str, str], bytes]:
    host, port = server.server_address[:2]
    connection = http.client.HTTPConnection(host, port, timeout=2)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


class OracleLoginFixtureTest(unittest.TestCase):
    def test_checked_in_fixture_serves_exact_snapshot_and_ignores_page_query(
        self,
    ) -> None:
        fixture = fixture_server.load_fixture()
        fixture_directory = fixture_server.default_fixture_directory()
        self.assertEqual(
            fixture.index_html, (fixture_directory / "index.html").read_bytes()
        )
        self.assertEqual(
            fixture.manifest, (fixture_directory / "manifest.json").read_bytes()
        )

        with _running_server(fixture) as server:
            self.assertEqual(server.server_address[0], fixture_server.LOOPBACK_ADDRESS)
            status, headers, page = _request(
                server, "GET", fixture_server.LOGIN_PAGE_PATH
            )
            query_status, query_headers, query_page = _request(
                server,
                "GET",
                fixture_server.LOGIN_PAGE_PATH
                + "?lang=en&version=7.1.0&channel=Firestorm&grid=SecondLife",
            )
            head_status, head_headers, head_body = _request(
                server, "HEAD", fixture_server.LOGIN_PAGE_PATH
            )
            manifest_status, manifest_headers, manifest = _request(
                server, "GET", fixture_server.MANIFEST_PATH
            )
            manifest_head_status, manifest_head_headers, manifest_head_body = _request(
                server, "HEAD", fixture_server.MANIFEST_PATH
            )

        self.assertEqual((status, page), (200, fixture.index_html))
        self.assertEqual((query_status, query_page), (200, fixture.index_html))
        self.assertEqual(headers["Content-Length"], str(len(fixture.index_html)))
        self.assertEqual(query_headers["Content-Length"], str(len(fixture.index_html)))
        self.assertEqual((head_status, head_body), (200, b""))
        self.assertEqual(head_headers["Content-Length"], str(len(fixture.index_html)))
        self.assertEqual((manifest_status, manifest), (200, fixture.manifest))
        self.assertEqual(manifest_headers["Content-Length"], str(len(fixture.manifest)))
        self.assertEqual((manifest_head_status, manifest_head_body), (200, b""))
        self.assertEqual(
            manifest_head_headers["Content-Length"], str(len(fixture.manifest))
        )

    def test_server_uses_startup_snapshot_and_fixed_routes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture_directory = Path(temporary) / "login_ui"
            original_page = b"<p>original</p>\n"
            _write_fixture(fixture_directory, original_page)
            fixture = fixture_server.load_fixture(fixture_directory)
            original_manifest = fixture.manifest

            (fixture_directory / "index.html").write_bytes(b"<p>changed</p>\n")
            (fixture_directory / "manifest.json").write_bytes(b"{}")

            with _running_server(fixture) as server:
                self.assertEqual(
                    _request(server, "GET", fixture_server.LOGIN_PAGE_PATH)[2],
                    original_page,
                )
                self.assertEqual(
                    _request(server, "GET", fixture_server.MANIFEST_PATH)[2],
                    original_manifest,
                )
                self.assertEqual(_request(server, "GET", "/")[0], 404)
                self.assertEqual(
                    _request(server, "GET", "/login_ui/index.html/")[0], 404
                )
                status, headers, body = _request(
                    server, "POST", fixture_server.LOGIN_PAGE_PATH
                )
                trace_status, trace_headers, trace_body = _request(
                    server, "TRACE", fixture_server.LOGIN_PAGE_PATH
                )

        self.assertEqual((status, body), (405, b""))
        self.assertEqual(headers["Allow"], "GET, HEAD")
        self.assertEqual((trace_status, trace_body), (405, b""))
        self.assertEqual(trace_headers["Allow"], "GET, HEAD")

    def test_loader_rejects_tampering_malformed_manifest_and_unsafe_asset_paths(
        self,
    ) -> None:
        cases = {
            "wrong-page-hash": {
                "assets": [
                    {
                        "path": "index.html",
                        "bytes": 1,
                        "sha256": "0" * 64,
                    }
                ]
            },
            "wrong-identity": {"fixture_id": "other"},
            "wrong-revision": {"fixture_revision": "other"},
            "multiple-assets": {
                "assets": [
                    {
                        "path": "index.html",
                        "bytes": 0,
                        "sha256": "0" * 64,
                    },
                    {
                        "path": "index.html",
                        "bytes": 0,
                        "sha256": "0" * 64,
                    },
                ]
            },
            "unsafe-relative-path": {
                "assets": [
                    {
                        "path": "../index.html",
                        "bytes": 0,
                        "sha256": "0" * 64,
                    }
                ]
            },
            "unsafe-absolute-path": {
                "assets": [
                    {
                        "path": "/index.html",
                        "bytes": 0,
                        "sha256": "0" * 64,
                    }
                ]
            },
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, overrides in cases.items():
                with self.subTest(name=name):
                    fixture_directory = root / name
                    _write_fixture(fixture_directory, **overrides)
                    with self.assertRaises(fixture_server.FixtureError):
                        fixture_server.load_fixture(fixture_directory)

            malformed_directory = root / "malformed"
            malformed_directory.mkdir()
            (malformed_directory / "index.html").write_bytes(b"<p>fixture</p>\n")
            (malformed_directory / "manifest.json").write_bytes(b'{"schema":')
            with self.assertRaises(fixture_server.FixtureError):
                fixture_server.load_fixture(malformed_directory)

    def test_loader_rejects_file_changes_that_no_longer_match_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture_directory = Path(temporary) / "login_ui"
            _write_fixture(fixture_directory)
            (fixture_directory / "index.html").write_bytes(b"<p>tampered</p>\n")
            with self.assertRaises(fixture_server.FixtureError):
                fixture_server.load_fixture(fixture_directory)

    def test_build_server_rejects_non_loopback_port_values(self) -> None:
        fixture = fixture_server.LoginFixture(b"page", b"manifest")
        for port in (-1, 65536, True, "19472"):
            with (
                self.subTest(port=port),
                self.assertRaises(fixture_server.FixtureError),
            ):
                fixture_server.build_server(fixture, port=port)

    def test_cli_cannot_override_the_checked_in_fixture_directory(self) -> None:
        with StringIO() as stderr:
            with redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                fixture_server.main(["--fixture-dir", "."])
            self.assertEqual(raised.exception.code, 2)
            self.assertIn("unrecognized arguments", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
