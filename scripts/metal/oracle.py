#!/usr/bin/env python3
"""Stage, record, and verify the pinned OpenGL oracle corpus."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib
from collections import Counter
from datetime import datetime, timezone
from itertools import zip_longest
from pathlib import Path
from typing import Final

REQUIRED_GROUPS: Final = {
    "login_ui",
    "opaque_region",
    "pbr_material_avatar_alpha",
    "water_sky_shadows_probes_post",
    "tools_readback",
    "hud_name_tags",
    "impostors_particles",
    "media_previews",
    "day_night",
}
REQUIRED_FEATURES: Final = {
    "login",
    "ui",
    "font",
    "opaque_geometry",
    "terrain",
    "legacy_material",
    "pbr",
    "avatar_skinning",
    "alpha_mask",
    "alpha_blend",
    "water",
    "sky",
    "shadows",
    "reflection_probes",
    "post_processing",
    "tools",
    "readback",
    "hud",
    "name_tags",
    "impostors",
    "particles",
    "media",
    "previews",
    "day_night",
}
HASH_PATTERN: Final = re.compile(r"[0-9a-f]{64}")
COMMIT_PATTERN: Final = re.compile(r"[0-9a-f]{40}")
MAX_PNG_BYTES: Final = 256 * 1024 * 1024
MAX_JSON_BYTES: Final = 16 * 1024 * 1024
MAX_BLOB_BYTES: Final = 256 * 1024 * 1024
ACQUISITION_PROTOCOL: Final = "firestorm-opengl-oracle-capture-v1"
CPU_TIMING_SCOPE: Final = "display_to_pre_swap_wall_v1"
GPU_TIMING_SCOPE: Final = "gl_time_elapsed_frame_v1"
GPU_MEMORY_METHOD: Final = "renderer_accounted_v1"
GPU_MEMORY_SOURCES: Final = (
    "viewer texture allocation counters",
    "viewer vertex-buffer allocation counters",
    "viewer render-target attachment accounting",
)
LOGIN_PAGE_URL: Final = "http://127.0.0.1:19472/login_ui/index.html"
SESSION_ID_PATTERN: Final = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"
)
SRGB_TO_LINEAR: Final = tuple(
    value / (255.0 * 12.92) if value <= 10 else ((value / 255.0 + 0.055) / 1.055) ** 2.4
    for value in range(256)
)


class OracleError(ValueError):
    """The corpus or a capture session does not satisfy its contract."""


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _read_json(path: Path) -> dict[str, object]:
    encoded = _read_file_bytes(path, "JSON document", MAX_JSON_BYTES)
    return _read_json_bytes(encoded, str(path))


def _read_json_bytes(encoded: bytes, label: str) -> dict[str, object]:
    return _read_strict_json_bytes(encoded, label)


def _read_strict_json_bytes(encoded: bytes, label: str) -> dict[str, object]:
    def reject_constant(value: str) -> object:
        raise OracleError(f"{label} contains non-standard number {value}")

    def reject_duplicate_keys(
        pairs: list[tuple[str, object]],
    ) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise OracleError(f"{label} contains duplicate key {key}")
            result[key] = value
        return result

    try:
        document = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except OracleError:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise OracleError(f"cannot read {label}: {error}") from error
    if not isinstance(document, dict):
        raise OracleError(f"{label} must contain a JSON object")
    return document


def _write_json(path: Path, document: dict[str, object]) -> None:
    encoded = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    directory_fd, _ = _open_canonical_directory(path.parent, "JSON destination")
    temporary_name = f".{path.name}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    file_fd = -1
    try:
        file_fd = os.open(temporary_name, flags, 0o600, dir_fd=directory_fd)
        offset = 0
        while offset < len(encoded):
            written = os.write(file_fd, encoded[offset:])
            if written <= 0:
                raise OSError("write returned no progress")
            offset += written
        os.fsync(file_fd)
        os.close(file_fd)
        file_fd = -1
        os.rename(
            temporary_name,
            path.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
    except BaseException:
        if file_fd >= 0:
            os.close(file_fd)
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        raise
    finally:
        os.close(directory_fd)


def _canonical_json_bytes(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def _canonical_hash(value: object) -> str:
    return hashlib.sha256(_canonical_json_bytes(value)).hexdigest()


def _canonical_json_equal(left: object, right: object) -> bool:
    return _canonical_json_bytes(left) == _canonical_json_bytes(right)


def _read_file_bytes(path: Path, field: str, maximum_bytes: int | None = None) -> bytes:
    try:
        if maximum_bytes is None:
            return path.read_bytes()
        with path.open("rb") as source:
            encoded = source.read(maximum_bytes + 1)
    except OSError as error:
        raise OracleError(f"cannot read {field} {path}: {error}") from error
    if len(encoded) > maximum_bytes:
        raise OracleError(f"{field} exceeds the {maximum_bytes}-byte limit: {path}")
    return encoded


def _open_canonical_directory(path: Path, field: str) -> tuple[int, Path]:
    if not hasattr(os, "O_NOFOLLOW"):
        raise OracleError("this platform cannot enforce the no-symlink file contract")
    try:
        canonical = path.resolve(strict=True)
    except OSError as error:
        raise OracleError(
            f"cannot resolve {field} directory {path}: {error}"
        ) from error

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    directory_fd = -1
    try:
        directory_fd = os.open(canonical.anchor, flags)
        for component in canonical.parts[1:]:
            next_fd = os.open(component, flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        return directory_fd, canonical
    except OSError as error:
        if directory_fd >= 0:
            os.close(directory_fd)
        raise OracleError(
            f"cannot open {field} directory without following symbolic links: {error}"
        ) from error


def _open_relative_regular_file(root: Path, relative: Path, field: str) -> int:
    if (
        relative.is_absolute()
        or relative == Path(".")
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise OracleError(f"{field} must be a safe relative regular-file path")
    directory_fd, _ = _open_canonical_directory(root, field)
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    file_flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        file_flags |= os.O_NONBLOCK
    if hasattr(os, "O_CLOEXEC"):
        directory_flags |= os.O_CLOEXEC
        file_flags |= os.O_CLOEXEC

    file_fd = -1
    try:
        for component in relative.parts[:-1]:
            next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(relative.name, file_flags, dir_fd=directory_fd)
        metadata = os.fstat(file_fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise OracleError(f"{field} must be a real regular file")
        os.close(directory_fd)
        directory_fd = -1
        result = file_fd
        file_fd = -1
        return result
    except OracleError:
        raise
    except OSError as error:
        raise OracleError(
            f"cannot open {field} without following symbolic links: {error}"
        ) from error
    finally:
        if file_fd >= 0:
            os.close(file_fd)
        if directory_fd >= 0:
            os.close(directory_fd)


def _read_relative_regular_file_once(
    root: Path,
    relative: Path,
    field: str,
    maximum_bytes: int | None = None,
) -> bytes:
    file_fd = _open_relative_regular_file(root, relative, field)
    try:
        chunks: list[bytes] = []
        byte_count = 0
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            byte_count += len(chunk)
            if maximum_bytes is not None and byte_count > maximum_bytes:
                raise OracleError(f"{field} exceeds the {maximum_bytes}-byte limit")
            chunks.append(chunk)
        return b"".join(chunks)
    except OracleError:
        raise
    except OSError as error:
        raise OracleError(f"cannot read {field}: {error}") from error
    finally:
        os.close(file_fd)


def _hash_relative_regular_file_once(
    root: Path,
    relative: Path,
    field: str,
    maximum_bytes: int | None = None,
) -> tuple[int, str]:
    file_fd = _open_relative_regular_file(root, relative, field)
    digest = hashlib.sha256()
    byte_count = 0
    try:
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            byte_count += len(chunk)
            if maximum_bytes is not None and byte_count > maximum_bytes:
                raise OracleError(f"{field} exceeds its {maximum_bytes}-byte contract")
            digest.update(chunk)
        return byte_count, digest.hexdigest()
    except OracleError:
        raise
    except OSError as error:
        raise OracleError(f"cannot read {field}: {error}") from error
    finally:
        os.close(file_fd)


def _read_regular_file_once(
    path: Path, field: str, maximum_bytes: int | None = None
) -> bytes:
    try:
        parent = path.parent.resolve(strict=True)
    except OSError as error:
        raise OracleError(
            f"cannot resolve {field} parent {path.parent}: {error}"
        ) from error
    return _read_relative_regular_file_once(
        parent, Path(path.name), field, maximum_bytes
    )


def _open_child_directory(
    parent_fd: int, name: str, field: str, *, create: bool, exclusive: bool = False
) -> int:
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent_fd)
        except FileExistsError:
            if exclusive:
                raise OracleError(f"refusing existing {field}") from None
        except OSError as error:
            raise OracleError(f"cannot create {field}: {error}") from error
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        return os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        raise OracleError(
            f"cannot open {field} without following symbolic links: {error}"
        ) from error


def _create_acquisition_directory(
    session_path: Path, slot_id: str, name: str
) -> tuple[int, Path]:
    directory_fd, root = _open_canonical_directory(
        session_path.parent, "session artifact"
    )
    try:
        for component in ("artifacts", slot_id):
            next_fd = _open_child_directory(
                directory_fd,
                component,
                f"artifact directory {component}",
                create=True,
            )
            os.close(directory_fd)
            directory_fd = next_fd
        acquisition_fd = _open_child_directory(
            directory_fd,
            name,
            f"acquisition directory {name}",
            create=True,
            exclusive=True,
        )
        return acquisition_fd, root / "artifacts" / slot_id / name
    finally:
        os.close(directory_fd)


def _persist_relative_bytes(
    root_fd: int, relative: str, encoded: bytes, field: str
) -> None:
    parts = relative.split("/")
    directory_fd = os.dup(root_fd)
    file_fd = -1
    try:
        for component in parts[:-1]:
            next_fd = _open_child_directory(
                directory_fd,
                component,
                f"{field} directory {component}",
                create=True,
            )
            os.close(directory_fd)
            directory_fd = next_fd
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        file_fd = os.open(parts[-1], flags, 0o600, dir_fd=directory_fd)
        offset = 0
        while offset < len(encoded):
            written = os.write(file_fd, encoded[offset:])
            if written <= 0:
                raise OSError("write returned no progress")
            offset += written
        os.fsync(file_fd)
    except OracleError:
        raise
    except OSError as error:
        raise OracleError(f"cannot persist {field}: {error}") from error
    finally:
        if file_fd >= 0:
            os.close(file_fd)
        os.close(directory_fd)


def _validated_session_child_directory(
    session_directory: Path, child: Path, name: str
) -> Path:
    if child.is_symlink() or not child.is_dir():
        raise OracleError(f"session {name} path must be a real directory")
    try:
        resolved = child.resolve(strict=True)
        relative = resolved.relative_to(session_directory)
    except (OSError, ValueError) as error:
        raise OracleError(
            f"session {name} directory escapes the canonical session directory"
        ) from error
    if relative != Path(name):
        raise OracleError(
            f"session {name} directory is not its canonical session child"
        )
    return resolved


def _prepare_session_directories(session_path: Path) -> tuple[Path, Path, Path]:
    if session_path.is_symlink() or session_path.exists():
        raise OracleError(f"refusing to overwrite existing session: {session_path}")
    requested_requests = session_path.parent / "requests"
    if requested_requests.is_symlink() or requested_requests.exists():
        raise OracleError(
            f"refusing pre-existing or aliased requests directory: {requested_requests}"
        )

    session_directory = session_path.parent.resolve()
    try:
        session_directory.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise OracleError(
            f"cannot create canonical session directory {session_directory}: {error}"
        ) from error
    if not session_directory.is_dir():
        raise OracleError(
            f"canonical session directory is not a directory: {session_directory}"
        )

    canonical_session_path = session_directory / session_path.name
    if canonical_session_path.is_symlink() or canonical_session_path.exists():
        raise OracleError(
            f"refusing to overwrite existing session: {canonical_session_path}"
        )
    requests_directory = session_directory / "requests"
    if requests_directory.is_symlink() or requests_directory.exists():
        raise OracleError(
            f"refusing pre-existing or aliased requests directory: {requests_directory}"
        )
    try:
        requests_directory.mkdir(mode=0o700)
    except OSError as error:
        raise OracleError(
            f"cannot create canonical requests directory {requests_directory}: {error}"
        ) from error
    requests_directory = _validated_session_child_directory(
        session_directory, requests_directory, "requests"
    )
    return canonical_session_path, session_directory, requests_directory


def _stored_artifact_path(session_path: Path, slot_id: str, value: object) -> Path:
    relative_text = _require_string(value, f"{slot_id} artifact path")
    relative = Path(relative_text)
    expected_parent = Path("artifacts") / slot_id
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or relative == Path(".")
        or not relative.is_relative_to(expected_parent)
    ):
        raise OracleError(f"{slot_id}: artifact path escapes its slot directory")
    root = session_path.parent.resolve()
    candidate = root
    for part in relative.parts:
        candidate /= part
        if candidate.is_symlink():
            raise OracleError(f"{slot_id}: artifact path traverses a symbolic link")
    return candidate


def _paeth(left: int, up: int, upper_left: int) -> int:
    estimate = left + up - upper_left
    left_distance = abs(estimate - left)
    up_distance = abs(estimate - up)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= up_distance and left_distance <= upper_left_distance:
        return left
    if up_distance <= upper_left_distance:
        return up
    return upper_left


def _decode_png_bytes(
    png: bytes,
    label: str,
    expected_dimensions: tuple[int, int] | None = None,
    expected_color_type: int | None = None,
) -> tuple[int, int, bytes]:
    if len(png) > MAX_PNG_BYTES:
        raise OracleError(f"PNG is unreasonably large: {label}")
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        raise OracleError(f"capture is not a PNG: {label}")

    offset = 8
    dimensions: tuple[int, int] | None = None
    channels = 0
    compressed = bytearray()
    compressed_limit = 0
    saw_srgb = False
    saw_gamma = False
    saw_chromaticities = False
    saw_palette = False
    saw_image_data = False
    image_data_ended = False
    chunk_index = 0
    while True:
        if offset + 12 > len(png):
            raise OracleError(f"capture has a truncated PNG chunk: {label}")
        length, chunk_type = struct.unpack_from(">I4s", png, offset)
        offset += 8
        end = offset + length
        if end + 4 > len(png):
            raise OracleError(f"capture has a truncated PNG chunk: {label}")
        data = png[offset:end]
        expected_crc = struct.unpack_from(">I", png, end)[0]
        offset = end + 4
        if not all(
            65 <= character <= 90 or 97 <= character <= 122 for character in chunk_type
        ):
            raise OracleError(f"capture has an invalid PNG chunk name: {label}")
        if chunk_type[2] & 0x20:
            raise OracleError(
                f"capture has a lowercase reserved PNG chunk bit: {label}"
            )
        if zlib.crc32(chunk_type + data) & 0xFFFFFFFF != expected_crc:
            raise OracleError(f"capture has an invalid PNG checksum: {label}")

        if chunk_type == b"IHDR":
            if chunk_index != 0 or dimensions is not None or length != 13:
                raise OracleError(f"capture has an invalid PNG header: {label}")
            (
                width,
                height,
                bit_depth,
                color_type,
                compression,
                filtering,
                interlace,
            ) = struct.unpack(">IIBBBBB", data)
            if (
                width == 0
                or height == 0
                or bit_depth != 8
                or color_type not in {2, 6}
                or compression != 0
                or filtering != 0
                or interlace != 0
            ):
                raise OracleError(
                    f"capture must be a non-interlaced 8-bit RGB or RGBA PNG: {label}"
                )
            if expected_color_type is not None and color_type != expected_color_type:
                expected_name = "RGB" if expected_color_type == 2 else "RGBA"
                raise OracleError(f"capture must use {expected_name} pixels: {label}")
            dimensions = (width, height)
            channels = 3 if color_type == 2 else 4
            if expected_dimensions is not None and dimensions != expected_dimensions:
                raise OracleError(
                    f"capture dimensions are {width}x{height}; expected "
                    f"{expected_dimensions[0]}x{expected_dimensions[1]}: {label}"
                )
            if width * height > 64 * 1024 * 1024:
                raise OracleError(f"capture dimensions are unreasonable: {label}")
            decoded_size = height * (width * channels + 1)
            compressed_limit = min(MAX_PNG_BYTES, max(64 * 1024, decoded_size * 2))
        elif chunk_type == b"sRGB":
            if saw_srgb or saw_palette or saw_image_data or length != 1 or data[0] > 3:
                raise OracleError(f"capture has an invalid sRGB declaration: {label}")
            saw_srgb = True
        elif chunk_type == b"gAMA":
            if (
                saw_gamma
                or saw_palette
                or saw_image_data
                or length != 4
                or struct.unpack(">I", data)[0] != 45455
            ):
                raise OracleError(f"capture has a non-sRGB gamma declaration: {label}")
            saw_gamma = True
        elif chunk_type == b"cHRM":
            canonical_chromaticities = (
                31270,
                32900,
                64000,
                33000,
                30000,
                60000,
                15000,
                6000,
            )
            if (
                saw_chromaticities
                or saw_palette
                or saw_image_data
                or length != 32
                or struct.unpack(">8I", data) != canonical_chromaticities
            ):
                raise OracleError(
                    f"capture has a non-sRGB chromaticity declaration: {label}"
                )
            saw_chromaticities = True
        elif chunk_type in {b"iCCP", b"cICP"}:
            raise OracleError(f"capture has a conflicting color profile: {label}")
        elif chunk_type in {b"acTL", b"fcTL", b"fdAT"}:
            raise OracleError(f"animated PNG captures are not supported: {label}")
        elif chunk_type == b"tRNS":
            raise OracleError(f"capture has ambiguous PNG transparency: {label}")
        elif chunk_type == b"PLTE":
            if (
                saw_palette
                or saw_image_data
                or length == 0
                or length > 768
                or length % 3
            ):
                raise OracleError(f"capture has an invalid PNG palette: {label}")
            saw_palette = True
        elif chunk_type == b"IDAT":
            if dimensions is None or image_data_ended:
                raise OracleError(f"capture has non-contiguous PNG image data: {label}")
            if len(compressed) + length > compressed_limit:
                raise OracleError(f"capture has excessive compressed PNG data: {label}")
            saw_image_data = True
            compressed.extend(data)
        elif chunk_type == b"IEND":
            if length != 0 or not saw_image_data:
                raise OracleError(f"capture has an invalid PNG terminator: {label}")
            if offset != len(png):
                raise OracleError(f"capture has data after the PNG terminator: {label}")
            break
        else:
            if chunk_type[0] & 0x20 == 0:
                name = chunk_type.decode("ascii", errors="replace")
                raise OracleError(
                    f"capture has unsupported critical PNG chunk {name}: {label}"
                )
            if saw_image_data:
                image_data_ended = True
        chunk_index += 1

    if dimensions is None:
        raise OracleError(f"capture has no PNG header: {label}")
    if not saw_srgb and saw_gamma != saw_chromaticities:
        raise OracleError(f"capture has an incomplete sRGB color declaration: {label}")
    width, height = dimensions
    row_bytes = width * channels
    expected_size = height * (row_bytes + 1)
    decoder = zlib.decompressobj()
    try:
        scanlines = decoder.decompress(bytes(compressed), expected_size + 1)
        if decoder.unconsumed_tail or len(scanlines) > expected_size:
            raise OracleError(f"capture expands beyond its PNG dimensions: {label}")
        scanlines += decoder.flush(expected_size + 1 - len(scanlines))
    except zlib.error as error:
        raise OracleError(
            f"capture has invalid compressed PNG image data: {label}"
        ) from error
    if (
        not decoder.eof
        or decoder.unused_data
        or decoder.unconsumed_tail
        or len(scanlines) != expected_size
    ):
        raise OracleError(f"capture has incomplete PNG image data: {label}")

    previous = bytearray(row_bytes)
    rgba = bytearray(width * height * 4)
    source_offset = 0
    output_offset = 0
    for _ in range(height):
        filter_type = scanlines[source_offset]
        source_offset += 1
        if filter_type > 4:
            raise OracleError(f"capture has an invalid PNG row filter: {label}")
        row = bytearray(scanlines[source_offset : source_offset + row_bytes])
        source_offset += row_bytes
        if filter_type:
            for index, encoded in enumerate(row):
                left = row[index - channels] if index >= channels else 0
                up = previous[index]
                upper_left = previous[index - channels] if index >= channels else 0
                if filter_type == 1:
                    row[index] = (encoded + left) & 0xFF
                elif filter_type == 2:
                    row[index] = (encoded + up) & 0xFF
                elif filter_type == 3:
                    row[index] = (encoded + ((left + up) // 2)) & 0xFF
                elif filter_type == 4:
                    row[index] = (encoded + _paeth(left, up, upper_left)) & 0xFF
        if channels == 4:
            rgba[output_offset : output_offset + width * 4] = row
        else:
            for pixel in range(width):
                rgb_offset = pixel * 3
                rgba_offset = output_offset + pixel * 4
                rgba[rgba_offset : rgba_offset + 3] = row[rgb_offset : rgb_offset + 3]
                rgba[rgba_offset + 3] = 255
        output_offset += width * 4
        previous = row
    return width, height, bytes(rgba)


def _decode_png(
    path: Path,
    expected_dimensions: tuple[int, int] | None = None,
    expected_color_type: int | None = None,
) -> tuple[int, int, bytes]:
    return _decode_png_bytes(
        _read_file_bytes(path, "capture", MAX_PNG_BYTES),
        str(path),
        expected_dimensions,
        expected_color_type,
    )


def _png_dimensions(path: Path) -> tuple[int, int]:
    width, height, _ = _decode_png(path)
    return width, height


def _self_variance(captures: list[bytes]) -> dict[str, object]:
    if len(captures) < 2 or not captures[0] or len(captures[0]) % 4:
        raise OracleError("self-variance requires at least two decoded RGBA captures")
    reference_size = len(captures[0])
    if any(len(capture) != reference_size for capture in captures[1:]):
        raise OracleError("self-variance captures have different decoded sizes")
    ordered_captures = sorted(captures)

    rgb_difference_counts = [0] * 65536
    alpha_difference_counts = [0] * 65536
    identical_pixels = 0
    pixel_count = reference_size // 4
    comparison_count = len(ordered_captures) * (len(ordered_captures) - 1) // 2
    for left_index in range(len(ordered_captures) - 1):
        for right_index in range(left_index + 1, len(ordered_captures)):
            left_capture = ordered_captures[left_index]
            right_capture = ordered_captures[right_index]
            identical_pixels += sum(
                left_pixel == right_pixel
                for left_pixel, right_pixel in zip_longest(
                    struct.iter_unpack("<I", left_capture),
                    struct.iter_unpack("<I", right_capture),
                )
            )
            for channel in range(4):
                pair_counts = Counter(
                    zip_longest(left_capture[channel::4], right_capture[channel::4])
                )
                counts = (
                    alpha_difference_counts if channel == 3 else rgb_difference_counts
                )
                for (left_byte, right_byte), count in pair_counts.items():
                    low = min(left_byte, right_byte)
                    high = max(left_byte, right_byte)
                    counts[(low << 8) | high] += count
    channel_sample_count = pixel_count * 4 * comparison_count
    pixel_sample_count = pixel_count * comparison_count

    def weighted_difference_terms(square: bool = False):
        for counts, alpha in (
            (rgb_difference_counts, False),
            (alpha_difference_counts, True),
        ):
            for key, count in enumerate(counts):
                if not count:
                    continue
                low = key >> 8
                high = key & 0xFF
                difference = (
                    (high - low) / 255.0
                    if alpha
                    else SRGB_TO_LINEAR[high] - SRGB_TO_LINEAR[low]
                )
                value = difference * difference if square else difference
                yield value * (count / channel_sample_count)

    mean_absolute_error = math.fsum(weighted_difference_terms())
    mean_square_error = math.fsum(weighted_difference_terms(square=True))
    maximum = 0.0
    for counts, alpha in (
        (rgb_difference_counts, False),
        (alpha_difference_counts, True),
    ):
        for key, count in enumerate(counts):
            if not count:
                continue
            low = key >> 8
            high = key & 0xFF
            difference = (
                (high - low) / 255.0
                if alpha
                else SRGB_TO_LINEAR[high] - SRGB_TO_LINEAR[low]
            )
            maximum = max(maximum, difference)
    return {
        "method": "linear_srgb_rgba8_all_pairs_v1",
        "units": "normalized_linear_0_1",
        "comparison_count": comparison_count,
        "channel_sample_count": channel_sample_count,
        "pixel_sample_count": pixel_sample_count,
        "mean_absolute_error": round(mean_absolute_error, 12),
        "rmse": round(math.sqrt(mean_square_error), 12),
        "max_absolute_error": round(maximum, 12),
        "identical_pixel_fraction": round(identical_pixels / pixel_sample_count, 12),
    }


def _require_object(value: object, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise OracleError(f"{field} must be an object")
    return value


def _require_exact_keys(
    value: object, field: str, expected: set[str]
) -> dict[str, object]:
    document = _require_object(value, field)
    actual = set(document)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(f"unexpected {', '.join(extra)}")
        raise OracleError(f"{field} has invalid fields ({'; '.join(details)})")
    return document


def _require_array(value: object, field: str) -> list[object]:
    if not isinstance(value, list):
        raise OracleError(f"{field} must be an array")
    return value


def _require_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise OracleError(f"{field} must be a non-empty string")
    return value


def _require_number(value: object, field: str, minimum: float = 0.0) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise OracleError(f"{field} must be a number >= {minimum}")
    number = float(value)
    if not math.isfinite(number) or number < minimum:
        raise OracleError(f"{field} must be a finite number >= {minimum}")
    return number


def _require_integer(value: object, field: str, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise OracleError(f"{field} must be an integer >= {minimum}")
    return value


def _require_exact_integer(value: object, field: str, expected: int) -> int:
    integer = _require_integer(value, field)
    if integer != expected:
        raise OracleError(f"{field} must equal {expected}")
    return integer


def _require_u64(value: object, field: str) -> int:
    integer = _require_integer(value, field)
    if integer > (1 << 64) - 1:
        raise OracleError(f"{field} must fit in an unsigned 64-bit integer")
    return integer


def _require_hash(
    value: object, field: str, pattern: re.Pattern[str] = HASH_PATTERN
) -> str:
    digest = _require_string(value, field)
    if not pattern.fullmatch(digest):
        raise OracleError(f"{field} has an invalid hash")
    return digest


def _require_session_id(value: object, field: str) -> str:
    session_id = _require_string(value, field)
    if not SESSION_ID_PATTERN.fullmatch(session_id):
        raise OracleError(f"{field} must be a lowercase UUIDv4")
    return session_id


def _safe_fixture_relative_path(relative_value: object, field: str) -> Path:
    relative_text = _require_string(relative_value, field)
    relative = Path(relative_text)
    if (
        relative.is_absolute()
        or relative == Path(".")
        or "\\" in relative_text
        or any(part in {"", ".", ".."} for part in relative.parts)
        or any(
            re.fullmatch(r"[a-z0-9][a-z0-9._-]*", part) is None
            for part in relative.parts
        )
        or relative.as_posix() != relative_text
    ):
        raise OracleError(f"{field} must be a canonical safe relative path")
    return relative


def _validate_fixture_manifest(
    content: dict[str, object], field: str, fixture_root: Path
) -> None:
    availability = content["availability"]
    path_value = content.get("asset_manifest_path")
    bytes_value = content.get("asset_manifest_bytes")
    hash_value = content.get("asset_manifest_sha256")
    if availability == "missing":
        if any(value is not None for value in (path_value, bytes_value, hash_value)):
            raise OracleError(
                f"{field} must not claim a fixture manifest while availability is missing"
            )
        return

    manifest_relative = _safe_fixture_relative_path(
        path_value, f"{field}.asset_manifest_path"
    )
    expected_bytes = _require_integer(bytes_value, f"{field}.asset_manifest_bytes", 1)
    expected_hash = _require_string(hash_value, f"{field}.asset_manifest_sha256")
    if not HASH_PATTERN.fullmatch(expected_hash):
        raise OracleError(f"{field}.asset_manifest_sha256 must be a SHA-256 hash")
    if expected_bytes > MAX_JSON_BYTES:
        raise OracleError(
            f"{field}.asset_manifest_bytes exceeds the fixture manifest limit"
        )
    manifest_bytes = _read_relative_regular_file_once(
        fixture_root,
        manifest_relative,
        "fixture manifest",
        MAX_JSON_BYTES,
    )
    if len(manifest_bytes) != expected_bytes:
        raise OracleError(f"{field}.asset_manifest_bytes does not match the file")
    if hashlib.sha256(manifest_bytes).hexdigest() != expected_hash:
        raise OracleError(f"{field}.asset_manifest_sha256 does not match the file")

    fixture_manifest = _read_json_bytes(
        manifest_bytes, str(fixture_root / manifest_relative)
    )
    _require_exact_integer(
        fixture_manifest.get("schema"), f"{field} fixture manifest schema", 1
    )
    if fixture_manifest.get("fixture_id") != content["fixture_id"]:
        raise OracleError(f"{field} fixture manifest id does not match")
    if fixture_manifest.get("fixture_revision") != content["fixture_revision"]:
        raise OracleError(f"{field} fixture manifest revision does not match")
    assets = _require_array(fixture_manifest.get("assets"), f"{field}.assets")
    if not assets:
        raise OracleError(f"{field} fixture manifest assets must not be empty")
    seen_paths: set[Path] = set()
    manifest_parent = manifest_relative.parent
    for index, value in enumerate(assets):
        asset_field = f"{field}.assets[{index}]"
        asset = _require_object(value, asset_field)
        relative_path = _safe_fixture_relative_path(
            asset.get("path"), f"{asset_field}.path"
        )
        asset_path = manifest_parent / relative_path
        if asset_path in seen_paths:
            raise OracleError(f"{field} fixture manifest has duplicate asset paths")
        seen_paths.add(asset_path)
        asset_bytes = _require_integer(asset.get("bytes"), f"{asset_field}.bytes", 1)
        asset_hash = _require_string(asset.get("sha256"), f"{asset_field}.sha256")
        if not HASH_PATTERN.fullmatch(asset_hash):
            raise OracleError(f"{asset_field}.sha256 must be a SHA-256 hash")
        actual_bytes, actual_hash = _hash_relative_regular_file_once(
            fixture_root,
            asset_path,
            "fixture asset",
            asset_bytes,
        )
        if actual_bytes != asset_bytes:
            raise OracleError(f"{asset_field}.bytes does not match the file")
        if actual_hash != asset_hash:
            raise OracleError(f"{asset_field}.sha256 does not match the file")


def _validate_supporting_contracts(
    value: object, display: dict[str, object], field: str
) -> dict[str, object]:
    contracts = _require_object(value, field)
    for role, contract_value in contracts.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", role):
            raise OracleError(f"{field} contains an invalid role: {role}")
        contract = _require_object(contract_value, f"{field}.{role}")
        kind = contract.get("kind")
        if kind == "png":
            expected_keys = {
                "kind",
                "encoding",
                "width_px",
                "height_px",
                "interlaced",
            }
            if set(contract) != expected_keys:
                raise OracleError(f"{field}.{role} PNG contract fields are invalid")
            if contract.get("encoding") != "rgb_or_rgba8_srgb_encoded":
                raise OracleError(f"{field}.{role}.encoding is invalid")
            if contract.get("interlaced") is not False:
                raise OracleError(f"{field}.{role}.interlaced must be false")
            width = _require_integer(
                contract.get("width_px"), f"{field}.{role}.width_px", 1
            )
            height = _require_integer(
                contract.get("height_px"), f"{field}.{role}.height_px", 1
            )
            if (width, height) != (display["width_px"], display["height_px"]):
                raise OracleError(f"{field}.{role} dimensions must match the slot")
        elif kind == "raw":
            expected_keys = {
                "kind",
                "encoding",
                "origin",
                "width_px",
                "height_px",
                "row_pitch_bytes",
                "bytes",
            }
            if set(contract) != expected_keys:
                raise OracleError(f"{field}.{role} raw contract fields are invalid")
            encoding = contract.get("encoding")
            if encoding not in {
                "bgra8_unorm_srgb_encoded",
                "depth32_float_le_zero_to_one",
            }:
                raise OracleError(f"{field}.{role}.encoding is invalid")
            if contract.get("origin") != "top_left":
                raise OracleError(f"{field}.{role}.origin must be top_left")
            width = _require_integer(
                contract.get("width_px"), f"{field}.{role}.width_px", 1
            )
            height = _require_integer(
                contract.get("height_px"), f"{field}.{role}.height_px", 1
            )
            if (width, height) != (display["width_px"], display["height_px"]):
                raise OracleError(f"{field}.{role} dimensions must match the slot")
            row_pitch = _require_integer(
                contract.get("row_pitch_bytes"),
                f"{field}.{role}.row_pitch_bytes",
                1,
            )
            if row_pitch != width * 4:
                raise OracleError(
                    f"{field}.{role}.row_pitch_bytes must equal width * 4"
                )
            byte_count = _require_integer(
                contract.get("bytes"), f"{field}.{role}.bytes", 1
            )
            if byte_count != row_pitch * height:
                raise OracleError(f"{field}.{role}.bytes must equal row pitch * height")
        elif kind == "blob":
            if set(contract) != {"kind", "min_bytes", "max_bytes"}:
                raise OracleError(f"{field}.{role} blob contract fields are invalid")
            minimum_bytes = _require_integer(
                contract.get("min_bytes"), f"{field}.{role}.min_bytes", 1
            )
            maximum_bytes = _require_integer(
                contract.get("max_bytes"), f"{field}.{role}.max_bytes", minimum_bytes
            )
            if maximum_bytes > MAX_BLOB_BYTES:
                raise OracleError(
                    f"{field}.{role}.max_bytes exceeds the global blob limit"
                )
        else:
            raise OracleError(f"{field}.{role}.kind is invalid")
    return contracts


def _tools_readback_contract(display: dict[str, object]) -> dict[str, object]:
    width = display["width_px"]
    height = display["height_px"]
    row_pitch = width * 4
    byte_count = row_pitch * height
    return {
        "local_snapshot": {
            "kind": "png",
            "encoding": "rgb_or_rgba8_srgb_encoded",
            "width_px": width,
            "height_px": height,
            "interlaced": False,
        },
        "raw_color": {
            "kind": "raw",
            "encoding": "bgra8_unorm_srgb_encoded",
            "origin": "top_left",
            "width_px": width,
            "height_px": height,
            "row_pitch_bytes": row_pitch,
            "bytes": byte_count,
        },
        "raw_depth": {
            "kind": "raw",
            "encoding": "depth32_float_le_zero_to_one",
            "origin": "top_left",
            "width_px": width,
            "height_px": height,
            "row_pitch_bytes": row_pitch,
            "bytes": byte_count,
        },
    }


def _validate_supporting_artifact_bytes(
    role: str, data: bytes, label: str, contract: dict[str, object]
) -> None:
    kind = contract["kind"]
    if kind == "png":
        _decode_png_bytes(
            data,
            label,
            (contract["width_px"], contract["height_px"]),
        )
        return
    size = len(data)
    if kind == "blob":
        if size < contract["min_bytes"]:
            raise OracleError(f"supporting artifact {role} is empty or truncated")
        if size > contract["max_bytes"]:
            raise OracleError(f"supporting artifact {role} exceeds its byte limit")
        return
    if size != contract["bytes"]:
        raise OracleError(
            f"supporting artifact {role} has {size} bytes; expected {contract['bytes']}"
        )
    if contract["encoding"] == "depth32_float_le_zero_to_one":
        for (depth,) in struct.iter_unpack("<f", data):
            if not math.isfinite(depth) or not 0.0 <= depth <= 1.0:
                raise OracleError(
                    f"supporting artifact {role} contains an invalid depth value"
                )


def _supporting_artifact_read_limit(contract: dict[str, object]) -> int | None:
    if contract["kind"] == "png":
        return MAX_PNG_BYTES
    if contract["kind"] == "raw":
        return int(contract["bytes"])
    return int(contract["max_bytes"])


def _validate_tools_readback_consistency(
    artifacts: dict[str, bytes], contracts: dict[str, object]
) -> None:
    snapshot = artifacts["local_snapshot"]
    raw_color = artifacts["raw_color"]
    contract = contracts["local_snapshot"]
    _, _, snapshot_rgba = _decode_png_bytes(
        snapshot,
        "local_snapshot",
        (contract["width_px"], contract["height_px"]),
    )
    snapshot_has_alpha = snapshot[25] == 6
    for pixel_offset in range(0, len(snapshot_rgba), 4):
        snapshot_red = snapshot_rgba[pixel_offset]
        snapshot_green = snapshot_rgba[pixel_offset + 1]
        snapshot_blue = snapshot_rgba[pixel_offset + 2]
        snapshot_alpha = snapshot_rgba[pixel_offset + 3]
        raw_blue = raw_color[pixel_offset]
        raw_green = raw_color[pixel_offset + 1]
        raw_red = raw_color[pixel_offset + 2]
        raw_alpha = raw_color[pixel_offset + 3]
        if (
            snapshot_red != raw_red
            or snapshot_green != raw_green
            or snapshot_blue != raw_blue
            or (snapshot_has_alpha and snapshot_alpha != raw_alpha)
        ):
            pixel_index = pixel_offset // 4
            raise OracleError(
                "tools_readback local_snapshot pixels do not match raw_color "
                f"BGRA bytes at pixel {pixel_index}"
            )


def _validate_conditions(value: object, field: str, fixture_root: Path) -> None:
    conditions = _require_object(value, field)
    required = {"settings", "camera", "content", "environment", "display"}
    missing = sorted(required - conditions.keys())
    if missing:
        raise OracleError(f"{field} is missing: {', '.join(missing)}")

    settings = _require_object(conditions["settings"], f"{field}.settings")
    if not settings or not all(isinstance(key, str) for key in settings):
        raise OracleError(f"{field}.settings must contain named settings")

    camera = _require_object(conditions["camera"], f"{field}.camera")
    _require_string(camera.get("mode"), f"{field}.camera.mode")
    if camera.get("mode") != "not_applicable":
        render_target_settings = {
            "RenderHDREnabled": True,
            "RenderEnableEmissiveBuffer": False,
        }
        for setting, expected in render_target_settings.items():
            if settings.get(setting) is not expected:
                raise OracleError(
                    f"{field}.settings.{setting} must be pinned to "
                    f"{str(expected).lower()} for a rendered-world slot"
                )
        for name in ("position_m", "look_at_m"):
            vector = _require_array(camera.get(name), f"{field}.camera.{name}")
            if len(vector) != 3:
                raise OracleError(f"{field}.camera.{name} must have three values")
            for index, component in enumerate(vector):
                _require_number(component, f"{field}.camera.{name}[{index}]")
        _require_number(
            camera.get("vertical_fov_degrees"),
            f"{field}.camera.vertical_fov_degrees",
            minimum=1.0,
        )

    content = _require_object(conditions["content"], f"{field}.content")
    _require_string(content.get("fixture_id"), f"{field}.content.fixture_id")
    _require_string(
        content.get("fixture_revision"), f"{field}.content.fixture_revision"
    )
    availability = _require_string(
        content.get("availability"), f"{field}.content.availability"
    )
    if availability not in {"missing", "available", "baseline_builtin"}:
        raise OracleError(
            f"{field}.content.availability must be missing, available, or baseline_builtin"
        )
    asset_hash = content.get("asset_manifest_sha256")
    if asset_hash is not None and (
        not isinstance(asset_hash, str) or not HASH_PATTERN.fullmatch(asset_hash)
    ):
        raise OracleError(
            f"{field}.content.asset_manifest_sha256 must be null or a SHA-256 hash"
        )
    _validate_fixture_manifest(content, f"{field}.content", fixture_root)
    requirements = _require_array(
        content.get("requirements"), f"{field}.content.requirements"
    )
    if not requirements or not all(
        isinstance(item, str) and item for item in requirements
    ):
        raise OracleError(f"{field}.content.requirements must contain descriptions")

    environment = _require_object(conditions["environment"], f"{field}.environment")
    _require_string(environment.get("mode"), f"{field}.environment.mode")
    environment_asset = environment.get("asset_id")
    if environment_asset is not None and (
        not isinstance(environment_asset, str) or not environment_asset
    ):
        raise OracleError(f"{field}.environment.asset_id must be null or non-empty")
    if environment.get("mode") != "not_applicable":
        _require_string(
            environment.get("time_of_day"), f"{field}.environment.time_of_day"
        )
        _require_string(environment.get("weather"), f"{field}.environment.weather")

    display = _require_object(conditions["display"], f"{field}.display")
    _require_integer(display.get("width_px"), f"{field}.display.width_px", 1)
    _require_integer(display.get("height_px"), f"{field}.display.height_px", 1)
    _require_number(display.get("scale_factor"), f"{field}.display.scale_factor", 1.0)
    if display.get("color_space") != "sRGB":
        raise OracleError(f"{field}.display.color_space must be sRGB")
    if display.get("window_mode") != "windowed_no_occlusion":
        raise OracleError(f"{field}.display.window_mode must be windowed_no_occlusion")


def _validate_typed_machine_contract(
    value: object, conditions: dict[str, object], field: str
) -> None:
    contract = _require_exact_keys(
        value,
        field,
        {"schema", "kind", "expected", "producer"},
    )
    _require_exact_integer(contract.get("schema"), f"{field}.schema", 1)
    if contract.get("kind") != "typed_runtime_state_v1":
        raise OracleError(f"{field}.kind must be typed_runtime_state_v1")

    expected = _require_exact_keys(
        contract.get("expected"),
        f"{field}.expected",
        {
            "runtime_settings",
            "camera",
            "environment",
            "display",
            "fixture_state",
        },
    )
    for expected_name, condition_name in (
        ("runtime_settings", "settings"),
        ("camera", "camera"),
        ("environment", "environment"),
        ("display", "display"),
    ):
        observed = _require_object(
            expected.get(expected_name), f"{field}.expected.{expected_name}"
        )
        if not _canonical_json_equal(observed, conditions[condition_name]):
            raise OracleError(
                f"{field}.expected.{expected_name} must exactly bind "
                f"conditions.{condition_name}"
            )

    fixture = _require_exact_keys(
        expected.get("fixture_state"),
        f"{field}.expected.fixture_state",
        {
            "schema",
            "driver",
            "fixture_id",
            "fixture_revision",
            "asset_manifest_sha256",
            "state",
        },
    )
    _require_exact_integer(
        fixture.get("schema"), f"{field}.expected.fixture_state.schema", 1
    )
    driver = _require_string(
        fixture.get("driver"), f"{field}.expected.fixture_state.driver"
    )
    if not re.fullmatch(r"[a-z][a-z0-9_]*_v[1-9][0-9]*", driver):
        raise OracleError(
            f"{field}.expected.fixture_state.driver must be a versioned driver id"
        )
    content = conditions["content"]
    for name in ("fixture_id", "fixture_revision", "asset_manifest_sha256"):
        if fixture.get(name) != content[name]:
            raise OracleError(
                f"{field}.expected.fixture_state.{name} must exactly bind "
                f"conditions.content.{name}"
            )
    _require_hash(
        fixture.get("asset_manifest_sha256"),
        f"{field}.expected.fixture_state.asset_manifest_sha256",
    )
    state = _require_object(
        fixture.get("state"), f"{field}.expected.fixture_state.state"
    )
    if not state:
        raise OracleError(f"{field}.expected.fixture_state.state must not be empty")

    producer = _require_exact_keys(
        contract.get("producer"),
        f"{field}.producer",
        {"instrumentation_commit", "executable_sha256"},
    )
    _require_hash(
        producer.get("instrumentation_commit"),
        f"{field}.producer.instrumentation_commit",
        COMMIT_PATTERN,
    )
    _require_hash(
        producer.get("executable_sha256"),
        f"{field}.producer.executable_sha256",
    )


def _validate_missing_evidence(value: object, field: str) -> None:
    evidence = _require_object(value, field)
    if evidence.get("status") != "missing":
        raise OracleError(f"{field}.status must be missing in the corpus template")
    if evidence.get("captures") != []:
        raise OracleError(f"{field}.captures must be empty while evidence is missing")
    if evidence.get("supporting_artifacts") != []:
        raise OracleError(
            f"{field}.supporting_artifacts must be empty while evidence is missing"
        )
    for name in (
        "self_variance",
        "frame_timing_ms",
        "memory_mib",
        "hardware_os",
        "known_quirks",
    ):
        if evidence.get(name) is not None:
            raise OracleError(f"{field}.{name} must be null while evidence is missing")


def validate_manifest(
    document: dict[str, object], fixture_root: Path | None = None
) -> None:
    fixture_root = fixture_root or repository_root()
    _require_exact_integer(document.get("schema"), "manifest schema", 2)
    if document.get("kind") != "firestorm-opengl-oracle-corpus":
        raise OracleError("manifest kind must be firestorm-opengl-oracle-corpus")

    baseline = _require_exact_keys(
        document.get("baseline"),
        "baseline",
        {"remote", "commit", "renderer"},
    )
    _require_string(baseline.get("remote"), "baseline.remote")
    commit = _require_string(baseline.get("commit"), "baseline.commit")
    if not COMMIT_PATTERN.fullmatch(commit):
        raise OracleError("baseline.commit must be a lowercase 40-character hash")
    if baseline.get("renderer") != "OpenGL":
        raise OracleError("baseline.renderer must be OpenGL")

    contract = _require_exact_keys(
        document.get("capture_contract"),
        "capture_contract",
        {
            "repetitions",
            "warmup_frames",
            "measurement_frames",
            "capture_format",
            "capture_encoding",
            "png_interlaced",
            "self_variance_method",
            "cpu_timing_scope",
            "gpu_timing_scope",
            "gpu_memory_method",
            "renderer_accounted_gpu_memory_sources",
            "platform",
            "notes",
        },
    )
    _require_exact_integer(
        contract.get("repetitions"), "capture_contract.repetitions", 3
    )
    _require_exact_integer(
        contract.get("warmup_frames"), "capture_contract.warmup_frames", 300
    )
    _require_exact_integer(
        contract.get("measurement_frames"),
        "capture_contract.measurement_frames",
        600,
    )
    if contract.get("capture_format") != "png":
        raise OracleError("capture_contract.capture_format must be png")
    if contract.get("capture_encoding") != "rgb_or_rgba8_srgb":
        raise OracleError("capture_contract.capture_encoding must be rgb_or_rgba8_srgb")
    if contract.get("png_interlaced") is not False:
        raise OracleError("capture_contract.png_interlaced must be false")
    if contract.get("self_variance_method") != "linear_srgb_rgba8_all_pairs_v1":
        raise OracleError(
            "capture_contract.self_variance_method must be "
            "linear_srgb_rgba8_all_pairs_v1"
        )
    if contract.get("cpu_timing_scope") != CPU_TIMING_SCOPE:
        raise OracleError(
            f"capture_contract.cpu_timing_scope must be {CPU_TIMING_SCOPE}"
        )
    if contract.get("gpu_timing_scope") != GPU_TIMING_SCOPE:
        raise OracleError(
            f"capture_contract.gpu_timing_scope must be {GPU_TIMING_SCOPE}"
        )
    if contract.get("gpu_memory_method") != GPU_MEMORY_METHOD:
        raise OracleError(
            f"capture_contract.gpu_memory_method must be {GPU_MEMORY_METHOD}"
        )
    memory_sources = _require_array(
        contract.get("renderer_accounted_gpu_memory_sources"),
        "capture_contract.renderer_accounted_gpu_memory_sources",
    )
    if memory_sources != list(GPU_MEMORY_SOURCES):
        raise OracleError(
            "capture_contract.renderer_accounted_gpu_memory_sources must use the "
            "canonical renderer-accounted provenance"
        )
    notes = _require_array(contract.get("notes"), "capture_contract.notes")
    if not all(isinstance(note, str) and note for note in notes):
        raise OracleError("capture_contract.notes must contain only non-empty strings")
    platform = _require_exact_keys(
        contract.get("platform"),
        "capture_contract.platform",
        {"os", "architecture"},
    )
    if platform.get("os") != "macOS":
        raise OracleError("capture_contract.platform.os must be macOS")
    if platform.get("architecture") != "arm64":
        raise OracleError("capture_contract.platform.architecture must be arm64")

    slots = _require_array(document.get("slots"), "slots")
    if not slots:
        raise OracleError("slots must not be empty")
    seen_ids: set[str] = set()
    groups: set[str] = set()
    features: set[str] = set()
    for index, value in enumerate(slots):
        field = f"slots[{index}]"
        slot = _require_object(value, field)
        slot_id = _require_string(slot.get("id"), f"{field}.id")
        if not re.fullmatch(r"[a-z][a-z0-9_]*", slot_id):
            raise OracleError(f"{field}.id must be a stable snake_case identifier")
        if slot_id in seen_ids:
            raise OracleError(f"duplicate slot id: {slot_id}")
        seen_ids.add(slot_id)
        if slot.get("required") is not True:
            raise OracleError(f"{field}.required must be true")
        groups.add(_require_string(slot.get("group"), f"{field}.group"))
        feature_values = _require_array(slot.get("features"), f"{field}.features")
        if not feature_values or not all(
            isinstance(feature, str) and feature for feature in feature_values
        ):
            raise OracleError(f"{field}.features must contain stable feature names")
        features.update(feature_values)
        _require_string(slot.get("description"), f"{field}.description")
        _validate_conditions(
            slot.get("conditions"), f"{field}.conditions", fixture_root
        )
        if slot_id == "login_ui":
            settings = slot["conditions"]["settings"]
            if settings.get("LoginPage") != LOGIN_PAGE_URL:
                raise OracleError(
                    f"{field}.conditions.settings.LoginPage must be {LOGIN_PAGE_URL} "
                    "for the --loginpage fixture contract"
                )
            if settings.get("ForceLoginURL") != "":
                raise OracleError(
                    f"{field}.conditions.settings.ForceLoginURL must remain empty "
                    "so WarnForceLoginURL is not opened"
                )
        supporting_contracts = _validate_supporting_contracts(
            slot.get("required_supporting_artifacts"),
            slot["conditions"]["display"],
            f"{field}.required_supporting_artifacts",
        )
        if (
            slot_id == "tools_readback"
            and supporting_contracts
            != _tools_readback_contract(slot["conditions"]["display"])
        ):
            raise OracleError(
                f"{field}.required_supporting_artifacts must use the canonical "
                "tools_readback role contracts"
            )
        status = slot.get("definition_status")
        if status not in {"ready", "blocked"}:
            raise OracleError(f"{field}.definition_status must be ready or blocked")
        blockers = _require_array(
            slot.get("definition_blockers"), f"{field}.definition_blockers"
        )
        if not all(isinstance(blocker, str) and blocker for blocker in blockers):
            raise OracleError(
                f"{field}.definition_blockers must contain non-empty descriptions"
            )
        if status == "blocked" and not blockers:
            raise OracleError(
                f"{field}.definition_blockers must explain a blocked slot"
            )
        if status == "ready" and blockers:
            raise OracleError(
                f"{field}.definition_blockers must be empty for a ready slot"
            )
        if status == "ready":
            conditions = slot["conditions"]
            content = conditions["content"]
            if content["availability"] == "missing":
                raise OracleError(
                    f"{field} cannot be ready while content availability is missing"
                )
            asset_hash = content["asset_manifest_sha256"]
            if not isinstance(asset_hash, str) or not HASH_PATTERN.fullmatch(
                asset_hash
            ):
                raise OracleError(
                    f"{field} cannot be ready without content.asset_manifest_sha256"
                )
            environment = conditions["environment"]
            if environment["mode"] != "not_applicable" and not environment["asset_id"]:
                raise OracleError(
                    f"{field} cannot be ready without environment.asset_id"
                )
        machine_status = slot.get("machine_contract_status")
        if machine_status not in {"ready", "blocked"}:
            raise OracleError(
                f"{field}.machine_contract_status must be ready or blocked"
            )
        machine_blockers = _require_array(
            slot.get("machine_contract_blockers"),
            f"{field}.machine_contract_blockers",
        )
        if not all(
            isinstance(blocker, str) and blocker for blocker in machine_blockers
        ):
            raise OracleError(
                f"{field}.machine_contract_blockers must contain non-empty descriptions"
            )
        machine_contract = slot.get("machine_contract")
        if machine_status == "blocked":
            if not machine_blockers or machine_contract is not None:
                raise OracleError(
                    f"{field} blocked machine contract needs blockers and null contract"
                )
        else:
            if machine_blockers:
                raise OracleError(
                    f"{field}.machine_contract_blockers must be empty when ready"
                )
            _validate_typed_machine_contract(
                machine_contract,
                slot["conditions"],
                f"{field}.machine_contract",
            )
        _validate_missing_evidence(slot.get("evidence"), f"{field}.evidence")

    missing_groups = sorted(REQUIRED_GROUPS - groups)
    if missing_groups:
        raise OracleError(
            f"manifest does not cover groups: {', '.join(missing_groups)}"
        )
    missing_features = sorted(REQUIRED_FEATURES - features)
    if missing_features:
        raise OracleError(
            f"manifest does not cover features: {', '.join(missing_features)}"
        )


def load_manifest(path: Path, fixture_root: Path | None = None) -> dict[str, object]:
    document = _read_json(path)
    validate_manifest(document, fixture_root)
    return document


def _slot_definition(slot: dict[str, object]) -> dict[str, object]:
    return {
        key: value
        for key, value in slot.items()
        if key not in {"conditions_sha256", "definition_sha256", "evidence"}
    }


def _session_definition_errors(
    manifest: dict[str, object], session: dict[str, object]
) -> list[str]:
    errors: list[str] = []
    if (
        not isinstance(session.get("schema"), int)
        or isinstance(session.get("schema"), bool)
        or session.get("schema") != 2
        or session.get("kind") != "firestorm-opengl-oracle-session"
    ):
        return ["session schema or kind is invalid"]
    try:
        _require_session_id(session.get("session_id"), "session.session_id")
    except OracleError as error:
        errors.append(str(error))
    if session.get("corpus_sha256") != _canonical_hash(manifest):
        errors.append("session corpus hash does not match the manifest")
    if not _canonical_json_equal(session.get("baseline"), manifest["baseline"]):
        errors.append("session baseline does not match the manifest")
    if not _canonical_json_equal(
        session.get("capture_contract"), manifest["capture_contract"]
    ):
        errors.append("session capture contract does not match the manifest")
    if not isinstance(session.get("oracle_worktree"), str) or not session.get(
        "oracle_worktree"
    ):
        errors.append("session oracle_worktree is invalid")

    session_slots = session.get("slots")
    if not isinstance(session_slots, list):
        errors.append("session slots are invalid")
        return errors
    manifest_slots = {slot["id"]: slot for slot in manifest["slots"]}
    session_ids = [slot.get("id") for slot in session_slots if isinstance(slot, dict)]
    if len(session_ids) != len(session_slots) or not all(
        isinstance(slot_id, str) for slot_id in session_ids
    ):
        errors.append("session contains invalid or duplicate slot identifiers")
        return errors
    if len(set(session_ids)) != len(session_ids):
        errors.append("session contains invalid or duplicate slot identifiers")
        return errors
    if set(session_ids) != set(manifest_slots):
        errors.append("session slot set does not match the manifest")
        return errors

    for slot in session_slots:
        slot_id = slot["id"]
        canonical = manifest_slots[slot_id]
        canonical_definition_hash = _canonical_hash(_slot_definition(canonical))
        session_definition_hash = _canonical_hash(_slot_definition(slot))
        if session_definition_hash != canonical_definition_hash:
            errors.append(f"{slot_id}: session definition does not match the manifest")
        if (
            slot.get("definition_sha256") != canonical_definition_hash
            or slot.get("definition_sha256") != session_definition_hash
        ):
            errors.append(f"{slot_id}: session definition hash is invalid")
        canonical_conditions_hash = _canonical_hash(canonical["conditions"])
        session_conditions_hash = _canonical_hash(slot.get("conditions"))
        if session_conditions_hash != canonical_conditions_hash:
            errors.append(f"{slot_id}: session conditions do not match the manifest")
        if (
            slot.get("conditions_sha256") != canonical_conditions_hash
            or slot.get("conditions_sha256") != session_conditions_hash
        ):
            errors.append(f"{slot_id}: session conditions hash is invalid")
    return errors


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _git_errors(worktree: Path, expected_commit: str) -> list[str]:
    errors: list[str] = []
    git_environment = os.environ.copy()
    for variable in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_NAMESPACE",
    ):
        git_environment.pop(variable, None)
    git_environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    git_command = [
        "git",
        "-c",
        "core.fileMode=true",
        "-c",
        "core.symlinks=true",
        "-C",
        str(worktree),
    ]
    try:
        head_result = subprocess.run(
            [*git_command, "rev-parse", "--verify", "HEAD^{commit}"],
            check=True,
            capture_output=True,
            text=True,
            env=git_environment,
        )
        top_level_result = subprocess.run(
            [*git_command, "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
            env=git_environment,
        )
        symbolic_result = subprocess.run(
            [*git_command, "symbolic-ref", "-q", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
            env=git_environment,
        )
        if symbolic_result.returncode not in {0, 1}:
            raise subprocess.CalledProcessError(
                symbolic_result.returncode,
                symbolic_result.args,
                symbolic_result.stdout,
                symbolic_result.stderr,
            )
        status_result = subprocess.run(
            [*git_command, "status", "--porcelain=v1", "--untracked-files=all"],
            check=True,
            capture_output=True,
            text=True,
            env=git_environment,
        )
        flags_result = subprocess.run(
            [*git_command, "ls-files", "-v", "-z"],
            check=True,
            capture_output=True,
            env=git_environment,
        )
        ignored_result = subprocess.run(
            [
                *git_command,
                "ls-files",
                "--others",
                "--ignored",
                "--exclude-standard",
                "-z",
            ],
            check=True,
            capture_output=True,
            env=git_environment,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        return [f"cannot inspect oracle worktree {worktree}: {error}"]

    head = head_result.stdout.strip()
    if head != expected_commit:
        errors.append(f"oracle HEAD is {head}, expected {expected_commit}")
    if Path(top_level_result.stdout.strip()).resolve() != worktree.resolve():
        errors.append("oracle worktree path is not the repository top level")
    if symbolic_result.returncode == 0:
        errors.append("oracle worktree HEAD must be detached")
    if status_result.stdout.strip():
        errors.append("oracle worktree is not clean")
    ignored_paths = [
        value.decode("utf-8", errors="replace")
        for value in ignored_result.stdout.split(b"\0")
        if value
    ]
    if ignored_paths:
        errors.append(
            "oracle worktree contains ignored untracked paths: "
            + ", ".join(ignored_paths)
        )

    hidden_flags: list[str] = []
    for entry in flags_result.stdout.split(b"\0"):
        if not entry:
            continue
        tag = chr(entry[0])
        if tag == "S" or tag.islower():
            hidden_flags.append(entry[2:].decode("utf-8", errors="replace"))
    if hidden_flags:
        errors.append(
            "oracle index contains skip-worktree or assume-unchanged paths: "
            + ", ".join(hidden_flags)
        )

    tracked_paths = [entry[2:] for entry in flags_result.stdout.split(b"\0") if entry]
    if tracked_paths:
        try:
            attribute_result = subprocess.run(
                [
                    *git_command,
                    "check-attr",
                    "-z",
                    "--stdin",
                    "filter",
                    "ident",
                    "working-tree-encoding",
                ],
                input=b"\0".join(tracked_paths) + b"\0",
                check=True,
                capture_output=True,
                env=git_environment,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            errors.append(f"cannot inspect oracle conversion attributes: {error}")
        else:
            values = attribute_result.stdout.split(b"\0")
            attribute_entries = [
                values[index : index + 3] for index in range(0, len(values) - 1, 3)
            ]
            unsafe_attributes = [
                f"{path.decode('utf-8', errors='replace')}:{attribute.decode()}"
                for path, attribute, value in attribute_entries
                if value not in {b"unspecified", b"unset"}
            ]
            if unsafe_attributes:
                errors.append(
                    "oracle tracked paths use content-conversion attributes: "
                    + ", ".join(unsafe_attributes)
                )

    try:
        with tempfile.TemporaryDirectory(prefix="firestorm-oracle-index-") as temporary:
            environment = git_environment.copy()
            environment["GIT_INDEX_FILE"] = str(Path(temporary) / "index")
            subprocess.run(
                [
                    *git_command,
                    "read-tree",
                    "--no-sparse-checkout",
                    "HEAD",
                ],
                check=True,
                capture_output=True,
                env=environment,
            )
            subprocess.run(
                [*git_command, "update-index", "--really-refresh"],
                check=False,
                capture_output=True,
                env=environment,
            )
            changed_result = subprocess.run(
                [
                    *git_command,
                    "diff-files",
                    "--name-only",
                    "-z",
                    "--no-ext-diff",
                ],
                check=True,
                capture_output=True,
                env=environment,
            )
    except (OSError, subprocess.CalledProcessError) as error:
        errors.append(f"cannot independently verify tracked oracle content: {error}")
    else:
        changed_paths = [
            value.decode("utf-8", errors="replace")
            for value in changed_result.stdout.split(b"\0")
            if value
        ]
        if changed_paths:
            errors.append(
                "oracle tracked content differs from HEAD: " + ", ".join(changed_paths)
            )
    return errors


def _request_document(
    manifest: dict[str, object], slot: dict[str, object], session_id: str
) -> dict[str, object]:
    contract = manifest["capture_contract"]
    return {
        "schema": 2,
        "kind": "firestorm-opengl-oracle-request",
        "session_id": session_id,
        "slot_id": slot["id"],
        "corpus_sha256": _canonical_hash(manifest),
        "baseline": copy.deepcopy(manifest["baseline"]),
        "definition": _slot_definition(slot),
        "definition_status": slot["definition_status"],
        "definition_blockers": slot["definition_blockers"],
        "machine_contract_status": slot["machine_contract_status"],
        "machine_contract_blockers": slot["machine_contract_blockers"],
        "machine_contract": slot["machine_contract"],
        "conditions": slot["conditions"],
        "conditions_sha256": slot["conditions_sha256"],
        "definition_sha256": slot["definition_sha256"],
        "capture_contract": copy.deepcopy(contract),
        "warmup_frames": contract["warmup_frames"],
        "measurement_frames": contract["measurement_frames"],
        "capture_repetitions": contract["repetitions"],
        "required_supporting_artifacts": slot["required_supporting_artifacts"],
    }


def initialize_session(
    manifest: dict[str, object],
    session_path: Path,
    oracle_worktree: Path,
    fixture_root: Path | None = None,
) -> dict[str, object]:
    validate_manifest(manifest, fixture_root)
    baseline = manifest["baseline"]
    git_errors = _git_errors(oracle_worktree, baseline["commit"])
    if git_errors:
        raise OracleError("; ".join(git_errors))
    canonical_session_path, session_directory, request_directory = (
        _prepare_session_directories(session_path)
    )

    slots: list[dict[str, object]] = []
    for source_slot in manifest["slots"]:
        slot = copy.deepcopy(source_slot)
        slot["conditions_sha256"] = _canonical_hash(slot["conditions"])
        slot["definition_sha256"] = _canonical_hash(_slot_definition(slot))
        slots.append(slot)
    session_id = str(uuid.uuid4())
    corpus_sha256 = _canonical_hash(manifest)
    session: dict[str, object] = {
        "schema": 2,
        "kind": "firestorm-opengl-oracle-session",
        "session_id": session_id,
        "created_at": _utc_now(),
        "corpus_sha256": corpus_sha256,
        "baseline": copy.deepcopy(baseline),
        "capture_contract": copy.deepcopy(manifest["capture_contract"]),
        "oracle_worktree": str(oracle_worktree.resolve()),
        "slots": slots,
    }
    _write_json(canonical_session_path, session)

    for slot in slots:
        request_directory = _validated_session_child_directory(
            session_directory, request_directory, "requests"
        )
        request = _request_document(manifest, slot, session_id)
        _write_json(request_directory / f"{slot['id']}.json", request)
    return session


def _validate_percentiles(value: object, field: str) -> dict[str, object]:
    metrics = _require_exact_keys(value, field, {"mean", "p50", "p95", "p99"})
    for name in ("mean", "p50", "p95", "p99"):
        _require_number(metrics.get(name), f"{field}.{name}")
    if float(metrics["p50"]) > float(metrics["p95"]):
        raise OracleError(f"{field}.p50 must not exceed p95")
    if float(metrics["p95"]) > float(metrics["p99"]):
        raise OracleError(f"{field}.p95 must not exceed p99")
    return metrics


def validate_measurements(
    measurements: dict[str, object],
    slot: dict[str, object],
    baseline_commit: str,
    contract: dict[str, object],
    instrumentation_commit: str,
) -> None:
    _require_exact_keys(
        measurements,
        "measurements",
        {
            "schema",
            "slot_id",
            "baseline_commit",
            "conditions_sha256",
            "self_variance",
            "frame_timing_ms",
            "memory_mib",
            "hardware_os",
            "known_quirks",
        },
    )
    _require_exact_integer(measurements.get("schema"), "measurements.schema", 2)
    if measurements.get("slot_id") != slot["id"]:
        raise OracleError("measurements.slot_id does not match the selected slot")
    if measurements.get("baseline_commit") != baseline_commit:
        raise OracleError("measurements.baseline_commit does not match the oracle")
    if measurements.get("conditions_sha256") != slot["conditions_sha256"]:
        raise OracleError("measurements.conditions_sha256 does not match the request")

    variance = _require_object(measurements.get("self_variance"), "self_variance")
    variance_method = contract["self_variance_method"]
    if variance.get("method") != variance_method:
        raise OracleError(f"self_variance.method must be {variance_method}")
    if variance.get("units") != "normalized_linear_0_1":
        raise OracleError("self_variance.units must be normalized_linear_0_1")
    repetitions = int(contract["repetitions"])
    comparison_count = repetitions * (repetitions - 1) // 2
    recorded_comparison_count = _require_integer(
        variance.get("comparison_count"), "self_variance.comparison_count", 1
    )
    if recorded_comparison_count != comparison_count:
        raise OracleError(
            f"self_variance.comparison_count must equal {comparison_count}"
        )
    display = slot["conditions"]["display"]
    pixel_sample_count = (
        int(display["width_px"]) * int(display["height_px"]) * comparison_count
    )
    channel_sample_count = pixel_sample_count * 4
    recorded_channel_count = _require_integer(
        variance.get("channel_sample_count"),
        "self_variance.channel_sample_count",
        1,
    )
    if recorded_channel_count != channel_sample_count:
        raise OracleError(
            f"self_variance.channel_sample_count must equal {channel_sample_count}"
        )
    recorded_pixel_count = _require_integer(
        variance.get("pixel_sample_count"), "self_variance.pixel_sample_count", 1
    )
    if recorded_pixel_count != pixel_sample_count:
        raise OracleError(
            f"self_variance.pixel_sample_count must equal {pixel_sample_count}"
        )
    for name in ("mean_absolute_error", "rmse", "max_absolute_error"):
        metric = _require_number(variance.get(name), f"self_variance.{name}")
        if metric > 1.0:
            raise OracleError(f"self_variance.{name} must not exceed 1")
    identical = _require_number(
        variance.get("identical_pixel_fraction"),
        "self_variance.identical_pixel_fraction",
    )
    if identical > 1.0:
        raise OracleError("self_variance.identical_pixel_fraction must not exceed 1")

    timing = _require_exact_keys(
        measurements.get("frame_timing_ms"),
        "frame_timing_ms",
        {"sample_count", "aggregate_method", "cpu_scope", "gpu_scope", "cpu", "gpu"},
    )
    _require_exact_integer(
        timing.get("sample_count"),
        "frame_timing_ms.sample_count",
        int(contract["measurement_frames"]),
    )
    if timing.get("aggregate_method") != "sorted_linear_interpolation_v1":
        raise OracleError("frame_timing_ms.aggregate_method is invalid")
    if timing.get("cpu_scope") != contract["cpu_timing_scope"]:
        raise OracleError("frame_timing_ms.cpu_scope does not match the contract")
    if timing.get("gpu_scope") != contract["gpu_timing_scope"]:
        raise OracleError("frame_timing_ms.gpu_scope does not match the contract")
    _validate_percentiles(timing.get("cpu"), "frame_timing_ms.cpu")
    _validate_percentiles(timing.get("gpu"), "frame_timing_ms.gpu")

    memory = _require_exact_keys(
        measurements.get("memory_mib"),
        "memory_mib",
        {
            "process_resident_start",
            "process_resident_peak",
            "renderer_accounted_gpu_start",
            "renderer_accounted_gpu_peak",
            "gpu_memory_method",
            "gpu_memory_provenance",
        },
    )
    if memory.get("gpu_memory_method") != contract["gpu_memory_method"]:
        raise OracleError("memory_mib.gpu_memory_method does not match the contract")
    if not _canonical_json_equal(
        memory.get("gpu_memory_provenance"),
        contract["renderer_accounted_gpu_memory_sources"],
    ):
        raise OracleError(
            "memory_mib.gpu_memory_provenance does not match the contract"
        )
    for prefix in ("process_resident", "renderer_accounted_gpu"):
        start = _require_number(
            memory.get(f"{prefix}_start"), f"memory_mib.{prefix}_start"
        )
        peak = _require_number(
            memory.get(f"{prefix}_peak"), f"memory_mib.{prefix}_peak"
        )
        if peak < start:
            raise OracleError(f"memory_mib.{prefix}_peak must be >= {prefix}_start")

    hardware = _require_exact_keys(
        measurements.get("hardware_os"),
        "hardware_os",
        {
            "machine_model",
            "cpu",
            "gpu",
            "ram_mib",
            "os_name",
            "os_version",
            "architecture",
            "display_id",
            "display_scale",
            "opengl_vendor",
            "opengl_renderer",
            "opengl_version",
            "viewer_build",
            "xcode_build",
        },
    )
    for name in (
        "machine_model",
        "cpu",
        "gpu",
        "os_name",
        "os_version",
        "architecture",
        "display_id",
        "opengl_vendor",
        "opengl_renderer",
        "opengl_version",
        "viewer_build",
        "xcode_build",
    ):
        _require_string(hardware.get(name), f"hardware_os.{name}")
    _require_integer(hardware.get("ram_mib"), "hardware_os.ram_mib", 1)
    _require_number(hardware.get("display_scale"), "hardware_os.display_scale", 1.0)
    platform = contract["platform"]
    if hardware["os_name"] != platform["os"]:
        raise OracleError("hardware_os.os_name does not match the capture contract")
    if hardware["architecture"] != platform["architecture"]:
        raise OracleError(
            "hardware_os.architecture does not match the capture contract"
        )
    if hardware["viewer_build"] != instrumentation_commit:
        raise OracleError(
            "hardware_os.viewer_build must equal the instrumentation commit"
        )
    expected_scale = slot["conditions"]["display"]["scale_factor"]
    if float(hardware["display_scale"]) != float(expected_scale):
        raise OracleError("hardware_os.display_scale does not match slot conditions")

    quirks = _require_array(measurements.get("known_quirks"), "known_quirks")
    for index, value in enumerate(quirks):
        quirk = _require_exact_keys(
            value,
            f"known_quirks[{index}]",
            {"id", "description", "impact"},
        )
        for name in ("id", "description", "impact"):
            _require_string(quirk.get(name), f"known_quirks[{index}].{name}")


def _capture_artifact_contract(
    slot: dict[str, object], contract: dict[str, object]
) -> dict[str, object]:
    display = slot["conditions"]["display"]
    return {
        "kind": contract["capture_format"],
        "encoding": contract["capture_encoding"],
        "width_px": display["width_px"],
        "height_px": display["height_px"],
        "interlaced": contract["png_interlaced"],
    }


def _safe_acquisition_artifact(value: object, field: str) -> str:
    relative = _require_string(value, field)
    parts = relative.split("/")
    if (
        relative.startswith("/")
        or "\\" in relative
        or any(part in {"", ".", ".."} for part in parts)
        or any(re.fullmatch(r"[a-z0-9][a-z0-9._-]*", part) is None for part in parts)
        or parts[0] in {"receipt.json", "known-quirks-review.json"}
    ):
        raise OracleError(f"{field} must be a canonical safe relative path")
    return relative


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def _sample_aggregate(values: list[float]) -> dict[str, object]:
    return {
        "mean": round(sum(value / len(values) for value in values), 12),
        "p50": round(_percentile(values, 0.50), 12),
        "p95": round(_percentile(values, 0.95), 12),
        "p99": round(_percentile(values, 0.99), 12),
    }


def _validate_quirks_review(
    review: dict[str, object],
    *,
    session_id: str,
    slot_id: str,
    acquisition_sha256: str,
) -> list[object]:
    _require_exact_keys(
        review,
        "known-quirks review",
        {
            "schema",
            "kind",
            "session_id",
            "slot_id",
            "acquisition_sha256",
            "reviewed_at",
            "quirks",
        },
    )
    _require_exact_integer(review.get("schema"), "known-quirks review.schema", 1)
    if review.get("kind") != "firestorm-opengl-oracle-known-quirks-review":
        raise OracleError("known-quirks review kind is invalid")
    if review.get("session_id") != session_id or review.get("slot_id") != slot_id:
        raise OracleError("known-quirks review does not match the session and slot")
    if review.get("acquisition_sha256") != acquisition_sha256:
        raise OracleError("known-quirks review is not bound to the acquisition")
    reviewed_at = _require_string(review.get("reviewed_at"), "reviewed_at")
    try:
        parsed = datetime.fromisoformat(reviewed_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise OracleError("reviewed_at must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise OracleError("reviewed_at must include a timezone")
    quirks = _require_array(review.get("quirks"), "known-quirks review.quirks")
    identifiers: set[str] = set()
    for index, value in enumerate(quirks):
        quirk = _require_exact_keys(
            value,
            f"known-quirks review.quirks[{index}]",
            {"id", "description", "impact"},
        )
        identifier = _require_string(quirk.get("id"), f"quirks[{index}].id")
        if identifier in identifiers:
            raise OracleError("known-quirks review contains duplicate identifiers")
        identifiers.add(identifier)
        for name in ("description", "impact"):
            _require_string(quirk.get(name), f"quirks[{index}].{name}")
    return quirks


def _load_machine_acquisition(
    manifest: dict[str, object],
    session: dict[str, object],
    slot: dict[str, object],
    request_path: Path,
    acquisition_path: Path,
    quirks_path: Path,
) -> dict[str, object]:
    slot_id = str(slot["id"])
    request_bytes = _read_regular_file_once(request_path, "request", MAX_JSON_BYTES)
    request = _read_strict_json_bytes(request_bytes, "request")
    expected_request = _request_document(manifest, slot, str(session["session_id"]))
    if not _canonical_json_equal(request, expected_request):
        raise OracleError("request does not match the immutable session definition")
    request_sha256 = hashlib.sha256(request_bytes).hexdigest()

    acquisition_bytes = _read_regular_file_once(
        acquisition_path, "acquisition receipt", MAX_JSON_BYTES
    )
    acquisition = _read_strict_json_bytes(acquisition_bytes, "acquisition receipt")
    _require_exact_keys(
        acquisition,
        "acquisition receipt",
        {
            "schema",
            "kind",
            "binding",
            "producer",
            "scopes",
            "hardware_os",
            "capture_state_generation",
            "observed_state",
            "warmup_frames",
            "samples",
            "captures",
            "supporting_artifacts",
        },
    )
    _require_exact_integer(acquisition.get("schema"), "acquisition.schema", 1)
    if acquisition.get("kind") != "firestorm-opengl-oracle-acquisition":
        raise OracleError("acquisition kind is invalid")

    binding = _require_exact_keys(
        acquisition.get("binding"),
        "acquisition.binding",
        {
            "session_id",
            "slot_id",
            "corpus_sha256",
            "request_sha256",
            "definition_sha256",
            "conditions_sha256",
            "baseline_commit",
        },
    )
    expected_binding = {
        "session_id": session["session_id"],
        "slot_id": slot_id,
        "corpus_sha256": session["corpus_sha256"],
        "request_sha256": request_sha256,
        "definition_sha256": slot["definition_sha256"],
        "conditions_sha256": slot["conditions_sha256"],
        "baseline_commit": manifest["baseline"]["commit"],
    }
    if not _canonical_json_equal(binding, expected_binding):
        raise OracleError("acquisition binding does not match the immutable request")

    producer = _require_exact_keys(
        acquisition.get("producer"),
        "acquisition.producer",
        {
            "protocol",
            "instrumentation_commit",
            "executable_sha256",
            "process_run_id",
        },
    )
    if producer.get("protocol") != ACQUISITION_PROTOCOL:
        raise OracleError("acquisition producer protocol is invalid")
    instrumentation_commit = _require_hash(
        producer.get("instrumentation_commit"),
        "acquisition.producer.instrumentation_commit",
        COMMIT_PATTERN,
    )
    _require_hash(
        producer.get("executable_sha256"),
        "acquisition.producer.executable_sha256",
    )
    _require_string(
        producer.get("process_run_id"), "acquisition.producer.process_run_id"
    )
    scopes = _require_exact_keys(
        acquisition.get("scopes"),
        "acquisition.scopes",
        {"cpu_timing", "gpu_timing", "gpu_memory"},
    )
    expected_scopes = {
        "cpu_timing": manifest["capture_contract"]["cpu_timing_scope"],
        "gpu_timing": manifest["capture_contract"]["gpu_timing_scope"],
        "gpu_memory": manifest["capture_contract"]["gpu_memory_method"],
    }
    if not _canonical_json_equal(scopes, expected_scopes):
        raise OracleError("acquisition measurement scopes do not match the contract")

    machine_contract = slot.get("machine_contract")
    if (
        slot.get("machine_contract_status") != "ready"
        or not isinstance(machine_contract, dict)
        or machine_contract.get("kind") != "typed_runtime_state_v1"
    ):
        raise OracleError("slot has no admissible typed runtime-state contract")
    if not _canonical_json_equal(
        {
            "instrumentation_commit": producer["instrumentation_commit"],
            "executable_sha256": producer["executable_sha256"],
        },
        machine_contract["producer"],
    ):
        raise OracleError(
            "acquisition producer does not match the pinned machine contract"
        )
    observed_state = _require_object(
        acquisition.get("observed_state"), "acquisition.observed_state"
    )
    if not _canonical_json_equal(observed_state, machine_contract["expected"]):
        raise OracleError(
            "acquisition observed state does not match the typed contract"
        )
    state_generation = _require_u64(
        acquisition.get("capture_state_generation"),
        "acquisition.capture_state_generation",
    )

    contract = manifest["capture_contract"]
    warmup = _require_array(acquisition.get("warmup_frames"), "warmup_frames")
    expected_warmup = int(contract["warmup_frames"])
    if len(warmup) != expected_warmup:
        raise OracleError(
            f"warmup_frames must contain exactly {expected_warmup} frames"
        )
    warmup_serials = [
        _require_u64(value, f"warmup_frames[{index}]")
        for index, value in enumerate(warmup)
    ]
    if warmup_serials[0] != 1 or any(
        warmup_serials[index + 1] != warmup_serials[index] + 1
        for index in range(len(warmup_serials) - 1)
    ):
        raise OracleError("warmup_frames must be presented frame serials 1 through 300")

    sample_values = _require_array(acquisition.get("samples"), "samples")
    expected_samples = int(contract["measurement_frames"])
    if len(sample_values) != expected_samples:
        raise OracleError(f"samples must contain exactly {expected_samples} frames")
    samples: list[dict[str, object]] = []
    sample_serials: list[int] = []
    for index, value in enumerate(sample_values):
        sample = _require_exact_keys(
            value,
            f"samples[{index}]",
            {
                "frame_serial",
                "capture_state_generation",
                "cpu_ms",
                "gpu_ms",
                "process_resident_bytes",
                "renderer_accounted_gpu_bytes",
            },
        )
        serial = _require_u64(
            sample.get("frame_serial"), f"samples[{index}].frame_serial"
        )
        if (
            _require_u64(
                sample.get("capture_state_generation"),
                f"samples[{index}].capture_state_generation",
            )
            != state_generation
        ):
            raise OracleError(
                "sample capture_state_generation changed during acquisition"
            )
        _require_number(sample.get("cpu_ms"), f"samples[{index}].cpu_ms")
        _require_number(sample.get("gpu_ms"), f"samples[{index}].gpu_ms")
        _require_u64(
            sample.get("process_resident_bytes"),
            f"samples[{index}].process_resident_bytes",
        )
        _require_u64(
            sample.get("renderer_accounted_gpu_bytes"),
            f"samples[{index}].renderer_accounted_gpu_bytes",
        )
        samples.append(sample)
        sample_serials.append(serial)
    if sample_serials[0] != warmup_serials[-1] + 1 or any(
        sample_serials[index + 1] != sample_serials[index] + 1
        for index in range(len(sample_serials) - 1)
    ):
        raise OracleError("samples must immediately follow warmup as contiguous frames")

    artifact_root = acquisition_path.parent
    seen_paths: set[str] = set()
    capture_values = _require_array(acquisition.get("captures"), "captures")
    repetitions = int(contract["repetitions"])
    if len(capture_values) != repetitions:
        raise OracleError(f"captures must contain exactly {repetitions} entries")
    display = slot["conditions"]["display"]
    expected_dimensions = (int(display["width_px"]), int(display["height_px"]))
    captures: list[dict[str, object]] = []
    decoded_captures: list[bytes] = []
    capture_transactions: set[tuple[int, str]] = set()
    capture_transaction_ids: set[str] = set()
    for index, value in enumerate(capture_values):
        field = f"captures[{index}]"
        capture = _require_exact_keys(
            value,
            field,
            {
                "ordinal",
                "frame_serial",
                "capture_state_generation",
                "path",
                "bytes",
                "sha256",
                "transaction_id",
            },
        )
        _require_exact_integer(capture.get("ordinal"), f"{field}.ordinal", index + 1)
        frame_serial = _require_exact_integer(
            capture.get("frame_serial"),
            f"{field}.frame_serial",
            sample_serials[-1] + index + 1,
        )
        if (
            _require_u64(
                capture.get("capture_state_generation"),
                f"{field}.capture_state_generation",
            )
            != state_generation
        ):
            raise OracleError("capture_state_generation changed during captures")
        transaction_id = _require_string(
            capture.get("transaction_id"), f"{field}.transaction_id"
        )
        transaction = (frame_serial, transaction_id)
        if (
            transaction in capture_transactions
            or transaction_id in capture_transaction_ids
        ):
            raise OracleError("capture transactions must be unique")
        capture_transactions.add(transaction)
        capture_transaction_ids.add(transaction_id)
        relative = _safe_acquisition_artifact(capture.get("path"), f"{field}.path")
        if relative in seen_paths:
            raise OracleError("acquisition artifact paths must be unique")
        seen_paths.add(relative)
        encoded = _read_relative_regular_file_once(
            artifact_root, Path(relative), field, MAX_PNG_BYTES
        )
        expected_bytes = _require_integer(capture.get("bytes"), f"{field}.bytes", 1)
        expected_hash = _require_hash(capture.get("sha256"), f"{field}.sha256")
        if (
            len(encoded) != expected_bytes
            or hashlib.sha256(encoded).hexdigest() != expected_hash
        ):
            raise OracleError(f"{field} size or SHA-256 does not match its file")
        _, _, rgba = _decode_png_bytes(encoded, relative, expected_dimensions)
        captures.append({"metadata": capture, "relative": relative, "bytes": encoded})
        decoded_captures.append(rgba)

    supporting_contracts = slot["required_supporting_artifacts"]
    supporting_values = _require_array(
        acquisition.get("supporting_artifacts"), "supporting_artifacts"
    )
    supporting: list[dict[str, object]] = []
    supporting_bytes: dict[str, bytes] = {}
    roles: set[str] = set()
    for index, value in enumerate(supporting_values):
        field = f"supporting_artifacts[{index}]"
        artifact = _require_exact_keys(
            value,
            field,
            {
                "role",
                "frame_serial",
                "capture_state_generation",
                "path",
                "bytes",
                "sha256",
                "transaction_id",
            },
        )
        role = _require_string(artifact.get("role"), f"{field}.role")
        if role in roles or role not in supporting_contracts:
            raise OracleError(f"{field}.role is duplicate or unexpected")
        roles.add(role)
        frame_serial = _require_u64(
            artifact.get("frame_serial"), f"{field}.frame_serial"
        )
        if (
            _require_u64(
                artifact.get("capture_state_generation"),
                f"{field}.capture_state_generation",
            )
            != state_generation
        ):
            raise OracleError("supporting artifact state generation is inconsistent")
        transaction_id = _require_string(
            artifact.get("transaction_id"), f"{field}.transaction_id"
        )
        if (frame_serial, transaction_id) not in capture_transactions:
            raise OracleError(
                "supporting artifact is not bound to a capture transaction"
            )
        relative = _safe_acquisition_artifact(artifact.get("path"), f"{field}.path")
        if relative in seen_paths:
            raise OracleError("acquisition artifact paths must be unique")
        seen_paths.add(relative)
        role_contract = supporting_contracts[role]
        encoded = _read_relative_regular_file_once(
            artifact_root,
            Path(relative),
            field,
            _supporting_artifact_read_limit(role_contract),
        )
        expected_bytes = _require_integer(artifact.get("bytes"), f"{field}.bytes", 1)
        expected_hash = _require_hash(artifact.get("sha256"), f"{field}.sha256")
        if (
            len(encoded) != expected_bytes
            or hashlib.sha256(encoded).hexdigest() != expected_hash
        ):
            raise OracleError(f"{field} size or SHA-256 does not match its file")
        _validate_supporting_artifact_bytes(role, encoded, relative, role_contract)
        supporting.append(
            {"metadata": artifact, "relative": relative, "bytes": encoded}
        )
        supporting_bytes[role] = encoded
    if roles != set(supporting_contracts):
        raise OracleError("supporting artifact roles do not match the request")
    if slot_id == "tools_readback":
        transactions = {
            (item["metadata"]["frame_serial"], item["metadata"]["transaction_id"])
            for item in supporting
        }
        if len(transactions) != 1:
            raise OracleError("tools_readback artifacts must share one transaction")
        _validate_tools_readback_consistency(supporting_bytes, supporting_contracts)
        frame_serial, transaction_id = next(iter(transactions))
        matching_capture = next(
            item
            for item in captures
            if item["metadata"]["frame_serial"] == frame_serial
            and item["metadata"]["transaction_id"] == transaction_id
        )
        if supporting_bytes["local_snapshot"] != matching_capture["bytes"]:
            raise OracleError(
                "tools_readback local_snapshot must be the PNG for its capture transaction"
            )

    acquisition_sha256 = hashlib.sha256(acquisition_bytes).hexdigest()
    review_bytes = _read_regular_file_once(
        quirks_path, "known-quirks review", MAX_JSON_BYTES
    )
    review = _read_strict_json_bytes(review_bytes, "known-quirks review")
    quirks = _validate_quirks_review(
        review,
        session_id=str(session["session_id"]),
        slot_id=slot_id,
        acquisition_sha256=acquisition_sha256,
    )

    cpu_values = [float(sample["cpu_ms"]) for sample in samples]
    gpu_values = [float(sample["gpu_ms"]) for sample in samples]
    rss_values = [int(sample["process_resident_bytes"]) for sample in samples]
    gpu_memory_values = [
        int(sample["renderer_accounted_gpu_bytes"]) for sample in samples
    ]
    measurements = {
        "schema": 2,
        "slot_id": slot_id,
        "baseline_commit": manifest["baseline"]["commit"],
        "conditions_sha256": slot["conditions_sha256"],
        "self_variance": _self_variance(decoded_captures),
        "frame_timing_ms": {
            "sample_count": len(samples),
            "aggregate_method": "sorted_linear_interpolation_v1",
            "cpu_scope": scopes["cpu_timing"],
            "gpu_scope": scopes["gpu_timing"],
            "cpu": _sample_aggregate(cpu_values),
            "gpu": _sample_aggregate(gpu_values),
        },
        "memory_mib": {
            "process_resident_start": round(rss_values[0] / (1024 * 1024), 12),
            "process_resident_peak": round(max(rss_values) / (1024 * 1024), 12),
            "renderer_accounted_gpu_start": round(
                gpu_memory_values[0] / (1024 * 1024), 12
            ),
            "renderer_accounted_gpu_peak": round(
                max(gpu_memory_values) / (1024 * 1024), 12
            ),
            "gpu_memory_method": scopes["gpu_memory"],
            "gpu_memory_provenance": copy.deepcopy(
                contract["renderer_accounted_gpu_memory_sources"]
            ),
        },
        "hardware_os": copy.deepcopy(acquisition["hardware_os"]),
        "known_quirks": copy.deepcopy(quirks),
    }
    validate_measurements(
        measurements,
        slot,
        manifest["baseline"]["commit"],
        contract,
        instrumentation_commit,
    )
    return {
        "acquisition": acquisition,
        "acquisition_bytes": acquisition_bytes,
        "acquisition_sha256": acquisition_sha256,
        "review": review,
        "review_bytes": review_bytes,
        "review_sha256": hashlib.sha256(review_bytes).hexdigest(),
        "captures": captures,
        "supporting": supporting,
        "measurements": measurements,
    }


def record_acquisition(
    manifest: dict[str, object],
    session_path: Path,
    slot_id: str,
    acquisition_path: Path,
    quirks_path: Path,
    fixture_root: Path | None = None,
) -> None:
    validate_manifest(manifest, fixture_root)
    session = _read_json(session_path)
    definition_errors = _session_definition_errors(manifest, session)
    if definition_errors:
        raise OracleError("invalid session: " + "; ".join(definition_errors))
    slots = _require_array(session.get("slots"), "session.slots")
    slot = next(
        (
            value
            for value in slots
            if isinstance(value, dict) and value.get("id") == slot_id
        ),
        None,
    )
    if slot is None:
        raise OracleError(f"unknown slot: {slot_id}")
    evidence = slot.get("evidence")
    if not isinstance(evidence, dict):
        raise OracleError(f"slot {slot_id} evidence is invalid; start a new session")
    if evidence.get("status") != "missing":
        raise OracleError(f"slot {slot_id} already has evidence; start a new session")
    if slot.get("definition_status") != "ready":
        raise OracleError(f"slot {slot_id} is blocked by its corpus definition")
    if slot.get("machine_contract_status") != "ready":
        raise OracleError(f"slot {slot_id} is blocked by its machine contract")

    requests_directory = _validated_session_child_directory(
        session_path.parent.resolve(), session_path.parent / "requests", "requests"
    )
    request_path = requests_directory / f"{slot_id}.json"
    loaded = _load_machine_acquisition(
        manifest,
        session,
        slot,
        request_path,
        acquisition_path,
        quirks_path,
    )
    git_errors = _git_errors(
        Path(session["oracle_worktree"]), manifest["baseline"]["commit"]
    )
    if git_errors:
        raise OracleError("; ".join(git_errors))

    acquisition_name = f"acquisition-{str(loaded['acquisition_sha256'])[:12]}"
    acquisition_fd, acquisition_root = _create_acquisition_directory(
        session_path, slot_id, acquisition_name
    )
    relative_root = Path("artifacts") / slot_id / acquisition_root.name

    captures: list[dict[str, object]] = []
    capture_contract = _capture_artifact_contract(slot, manifest["capture_contract"])
    supporting_artifacts: list[dict[str, object]] = []
    try:
        for item in loaded["captures"]:
            _persist_relative_bytes(
                acquisition_fd,
                item["relative"],
                item["bytes"],
                "capture artifact",
            )
            metadata = item["metadata"]
            captures.append(
                {
                    "path": (relative_root / item["relative"]).as_posix(),
                    "sha256": metadata["sha256"],
                    "bytes": metadata["bytes"],
                    "source_name": Path(item["relative"]).name,
                    "contract": copy.deepcopy(capture_contract),
                    "frame_serial": metadata["frame_serial"],
                    "transaction_id": metadata["transaction_id"],
                }
            )

        for item in loaded["supporting"]:
            _persist_relative_bytes(
                acquisition_fd,
                item["relative"],
                item["bytes"],
                "supporting artifact",
            )
            metadata = item["metadata"]
            role = metadata["role"]
            supporting_artifacts.append(
                {
                    "role": role,
                    "path": (relative_root / item["relative"]).as_posix(),
                    "sha256": metadata["sha256"],
                    "bytes": metadata["bytes"],
                    "source_name": Path(item["relative"]).name,
                    "contract": copy.deepcopy(
                        slot["required_supporting_artifacts"][role]
                    ),
                    "frame_serial": metadata["frame_serial"],
                    "transaction_id": metadata["transaction_id"],
                }
            )

        _persist_relative_bytes(
            acquisition_fd,
            "receipt.json",
            loaded["acquisition_bytes"],
            "acquisition receipt",
        )
        _persist_relative_bytes(
            acquisition_fd,
            "known-quirks-review.json",
            loaded["review_bytes"],
            "known-quirks review",
        )
    finally:
        os.close(acquisition_fd)

    measurements = loaded["measurements"]
    slot["evidence"] = {
        "status": "complete",
        "recorded_at": _utc_now(),
        "acquisition": {
            "path": (relative_root / "receipt.json").as_posix(),
            "sha256": loaded["acquisition_sha256"],
            "bytes": len(loaded["acquisition_bytes"]),
        },
        "known_quirks_review": {
            "path": (relative_root / "known-quirks-review.json").as_posix(),
            "sha256": loaded["review_sha256"],
            "bytes": len(loaded["review_bytes"]),
        },
        "producer": copy.deepcopy(loaded["acquisition"]["producer"]),
        "captures": captures,
        "supporting_artifacts": supporting_artifacts,
        "self_variance": measurements["self_variance"],
        "frame_timing_ms": measurements["frame_timing_ms"],
        "memory_mib": measurements["memory_mib"],
        "hardware_os": measurements["hardware_os"],
        "known_quirks": measurements["known_quirks"],
    }
    _write_json(session_path, session)


def verify_session(
    manifest: dict[str, object],
    session_path: Path,
    check_git: bool = True,
    fixture_root: Path | None = None,
) -> list[str]:
    try:
        validate_manifest(manifest, fixture_root)
        session = _read_json(session_path)
    except OracleError as error:
        return [str(error)]
    errors = _session_definition_errors(manifest, session)
    if errors:
        return errors
    if check_git:
        errors.extend(
            _git_errors(
                Path(str(session["oracle_worktree"])),
                str(manifest["baseline"]["commit"]),
            )
        )
    try:
        requests_directory = _validated_session_child_directory(
            session_path.parent.resolve(),
            session_path.parent / "requests",
            "requests",
        )
    except OracleError as error:
        return errors + [str(error)]

    session_slots = _require_array(session.get("slots"), "session.slots")
    session_slots_by_id = {
        str(slot["id"]): slot for slot in session_slots if isinstance(slot, dict)
    }
    for expected in manifest["slots"]:
        slot_id = str(expected["id"])
        slot = session_slots_by_id[slot_id]
        if expected["definition_status"] != "ready":
            blockers = expected["definition_blockers"]
            errors.append(f"{slot_id}: definition is blocked ({'; '.join(blockers)})")
        evidence = slot.get("evidence")
        if not isinstance(evidence, dict) or evidence.get("status") != "complete":
            errors.append(f"{slot_id}: required oracle evidence is missing")
            continue

        try:
            _require_exact_keys(
                evidence,
                f"{slot_id}.evidence",
                {
                    "status",
                    "recorded_at",
                    "acquisition",
                    "known_quirks_review",
                    "producer",
                    "captures",
                    "supporting_artifacts",
                    "self_variance",
                    "frame_timing_ms",
                    "memory_mib",
                    "hardware_os",
                    "known_quirks",
                },
            )
            _require_string(evidence.get("recorded_at"), f"{slot_id}.recorded_at")
            acquisition_metadata = _require_exact_keys(
                evidence.get("acquisition"),
                f"{slot_id}.acquisition",
                {"path", "sha256", "bytes"},
            )
            review_metadata = _require_exact_keys(
                evidence.get("known_quirks_review"),
                f"{slot_id}.known_quirks_review",
                {"path", "sha256", "bytes"},
            )
            acquisition_path = _stored_artifact_path(
                session_path, slot_id, acquisition_metadata["path"]
            )
            review_path = _stored_artifact_path(
                session_path, slot_id, review_metadata["path"]
            )
            loaded = _load_machine_acquisition(
                manifest,
                session,
                slot,
                requests_directory / f"{slot_id}.json",
                acquisition_path,
                review_path,
            )
            acquisition_size = _require_integer(
                acquisition_metadata.get("bytes"),
                f"{slot_id}.acquisition.bytes",
                1,
            )
            review_size = _require_integer(
                review_metadata.get("bytes"),
                f"{slot_id}.known_quirks_review.bytes",
                1,
            )
            if _require_hash(
                acquisition_metadata.get("sha256"),
                f"{slot_id}.acquisition.sha256",
            ) != loaded["acquisition_sha256"] or acquisition_size != len(
                loaded["acquisition_bytes"]
            ):
                raise OracleError("acquisition receipt metadata mismatch")
            if _require_hash(
                review_metadata.get("sha256"),
                f"{slot_id}.known_quirks_review.sha256",
            ) != loaded["review_sha256"] or review_size != len(loaded["review_bytes"]):
                raise OracleError("known-quirks review metadata mismatch")

            producer = loaded["acquisition"]["producer"]
            if not _canonical_json_equal(evidence.get("producer"), producer):
                raise OracleError("producer metadata is not receipt-derived")
            derived = loaded["measurements"]
            for name in (
                "self_variance",
                "frame_timing_ms",
                "memory_mib",
                "hardware_os",
                "known_quirks",
            ):
                if not _canonical_json_equal(evidence.get(name), derived[name]):
                    raise OracleError(f"{name} is not acquisition-derived")

            stored_root = Path(str(acquisition_metadata["path"])).parent
            capture_contract = _capture_artifact_contract(
                slot, manifest["capture_contract"]
            )
            expected_captures = []
            for item in loaded["captures"]:
                metadata = item["metadata"]
                expected_captures.append(
                    {
                        "path": (stored_root / item["relative"]).as_posix(),
                        "sha256": metadata["sha256"],
                        "bytes": metadata["bytes"],
                        "source_name": Path(item["relative"]).name,
                        "contract": copy.deepcopy(capture_contract),
                        "frame_serial": metadata["frame_serial"],
                        "transaction_id": metadata["transaction_id"],
                    }
                )
            if not _canonical_json_equal(evidence.get("captures"), expected_captures):
                raise OracleError("capture metadata is not receipt-derived")

            expected_supporting = []
            for item in loaded["supporting"]:
                metadata = item["metadata"]
                role = metadata["role"]
                expected_supporting.append(
                    {
                        "role": role,
                        "path": (stored_root / item["relative"]).as_posix(),
                        "sha256": metadata["sha256"],
                        "bytes": metadata["bytes"],
                        "source_name": Path(item["relative"]).name,
                        "contract": copy.deepcopy(
                            slot["required_supporting_artifacts"][role]
                        ),
                        "frame_serial": metadata["frame_serial"],
                        "transaction_id": metadata["transaction_id"],
                    }
                )
            if not _canonical_json_equal(
                evidence.get("supporting_artifacts"), expected_supporting
            ):
                raise OracleError("supporting metadata is not receipt-derived")
        except (KeyError, OracleError) as error:
            errors.append(f"{slot_id}: invalid machine acquisition: {error}")
    return errors


def _parser() -> argparse.ArgumentParser:
    root = repository_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "doc/metal/oracle-corpus.json",
        help="oracle corpus manifest",
    )
    parser.add_argument(
        "--fixture-root",
        type=Path,
        default=root,
        help="root for fixture manifests and assets referenced by the corpus",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    initialize = subparsers.add_parser(
        "init", help="initialize a local capture session"
    )
    initialize.add_argument(
        "--session", type=Path, default=root / ".build/metal-oracle/session.json"
    )
    initialize.add_argument(
        "--oracle-worktree", type=Path, default=root.parent / "metal-opengl-oracle"
    )

    record = subparsers.add_parser("record", help="record one complete oracle slot")
    record.add_argument(
        "--session", type=Path, default=root / ".build/metal-oracle/session.json"
    )
    record.add_argument("--slot", required=True)
    record.add_argument("--acquisition", type=Path, required=True)
    record.add_argument("--quirks", type=Path, required=True)

    verify = subparsers.add_parser("verify", help="verify every required oracle slot")
    verify.add_argument(
        "--session", type=Path, default=root / ".build/metal-oracle/session.json"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        manifest = load_manifest(arguments.manifest, arguments.fixture_root)
        if arguments.command == "init":
            session = initialize_session(
                manifest,
                arguments.session,
                arguments.oracle_worktree,
                arguments.fixture_root,
            )
            blocked = sum(
                slot["definition_status"] != "ready" for slot in session["slots"]
            )
            print(
                f"initialized {len(session['slots'])} oracle slots at {arguments.session} "
                f"({blocked} definitions blocked, all evidence missing)"
            )
            return 0
        if arguments.command == "record":
            record_acquisition(
                manifest,
                arguments.session,
                arguments.slot,
                arguments.acquisition,
                arguments.quirks,
                arguments.fixture_root,
            )
            print(f"recorded oracle slot {arguments.slot}")
            return 0
        errors = verify_session(
            manifest, arguments.session, fixture_root=arguments.fixture_root
        )
        if errors:
            for error in errors:
                print(f"FAIL: {error}", file=sys.stderr)
            print(
                f"oracle verification failed with {len(errors)} issue(s)",
                file=sys.stderr,
            )
            return 1
        print("oracle verification passed")
        return 0
    except OracleError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
