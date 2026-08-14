"""Tests for structural SPIR-V interface inspection and location remapping."""

from __future__ import annotations

import importlib.util
import itertools
import struct
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("spirv_locations.py")
SPEC = importlib.util.spec_from_file_location("spirv_locations", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
spirv_locations = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = spirv_locations
SPEC.loader.exec_module(spirv_locations)


def _literal(value: str) -> tuple[int, ...]:
    encoded = value.encode("utf-8") + b"\0"
    encoded += b"\0" * (-len(encoded) % 4)
    return struct.unpack(f"<{len(encoded) // 4}I", encoded)


def _instruction(opcode: int, *operands: int) -> tuple[int, ...]:
    return (((len(operands) + 1) << 16) | opcode, *operands)


def _module(*instructions: tuple[int, ...], bound: int = 64) -> bytes:
    words = [spirv_locations.SPIRV_MAGIC, 0x00010600, 0, bound, 0]
    for instruction in instructions:
        words.extend(instruction)
    return struct.pack(f"<{len(words)}I", *words)


def _name(target_id: int, name: str) -> tuple[int, ...]:
    return _instruction(spirv_locations.OP_NAME, target_id, *_literal(name))


def _decorate(target_id: int, kind: int, *values: int) -> tuple[int, ...]:
    return _instruction(spirv_locations.OP_DECORATE, target_id, kind, *values)


def _location(target_id: int, value: int) -> tuple[int, ...]:
    return _decorate(target_id, spirv_locations.DECORATION_LOCATION, value)


def _variable(target_id: int, storage_class: int) -> tuple[int, ...]:
    return _instruction(spirv_locations.OP_VARIABLE, 2, target_id, storage_class)


def _entry_point(
    *interface_ids: int, target_id: int = 1, name: str = "main"
) -> tuple[int, ...]:
    return _instruction(
        spirv_locations.OP_ENTRY_POINT,
        0,
        target_id,
        *_literal(name),
        *interface_ids,
    )


class SpirvLocationTest(unittest.TestCase):
    def test_inspects_semantics_and_only_changes_location_words(self) -> None:
        original = _module(
            _instruction(17, 1),
            _entry_point(3, 7, 8, 9),
            _name(3, "position"),
            _name(7, "color"),
            _name(8, "vertex_index"),
            _name(9, "system_block"),
            _location(3, 4),
            _decorate(3, spirv_locations.DECORATION_FLAT),
            _decorate(3, spirv_locations.DECORATION_CENTROID),
            _decorate(3, spirv_locations.DECORATION_INVARIANT),
            _location(7, 9),
            _decorate(7, spirv_locations.DECORATION_NO_PERSPECTIVE),
            _decorate(7, spirv_locations.DECORATION_SAMPLE),
            _decorate(7, spirv_locations.DECORATION_PATCH),
            _decorate(8, spirv_locations.DECORATION_BUILT_IN, 42),
            _instruction(0),
        )
        self.assertEqual(
            (
                spirv_locations.EntryPointInterface(
                    name="color",
                    target_id=7,
                    location=9,
                    semantics=spirv_locations.InterfaceSemantics(
                        no_perspective=True, sample=True, patch=True
                    ),
                ),
                spirv_locations.EntryPointInterface(
                    name="position",
                    target_id=3,
                    location=4,
                    semantics=spirv_locations.InterfaceSemantics(
                        flat=True, centroid=True, invariant=True
                    ),
                ),
            ),
            spirv_locations.inspect_entry_point_interfaces(original),
        )

        remapped = spirv_locations.remap_interface_locations(
            original, {"color": 1, "position": 0}
        )
        before = struct.unpack(f"<{len(original) // 4}I", original)
        after = struct.unpack(f"<{len(remapped) // 4}I", remapped)
        self.assertEqual(len(before), len(after))
        differences = [
            (old, new)
            for old, new in itertools.zip_longest(before, after)
            if old != new
        ]
        self.assertEqual([(4, 0), (9, 1)], differences)
        self.assertEqual(len(original), len(remapped))
        self.assertEqual(
            (
                spirv_locations.LocationRemap("color", 7, 9, 1),
                spirv_locations.LocationRemap("position", 3, 4, 0),
            ),
            spirv_locations.describe_location_remap(
                original, {"position": 0, "color": 1}
            ),
        )

    def test_empty_mapping_requires_main_but_preserves_valid_module(self) -> None:
        original = _module(_entry_point(), _instruction(0))
        self.assertEqual((), spirv_locations.inspect_entry_point_interfaces(original))
        self.assertEqual(
            original, spirv_locations.remap_interface_locations(original, {})
        )

    def test_requires_exactly_one_entry_point_named_main(self) -> None:
        modules = {
            "zero": _module(_instruction(0)),
            "multiple": _module(_entry_point(), _entry_point(target_id=2)),
            "wrong name": _module(_entry_point(name="vertex_main")),
        }
        for label, module in modules.items():
            with (
                self.subTest(label=label, operation="inspect"),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.inspect_entry_point_interfaces(module)
            with (
                self.subTest(label=label, operation="remap"),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.remap_interface_locations(module, {})

    def test_reports_component_and_index_but_generic_remap_rejects_them(self) -> None:
        for label, decoration, value in (
            ("Component", spirv_locations.DECORATION_COMPONENT, 2),
            ("Index", spirv_locations.DECORATION_INDEX, 1),
        ):
            module = _module(
                _entry_point(3),
                _name(3, "packed"),
                _location(3, 0),
                _decorate(3, decoration, value),
            )
            interface = spirv_locations.inspect_entry_point_interfaces(module)[0]
            self.assertEqual(
                value,
                (
                    interface.semantics.component
                    if label == "Component"
                    else interface.semantics.index
                ),
            )
            with self.assertRaisesRegex(
                spirv_locations.SpirvLocationError, f"unsupported {label}"
            ):
                spirv_locations.remap_interface_locations(module, {"packed": 3})

    def test_builtins_and_system_blocks_are_not_user_interfaces(self) -> None:
        module = _module(
            _entry_point(3, 4, 5),
            _name(3, "position"),
            _name(4, "system_block"),
            _name(5, "user_value"),
            _decorate(3, spirv_locations.DECORATION_BUILT_IN, 0),
            _location(5, 2),
            _instruction(
                spirv_locations.OP_MEMBER_DECORATE,
                20,
                0,
                spirv_locations.DECORATION_BUILT_IN,
                0,
            ),
            _instruction(
                spirv_locations.OP_MEMBER_DECORATE,
                20,
                0,
                spirv_locations.DECORATION_INVARIANT,
            ),
        )
        self.assertEqual(
            ("user_value",),
            tuple(
                item.name
                for item in spirv_locations.inspect_entry_point_interfaces(module)
            ),
        )
        with self.assertRaisesRegex(spirv_locations.SpirvLocationError, "not a named"):
            spirv_locations.remap_interface_locations(module, {"position": 1})

    def test_ignores_same_named_local_variable(self) -> None:
        module = _module(
            _entry_point(4),
            _name(3, "pos"),
            _name(4, "pos"),
            _location(4, 0),
        )
        self.assertEqual(
            (spirv_locations.LocationRemap("pos", 4, 0, 2),),
            spirv_locations.describe_location_remap(module, {"pos": 2}),
        )

    def test_rejects_non_interface_and_ambiguous_interface_names(self) -> None:
        with self.assertRaisesRegex(spirv_locations.SpirvLocationError, "not a named"):
            spirv_locations.remap_interface_locations(
                _module(
                    _entry_point(4),
                    _name(3, "local"),
                    _name(4, "interface"),
                    _location(3, 0),
                    _location(4, 1),
                ),
                {"local": 2},
            )
        with self.assertRaisesRegex(
            spirv_locations.SpirvLocationError, "name 'position' is ambiguous"
        ):
            spirv_locations.inspect_entry_point_interfaces(
                _module(
                    _entry_point(3, 4),
                    _name(3, "position"),
                    _name(4, "position"),
                    _location(3, 0),
                    _location(4, 1),
                )
            )

    def test_rejects_duplicate_names_and_semantic_decorations(self) -> None:
        modules = {
            "names": _module(
                _entry_point(3),
                _name(3, "position"),
                _name(3, "alias"),
                _location(3, 0),
            ),
            "locations": _module(
                _entry_point(3),
                _name(3, "position"),
                _location(3, 0),
                _location(3, 1),
            ),
            "flags": _module(
                _entry_point(3),
                _name(3, "position"),
                _location(3, 0),
                _decorate(3, spirv_locations.DECORATION_FLAT),
                _decorate(3, spirv_locations.DECORATION_FLAT),
            ),
        }
        for label, module in modules.items():
            with (
                self.subTest(label=label),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.inspect_entry_point_interfaces(module)

    def test_rejects_duplicate_destinations_and_invalid_values(self) -> None:
        module = _module(
            _entry_point(3, 4),
            _name(3, "position"),
            _name(4, "color"),
            _location(3, 0),
            _location(4, 1),
        )
        with self.assertRaisesRegex(
            spirv_locations.SpirvLocationError, "location 1 is duplicated"
        ):
            spirv_locations.remap_interface_locations(
                module, {"position": 1, "color": 1}
            )
        for location in (True, -1, 0x1_0000_0000):
            with (
                self.subTest(location=location),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.remap_interface_locations(
                    module, {"position": location}
                )

    def test_partial_mapping_rejects_only_same_storage_class_collision(self) -> None:
        unknown_storage_class = _module(
            _entry_point(3, 4),
            _name(3, "position"),
            _name(4, "normal"),
            _location(3, 0),
            _location(4, 1),
        )
        with self.assertRaisesRegex(
            spirv_locations.SpirvLocationError,
            "location 1.*collides with unchanged interface 'normal'",
        ):
            spirv_locations.remap_interface_locations(
                unknown_storage_class, {"position": 1}
            )

        same_storage_class = _module(
            _entry_point(3, 4, 5),
            _name(3, "position"),
            _name(4, "normal"),
            _name(5, "varying"),
            _location(3, 0),
            _location(4, 1),
            _location(5, 1),
            _variable(3, 1),
            _variable(4, 1),
            _variable(5, 3),
        )
        with self.assertRaisesRegex(
            spirv_locations.SpirvLocationError,
            "location 1.*collides with unchanged interface 'normal'",
        ):
            spirv_locations.remap_interface_locations(
                same_storage_class, {"position": 1}
            )

        different_storage_class = _module(
            _entry_point(3, 5),
            _name(3, "position"),
            _name(5, "varying"),
            _location(3, 0),
            _location(5, 1),
            _variable(3, 1),
            _variable(5, 3),
        )
        self.assertEqual(
            (spirv_locations.LocationRemap("position", 3, 0, 1),),
            spirv_locations.describe_location_remap(
                different_storage_class, {"position": 1}
            ),
        )

    def test_rejects_indirect_and_member_level_interface_layouts(self) -> None:
        indirect = _module(
            _entry_point(3),
            _name(3, "position"),
            _instruction(spirv_locations.OP_DECORATION_GROUP, 20),
            _location(20, 0),
            _instruction(spirv_locations.OP_GROUP_DECORATE, 20, 3),
        )
        with self.assertRaisesRegex(
            spirv_locations.SpirvLocationError, "indirect grouped Location"
        ):
            spirv_locations.inspect_entry_point_interfaces(indirect)

        member = _module(
            _entry_point(3),
            _name(3, "position"),
            _location(3, 0),
            _instruction(
                spirv_locations.OP_MEMBER_DECORATE,
                20,
                0,
                spirv_locations.DECORATION_LOCATION,
                1,
            ),
        )
        with self.assertRaisesRegex(spirv_locations.SpirvLocationError, "member-level"):
            spirv_locations.inspect_entry_point_interfaces(member)

    def test_rejects_malformed_decoration_shapes(self) -> None:
        malformed = {
            "location missing literal": _decorate(
                3, spirv_locations.DECORATION_LOCATION
            ),
            "component extra literal": _decorate(
                3, spirv_locations.DECORATION_COMPONENT, 0, 1
            ),
            "flag with operand": _decorate(3, spirv_locations.DECORATION_FLAT, 1),
        }
        for label, decoration in malformed.items():
            with (
                self.subTest(label=label),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.inspect_entry_point_interfaces(
                    _module(_entry_point(3), _name(3, "value"), decoration)
                )

    def test_rejects_malformed_headers_and_instruction_bounds(self) -> None:
        valid = _module(_entry_point(), _instruction(0))
        malformed = {
            "short header": valid[:16],
            "partial word": valid + b"x",
            "wrong endian": b"\x07\x23\x02\x03" + valid[4:],
            "zero bound": valid[:12] + struct.pack("<I", 0) + valid[16:],
            "nonzero schema": valid[:16] + struct.pack("<I", 1) + valid[20:],
            "zero word count": _module((0,)),
            "instruction overrun": _module(((4 << 16) | 17, 1)),
        }
        for label, module in malformed.items():
            with (
                self.subTest(label=label),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.remap_interface_locations(module, {})

    def test_rejects_malformed_name_and_entry_point_instructions(self) -> None:
        malformed = {
            "out-of-bound name ID": _module(_entry_point(), _name(64, "value")),
            "unterminated name": _module(
                _entry_point(),
                _instruction(
                    spirv_locations.OP_NAME,
                    3,
                    struct.unpack("<I", b"name")[0],
                ),
            ),
            "short entry point": _module(
                _instruction(spirv_locations.OP_ENTRY_POINT, 0, 1)
            ),
            "invalid entry target": _module(_entry_point(target_id=64)),
            "invalid interface": _module(_entry_point(64)),
            "duplicate interface": _module(_entry_point(3, 3)),
            "nonzero name padding": _module(
                _instruction(
                    spirv_locations.OP_ENTRY_POINT,
                    0,
                    1,
                    struct.unpack("<I", b"m\0x\0")[0],
                )
            ),
            "unterminated entry name": _module(
                _instruction(
                    spirv_locations.OP_ENTRY_POINT,
                    0,
                    1,
                    struct.unpack("<I", b"main")[0],
                )
            ),
        }
        for label, module in malformed.items():
            with (
                self.subTest(label=label),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.remap_interface_locations(module, {})

    def test_rejects_malformed_decoration_groups(self) -> None:
        malformed = {
            "unknown group": _module(
                _entry_point(),
                _instruction(spirv_locations.OP_GROUP_DECORATE, 20, 3),
            ),
            "nested group": _module(
                _entry_point(),
                _instruction(spirv_locations.OP_DECORATION_GROUP, 20),
                _instruction(spirv_locations.OP_DECORATION_GROUP, 21),
                _decorate(20, spirv_locations.DECORATION_FLAT),
                _instruction(spirv_locations.OP_GROUP_DECORATE, 20, 21),
            ),
            "odd member operands": _module(
                _entry_point(),
                _instruction(spirv_locations.OP_GROUP_MEMBER_DECORATE, 20, 3),
            ),
        }
        for label, module in malformed.items():
            with (
                self.subTest(label=label),
                self.assertRaises(spirv_locations.SpirvLocationError),
            ):
                spirv_locations.inspect_entry_point_interfaces(module)


if __name__ == "__main__":
    unittest.main()
