from __future__ import annotations

import copy
import hashlib
import importlib.util
import itertools
import json
import math
import os
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("oracle.py")
SPEC = importlib.util.spec_from_file_location("firestorm_metal_oracle", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
oracle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(oracle)


def _chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def _png_bytes(
    width: int = 4,
    height: int = 3,
    pixel: tuple[int, ...] = (0, 0, 0, 255),
    *,
    color_type: int = 6,
    include_srgb: bool = True,
    before_idat: tuple[tuple[bytes, bytes], ...] = (),
    between_idat: tuple[tuple[bytes, bytes], ...] = (),
    after_idat: tuple[tuple[bytes, bytes], ...] = (),
    filter_type: int = 0,
    compressed: bytes | None = None,
    trailing: bytes = b"",
) -> bytes:
    channels = 3 if color_type == 2 else 4
    if len(pixel) != channels:
        raise ValueError("pixel does not match PNG color type")
    scanlines = bytes([filter_type]) + bytes(pixel) * width
    payload = zlib.compress(scanlines * height) if compressed is None else compressed
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    result = bytearray(b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header))
    if include_srgb:
        result.extend(_chunk(b"sRGB", b"\0"))
    for kind, data in before_idat:
        result.extend(_chunk(kind, data))
    if between_idat:
        split = max(1, len(payload) // 2)
        result.extend(_chunk(b"IDAT", payload[:split]))
        for kind, data in between_idat:
            result.extend(_chunk(kind, data))
        result.extend(_chunk(b"IDAT", payload[split:]))
    else:
        result.extend(_chunk(b"IDAT", payload))
    for kind, data in after_idat:
        result.extend(_chunk(kind, data))
    result.extend(_chunk(b"IEND", b""))
    result.extend(trailing)
    return bytes(result)


def _write_png(
    path: Path,
    width: int = 4,
    height: int = 3,
    pixel: tuple[int, ...] = (0, 0, 0, 255),
    *,
    color_type: int = 6,
) -> None:
    path.write_bytes(_png_bytes(width, height, pixel, color_type=color_type))


def _git(repository: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repository), "-c", "commit.gpgsign=false", *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


class OracleCorpusTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest_path = oracle.repository_root() / "doc/metal/oracle-corpus.json"
        cls.manifest = oracle.load_manifest(cls.manifest_path)

    @staticmethod
    def _copy_available_fixtures(
        manifest: dict[str, object], fixture_root: Path, excluded_slot_id: str
    ) -> None:
        for slot in manifest["slots"]:
            content = slot["conditions"]["content"]
            if slot["id"] == excluded_slot_id or content["availability"] != "available":
                continue
            source_manifest = oracle.repository_root() / content["asset_manifest_path"]
            fixture = json.loads(source_manifest.read_text(encoding="utf-8"))
            destination_directory = fixture_root / slot["id"]
            destination_directory.mkdir(parents=True, exist_ok=True)
            destination_manifest = destination_directory / "manifest.json"
            destination_manifest.write_bytes(source_manifest.read_bytes())
            for asset in fixture["assets"]:
                source_asset = source_manifest.parent / asset["path"]
                destination_asset = destination_directory / asset["path"]
                destination_asset.parent.mkdir(parents=True, exist_ok=True)
                destination_asset.write_bytes(source_asset.read_bytes())
            content["asset_manifest_path"] = (
                Path(slot["id"]) / "manifest.json"
            ).as_posix()

    def _ready_manifest(
        self, directory: Path, slot_id: str = "login_ui"
    ) -> tuple[dict[str, object], Path]:
        manifest = copy.deepcopy(self.manifest)
        fixture_root = directory / "fixtures"
        self._copy_available_fixtures(manifest, fixture_root, slot_id)
        slot = next(value for value in manifest["slots"] if value["id"] == slot_id)
        slot["definition_status"] = "ready"
        slot["definition_blockers"] = []
        slot["machine_contract_status"] = "ready"
        slot["machine_contract_blockers"] = []
        display = slot["conditions"]["display"]
        display["width_px"] = 4
        display["height_px"] = 3
        for contract in slot["required_supporting_artifacts"].values():
            if contract["kind"] in {"png", "raw"}:
                contract["width_px"] = 4
                contract["height_px"] = 3
            if contract["kind"] == "raw":
                contract["row_pitch_bytes"] = 16
                contract["bytes"] = 48

        fixture_directory = fixture_root / slot_id
        fixture_directory.mkdir(parents=True)
        asset = b"canonical-fixture-" + slot_id.encode("ascii")
        asset_path = fixture_directory / "asset.bin"
        asset_path.write_bytes(asset)
        content = slot["conditions"]["content"]
        fixture = {
            "schema": 1,
            "fixture_id": content["fixture_id"],
            "fixture_revision": content["fixture_revision"],
            "assets": [
                {
                    "path": "asset.bin",
                    "bytes": len(asset),
                    "sha256": hashlib.sha256(asset).hexdigest(),
                }
            ],
        }
        fixture_bytes = json.dumps(
            fixture, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        fixture_manifest_path = fixture_directory / "manifest.json"
        fixture_manifest_path.write_bytes(fixture_bytes)
        content.update(
            {
                "availability": "available",
                "asset_manifest_path": f"{slot_id}/manifest.json",
                "asset_manifest_bytes": len(fixture_bytes),
                "asset_manifest_sha256": hashlib.sha256(fixture_bytes).hexdigest(),
            }
        )
        environment = slot["conditions"]["environment"]
        if environment["mode"] != "not_applicable":
            environment["asset_id"] = "test-environment-asset"
        oracle.validate_manifest(manifest, fixture_root)
        return manifest, fixture_root

    def _initialize(
        self,
        directory: Path,
        manifest: dict[str, object] | None = None,
        fixture_root: Path | None = None,
    ) -> Path:
        manifest = manifest or self.manifest
        session_path = directory / "session.json"
        with patch.object(oracle, "_git_errors", return_value=[]):
            oracle.initialize_session(
                manifest,
                session_path,
                directory / "oracle",
                fixture_root,
            )
        return session_path

    def _measurements(self, session_path: Path, slot_id: str) -> Path:
        request = json.loads(
            (session_path.parent / "requests" / f"{slot_id}.json").read_text(
                encoding="utf-8"
            )
        )
        measurements = request["measurement_template"]
        for processor in ("cpu", "gpu"):
            measurements["frame_timing_ms"][processor].update(
                {"mean": 1.5, "p50": 1.0, "p95": 2.0, "p99": 3.0}
            )
        measurements["memory_mib"].update(
            {
                "process_resident_start": 1000.0,
                "process_resident_peak": 1100.0,
                "gpu_allocated_start": 500.0,
                "gpu_allocated_peak": 600.0,
            }
        )
        measurements["hardware_os"].update(
            {
                "machine_model": "Mac-Test",
                "cpu": "Test CPU",
                "gpu": "Test GPU",
                "ram_mib": 16384,
                "os_version": "test",
                "display_id": "test-display",
                "opengl_vendor": "test-vendor",
                "opengl_renderer": "test-renderer",
                "opengl_version": "test-version",
                "viewer_build": measurements["baseline_commit"],
                "xcode_build": "test-xcode",
            }
        )
        path = session_path.parent / f"{slot_id}-measurements.json"
        path.write_text(json.dumps(measurements), encoding="utf-8")
        return path

    def _captures(
        self,
        directory: Path,
        pixels: tuple[tuple[int, int, int, int], ...] | None = None,
    ) -> list[Path]:
        pixels = pixels or ((0, 0, 0, 255),) * 3
        captures: list[Path] = []
        for index, pixel in enumerate(pixels):
            capture = directory / f"capture-{index}.png"
            _write_png(capture, pixel=pixel)
            captures.append(capture)
        return captures

    def _record(
        self,
        manifest: dict[str, object],
        fixture_root: Path,
        session_path: Path,
        slot_id: str,
        captures: list[Path],
        supporting: dict[str, Path] | None = None,
    ) -> None:
        with patch.object(oracle, "_git_errors", return_value=[]):
            oracle.record_slot(
                manifest,
                session_path,
                slot_id,
                captures,
                self._measurements(session_path, slot_id),
                supporting,
                fixture_root,
            )

    def test_manifest_pins_baseline_contract_and_required_coverage(self) -> None:
        self.assertEqual(self.manifest["schema"], 2)
        self.assertEqual(
            self.manifest["baseline"]["commit"],
            "1e8fd5491bde91fe6daca7d78f217a4d46084a5b",
        )
        self.assertEqual(
            self.manifest["capture_contract"]["self_variance_method"],
            "linear_srgb_rgba8_all_pairs_v1",
        )
        tools = next(
            slot for slot in self.manifest["slots"] if slot["id"] == "tools_readback"
        )
        tools_contracts = tools["required_supporting_artifacts"]
        self.assertEqual(
            tools_contracts["local_snapshot"]["encoding"],
            "rgb_or_rgba8_srgb_encoded",
        )
        self.assertEqual(
            tools_contracts["raw_color"]["encoding"],
            "bgra8_unorm_srgb_encoded",
        )
        slots = self.manifest["slots"]
        groups = {slot["group"] for slot in slots}
        features = {feature for slot in slots for feature in slot["features"]}
        self.assertTrue(oracle.REQUIRED_GROUPS <= groups)
        self.assertTrue(oracle.REQUIRED_FEATURES <= features)
        self.assertTrue(all(slot["evidence"]["status"] == "missing" for slot in slots))
        self.assertTrue(
            all(slot["machine_contract_status"] == "blocked" for slot in slots)
        )
        self.assertTrue(all(slot["machine_contract_blockers"] for slot in slots))
        login = next(slot for slot in slots if slot["id"] == "login_ui")
        self.assertEqual(login["definition_status"], "ready")
        self.assertEqual(login["definition_blockers"], [])
        self.assertEqual(login["conditions"]["content"]["availability"], "available")
        for slot in slots:
            if slot["conditions"]["camera"]["mode"] != "not_applicable":
                settings = slot["conditions"]["settings"]
                self.assertIs(settings["RenderHDREnabled"], True)
                self.assertIs(settings["RenderEnableEmissiveBuffer"], False)

    def test_initialize_and_verify_keep_missing_evidence_honest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            session_path = self._initialize(Path(temporary))
            session = json.loads(session_path.read_text(encoding="utf-8"))
            self.assertTrue(
                all(
                    slot["evidence"]["status"] == "missing" for slot in session["slots"]
                )
            )
            self.assertEqual(session["schema"], 2)
            self.assertTrue((session_path.parent / "requests/login_ui.json").is_file())
            errors = oracle.verify_session(self.manifest, session_path, check_git=False)
            self.assertTrue(
                any(
                    "login_ui: required oracle evidence is missing" in error
                    for error in errors
                )
            )
            self.assertTrue(
                any("opaque_region: definition is blocked" in error for error in errors)
            )
            self.assertTrue(
                any("login_ui: machine contract is blocked" in error for error in errors)
            )
            request = json.loads(
                (session_path.parent / "requests/login_ui.json").read_text(
                    encoding="utf-8"
                )
            )
            login = next(
                slot for slot in self.manifest["slots"] if slot["id"] == "login_ui"
            )
            session_login = next(
                slot for slot in session["slots"] if slot["id"] == "login_ui"
            )
            self.assertEqual(request["schema"], 2)
            self.assertEqual(
                request["definition_status"],
                login["definition_status"],
            )
            self.assertEqual(
                request["definition_blockers"],
                login["definition_blockers"],
            )
            self.assertEqual(
                session_login["machine_contract_status"],
                login["machine_contract_status"],
            )
            self.assertEqual(
                session_login["machine_contract_blockers"],
                login["machine_contract_blockers"],
            )
            self.assertEqual(
                request["machine_contract_status"],
                login["machine_contract_status"],
            )
            self.assertEqual(
                request["machine_contract_blockers"],
                login["machine_contract_blockers"],
            )

    def test_machine_contract_status_requires_matching_blockers(self) -> None:
        cases = (
            ("blocked", [], "must explain a blocked slot"),
            ("ready", ["still blocked"], "must be empty for a ready slot"),
            ("unknown", [], "must be ready or blocked"),
        )
        for status, blockers, expected in cases:
            with self.subTest(status=status):
                manifest = copy.deepcopy(self.manifest)
                login = next(
                    slot for slot in manifest["slots"] if slot["id"] == "login_ui"
                )
                login["machine_contract_status"] = status
                login["machine_contract_blockers"] = blockers
                with self.assertRaisesRegex(oracle.OracleError, expected):
                    oracle.validate_manifest(manifest)

    def test_login_ui_route_conditions_are_exact(self) -> None:
        cases = (
            ("LoginPage", "http://127.0.0.1:19472/other.html", "LoginPage must equal"),
            ("ForceLoginURL", "http://127.0.0.1:19472/login_ui/index.html", "ForceLoginURL must be empty"),
        )
        for setting, value, expected in cases:
            with self.subTest(setting=setting):
                manifest = copy.deepcopy(self.manifest)
                login = next(
                    slot for slot in manifest["slots"] if slot["id"] == "login_ui"
                )
                login["conditions"]["settings"][setting] = value
                with self.assertRaisesRegex(oracle.OracleError, expected):
                    oracle.validate_manifest(manifest)

    def test_machine_blocked_login_cannot_record_before_reading_captures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            login = next(slot for slot in manifest["slots"] if slot["id"] == "login_ui")
            login["machine_contract_status"] = "blocked"
            login["machine_contract_blockers"] = [
                "The test capture driver is not implemented."
            ]
            oracle.validate_manifest(manifest, fixture_root)
            session_path = self._initialize(directory, manifest, fixture_root)

            with self.assertRaisesRegex(
                oracle.OracleError, "blocked by its machine capture contract"
            ):
                oracle.record_slot(
                    manifest,
                    session_path,
                    "login_ui",
                    [directory / "capture-must-not-be-read.png"],
                    directory / "measurements-must-not-be-read.json",
                    fixture_root=fixture_root,
                )

            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertIn(
                "login_ui: machine contract is blocked "
                "(The test capture driver is not implemented.)",
                errors,
            )

    def test_record_rejects_session_slot_without_evidence_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            session_path = self._initialize(directory)
            session = json.loads(session_path.read_text(encoding="utf-8"))
            login = next(slot for slot in session["slots"] if slot["id"] == "login_ui")
            login.pop("evidence")
            session_path.write_text(json.dumps(session), encoding="utf-8")

            with self.assertRaisesRegex(
                oracle.OracleError, "slot login_ui evidence is invalid"
            ):
                oracle.record_slot(
                    self.manifest,
                    session_path,
                    "login_ui",
                    [],
                    directory / "missing.json",
                )

    def test_initialize_rejects_requests_symlink_without_overwriting_outside(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_directory = root / "session"
            outside = root / "outside"
            session_directory.mkdir()
            outside.mkdir()
            sentinel = outside / "login_ui.json"
            sentinel.write_text("outside-sentinel\n", encoding="utf-8")
            (session_directory / "requests").symlink_to(
                outside, target_is_directory=True
            )
            session_path = session_directory / "session.json"
            with (
                patch.object(oracle, "_git_errors", return_value=[]),
                self.assertRaisesRegex(
                    oracle.OracleError, "pre-existing or aliased requests"
                ),
            ):
                oracle.initialize_session(self.manifest, session_path, root / "oracle")
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside-sentinel\n")
            self.assertEqual(list(outside.iterdir()), [sentinel])
            self.assertFalse(session_path.exists())

    def test_record_computes_and_verifies_capture_bound_variance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            session_path = self._initialize(directory, manifest, fixture_root)
            captures = self._captures(
                directory,
                ((0, 0, 0, 255), (255, 0, 0, 255), (0, 255, 0, 255)),
            )
            self._record(manifest, fixture_root, session_path, "login_ui", captures)
            session = json.loads(session_path.read_text(encoding="utf-8"))
            login = next(slot for slot in session["slots"] if slot["id"] == "login_ui")
            variance = login["evidence"]["self_variance"]
            self.assertEqual(variance["comparison_count"], 3)
            self.assertAlmostEqual(variance["mean_absolute_error"], 1 / 3, places=11)
            self.assertAlmostEqual(variance["rmse"], math.sqrt(1 / 3), places=11)
            self.assertEqual(variance["max_absolute_error"], 1.0)
            self.assertEqual(variance["identical_pixel_fraction"], 0.0)
            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertFalse(any(error.startswith("login_ui:") for error in errors))

            login["evidence"]["self_variance"]["mean_absolute_error"] = 0.0
            session_path.write_text(json.dumps(session), encoding="utf-8")
            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertTrue(
                any("self-variance does not match" in error for error in errors)
            )

    def test_self_variance_is_order_independent_and_linearized(self) -> None:
        captures = (
            bytes((0, 0, 0, 255)),
            bytes((255, 0, 0, 255)),
            bytes((0, 255, 0, 255)),
        )
        expected = oracle._self_variance(list(captures))
        self.assertEqual(expected["method"], "linear_srgb_rgba8_all_pairs_v1")
        for permutation in itertools.permutations(captures):
            self.assertEqual(oracle._self_variance(list(permutation)), expected)

        large_captures = tuple(
            bytes((value, 0, 0, 255)) * 100_000 for value in (0, 1, 255)
        )
        large_expected = oracle._self_variance(list(large_captures))
        self.assertEqual(large_expected["mean_absolute_error"], round(1 / 6, 12))
        self.assertEqual(large_expected["max_absolute_error"], 1.0)
        for permutation in itertools.permutations(large_captures):
            self.assertEqual(oracle._self_variance(list(permutation)), large_expected)

        linear_midpoint = ((128 / 255 + 0.055) / 1.055) ** 2.4
        midpoint_capture = bytes((128, 0, 0, 255))
        midpoint = oracle._self_variance(
            [bytes((0, 0, 0, 255)), midpoint_capture, midpoint_capture]
        )
        self.assertEqual(
            midpoint["mean_absolute_error"], round(linear_midpoint / 6, 12)
        )
        self.assertEqual(midpoint["rmse"], round(linear_midpoint / math.sqrt(6), 12))
        self.assertEqual(midpoint["max_absolute_error"], round(linear_midpoint, 12))
        self.assertEqual(midpoint["identical_pixel_fraction"], round(1 / 3, 12))

        linear_alpha = 128 / 255
        alpha_capture = bytes((0, 0, 0, 128))
        alpha_midpoint = oracle._self_variance(
            [bytes((0, 0, 0, 0)), alpha_capture, alpha_capture]
        )
        self.assertEqual(
            alpha_midpoint["mean_absolute_error"], round(linear_alpha / 6, 12)
        )
        self.assertEqual(alpha_midpoint["rmse"], round(linear_alpha / math.sqrt(6), 12))

    def test_record_hashes_and_persists_the_exact_bytes_it_validated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory, "tools_readback")
            session_path = self._initialize(directory, manifest, fixture_root)
            captures = self._captures(directory)
            supporting = self._tools_artifacts(directory)
            measurement_path = self._measurements(session_path, "tools_readback")
            original_capture = captures[0].read_bytes()
            original_color = supporting["raw_color"].read_bytes()
            real_reader = oracle._read_file_bytes
            mutated: set[Path] = set()

            def racing_reader(
                path: Path, field: str, maximum_bytes: int | None = None
            ) -> bytes:
                encoded = real_reader(path, field, maximum_bytes)
                if path == captures[0] and path not in mutated:
                    mutated.add(path)
                    path.write_bytes(_png_bytes(pixel=(255, 0, 0, 255)))
                elif path == supporting["raw_color"] and path not in mutated:
                    mutated.add(path)
                    path.write_bytes(b"Z" * 48)
                return encoded

            with (
                patch.object(oracle, "_read_file_bytes", side_effect=racing_reader),
                patch.object(oracle, "_git_errors", return_value=[]),
            ):
                oracle.record_slot(
                    manifest,
                    session_path,
                    "tools_readback",
                    captures,
                    measurement_path,
                    supporting,
                    fixture_root,
                )

            session = json.loads(session_path.read_text(encoding="utf-8"))
            slot = next(
                value for value in session["slots"] if value["id"] == "tools_readback"
            )
            stored_capture = (
                session_path.parent / slot["evidence"]["captures"][0]["path"]
            )
            raw_color = next(
                value
                for value in slot["evidence"]["supporting_artifacts"]
                if value["role"] == "raw_color"
            )
            self.assertEqual(stored_capture.read_bytes(), original_capture)
            self.assertEqual(
                (session_path.parent / raw_color["path"]).read_bytes(), original_color
            )
            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertFalse(
                any(error.startswith("tools_readback:") for error in errors)
            )

    def test_png_decoder_rejects_undecodable_or_color_ambiguous_inputs(self) -> None:
        valid = _png_bytes()
        self.assertEqual(oracle._decode_png_bytes(valid, "valid")[:2], (4, 3))
        for filter_type in range(5):
            with self.subTest(filter_type=filter_type):
                _, _, decoded = oracle._decode_png_bytes(
                    _png_bytes(pixel=(0, 0, 0, 0), filter_type=filter_type),
                    f"filter-{filter_type}",
                )
                self.assertEqual(decoded, bytes(4 * 3 * 4))
        self.assertEqual(
            oracle._decode_png_bytes(
                _png_bytes(include_srgb=False), "contract-defined-srgb"
            )[:2],
            (4, 3),
        )
        header = struct.pack(">IIBBBBB", 4, 3, 8, 6, 0, 0, 0)
        scanlines = (b"\0" + b"\0\0\0\xff" * 4) * 3
        late_srgb = (
            b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR", header)
            + _chunk(b"PLTE", b"\0\0\0")
            + _chunk(b"sRGB", b"\0")
            + _chunk(b"IDAT", zlib.compress(scanlines))
            + _chunk(b"IEND", b"")
        )
        canonical_chrm = struct.pack(
            ">8I", 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000
        )
        cases = {
            "invalid-zlib": _png_bytes(compressed=b"not-zlib"),
            "empty-idat": _png_bytes(compressed=b""),
            "truncated-zlib": _png_bytes(compressed=zlib.compress(b"\0" * 51)[:-2]),
            "invalid-filter": _png_bytes(filter_type=5),
            "late-srgb": late_srgb,
            "icc-profile": _png_bytes(before_idat=((b"iCCP", b"x\0\0bad"),)),
            "cicp-profile": _png_bytes(before_idat=((b"cICP", b"\1\1\1\1"),)),
            "transparency": _png_bytes(before_idat=((b"tRNS", b"\0" * 6),)),
            "apng": _png_bytes(before_idat=((b"acTL", struct.pack(">II", 1, 0)),)),
            "split-idat": _png_bytes(between_idat=((b"tEXt", b"x\0y"),)),
            "reserved-bit": _png_bytes(before_idat=((b"texT", b"x"),)),
            "bad-gamma": _png_bytes(
                before_idat=((b"gAMA", struct.pack(">I", 100000)),)
            ),
            "bad-chromaticity": _png_bytes(before_idat=((b"cHRM", b"\0" * 32),)),
            "partial-gamma": _png_bytes(
                include_srgb=False,
                before_idat=((b"gAMA", struct.pack(">I", 45455)),),
            ),
            "partial-chromaticity": _png_bytes(
                include_srgb=False,
                before_idat=((b"cHRM", canonical_chrm),),
            ),
            "trailing-data": _png_bytes(trailing=b"garbage"),
            "truncated-png": valid[:-8],
        }
        self.assertEqual(
            oracle._decode_png_bytes(
                _png_bytes(
                    include_srgb=False,
                    before_idat=(
                        (b"gAMA", struct.pack(">I", 45455)),
                        (b"cHRM", canonical_chrm),
                    ),
                ),
                "canonical-color",
            )[:2],
            (4, 3),
        )
        for name, encoded in cases.items():
            with self.subTest(name=name), self.assertRaises(oracle.OracleError):
                oracle._decode_png_bytes(encoded, name)
        with tempfile.TemporaryDirectory() as temporary:
            capture = Path(temporary) / "oversized.png"
            capture.write_bytes(valid)
            with (
                patch.object(oracle, "MAX_PNG_BYTES", 16),
                self.assertRaisesRegex(oracle.OracleError, "byte limit"),
            ):
                oracle._decode_png(capture)

    def test_ready_fixture_must_bind_real_manifest_and_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            oracle.validate_manifest(manifest, fixture_root)
            login = next(slot for slot in manifest["slots"] if slot["id"] == "login_ui")
            fixture_path = fixture_root / "login_ui/manifest.json"
            original_fixture = fixture_path.read_bytes()
            duplicate_fixture = json.loads(original_fixture)
            duplicate = copy.deepcopy(duplicate_fixture["assets"][0])
            duplicate["path"] = "./asset.bin"
            duplicate_fixture["assets"].append(duplicate)
            duplicate_bytes = json.dumps(
                duplicate_fixture, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
            fixture_path.write_bytes(duplicate_bytes)
            content = login["conditions"]["content"]
            content["asset_manifest_bytes"] = len(duplicate_bytes)
            content["asset_manifest_sha256"] = hashlib.sha256(
                duplicate_bytes
            ).hexdigest()
            with self.assertRaisesRegex(oracle.OracleError, "duplicate asset paths"):
                oracle.validate_manifest(manifest, fixture_root)

            fixture_path.write_bytes(original_fixture)
            content["asset_manifest_bytes"] = len(original_fixture)
            login["conditions"]["content"]["asset_manifest_sha256"] = "ab" * 32
            with self.assertRaisesRegex(oracle.OracleError, "does not match the file"):
                oracle.validate_manifest(manifest, fixture_root)

        manifest = copy.deepcopy(self.manifest)
        login = next(slot for slot in manifest["slots"] if slot["id"] == "login_ui")
        content = login["conditions"]["content"]
        content["availability"] = "missing"
        content["asset_manifest_path"] = None
        content["asset_manifest_bytes"] = None
        content["asset_manifest_sha256"] = None
        with self.assertRaisesRegex(oracle.OracleError, "availability is missing"):
            oracle.validate_manifest(manifest)

    def test_fixture_tampering_blocks_record_and_verify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            session_path = self._initialize(directory, manifest, fixture_root)
            asset = fixture_root / "login_ui/asset.bin"
            original = asset.read_bytes()
            asset.write_bytes(b"X" * len(original))
            with self.assertRaisesRegex(oracle.OracleError, "sha256 does not match"):
                self._record(
                    manifest,
                    fixture_root,
                    session_path,
                    "login_ui",
                    self._captures(directory),
                )

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            session_path = self._initialize(directory, manifest, fixture_root)
            self._record(
                manifest,
                fixture_root,
                session_path,
                "login_ui",
                self._captures(directory),
            )
            asset = fixture_root / "login_ui/asset.bin"
            asset.write_bytes(b"Y" * len(asset.read_bytes()))
            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertTrue(any("sha256 does not match" in error for error in errors))

    def test_external_json_blob_and_fixture_reads_are_bounded_or_streamed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            document = directory / "document.json"
            document.write_text("{}", encoding="utf-8")
            with (
                patch.object(oracle, "MAX_JSON_BYTES", 1),
                self.assertRaisesRegex(oracle.OracleError, "byte limit"),
            ):
                oracle._read_json(document)

            manifest, fixture_root = self._ready_manifest(directory / "fixture")
            real_reader = oracle._read_file_bytes

            def fixture_reader(
                path: Path, field: str, maximum_bytes: int | None = None
            ) -> bytes:
                if field == "fixture asset":
                    raise AssertionError("fixture assets must be streamed")
                return real_reader(path, field, maximum_bytes)

            with patch.object(oracle, "_read_file_bytes", side_effect=fixture_reader):
                oracle.validate_manifest(manifest, fixture_root)

            with (
                patch.object(oracle, "MAX_JSON_BYTES", 1),
                self.assertRaisesRegex(oracle.OracleError, "fixture manifest limit"),
            ):
                oracle.validate_manifest(manifest, fixture_root)

        blob_contract = {"kind": "blob", "min_bytes": 1, "max_bytes": 2}
        with self.assertRaisesRegex(oracle.OracleError, "byte limit"):
            oracle._validate_supporting_artifact_bytes(
                "payload", b"abc", "payload", blob_contract
            )

    def test_fixture_paths_cannot_escape_or_traverse_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            login = next(slot for slot in manifest["slots"] if slot["id"] == "login_ui")
            login["conditions"]["content"]["asset_manifest_path"] = "../outside.json"
            with self.assertRaisesRegex(oracle.OracleError, "safe relative path"):
                oracle.validate_manifest(manifest, fixture_root)

            manifest, fixture_root = self._ready_manifest(directory / "second")
            login = next(slot for slot in manifest["slots"] if slot["id"] == "login_ui")
            target = fixture_root / "login_ui/manifest.json"
            link = fixture_root / "manifest-link.json"
            link.symlink_to(target)
            login["conditions"]["content"]["asset_manifest_path"] = "manifest-link.json"
            with self.assertRaisesRegex(oracle.OracleError, "symbolic link"):
                oracle.validate_manifest(manifest, fixture_root)

    def test_render_target_settings_are_canonical_and_explicit(self) -> None:
        for setting, invalid, expected_text in (
            ("RenderHDREnabled", False, "must be pinned to true"),
            ("RenderEnableEmissiveBuffer", True, "must be pinned to false"),
        ):
            with self.subTest(setting=setting):
                manifest = copy.deepcopy(self.manifest)
                opaque = next(
                    slot for slot in manifest["slots"] if slot["id"] == "opaque_region"
                )
                opaque["conditions"]["settings"][setting] = invalid
                with self.assertRaisesRegex(oracle.OracleError, expected_text):
                    oracle.validate_manifest(manifest)
                del opaque["conditions"]["settings"][setting]
                with self.assertRaisesRegex(oracle.OracleError, expected_text):
                    oracle.validate_manifest(manifest)

        manifest = copy.deepcopy(self.manifest)
        manifest["slots"][0]["conditions"]["display"]["color_space"] = "Display-P3"
        with self.assertRaisesRegex(oracle.OracleError, "color_space must be sRGB"):
            oracle.validate_manifest(manifest)

    def test_mutable_session_cannot_relax_definition_or_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            session_path = self._initialize(directory)
            session = json.loads(session_path.read_text(encoding="utf-8"))
            login = next(slot for slot in session["slots"] if slot["id"] == "login_ui")
            login["definition_status"] = "ready"
            login["definition_blockers"] = []
            login["machine_contract_status"] = "ready"
            login["machine_contract_blockers"] = []
            session["capture_contract"]["repetitions"] = 1
            session_path.write_text(json.dumps(session), encoding="utf-8")
            errors = oracle.verify_session(self.manifest, session_path, check_git=False)
            self.assertIn(
                "session capture contract does not match the manifest", errors
            )
            self.assertIn(
                "login_ui: session definition does not match the manifest", errors
            )
            with self.assertRaisesRegex(oracle.OracleError, "invalid session"):
                oracle.record_slot(
                    self.manifest,
                    session_path,
                    "login_ui",
                    [],
                    directory / "missing.json",
                )

    def test_session_binding_uses_strict_canonical_json_and_recomputed_hashes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            session_path = self._initialize(directory)
            session = json.loads(session_path.read_text(encoding="utf-8"))
            login = next(slot for slot in session["slots"] if slot["id"] == "login_ui")
            self.assertRegex(login["definition_sha256"], r"^[0-9a-f]{64}$")
            login["conditions"]["settings"]["RenderUIBuffer"] = 0
            session["capture_contract"]["repetitions"] = 3.0
            session_path.write_text(json.dumps(session), encoding="utf-8")

            errors = oracle.verify_session(self.manifest, session_path, check_git=False)
            self.assertIn(
                "session capture contract does not match the manifest", errors
            )
            self.assertIn(
                "login_ui: session definition does not match the manifest", errors
            )
            self.assertIn("login_ui: session definition hash is invalid", errors)
            self.assertIn(
                "login_ui: session conditions do not match the manifest", errors
            )
            self.assertIn("login_ui: session conditions hash is invalid", errors)
            with self.assertRaisesRegex(oracle.OracleError, "invalid session"):
                oracle.record_slot(
                    self.manifest,
                    session_path,
                    "login_ui",
                    [],
                    directory / "missing.json",
                )

    def test_schema_versions_require_json_integers(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["schema"] = True
        with self.assertRaisesRegex(oracle.OracleError, "manifest schema"):
            oracle.validate_manifest(manifest)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            fixture_path = fixture_root / "login_ui/manifest.json"
            fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
            fixture["schema"] = True
            fixture_bytes = json.dumps(
                fixture, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
            fixture_path.write_bytes(fixture_bytes)
            login = next(slot for slot in manifest["slots"] if slot["id"] == "login_ui")
            content = login["conditions"]["content"]
            content["asset_manifest_bytes"] = len(fixture_bytes)
            content["asset_manifest_sha256"] = hashlib.sha256(fixture_bytes).hexdigest()
            with self.assertRaisesRegex(oracle.OracleError, "fixture manifest schema"):
                oracle.validate_manifest(manifest, fixture_root)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            session_path = self._initialize(directory, manifest, fixture_root)
            session = json.loads(session_path.read_text(encoding="utf-8"))
            session["schema"] = True
            session_path.write_text(json.dumps(session), encoding="utf-8")
            self.assertIn(
                "session schema or kind is invalid",
                oracle.verify_session(
                    manifest,
                    session_path,
                    check_git=False,
                    fixture_root=fixture_root,
                ),
            )

            session["schema"] = 1
            session_path.write_text(json.dumps(session), encoding="utf-8")
            self.assertIn(
                "session schema or kind is invalid",
                oracle.verify_session(
                    manifest,
                    session_path,
                    check_git=False,
                    fixture_root=fixture_root,
                ),
            )

            measurements = json.loads(
                self._measurements(session_path, "login_ui").read_text(encoding="utf-8")
            )
            measurements["schema"] = True
            rgba = bytes((0, 0, 0, 255)) * 12
            measurements["self_variance"] = oracle._self_variance([rgba] * 3)
            login = next(slot for slot in session["slots"] if slot["id"] == "login_ui")
            with self.assertRaisesRegex(oracle.OracleError, "measurements.schema"):
                oracle.validate_measurements(
                    measurements,
                    login,
                    manifest["baseline"]["commit"],
                    manifest["capture_contract"],
                )

    def test_measurements_reject_nonfinite_numbers_and_unpinned_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory)
            session_path = self._initialize(directory, manifest, fixture_root)
            measurement_path = self._measurements(session_path, "login_ui")
            measurements = json.loads(measurement_path.read_text(encoding="utf-8"))
            session = json.loads(session_path.read_text(encoding="utf-8"))
            login = next(slot for slot in session["slots"] if slot["id"] == "login_ui")
            rgba = bytes((0, 0, 0, 255)) * 12
            measurements["self_variance"] = oracle._self_variance([rgba] * 3)
            fractional_schema = copy.deepcopy(measurements)
            fractional_schema["self_variance"]["comparison_count"] = 3.0
            with self.assertRaisesRegex(oracle.OracleError, "must be an integer"):
                oracle.validate_measurements(
                    fractional_schema,
                    login,
                    manifest["baseline"]["commit"],
                    manifest["capture_contract"],
                )
            wrong_sample_count = copy.deepcopy(measurements)
            wrong_sample_count["frame_timing_ms"]["sample_count"] = 601
            with self.assertRaisesRegex(oracle.OracleError, "must equal 600"):
                oracle.validate_measurements(
                    wrong_sample_count,
                    login,
                    manifest["baseline"]["commit"],
                    manifest["capture_contract"],
                )
            for nonfinite in (float("nan"), float("inf"), float("-inf")):
                with self.subTest(nonfinite=nonfinite):
                    invalid = copy.deepcopy(measurements)
                    invalid["frame_timing_ms"]["cpu"]["mean"] = nonfinite
                    with self.assertRaisesRegex(oracle.OracleError, "finite number"):
                        oracle.validate_measurements(
                            invalid,
                            login,
                            manifest["baseline"]["commit"],
                            manifest["capture_contract"],
                        )
            measurements["hardware_os"]["viewer_build"] = "not-the-baseline"
            with self.assertRaisesRegex(oracle.OracleError, "pinned baseline commit"):
                oracle.validate_measurements(
                    measurements,
                    login,
                    manifest["baseline"]["commit"],
                    manifest["capture_contract"],
                )

    def _tools_artifacts(self, directory: Path) -> dict[str, Path]:
        snapshot = directory / "snapshot.png"
        _write_png(snapshot, pixel=(10, 20, 30), color_type=2)
        raw_color = directory / "frame.bgra"
        raw_color.write_bytes(bytes((30, 20, 10, 255)) * 12)
        raw_depth = directory / "frame.depth"
        raw_depth.write_bytes(struct.pack("<12f", *([0.5] * 12)))
        return {
            "local_snapshot": snapshot,
            "raw_color": raw_color,
            "raw_depth": raw_depth,
        }

    def test_tools_artifact_contracts_record_and_verify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory, "tools_readback")
            session_path = self._initialize(directory, manifest, fixture_root)
            supporting = self._tools_artifacts(directory)
            self._record(
                manifest,
                fixture_root,
                session_path,
                "tools_readback",
                self._captures(directory),
                supporting,
            )
            session = json.loads(session_path.read_text(encoding="utf-8"))
            slot = next(
                slot for slot in session["slots"] if slot["id"] == "tools_readback"
            )
            for artifact in slot["evidence"]["supporting_artifacts"]:
                self.assertEqual(
                    artifact["contract"],
                    slot["required_supporting_artifacts"][artifact["role"]],
                )
            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertFalse(
                any(error.startswith("tools_readback:") for error in errors)
            )

    def test_tools_manifest_rejects_swapped_role_semantics(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        tools = next(
            slot for slot in manifest["slots"] if slot["id"] == "tools_readback"
        )
        contracts = tools["required_supporting_artifacts"]
        contracts["raw_color"], contracts["raw_depth"] = (
            contracts["raw_depth"],
            contracts["raw_color"],
        )
        with self.assertRaisesRegex(oracle.OracleError, "canonical tools_readback"):
            oracle.validate_manifest(manifest)

    def test_tools_artifacts_reject_empty_truncated_and_invalid_depth(self) -> None:
        cases = {
            "empty_png": "is not a PNG",
            "short_color": "has 47 bytes; expected 48",
            "long_color": "exceeds the 48-byte limit",
            "invalid_depth": "contains an invalid depth value",
            "color_mismatch": "do not match raw_color",
            "alpha_mismatch": "do not match raw_color",
        }
        for case, expected in cases.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                manifest, fixture_root = self._ready_manifest(
                    directory, "tools_readback"
                )
                session_path = self._initialize(directory, manifest, fixture_root)
                supporting = self._tools_artifacts(directory)
                if case == "empty_png":
                    supporting["local_snapshot"].write_bytes(b"")
                elif case == "short_color":
                    supporting["raw_color"].write_bytes(b"\0" * 47)
                elif case == "long_color":
                    supporting["raw_color"].write_bytes(b"\0" * 49)
                elif case == "invalid_depth":
                    supporting["raw_depth"].write_bytes(
                        struct.pack("<12f", float("nan"), *([0.5] * 11))
                    )
                elif case == "color_mismatch":
                    supporting["raw_color"].write_bytes(bytes((31, 20, 10, 255)) * 12)
                else:
                    _write_png(
                        supporting["local_snapshot"],
                        pixel=(10, 20, 30, 128),
                        color_type=6,
                    )
                    supporting["raw_color"].write_bytes(bytes((30, 20, 10, 127)) * 12)
                with self.assertRaisesRegex(oracle.OracleError, expected):
                    self._record(
                        manifest,
                        fixture_root,
                        session_path,
                        "tools_readback",
                        self._captures(directory),
                        supporting,
                    )

    def test_verify_rejects_supporting_tampering_duplicate_roles_and_path_escape(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest, fixture_root = self._ready_manifest(directory, "tools_readback")
            session_path = self._initialize(directory, manifest, fixture_root)
            self._record(
                manifest,
                fixture_root,
                session_path,
                "tools_readback",
                self._captures(directory),
                self._tools_artifacts(directory),
            )
            session = json.loads(session_path.read_text(encoding="utf-8"))
            slot = next(
                slot for slot in session["slots"] if slot["id"] == "tools_readback"
            )
            supporting = slot["evidence"]["supporting_artifacts"]
            raw_color = next(
                value for value in supporting if value["role"] == "raw_color"
            )
            raw_depth = next(
                value for value in supporting if value["role"] == "raw_depth"
            )
            for field in ("path", "sha256", "bytes"):
                raw_depth[field] = raw_color[field]
            (session_path.parent / raw_color["path"]).write_bytes(b"")
            raw_color["contract"]["encoding"] = "tampered"
            supporting.append(copy.deepcopy(supporting[0]))
            supporting[0]["path"] = "../../escape.png"
            session_path.write_text(json.dumps(session), encoding="utf-8")
            errors = oracle.verify_session(
                manifest, session_path, check_git=False, fixture_root=fixture_root
            )
            self.assertTrue(
                any("roles are invalid or duplicated" in error for error in errors)
            )
            self.assertTrue(
                any("escapes its slot directory" in error for error in errors)
            )
            self.assertTrue(
                any(
                    "supporting artifact paths must be unique" in error
                    for error in errors
                )
            )
            self.assertTrue(any("contract mismatch" in error for error in errors))
            self.assertTrue(any("artifact hash mismatch" in error for error in errors))

    def test_manifest_rejects_incomplete_feature_coverage(self) -> None:
        for missing_feature in ("readback", "hud", "day_night"):
            with self.subTest(missing_feature=missing_feature):
                manifest = copy.deepcopy(self.manifest)
                for slot in manifest["slots"]:
                    slot["features"] = [
                        feature
                        for feature in slot["features"]
                        if feature != missing_feature
                    ]
                with self.assertRaisesRegex(oracle.OracleError, missing_feature):
                    oracle.validate_manifest(manifest)

    def _new_git_repository(self, directory: Path) -> tuple[Path, str]:
        repository = directory / "oracle"
        repository.mkdir()
        _git(repository, "init")
        _git(repository, "config", "user.email", "oracle@example.invalid")
        _git(repository, "config", "user.name", "Oracle Test")
        (repository / "tracked.txt").write_text("baseline\n", encoding="utf-8")
        _git(repository, "add", "tracked.txt")
        _git(repository, "commit", "-m", "baseline")
        return repository, _git(repository, "rev-parse", "HEAD")

    def test_git_contract_requires_detached_exact_clean_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository, commit = self._new_git_repository(Path(temporary))
            self.assertTrue(
                any(
                    "HEAD must be detached" in error
                    for error in oracle._git_errors(repository, commit)
                )
            )
            _git(repository, "checkout", "--detach", commit)
            self.assertEqual(oracle._git_errors(repository, commit), [])
            self.assertTrue(
                any(
                    "expected" in error
                    for error in oracle._git_errors(repository, "0" * 40)
                )
            )
            (repository / "untracked.txt").write_text("untracked\n", encoding="utf-8")
            self.assertTrue(
                any(
                    "not clean" in error
                    for error in oracle._git_errors(repository, commit)
                )
            )

    def test_git_contract_exposes_hidden_tracked_changes(self) -> None:
        for flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as temporary:
                repository, commit = self._new_git_repository(Path(temporary))
                _git(repository, "checkout", "--detach", commit)
                _git(repository, "update-index", flag, "tracked.txt")
                (repository / "tracked.txt").write_text("tampered\n", encoding="utf-8")
                errors = oracle._git_errors(repository, commit)
                self.assertTrue(any("index contains" in error for error in errors))
                self.assertTrue(
                    any("tracked content differs" in error for error in errors)
                )

    def test_git_contract_ignores_redirects_and_rejects_replacements_and_filters(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            repository, commit = self._new_git_repository(directory)
            _git(repository, "checkout", "--detach", commit)
            alternate_index = directory / "alternate-index"
            subprocess.run(
                ["git", "-C", str(repository), "read-tree", "HEAD"],
                check=True,
                env={**dict(os.environ), "GIT_INDEX_FILE": str(alternate_index)},
            )
            _git(repository, "update-index", "--assume-unchanged", "tracked.txt")
            (repository / "tracked.txt").write_text("tampered\n", encoding="utf-8")
            with patch.dict(os.environ, {"GIT_INDEX_FILE": str(alternate_index)}):
                errors = oracle._git_errors(repository, commit)
            self.assertTrue(any("index contains" in error for error in errors))
            self.assertTrue(any("tracked content differs" in error for error in errors))

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            repository, baseline = self._new_git_repository(directory)
            (repository / "tracked.txt").write_text("replacement\n", encoding="utf-8")
            _git(repository, "commit", "-am", "replacement")
            replacement = _git(repository, "rev-parse", "HEAD")
            _git(repository, "checkout", "--detach", baseline)
            _git(repository, "replace", baseline, replacement)
            (repository / "tracked.txt").write_text("replacement\n", encoding="utf-8")
            errors = oracle._git_errors(repository, baseline)
            self.assertTrue(any("not clean" in error for error in errors))
            self.assertTrue(any("tracked content differs" in error for error in errors))

        with tempfile.TemporaryDirectory() as temporary:
            repository, commit = self._new_git_repository(Path(temporary))
            _git(repository, "checkout", "--detach", commit)
            (repository / ".git/info/attributes").write_text(
                "tracked.txt filter=oracle\n", encoding="utf-8"
            )
            _git(
                repository, "config", "filter.oracle.clean", "sed s/tampered/baseline/"
            )
            (repository / "tracked.txt").write_text("tampered\n", encoding="utf-8")
            errors = oracle._git_errors(repository, commit)
            self.assertTrue(
                any("content-conversion attributes" in error for error in errors)
            )

    def test_git_contract_rejects_ignored_untracked_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository, commit = self._new_git_repository(Path(temporary))
            _git(repository, "checkout", "--detach", commit)
            (repository / ".git/info/exclude").write_text(
                "ignored.tmp\n", encoding="utf-8"
            )
            (repository / "ignored.tmp").write_text("ignored\n", encoding="utf-8")
            errors = oracle._git_errors(repository, commit)
            self.assertTrue(any("ignored untracked paths" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
