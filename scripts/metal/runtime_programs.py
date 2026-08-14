"""Validate and render the path-free declared Metal program artifact."""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Iterable
from pathlib import Path
from typing import Final


class RuntimeProgramError(ValueError):
    """A translated runtime program cannot be represented safely."""


ARTIFACT_BASENAME: Final = "firestorm-declared-programs"
ARTIFACT_SCHEMA: Final = 1
STAGES: Final = ("vertex", "fragment")
KINDS: Final = ("buffer", "sampler", "texture")
COLOR_FORMATS: Final = {
    "bgra8unorm",
    "rg11b10float",
    "rgba8unorm",
    "rgba16unorm",
    "rgba16float",
}
DEPTH_FORMATS: Final = {"depth32float"}
VERTEX_FORMATS: Final = {
    "float": 4,
    "float2": 8,
    "float3": 12,
    "float4": 16,
    "int": 4,
    "int2": 8,
    "int3": 12,
    "int4": 16,
    "uint": 4,
    "uint2": 8,
    "uint3": 12,
    "uint4": 16,
    "uchar4normalized": 4,
    "ushort4": 8,
}
VERTEX_FORMAT_ALIGNMENTS: Final = {
    "uchar4normalized": 1,
    "ushort4": 2,
    **{
        name: 4
        for name in VERTEX_FORMATS
        if name not in {"uchar4normalized", "ushort4"}
    },
}
RESERVED_VERTEX_ATTRIBUTES: Final = {
    "position": 0,
    "normal": 1,
    "texcoord0": 2,
    "texcoord1": 3,
    "texcoord2": 4,
    "texcoord3": 5,
    "diffuse_color": 6,
    "emissive": 7,
    "tangent": 8,
    "weight": 9,
    "weight4": 10,
    "clothing": 11,
    "joint": 12,
    "texture_index": 13,
}
STEP_FUNCTIONS: Final = {"constant", "per_instance", "per_vertex"}
TEXTURE_TYPES: Final = {
    "1d",
    "1d_array",
    "2d",
    "2d_array",
    "2d_multisample",
    "2d_multisample_array",
    "3d",
    "cube",
    "cube_array",
    "texture_buffer",
}
DATA_TYPES: Final = {"float", "half", "int", "uint"}
ACCESS_TYPES: Final = {"read_only"}
MAX_VERTEX_ATTRIBUTE_INDEX: Final = 30
MAX_BUFFER_INDEX: Final = 30
MAX_TEXTURE_INDEX: Final = 127
MAX_SAMPLER_INDEX: Final = 15
DEFAULT_UNIFORM_BUFFER_INDEX: Final = 24

MEMBER_TYPE_SIZES: Final = {
    "bool": 4,
    "float": 4,
    "int": 4,
    "uint": 4,
    "vec2": 8,
    "ivec2": 8,
    "uvec2": 8,
    "vec3": 12,
    "ivec3": 12,
    "uvec3": 12,
    "vec4": 16,
    "ivec4": 16,
    "uvec4": 16,
}
MEMBER_TYPE_ALIGNMENTS: Final = {
    "bool": 4,
    "float": 4,
    "int": 4,
    "uint": 4,
    "vec2": 8,
    "ivec2": 8,
    "uvec2": 8,
    "vec3": 16,
    "ivec3": 16,
    "uvec3": 16,
    "vec4": 16,
    "ivec4": 16,
    "uvec4": 16,
}

_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_PROGRAM_ID = re.compile(r"[a-z][a-z0-9_]*\Z")
_ENUM_TOKEN = re.compile(r"[a-z0-9_]+\Z")
_HEX_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_DISPLAY_TEXT = re.compile(r"[\x20-\x7e]+\Z")
_MATRIX_TYPE = re.compile(r"mat([2-4])(?:x([2-4]))?\Z")
RUNTIME_MATRIX_TYPES: Final = {"mat3", "mat4"}

CPP_VERTEX_FORMATS: Final = {
    "float": "float32",
    "float2": "float32x2",
    "float3": "float32x3",
    "float4": "float32x4",
    "int": "int32",
    "int2": "int32x2",
    "int3": "int32x3",
    "int4": "int32x4",
    "uint": "uint32",
    "uint2": "uint32x2",
    "uint3": "uint32x3",
    "uint4": "uint32x4",
    "uchar4normalized": "uint8x4_normalized",
    "ushort4": "uint16x4",
}
CPP_TEXTURE_TYPES: Final = {
    "1d": "texture_1d",
    "1d_array": "texture_1d_array",
    "2d": "texture_2d",
    "2d_array": "texture_2d_array",
    "2d_multisample": "texture_2d_multisample",
    "2d_multisample_array": "texture_2d_multisample_array",
    "3d": "texture_3d",
    "cube": "texture_cube",
    "cube_array": "texture_cube_array",
    "texture_buffer": "texture_buffer",
}
CPP_TEXTURE_DATA_TYPES: Final = {
    "float": "float32",
    "half": "float16",
    "int": "int32",
    "uint": "uint32",
}
CPP_PIXEL_FORMATS: Final = {
    "bgra8unorm": "bgra8_unorm",
    "rg11b10float": "rg11b10_float",
    "rgba8unorm": "rgba8_unorm",
    "rgba16unorm": "rgba16_unorm",
    "rgba16float": "rgba16_float",
    "depth32float": "depth32_float",
}


def canonical_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def sha256_hex(value: object) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def _require_exact_keys(
    value: dict[object, object], expected: set[str], field: str
) -> None:
    actual = set(value)
    if actual != expected:
        raise RuntimeProgramError(
            f"{field} keys do not match schema; "
            f"missing={sorted(expected - actual)}, "
            f"unexpected={sorted(actual - expected)}"
        )


def _require_string(value: object, field: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise RuntimeProgramError(f"{field} is invalid")
    return value


def _require_int(value: object, field: str, minimum: int, maximum: int) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < minimum
        or value > maximum
    ):
        raise RuntimeProgramError(
            f"{field} must be an integer in [{minimum}, {maximum}]"
        )
    return value


def _validate_member_type(value: object, field: str, depth: int) -> dict[str, object]:
    if depth >= 16:
        raise RuntimeProgramError(f"{field} nesting exceeds 16 levels")
    if not isinstance(value, dict):
        raise RuntimeProgramError(f"{field} must be an object")
    type_name = _require_string(value.get("type"), f"{field}.type", _IDENTIFIER)
    if type_name == "array":
        _require_exact_keys(
            value, {"type", "array_length", "array_stride", "element"}, field
        )
        length = _require_int(
            value.get("array_length"), f"{field}.array_length", 1, 2**31 - 1
        )
        stride = _require_int(
            value.get("array_stride"), f"{field}.array_stride", 1, 2**31 - 1
        )
        element = _validate_member_type(
            value.get("element"), f"{field}.element", depth + 1
        )
        if _member_type_extent(element) > stride:
            raise RuntimeProgramError(
                f"{field}.array_stride is smaller than its element"
            )
        array_alignment = max(_member_type_alignment(element), min(stride, 16))
        if array_alignment & (array_alignment - 1) or stride % array_alignment:
            raise RuntimeProgramError(
                f"{field}.array_stride is incompatible with its alignment"
            )
        return {
            "type": type_name,
            "array_length": length,
            "array_stride": stride,
            "element": element,
        }
    if type_name == "struct":
        _require_exact_keys(value, {"type", "members"}, field)
        members = _validate_members(value.get("members"), f"{field}.members", depth + 1)
        return {"type": type_name, "members": members}
    matrix = _MATRIX_TYPE.fullmatch(type_name)
    if matrix is not None:
        if type_name not in RUNTIME_MATRIX_TYPES:
            raise RuntimeProgramError(
                f"{field}.type is unsupported by the v1 matrix layout"
            )
        _require_exact_keys(value, {"type", "matrix_stride", "matrix_major"}, field)
        stride = _require_int(
            value.get("matrix_stride"), f"{field}.matrix_stride", 1, 2**31 - 1
        )
        major = _require_string(
            value.get("matrix_major"), f"{field}.matrix_major", _ENUM_TOKEN
        )
        if major != "column":
            raise RuntimeProgramError(
                f"{field}.matrix_major must be column for the v1 matrix layout"
            )
        if stride != 16:
            raise RuntimeProgramError(
                f"{field}.matrix_stride must be 16 for the v1 matrix layout"
            )
        return {
            "type": type_name,
            "matrix_stride": stride,
            "matrix_major": major,
        }
    _require_exact_keys(value, {"type"}, field)
    if type_name not in MEMBER_TYPE_SIZES:
        raise RuntimeProgramError(f"{field}.type is unsupported")
    return {"type": type_name}


def _member_type_alignment(value: dict[str, object]) -> int:
    type_name = str(value["type"])
    if type_name == "array":
        element = value["element"]
        assert isinstance(element, dict)
        return max(_member_type_alignment(element), min(int(value["array_stride"]), 16))
    if type_name == "struct":
        members = value["members"]
        assert isinstance(members, list)
        return max(
            16,
            max((_member_type_alignment(member) for member in members), default=1),
        )
    matrix = _MATRIX_TYPE.fullmatch(type_name)
    if matrix is not None:
        return 16
    return MEMBER_TYPE_ALIGNMENTS[type_name]


def _member_type_extent(value: dict[str, object]) -> int:
    type_name = str(value["type"])
    if type_name == "array":
        return int(value["array_length"]) * int(value["array_stride"])
    if type_name == "struct":
        members = value["members"]
        assert isinstance(members, list)
        raw_extent = max(
            (int(member["offset"]) + _member_type_extent(member) for member in members),
            default=0,
        )
        alignment = _member_type_alignment(value)
        return (raw_extent + alignment - 1) // alignment * alignment
    matrix = _MATRIX_TYPE.fullmatch(type_name)
    if matrix is not None:
        columns = int(matrix.group(1))
        return columns * int(value["matrix_stride"])
    return MEMBER_TYPE_SIZES[type_name]


def _validate_members(
    value: object,
    field: str,
    depth: int = 0,
    maximum_size: int | None = None,
) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise RuntimeProgramError(f"{field} must be an array")
    if not value:
        raise RuntimeProgramError(f"{field} must not be empty")
    result: list[dict[str, object]] = []
    seen_names: set[str] = set()
    previous_offset = -1
    previous_end = 0
    for index, member in enumerate(value):
        prefix = f"{field}[{index}]"
        if not isinstance(member, dict):
            raise RuntimeProgramError(f"{prefix} must be an object")
        if "name" not in member or "offset" not in member:
            raise RuntimeProgramError(f"{prefix} requires name and offset")
        name = _require_string(member.get("name"), f"{prefix}.name", _IDENTIFIER)
        offset = _require_int(member.get("offset"), f"{prefix}.offset", 0, 2**31 - 1)
        if name in seen_names:
            raise RuntimeProgramError(f"{field} has duplicate member name {name}")
        if offset < previous_offset:
            raise RuntimeProgramError(f"{field} members are not offset ordered")
        seen_names.add(name)
        previous_offset = offset
        typed = _validate_member_type(
            {
                key: item
                for key, item in member.items()
                if key not in {"name", "offset"}
            },
            prefix,
            depth,
        )
        alignment = _member_type_alignment(typed)
        if offset % alignment:
            raise RuntimeProgramError(f"{prefix}.offset is not naturally aligned")
        end = offset + _member_type_extent(typed)
        if result and offset < previous_end:
            raise RuntimeProgramError(f"{field} has overlapping members")
        if maximum_size is not None and end > maximum_size:
            raise RuntimeProgramError(f"{prefix} exceeds its buffer size")
        previous_end = end
        result.append({"name": name, "offset": offset, **typed})
    return result


def _validate_binding(value: object, field: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise RuntimeProgramError(f"{field} must be an object")
    kind = _require_string(value.get("kind"), f"{field}.kind", _IDENTIFIER)
    if kind not in KINDS:
        raise RuntimeProgramError(f"{field}.kind is unsupported")
    name = _require_string(value.get("name"), f"{field}.name", _IDENTIFIER)
    metal_name = _require_string(
        value.get("metal_name"), f"{field}.metal_name", _IDENTIFIER
    )
    maximum = {
        "buffer": MAX_BUFFER_INDEX,
        "sampler": MAX_SAMPLER_INDEX,
        "texture": MAX_TEXTURE_INDEX,
    }[kind]
    binding_index = _require_int(value.get("index"), f"{field}.index", 0, maximum)
    common: dict[str, object] = {
        "name": name,
        "metal_name": metal_name,
        "kind": kind,
        "index": binding_index,
    }
    if kind == "sampler":
        _require_exact_keys(value, {"name", "metal_name", "kind", "index"}, field)
        return common
    access = _require_string(value.get("access"), f"{field}.access", _IDENTIFIER)
    if access not in ACCESS_TYPES:
        raise RuntimeProgramError(f"{field}.access is unsupported")
    common["access"] = access
    if kind == "buffer":
        _require_exact_keys(
            value,
            {
                "name",
                "metal_name",
                "kind",
                "index",
                "access",
                "buffer_size",
                "buffer_alignment",
                "members",
            },
            field,
        )
        size = _require_int(
            value.get("buffer_size"), f"{field}.buffer_size", 1, 2**32 - 1
        )
        alignment = _require_int(
            value.get("buffer_alignment"), f"{field}.buffer_alignment", 1, 2**16 - 1
        )
        if alignment & (alignment - 1):
            raise RuntimeProgramError(
                f"{field}.buffer_alignment must be a power of two"
            )
        if size % alignment:
            raise RuntimeProgramError(f"{field}.buffer_size is not alignment rounded")
        members = _validate_members(
            value.get("members"), f"{field}.members", maximum_size=size
        )
        required_alignment = max(
            (_member_type_alignment(member) for member in members), default=1
        )
        if alignment != required_alignment:
            raise RuntimeProgramError(
                f"{field}.buffer_alignment does not match its members"
            )
        layout = {
            "schema": 1,
            "buffer_size": size,
            "buffer_alignment": alignment,
            "members": members,
        }
        return {
            **common,
            "buffer_size": size,
            "buffer_alignment": alignment,
            "members": members,
            "layout_sha256": sha256_hex(layout),
        }
    _require_exact_keys(
        value,
        {
            "name",
            "metal_name",
            "kind",
            "index",
            "access",
            "texture_type",
            "texture_data_type",
            "array_length",
            "is_depth_texture",
        },
        field,
    )
    texture_type = _require_string(
        value.get("texture_type"), f"{field}.texture_type", _ENUM_TOKEN
    )
    data_type = _require_string(
        value.get("texture_data_type"), f"{field}.texture_data_type", _ENUM_TOKEN
    )
    if texture_type not in TEXTURE_TYPES or data_type not in DATA_TYPES:
        raise RuntimeProgramError(f"{field} has an unsupported texture enum")
    array_length = _require_int(
        value.get("array_length"), f"{field}.array_length", 1, 2**16 - 1
    )
    is_depth = value.get("is_depth_texture")
    if not isinstance(is_depth, bool):
        raise RuntimeProgramError(f"{field}.is_depth_texture must be boolean")
    if is_depth and data_type != "float":
        raise RuntimeProgramError(f"{field} depth texture must sample float")
    return {
        **common,
        "access": access,
        "texture_type": texture_type,
        "texture_data_type": data_type,
        "array_length": array_length,
        "is_depth_texture": is_depth,
    }


def _validate_stage_bindings(
    value: object, field: str
) -> dict[str, list[dict[str, object]]]:
    if not isinstance(value, dict):
        raise RuntimeProgramError(f"{field} must be an object")
    _require_exact_keys(value, set(STAGES), field)
    result: dict[str, list[dict[str, object]]] = {}
    for stage in STAGES:
        raw = value.get(stage)
        if not isinstance(raw, list):
            raise RuntimeProgramError(f"{field}.{stage} must be an array")
        bindings = [
            _validate_binding(item, f"{field}.{stage}[{index}]")
            for index, item in enumerate(raw)
        ]
        keys = [
            (str(item["kind"]), int(item["index"]), str(item["name"]))
            for item in bindings
        ]
        canonical = sorted(keys)
        if keys != canonical:
            raise RuntimeProgramError(f"{field}.{stage} is not canonically ordered")
        slots = [(kind, index) for kind, index, _ in keys]
        if len(slots) != len(set(slots)):
            raise RuntimeProgramError(f"{field}.{stage} has duplicate binding slots")
        textures = {
            (int(item["index"]), str(item["name"]))
            for item in bindings
            if item["kind"] == "texture"
        }
        samplers = {
            (int(item["index"]), str(item["name"]))
            for item in bindings
            if item["kind"] == "sampler"
        }
        if textures != samplers:
            raise RuntimeProgramError(
                f"{field}.{stage} texture and sampler bindings do not pair"
            )
        metal_names = [str(item["metal_name"]) for item in bindings]
        if len(metal_names) != len(set(metal_names)):
            raise RuntimeProgramError(
                f"{field}.{stage} has duplicate native Metal binding names"
            )
        result[stage] = bindings
    return result


def _validate_vertex_contract(
    attributes_value: object, layouts_value: object, field: str
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    if not isinstance(attributes_value, list) or not isinstance(layouts_value, list):
        raise RuntimeProgramError(f"{field} vertex contract must use arrays")
    layouts: list[dict[str, object]] = []
    seen_buffers: set[int] = set()
    for index, item in enumerate(layouts_value):
        prefix = f"{field}.vertex_layouts[{index}]"
        if not isinstance(item, dict):
            raise RuntimeProgramError(f"{prefix} must be an object")
        _require_exact_keys(item, {"buffer_index", "stride", "step_function"}, prefix)
        buffer_index = _require_int(
            item.get("buffer_index"), f"{prefix}.buffer_index", 0, MAX_BUFFER_INDEX
        )
        stride = _require_int(item.get("stride"), f"{prefix}.stride", 1, 2048)
        step = _require_string(
            item.get("step_function"), f"{prefix}.step_function", _IDENTIFIER
        )
        if step not in STEP_FUNCTIONS:
            raise RuntimeProgramError(f"{prefix}.step_function is unsupported")
        if buffer_index == DEFAULT_UNIFORM_BUFFER_INDEX:
            raise RuntimeProgramError(
                f"{prefix} collides with the default uniform slot"
            )
        if buffer_index in seen_buffers:
            raise RuntimeProgramError(f"{field} has duplicate vertex buffer layouts")
        seen_buffers.add(buffer_index)
        layouts.append(
            {"buffer_index": buffer_index, "stride": stride, "step_function": step}
        )
    if layouts != sorted(layouts, key=lambda item: int(item["buffer_index"])):
        raise RuntimeProgramError(f"{field}.vertex_layouts is not buffer ordered")

    attributes: list[dict[str, object]] = []
    seen_names: set[str] = set()
    seen_locations: set[int] = set()
    used_buffers: set[int] = set()
    layout_by_buffer = {int(item["buffer_index"]): item for item in layouts}
    for index, item in enumerate(attributes_value):
        prefix = f"{field}.vertex_attributes[{index}]"
        if not isinstance(item, dict):
            raise RuntimeProgramError(f"{prefix} must be an object")
        _require_exact_keys(
            item, {"name", "location", "format", "offset", "buffer_index"}, prefix
        )
        name = _require_string(item.get("name"), f"{prefix}.name", _IDENTIFIER)
        location = _require_int(
            item.get("location"), f"{prefix}.location", 0, MAX_VERTEX_ATTRIBUTE_INDEX
        )
        if (
            name not in RESERVED_VERTEX_ATTRIBUTES
            or RESERVED_VERTEX_ATTRIBUTES[name] != location
        ):
            raise RuntimeProgramError(
                f"{prefix} does not match the reserved Firestorm attribute contract"
            )
        format_name = _require_string(
            item.get("format"), f"{prefix}.format", _IDENTIFIER
        )
        if format_name not in VERTEX_FORMATS:
            raise RuntimeProgramError(f"{prefix}.format is unsupported")
        offset = _require_int(item.get("offset"), f"{prefix}.offset", 0, 2047)
        buffer_index = _require_int(
            item.get("buffer_index"), f"{prefix}.buffer_index", 0, MAX_BUFFER_INDEX
        )
        layout = layout_by_buffer.get(buffer_index)
        if layout is None:
            raise RuntimeProgramError(f"{prefix} references an undeclared layout")
        if offset + VERTEX_FORMATS[format_name] > int(layout["stride"]):
            raise RuntimeProgramError(f"{prefix} exceeds its vertex stride")
        alignment = VERTEX_FORMAT_ALIGNMENTS[format_name]
        if offset % alignment or int(layout["stride"]) % alignment:
            raise RuntimeProgramError(f"{prefix} is not naturally aligned")
        if name in seen_names or location in seen_locations:
            raise RuntimeProgramError(f"{field} has duplicate vertex attributes")
        seen_names.add(name)
        seen_locations.add(location)
        used_buffers.add(buffer_index)
        attributes.append(
            {
                "name": name,
                "location": location,
                "format": format_name,
                "offset": offset,
                "buffer_index": buffer_index,
            }
        )
    attributes.sort(key=lambda item: (int(item["location"]), str(item["name"])))
    if used_buffers != seen_buffers:
        raise RuntimeProgramError(f"{field} has an unused vertex layout")
    indexed = next(
        (item for item in attributes if item["name"] == "texture_index"), None
    )
    if indexed is not None:
        position = next(
            (item for item in attributes if item["name"] == "position"), None
        )
        layout = layout_by_buffer[int(indexed["buffer_index"])]
        if (
            position is None
            or position["buffer_index"] != indexed["buffer_index"]
            or position["offset"] != 0
            or indexed["offset"] != 12
            or indexed["format"] != "int"
            or layout["stride"] != 16
        ):
            raise RuntimeProgramError(
                f"{field} indexed position must alias texture_index at offset 12 stride 16"
            )
    return attributes, layouts


def make_program_record(
    family: str,
    pipeline_spec: object,
    stage_reflections: object,
) -> dict[str, object]:
    if not isinstance(pipeline_spec, dict):
        raise RuntimeProgramError("pipeline spec must be an object")
    _require_exact_keys(
        pipeline_spec,
        {
            "schema",
            "id",
            "metallib",
            "vertex_function",
            "fragment_function",
            "color_formats",
            "depth_format",
            "sample_count",
            "vertex_attributes",
            "vertex_layouts",
            "expected_arguments",
        },
        "pipeline spec",
    )
    if pipeline_spec.get("schema") != 4:
        raise RuntimeProgramError("pipeline spec.schema must be 4")
    program_id = _require_string(
        pipeline_spec.get("id"), "pipeline spec.id", _PROGRAM_ID
    )
    family = _require_string(family, f"{program_id}.family", _DISPLAY_TEXT)
    vertex_function = _require_string(
        pipeline_spec.get("vertex_function"),
        f"{program_id}.vertex_function",
        _IDENTIFIER,
    )
    fragment_function = _require_string(
        pipeline_spec.get("fragment_function"),
        f"{program_id}.fragment_function",
        _IDENTIFIER,
    )
    if (
        vertex_function != f"{program_id}_vertex"
        or fragment_function != f"{program_id}_fragment"
    ):
        raise RuntimeProgramError(f"{program_id} has unsafe or unstable function names")
    colors_value = pipeline_spec.get("color_formats")
    if (
        not isinstance(colors_value, list)
        or len(colors_value) > 4
        or not all(
            isinstance(item, str) and item in COLOR_FORMATS for item in colors_value
        )
    ):
        raise RuntimeProgramError(f"{program_id}.color_formats is unsupported")
    depth = pipeline_spec.get("depth_format")
    if depth is not None and depth not in DEPTH_FORMATS:
        raise RuntimeProgramError(f"{program_id}.depth_format is unsupported")
    if not colors_value and depth is None:
        raise RuntimeProgramError(f"{program_id} has no attachments")
    sample_count = _require_int(
        pipeline_spec.get("sample_count"), f"{program_id}.sample_count", 1, 1
    )
    attributes, layouts = _validate_vertex_contract(
        pipeline_spec.get("vertex_attributes"),
        pipeline_spec.get("vertex_layouts"),
        program_id,
    )
    bindings = _validate_stage_bindings(
        pipeline_spec.get("expected_arguments"), f"{program_id}.stage_bindings"
    )
    vertex_buffer_slots = {int(item["buffer_index"]) for item in layouts}
    vertex_shader_slots = {
        int(item["index"]) for item in bindings["vertex"] if item["kind"] == "buffer"
    }
    collisions = sorted(vertex_buffer_slots & vertex_shader_slots)
    if collisions:
        raise RuntimeProgramError(
            f"{program_id} vertex streams collide with shader buffers: {collisions}"
        )
    if not isinstance(stage_reflections, dict) or set(stage_reflections) != set(STAGES):
        raise RuntimeProgramError(
            f"{program_id}.stage_reflections must contain both stages"
        )
    reflection_digests: dict[str, str] = {}
    for stage in STAGES:
        reflection = stage_reflections[stage]
        if not isinstance(reflection, dict):
            raise RuntimeProgramError(
                f"{program_id}.{stage} reflection must be an object"
            )
        reflection_digests[stage] = sha256_hex(reflection)
    semantic = {
        "schema": 1,
        "id": program_id,
        "vertex_function": vertex_function,
        "fragment_function": fragment_function,
        "color_formats": colors_value,
        "depth_format": depth,
        "sample_count": sample_count,
        "vertex_attributes": attributes,
        "vertex_layouts": layouts,
        "stage_bindings": bindings,
        "stage_reflection_sha256": reflection_digests,
    }
    return {"family": family, **semantic, "reflection_sha256": sha256_hex(semantic)}


def make_artifact_document(
    programs: Iterable[dict[str, object]],
    metallib_sha256: str,
    manifest_schema: int,
    manifest_sha256: str,
    baseline_commit: str,
) -> dict[str, object]:
    ordered = sorted(programs, key=lambda item: str(item.get("id", "")))
    if not ordered:
        raise RuntimeProgramError("runtime artifact has no programs")
    ids = [str(item.get("id")) for item in ordered]
    if len(ids) != len(set(ids)):
        raise RuntimeProgramError("runtime artifact has duplicate program IDs")
    if _HEX_SHA256.fullmatch(metallib_sha256) is None:
        raise RuntimeProgramError("runtime artifact metallib digest is invalid")
    if _HEX_SHA256.fullmatch(manifest_sha256) is None:
        raise RuntimeProgramError("runtime artifact manifest digest is invalid")
    if re.fullmatch(r"[0-9a-f]{40}", baseline_commit) is None:
        raise RuntimeProgramError("runtime artifact baseline commit is invalid")
    manifest_schema = _require_int(
        manifest_schema, "runtime artifact manifest schema", 1, 2**16 - 1
    )
    families = sorted({str(item.get("family")) for item in ordered})
    identity = {
        "schema": ARTIFACT_SCHEMA,
        "programs": [
            {"id": item["id"], "reflection_sha256": item["reflection_sha256"]}
            for item in ordered
        ],
    }
    return {
        "schema": ARTIFACT_SCHEMA,
        "artifact": ARTIFACT_BASENAME,
        "library_resource": f"{ARTIFACT_BASENAME}.metallib",
        "source_manifest_schema": manifest_schema,
        "source_manifest_sha256": manifest_sha256,
        "baseline_commit": baseline_commit,
        "program_count": len(ordered),
        "family_count": len(families),
        "metallib_sha256": metallib_sha256,
        "reflection_sha256": sha256_hex(identity),
        "programs": ordered,
    }


def write_json(document: dict[str, object], path: Path) -> None:
    path.write_bytes(canonical_bytes(document))


def _cpp_string(value: object) -> str:
    if not isinstance(value, str) or "\0" in value:
        raise RuntimeProgramError("cannot render a non-string or NUL-containing value")
    return json.dumps(value, ensure_ascii=True)


def _cpp_enum(prefix: str, value: object) -> str:
    if not isinstance(value, str) or _IDENTIFIER.fullmatch(value) is None:
        raise RuntimeProgramError(f"unsafe C++ enum value: {value!r}")
    return f"{prefix}::{value}"


def _cpp_mapped_enum(prefix: str, value: object, mapping: dict[str, str]) -> str:
    if not isinstance(value, str) or value not in mapping:
        raise RuntimeProgramError(f"unsupported C++ enum value: {value!r}")
    return _cpp_enum(prefix, mapping[value])


def _array_declaration(
    cpp_type: str, name: str, rows: list[str]
) -> tuple[list[str], str]:
    if not rows:
        return [], f"emptyMetalArrayView<{cpp_type}>()"
    lines = [f"constexpr {cpp_type} {name}[] = {{"]
    lines.extend(f"    {row}," for row in rows)
    lines.append("};")
    return lines, f"metalArrayView({name})"


def render_header(document: dict[str, object]) -> bytes:
    programs = document.get("programs")
    if not isinstance(programs, list):
        raise RuntimeProgramError("artifact programs must be an array")
    enumerators = []
    for ordinal, program in enumerate(programs, 1):
        if not isinstance(program, dict):
            raise RuntimeProgramError("artifact program must be an object")
        program_id = _require_string(program.get("id"), "program.id", _PROGRAM_ID)
        enumerators.append(f"    {program_id} = {ordinal},")
    text = "\n".join(
        [
            "// Generated Firestorm Metal program catalog. Do not edit.",
            "#pragma once",
            "",
            '#include "llmetalprogram.h"',
            "",
            "#include <cstdint>",
            "#include <string_view>",
            "",
            "namespace firestorm::metal",
            "{",
            "",
            "// Values are deterministic lexical ordinals, not a persistence or telemetry ABI.",
            "enum class MetalProgramId : std::uint16_t",
            "{",
            *enumerators,
            "};",
            "",
            "const MetalProgramCatalogMetadata& declaredMetalProgramCatalog() noexcept;",
            "MetalArrayView<MetalProgramDescriptor> declaredMetalPrograms() noexcept;",
            "const MetalProgramDescriptor* metalProgramDescriptor(MetalProgramId id) noexcept;",
            "const MetalProgramDescriptor* metalProgramDescriptor(std::string_view id) noexcept;",
            "bool validateDeclaredMetalPrograms(std::string* error = nullptr);",
            "",
            "} // namespace firestorm::metal",
            "",
        ]
    )
    return text.encode("utf-8")


def render_source(document: dict[str, object], header_name: str) -> bytes:
    programs_value = document.get("programs")
    if not isinstance(programs_value, list):
        raise RuntimeProgramError("artifact programs must be an array")
    declarations: list[str] = []
    program_rows: list[str] = []
    for program_value in programs_value:
        if not isinstance(program_value, dict):
            raise RuntimeProgramError("artifact program must be an object")
        program_id = str(program_value["id"])
        symbol = f"k_{program_id}"

        colors = [
            _cpp_mapped_enum("PixelFormat", item, CPP_PIXEL_FORMATS)
            for item in program_value["color_formats"]  # type: ignore[index]
        ]
        lines, colors_view = _array_declaration(
            "PixelFormat", f"{symbol}_colors", colors
        )
        declarations.extend(lines)

        attributes = []
        for item in program_value["vertex_attributes"]:  # type: ignore[index]
            attributes.append(
                "{"
                + ", ".join(
                    [
                        _cpp_string(item["name"]),
                        str(item["location"]),
                        _cpp_mapped_enum(
                            "MetalVertexFormat", item["format"], CPP_VERTEX_FORMATS
                        ),
                        str(item["offset"]),
                        str(item["buffer_index"]),
                    ]
                )
                + "}"
            )
        lines, attributes_view = _array_declaration(
            "MetalVertexAttributeDescriptor", f"{symbol}_attributes", attributes
        )
        declarations.extend(lines)

        layouts = []
        for item in program_value["vertex_layouts"]:  # type: ignore[index]
            layouts.append(
                "{"
                + ", ".join(
                    [
                        str(item["buffer_index"]),
                        str(item["stride"]),
                        _cpp_enum("MetalVertexStepFunction", item["step_function"]),
                    ]
                )
                + "}"
            )
        lines, layouts_view = _array_declaration(
            "MetalVertexBufferLayoutDescriptor", f"{symbol}_layouts", layouts
        )
        declarations.extend(lines)

        stage_views: dict[str, tuple[str, str, str]] = {}
        for stage in STAGES:
            bindings = program_value["stage_bindings"][stage]  # type: ignore[index]
            buffer_rows: list[str] = []
            texture_rows: list[str] = []
            sampler_rows: list[str] = []
            for binding in bindings:
                kind = binding["kind"]
                if kind == "buffer":
                    buffer_rows.append(
                        "{"
                        + ", ".join(
                            [
                                _cpp_string(binding["name"]),
                                _cpp_string(binding["metal_name"]),
                                str(binding["index"]),
                                _cpp_enum("MetalResourceAccess", binding["access"]),
                                str(binding["buffer_size"]),
                                str(binding["buffer_alignment"]),
                                _cpp_string(binding["layout_sha256"]),
                            ]
                        )
                        + "}"
                    )
                elif kind == "texture":
                    texture_rows.append(
                        "{"
                        + ", ".join(
                            [
                                _cpp_string(binding["name"]),
                                _cpp_string(binding["metal_name"]),
                                str(binding["index"]),
                                _cpp_enum("MetalResourceAccess", binding["access"]),
                                _cpp_mapped_enum(
                                    "MetalTextureType",
                                    binding["texture_type"],
                                    CPP_TEXTURE_TYPES,
                                ),
                                _cpp_mapped_enum(
                                    "MetalTextureDataType",
                                    binding["texture_data_type"],
                                    CPP_TEXTURE_DATA_TYPES,
                                ),
                                str(binding["array_length"]),
                                "true" if binding["is_depth_texture"] else "false",
                            ]
                        )
                        + "}"
                    )
                elif kind == "sampler":
                    sampler_rows.append(
                        "{"
                        + ", ".join(
                            [
                                _cpp_string(binding["name"]),
                                _cpp_string(binding["metal_name"]),
                                str(binding["index"]),
                            ]
                        )
                        + "}"
                    )
            lines, buffer_view = _array_declaration(
                "MetalBufferBindingDescriptor", f"{symbol}_{stage}_buffers", buffer_rows
            )
            declarations.extend(lines)
            lines, texture_view = _array_declaration(
                "MetalTextureBindingDescriptor",
                f"{symbol}_{stage}_textures",
                texture_rows,
            )
            declarations.extend(lines)
            lines, sampler_view = _array_declaration(
                "MetalSamplerBindingDescriptor",
                f"{symbol}_{stage}_samplers",
                sampler_rows,
            )
            declarations.extend(lines)
            stage_views[stage] = (buffer_view, texture_view, sampler_view)

        depth = program_value["depth_format"]
        depth_enum = (
            "std::nullopt"
            if depth is None
            else _cpp_mapped_enum("PixelFormat", depth, CPP_PIXEL_FORMATS)
        )
        vertex = stage_views["vertex"]
        fragment = stage_views["fragment"]
        program_rows.append(
            "{"
            + ", ".join(
                [
                    f"MetalProgramId::{program_id}",
                    _cpp_string(program_id),
                    _cpp_string(program_value["family"]),
                    _cpp_string(program_value["vertex_function"]),
                    _cpp_string(program_value["fragment_function"]),
                    colors_view,
                    depth_enum,
                    str(program_value["sample_count"]),
                    attributes_view,
                    layouts_view,
                    "{" + ", ".join(vertex) + "}",
                    "{" + ", ".join(fragment) + "}",
                    _cpp_string(program_value["stage_reflection_sha256"]["vertex"]),  # type: ignore[index]
                    _cpp_string(program_value["stage_reflection_sha256"]["fragment"]),  # type: ignore[index]
                    _cpp_string(program_value["reflection_sha256"]),
                ]
            )
            + "}"
        )
        declarations.append("")

    source = "\n".join(
        [
            "// Generated Firestorm Metal program catalog. Do not edit.",
            f'#include "{header_name}"',
            "",
            "namespace firestorm::metal",
            "{",
            "namespace",
            "{",
            *declarations,
            "constexpr MetalProgramCatalogMetadata kCatalog{",
            f"    {document['schema']},",
            f"    {document['source_manifest_schema']},",
            f"    {document['program_count']},",
            f"    {document['family_count']},",
            f"    {_cpp_string(document['library_resource'])},",
            f"    {_cpp_string(document['source_manifest_sha256'])},",
            f"    {_cpp_string(document['baseline_commit'])},",
            f"    {_cpp_string(document['metallib_sha256'])},",
            f"    {_cpp_string(document['reflection_sha256'])},",
            "};",
            "",
            "constexpr MetalProgramDescriptor kPrograms[] = {",
            *(f"    {row}," for row in program_rows),
            "};",
            "",
            "} // namespace",
            "",
            "const MetalProgramCatalogMetadata& declaredMetalProgramCatalog() noexcept",
            "{",
            "    return kCatalog;",
            "}",
            "",
            "MetalArrayView<MetalProgramDescriptor> declaredMetalPrograms() noexcept",
            "{",
            "    return metalArrayView(kPrograms);",
            "}",
            "",
            "const MetalProgramDescriptor* metalProgramDescriptor(MetalProgramId id) noexcept",
            "{",
            "    for (const MetalProgramDescriptor& program : kPrograms)",
            "    {",
            "        if (program.id == id)",
            "        {",
            "            return &program;",
            "        }",
            "    }",
            "    return nullptr;",
            "}",
            "",
            "const MetalProgramDescriptor* metalProgramDescriptor(std::string_view id) noexcept",
            "{",
            "    for (const MetalProgramDescriptor& program : kPrograms)",
            "    {",
            "        if (program.name == id)",
            "        {",
            "            return &program;",
            "        }",
            "    }",
            "    return nullptr;",
            "}",
            "",
            "bool validateDeclaredMetalPrograms(std::string* error)",
            "{",
            "    if (!validateMetalProgramCatalogMetadata(kCatalog, error) ||",
            "        !validateMetalProgramDescriptors(declaredMetalPrograms(), error))",
            "    {",
            "        return false;",
            "    }",
            "    if (kCatalog.programCount != declaredMetalPrograms().size())",
            "    {",
            "        if (error != nullptr)",
            "        {",
            '            *error = "catalog program count disagrees with descriptors";',
            "        }",
            "        return false;",
            "    }",
            "    std::size_t family_count = 0;",
            "    for (std::size_t index = 0; index < declaredMetalPrograms().size(); ++index)",
            "    {",
            "        bool first = true;",
            "        for (std::size_t previous = 0; previous < index; ++previous)",
            "        {",
            "            first = first && declaredMetalPrograms()[previous].family !=",
            "                             declaredMetalPrograms()[index].family;",
            "        }",
            "        family_count += first ? 1U : 0U;",
            "    }",
            "    if (kCatalog.familyCount != family_count)",
            "    {",
            "        if (error != nullptr)",
            "        {",
            '            *error = "catalog family count disagrees with descriptors";',
            "        }",
            "        return false;",
            "    }",
            "    return true;",
            "}",
            "",
            "} // namespace firestorm::metal",
            "",
        ]
    )
    return source.encode("utf-8")


def write_cpp(document: dict[str, object], output_root: Path) -> tuple[Path, Path]:
    header = output_root / f"{ARTIFACT_BASENAME}.h"
    source = output_root / f"{ARTIFACT_BASENAME}.cpp"
    header.write_bytes(render_header(document))
    source.write_bytes(render_source(document, header.name))
    return header, source


def artifact_hashes(output_root: Path) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for suffix in ("json", "h", "cpp", "metallib"):
        path = output_root / f"{ARTIFACT_BASENAME}.{suffix}"
        if not path.is_file():
            raise RuntimeProgramError(f"missing runtime artifact: {path.name}")
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def reject_embedded_paths(paths: Iterable[Path], forbidden: Iterable[str]) -> None:
    needles = [item.encode("utf-8") for item in forbidden if item]
    for path in paths:
        contents = path.read_bytes()
        for needle in needles:
            if needle in contents:
                raise RuntimeProgramError(
                    f"{path.name} embeds forbidden path text {needle.decode('utf-8', errors='replace')!r}"
                )
