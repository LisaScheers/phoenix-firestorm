"""Serve the pinned, local login-page fixture for the OpenGL oracle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections.abc import Sequence
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

LOOPBACK_ADDRESS = "127.0.0.1"
DEFAULT_PORT = 19472
LOGIN_PAGE_PATH = "/login_ui/index.html"
MANIFEST_PATH = "/login_ui/manifest.json"
EXPECTED_FIXTURE_ID = "firestorm_metal_oracle_login"
EXPECTED_FIXTURE_REVISION = "v1-static-page"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class FixtureError(ValueError):
    """The checked-in login fixture does not satisfy its static contract."""


@dataclass(frozen=True)
class LoginFixture:
    """Immutable bytes captured from a validated fixture directory."""

    index_html: bytes
    manifest: bytes


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_fixture_directory() -> Path:
    return repository_root() / "doc/metal/oracle/fixtures/login_ui"


def _read_regular_file(path: Path, label: str) -> bytes:
    if path.is_symlink():
        raise FixtureError(f"{label} must not be a symbolic link: {path}")
    if not path.is_file():
        raise FixtureError(f"{label} must be a regular file: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise FixtureError(f"cannot read {label} {path}: {error}") from error


def _reject_json_constant(value: str) -> object:
    raise FixtureError(f"manifest must not contain non-finite JSON value {value!r}")


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise FixtureError(f"manifest contains duplicate key {key!r}")
        result[key] = value
    return result


def _parse_manifest(encoded: bytes) -> dict[str, object]:
    try:
        value = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=_unique_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FixtureError(f"cannot parse fixture manifest: {error}") from error
    if not isinstance(value, dict):
        raise FixtureError("fixture manifest must contain a JSON object")
    return value


def _require_exact_keys(
    value: dict[str, object], expected: set[str], label: str
) -> None:
    if set(value) != expected:
        raise FixtureError(
            f"{label} keys must be exactly {sorted(expected)!r}, got {sorted(value)!r}"
        )


def _validate_manifest(manifest: dict[str, object], index_html: bytes) -> None:
    _require_exact_keys(
        manifest,
        {"schema", "fixture_id", "fixture_revision", "assets"},
        "fixture manifest",
    )
    if type(manifest["schema"]) is not int or manifest["schema"] != 1:
        raise FixtureError("fixture manifest schema must be integer 1")
    if manifest["fixture_id"] != EXPECTED_FIXTURE_ID:
        raise FixtureError(
            f"fixture_id must be {EXPECTED_FIXTURE_ID!r}, got {manifest['fixture_id']!r}"
        )
    if manifest["fixture_revision"] != EXPECTED_FIXTURE_REVISION:
        raise FixtureError(
            "fixture_revision must be "
            f"{EXPECTED_FIXTURE_REVISION!r}, got {manifest['fixture_revision']!r}"
        )

    assets = manifest["assets"]
    if not isinstance(assets, list) or len(assets) != 1:
        raise FixtureError("fixture manifest must define exactly one asset")
    asset = assets[0]
    if not isinstance(asset, dict):
        raise FixtureError("fixture asset must be a JSON object")
    _require_exact_keys(asset, {"path", "bytes", "sha256"}, "fixture asset")
    if asset["path"] != "index.html":
        raise FixtureError("fixture asset path must be the safe literal 'index.html'")
    if type(asset["bytes"]) is not int or asset["bytes"] < 0:
        raise FixtureError("fixture asset bytes must be a non-negative integer")
    if asset["bytes"] != len(index_html):
        raise FixtureError(
            "fixture asset byte count does not match index.html: "
            f"{asset['bytes']} != {len(index_html)}"
        )
    expected_hash = asset["sha256"]
    if not isinstance(expected_hash, str) or not SHA256_PATTERN.fullmatch(
        expected_hash
    ):
        raise FixtureError(
            "fixture asset sha256 must be 64 lowercase hexadecimal digits"
        )
    actual_hash = hashlib.sha256(index_html).hexdigest()
    if expected_hash != actual_hash:
        raise FixtureError(
            "fixture asset sha256 does not match index.html: "
            f"{expected_hash} != {actual_hash}"
        )


def load_fixture(fixture_directory: Path | None = None) -> LoginFixture:
    """Validate and snapshot the checked-in fixture without retaining file paths."""

    directory = (
        default_fixture_directory()
        if fixture_directory is None
        else Path(fixture_directory)
    )
    if directory.is_symlink():
        raise FixtureError(
            f"fixture directory must not be a symbolic link: {directory}"
        )
    if not directory.is_dir():
        raise FixtureError(f"fixture directory must be a directory: {directory}")

    manifest = _read_regular_file(directory / "manifest.json", "fixture manifest")
    index_html = _read_regular_file(directory / "index.html", "fixture page")
    _validate_manifest(_parse_manifest(manifest), index_html)
    return LoginFixture(index_html=index_html, manifest=manifest)


class _FixtureRequestHandler(BaseHTTPRequestHandler):
    """Request handler whose fixture bytes are set by ``build_server``."""

    fixture: LoginFixture
    protocol_version = "HTTP/1.1"
    server_version = "FirestormOracleFixture/1.0"
    sys_version = ""

    def do_GET(self) -> None:
        self._serve(include_body=True)

    def do_HEAD(self) -> None:
        self._serve(include_body=False)

    def do_POST(self) -> None:
        self._method_not_allowed()

    def do_PUT(self) -> None:
        self._method_not_allowed()

    def do_DELETE(self) -> None:
        self._method_not_allowed()

    def do_OPTIONS(self) -> None:
        self._method_not_allowed()

    def do_PATCH(self) -> None:
        self._method_not_allowed()

    def __getattr__(self, name: str) -> object:
        if name.startswith("do_"):
            return self._method_not_allowed
        raise AttributeError(name)

    def _serve(self, include_body: bool) -> None:
        try:
            parsed = urlsplit(self.path)
        except ValueError:
            self._not_found()
            return
        if parsed.scheme or parsed.netloc:
            self._not_found()
            return
        if parsed.path == LOGIN_PAGE_PATH:
            self._respond(
                HTTPStatus.OK,
                "text/html; charset=utf-8",
                self.fixture.index_html,
                include_body,
            )
            return
        if parsed.path == MANIFEST_PATH:
            self._respond(
                HTTPStatus.OK,
                "application/json; charset=utf-8",
                self.fixture.manifest,
                include_body,
            )
            return
        self._not_found()

    def _respond(
        self, status: HTTPStatus, content_type: str, content: bytes, include_body: bool
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        if include_body:
            self.wfile.write(content)

    def _not_found(self) -> None:
        self._respond(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"", False)

    def _method_not_allowed(self) -> None:
        self.send_response(HTTPStatus.METHOD_NOT_ALLOWED)
        self.send_header("Allow", "GET, HEAD")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, message_format: str, *arguments: object) -> None:
        """Keep the fixture server silent during automated capture and tests."""


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False


def build_server(fixture: LoginFixture, port: int = DEFAULT_PORT) -> FixtureServer:
    """Bind a server exclusively to loopback; port zero is useful to tests."""

    if type(port) is not int or not 0 <= port <= 65535:
        raise FixtureError("port must be an integer between 0 and 65535")

    class RequestHandler(_FixtureRequestHandler):
        pass

    RequestHandler.fixture = fixture
    return FixtureServer((LOOPBACK_ADDRESS, port), RequestHandler)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Serve the deterministic local OpenGL-oracle login fixture."
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    arguments = parser.parse_args(argv)

    try:
        fixture = load_fixture()
        server = build_server(fixture, arguments.port)
    except (FixtureError, OSError) as error:
        parser.error(str(error))

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
