"""Inspect and structurally remap named SPIR-V interface locations."""

from __future__ import annotations

import struct
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Final

SPIRV_MAGIC: Final = 0x07230203
OP_NAME: Final = 5
OP_ENTRY_POINT: Final = 15
OP_VARIABLE: Final = 59
OP_DECORATE: Final = 71
OP_MEMBER_DECORATE: Final = 72
OP_DECORATION_GROUP: Final = 73
OP_GROUP_DECORATE: Final = 74
OP_GROUP_MEMBER_DECORATE: Final = 75

DECORATION_BUILT_IN: Final = 11
DECORATION_NO_PERSPECTIVE: Final = 13
DECORATION_FLAT: Final = 14
DECORATION_PATCH: Final = 15
DECORATION_CENTROID: Final = 16
DECORATION_SAMPLE: Final = 17
DECORATION_INVARIANT: Final = 18
DECORATION_LOCATION: Final = 30
DECORATION_COMPONENT: Final = 31
DECORATION_INDEX: Final = 32

HEADER_WORD_COUNT: Final = 5
MAX_WORD: Final = 0xFFFFFFFF

_LITERAL_INTERFACE_DECORATIONS: Final = {
    DECORATION_BUILT_IN: "BuiltIn",
    DECORATION_LOCATION: "Location",
    DECORATION_COMPONENT: "Component",
    DECORATION_INDEX: "Index",
}
_FLAG_INTERFACE_DECORATIONS: Final = {
    DECORATION_NO_PERSPECTIVE: "NoPerspective",
    DECORATION_FLAT: "Flat",
    DECORATION_PATCH: "Patch",
    DECORATION_CENTROID: "Centroid",
    DECORATION_SAMPLE: "Sample",
    DECORATION_INVARIANT: "Invariant",
}
_INTERFACE_DECORATIONS: Final = {
    **_LITERAL_INTERFACE_DECORATIONS,
    **_FLAG_INTERFACE_DECORATIONS,
}


class SpirvLocationError(ValueError):
    """The SPIR-V module or requested location mapping is invalid."""


@dataclass(frozen=True)
class InterfaceSemantics:
    """Location-adjacent semantics that must agree across shader stages."""

    component: int | None = None
    index: int | None = None
    flat: bool = False
    no_perspective: bool = False
    centroid: bool = False
    sample: bool = False
    patch: bool = False
    invariant: bool = False


@dataclass(frozen=True)
class EntryPointInterface:
    """One named, location-decorated user interface of entry point ``main``."""

    name: str
    target_id: int
    location: int
    semantics: InterfaceSemantics


@dataclass(frozen=True)
class LocationRemap:
    """One resolved interface-location change."""

    name: str
    target_id: int
    old_location: int
    new_location: int


@dataclass(frozen=True)
class _Decoration:
    kind: int
    value: int | None
    value_word_offset: int | None
    indirect: bool = False


@dataclass(frozen=True)
class _EntryPoint:
    execution_model: int
    target_id: int
    name: str
    interface_ids: tuple[int, ...]


@dataclass(frozen=True)
class _MemberDecoration:
    target_id: int
    member: int
    decoration: _Decoration


@dataclass(frozen=True)
class _GroupApplication:
    group_id: int
    target_ids: tuple[int, ...]


@dataclass(frozen=True)
class _GroupMemberApplication:
    group_id: int
    targets: tuple[tuple[int, int], ...]


@dataclass
class _ParsedModule:
    names: dict[int, list[str]]
    decorations: dict[int, list[_Decoration]]
    entry_points: list[_EntryPoint]
    member_decorations: list[_MemberDecoration]
    variable_storage_classes: dict[int, int]


@dataclass(frozen=True)
class _InspectedInterface:
    public: EntryPointInterface
    location_decoration: _Decoration
    storage_class: int | None


def _read_words(module: bytes) -> tuple[int, ...]:
    if len(module) < HEADER_WORD_COUNT * 4:
        raise SpirvLocationError("SPIR-V module is shorter than its five-word header")
    if len(module) % 4:
        raise SpirvLocationError("SPIR-V module size must be a multiple of four bytes")

    words = struct.unpack(f"<{len(module) // 4}I", module)
    if words[0] != SPIRV_MAGIC:
        raise SpirvLocationError(
            "SPIR-V module has an invalid little-endian magic word"
        )

    version = words[1]
    major = (version >> 16) & 0xFF
    if major == 0 or version & 0xFF0000FF:
        raise SpirvLocationError(
            f"SPIR-V module has an invalid version word: {version:#010x}"
        )
    if words[3] == 0:
        raise SpirvLocationError("SPIR-V module ID bound must be nonzero")
    if words[4] != 0:
        raise SpirvLocationError("SPIR-V module schema word must be zero")
    return words


def _validate_id(target_id: int, bound: int, instruction: str) -> None:
    if target_id == 0 or target_id >= bound:
        raise SpirvLocationError(
            f"{instruction} target ID {target_id} is outside the module bound {bound}"
        )


def _decode_literal_string(
    words: tuple[int, ...], start: int, end: int, instruction: str
) -> tuple[str, int]:
    encoded = bytearray()
    for offset in range(start, end):
        encoded_word = struct.pack("<I", words[offset])
        terminator = encoded_word.find(b"\0")
        if terminator < 0:
            encoded.extend(encoded_word)
            continue
        if any(encoded_word[terminator + 1 :]):
            raise SpirvLocationError(
                f"{instruction} string has nonzero padding after its terminator"
            )
        encoded.extend(encoded_word[:terminator])
        next_word = offset + 1
        break
    else:
        raise SpirvLocationError(f"{instruction} string is not null terminated")

    try:
        return encoded.decode("utf-8"), next_word
    except UnicodeDecodeError as error:
        raise SpirvLocationError(f"{instruction} string is not valid UTF-8") from error


def _parse_interface_decoration(
    words: tuple[int, ...],
    decoration_offset: int,
    end: int,
    instruction: str,
) -> _Decoration | None:
    kind = words[decoration_offset]
    operand_count = end - decoration_offset - 1
    if kind in _LITERAL_INTERFACE_DECORATIONS:
        if operand_count != 1:
            raise SpirvLocationError(
                f"{instruction} {_LITERAL_INTERFACE_DECORATIONS[kind]} must "
                "contain exactly one literal"
            )
        return _Decoration(
            kind=kind,
            value=words[decoration_offset + 1],
            value_word_offset=decoration_offset + 1,
        )
    if kind in _FLAG_INTERFACE_DECORATIONS:
        if operand_count != 0:
            raise SpirvLocationError(
                f"{instruction} {_FLAG_INTERFACE_DECORATIONS[kind]} must not "
                "contain operands"
            )
        return _Decoration(kind=kind, value=None, value_word_offset=None)
    return None


def _parse_module(words: tuple[int, ...]) -> _ParsedModule:
    names: dict[int, list[str]] = {}
    decorations: dict[int, list[_Decoration]] = {}
    entry_points: list[_EntryPoint] = []
    member_decorations: list[_MemberDecoration] = []
    variable_storage_classes: dict[int, int] = {}
    decoration_groups: set[int] = set()
    group_applications: list[_GroupApplication] = []
    group_member_applications: list[_GroupMemberApplication] = []
    bound = words[3]
    offset = HEADER_WORD_COUNT

    while offset < len(words):
        instruction_word = words[offset]
        word_count = instruction_word >> 16
        opcode = instruction_word & 0xFFFF
        if word_count == 0:
            raise SpirvLocationError(
                f"instruction at word {offset} has zero word count"
            )
        end = offset + word_count
        if end > len(words):
            raise SpirvLocationError(
                f"instruction at word {offset} extends beyond the module"
            )

        if opcode == OP_NAME:
            if word_count < 3:
                raise SpirvLocationError(
                    "OpName must contain a target ID and literal string"
                )
            target_id = words[offset + 1]
            _validate_id(target_id, bound, "OpName")
            name, next_word = _decode_literal_string(words, offset + 2, end, "OpName")
            if next_word != end:
                raise SpirvLocationError("OpName has operands after its literal string")
            names.setdefault(target_id, []).append(name)
        elif opcode == OP_ENTRY_POINT:
            if word_count < 4:
                raise SpirvLocationError(
                    "OpEntryPoint must contain an execution model, target ID, and name"
                )
            target_id = words[offset + 2]
            _validate_id(target_id, bound, "OpEntryPoint")
            name, interfaces_start = _decode_literal_string(
                words, offset + 3, end, "OpEntryPoint"
            )
            interface_ids = words[interfaces_start:end]
            if len(interface_ids) != len(set(interface_ids)):
                raise SpirvLocationError(
                    f"OpEntryPoint target ID {target_id} has duplicate interface IDs"
                )
            for interface_id in interface_ids:
                _validate_id(interface_id, bound, "OpEntryPoint interface")
            entry_points.append(
                _EntryPoint(
                    execution_model=words[offset + 1],
                    target_id=target_id,
                    name=name,
                    interface_ids=interface_ids,
                )
            )
        elif opcode == OP_DECORATE:
            if word_count < 3:
                raise SpirvLocationError(
                    "OpDecorate must contain a target ID and decoration"
                )
            target_id = words[offset + 1]
            _validate_id(target_id, bound, "OpDecorate")
            decoration = _parse_interface_decoration(
                words, offset + 2, end, "OpDecorate"
            )
            if decoration is not None:
                decorations.setdefault(target_id, []).append(decoration)
        elif opcode == OP_MEMBER_DECORATE:
            if word_count < 4:
                raise SpirvLocationError(
                    "OpMemberDecorate must contain a target ID, member, and decoration"
                )
            target_id = words[offset + 1]
            _validate_id(target_id, bound, "OpMemberDecorate")
            decoration = _parse_interface_decoration(
                words, offset + 3, end, "OpMemberDecorate"
            )
            if decoration is not None:
                member_decorations.append(
                    _MemberDecoration(
                        target_id=target_id,
                        member=words[offset + 2],
                        decoration=decoration,
                    )
                )
        elif opcode == OP_DECORATION_GROUP:
            if word_count != 2:
                raise SpirvLocationError(
                    "OpDecorationGroup must contain exactly one result ID"
                )
            group_id = words[offset + 1]
            _validate_id(group_id, bound, "OpDecorationGroup")
            if group_id in decoration_groups:
                raise SpirvLocationError(
                    f"duplicate OpDecorationGroup result ID {group_id}"
                )
            decoration_groups.add(group_id)
        elif opcode == OP_GROUP_DECORATE:
            if word_count < 3:
                raise SpirvLocationError(
                    "OpGroupDecorate must contain a group and at least one target"
                )
            group_id = words[offset + 1]
            _validate_id(group_id, bound, "OpGroupDecorate group")
            target_ids = words[offset + 2 : end]
            if len(target_ids) != len(set(target_ids)):
                raise SpirvLocationError("OpGroupDecorate has duplicate target IDs")
            for target_id in target_ids:
                _validate_id(target_id, bound, "OpGroupDecorate")
            group_applications.append(
                _GroupApplication(group_id=group_id, target_ids=target_ids)
            )
        elif opcode == OP_GROUP_MEMBER_DECORATE:
            if word_count < 4 or (word_count - 2) % 2:
                raise SpirvLocationError(
                    "OpGroupMemberDecorate must contain target/member pairs"
                )
            group_id = words[offset + 1]
            _validate_id(group_id, bound, "OpGroupMemberDecorate group")
            targets = tuple(
                (words[index], words[index + 1]) for index in range(offset + 2, end, 2)
            )
            if len(targets) != len(set(targets)):
                raise SpirvLocationError(
                    "OpGroupMemberDecorate has duplicate target/member pairs"
                )
            for target_id, _ in targets:
                _validate_id(target_id, bound, "OpGroupMemberDecorate")
            group_member_applications.append(
                _GroupMemberApplication(group_id=group_id, targets=targets)
            )
        elif opcode == OP_VARIABLE:
            if word_count not in {4, 5}:
                raise SpirvLocationError(
                    "OpVariable must contain a result type, result ID, storage "
                    "class, and optional initializer"
                )
            result_type = words[offset + 1]
            result_id = words[offset + 2]
            _validate_id(result_type, bound, "OpVariable result type")
            _validate_id(result_id, bound, "OpVariable result")
            if result_id in variable_storage_classes:
                raise SpirvLocationError(f"duplicate OpVariable result ID {result_id}")
            variable_storage_classes[result_id] = words[offset + 3]

        offset = end

    for application in group_applications:
        if application.group_id not in decoration_groups:
            raise SpirvLocationError(
                f"OpGroupDecorate references non-group ID {application.group_id}"
            )
        for target_id in application.target_ids:
            if target_id in decoration_groups:
                raise SpirvLocationError("nested decoration groups are unsupported")
            for decoration in decorations.get(application.group_id, []):
                decorations.setdefault(target_id, []).append(
                    _Decoration(
                        kind=decoration.kind,
                        value=decoration.value,
                        value_word_offset=decoration.value_word_offset,
                        indirect=True,
                    )
                )

    for application in group_member_applications:
        if application.group_id not in decoration_groups:
            raise SpirvLocationError(
                f"OpGroupMemberDecorate references non-group ID {application.group_id}"
            )
        for target_id, member in application.targets:
            for decoration in decorations.get(application.group_id, []):
                member_decorations.append(
                    _MemberDecoration(
                        target_id=target_id,
                        member=member,
                        decoration=_Decoration(
                            kind=decoration.kind,
                            value=decoration.value,
                            value_word_offset=decoration.value_word_offset,
                            indirect=True,
                        ),
                    )
                )

    return _ParsedModule(
        names=names,
        decorations=decorations,
        entry_points=entry_points,
        member_decorations=member_decorations,
        variable_storage_classes=variable_storage_classes,
    )


def _select_main_entry_point(parsed: _ParsedModule) -> _EntryPoint:
    if len(parsed.entry_points) != 1:
        raise SpirvLocationError(
            "SPIR-V module must contain exactly one OpEntryPoint instruction; "
            f"found {len(parsed.entry_points)}"
        )
    entry_point = parsed.entry_points[0]
    if entry_point.name != "main":
        raise SpirvLocationError(
            f"SPIR-V entry point must be named 'main', found {entry_point.name!r}"
        )
    return entry_point


def _decoration_records(
    parsed: _ParsedModule, target_id: int, kind: int
) -> list[_Decoration]:
    return [
        decoration
        for decoration in parsed.decorations.get(target_id, [])
        if decoration.kind == kind
    ]


def _single_decoration(
    parsed: _ParsedModule, target_id: int, kind: int
) -> _Decoration | None:
    records = _decoration_records(parsed, target_id, kind)
    if len(records) > 1:
        raise SpirvLocationError(
            f"target ID {target_id} has {len(records)} "
            f"{_INTERFACE_DECORATIONS[kind]} decorations"
        )
    return records[0] if records else None


def _flag_decoration(parsed: _ParsedModule, target_id: int, kind: int) -> bool:
    return _single_decoration(parsed, target_id, kind) is not None


def _inspect_module(module: bytes) -> tuple[_InspectedInterface, ...]:
    words = _read_words(module)
    parsed = _parse_module(words)
    entry_point = _select_main_entry_point(parsed)

    members: dict[tuple[int, int], list[_Decoration]] = {}
    for item in parsed.member_decorations:
        members.setdefault((item.target_id, item.member), []).append(item.decoration)
    for (target_id, member), decorations in members.items():
        built_ins = [
            decoration
            for decoration in decorations
            if decoration.kind == DECORATION_BUILT_IN
        ]
        if len(built_ins) > 1:
            raise SpirvLocationError(
                f"target ID {target_id}, member {member} has duplicate BuiltIn "
                "decorations"
            )
        if built_ins:
            conflicts = [
                decoration
                for decoration in decorations
                if decoration.kind
                in {
                    DECORATION_LOCATION,
                    DECORATION_COMPONENT,
                    DECORATION_INDEX,
                }
            ]
            if conflicts:
                raise SpirvLocationError(
                    f"BuiltIn target ID {target_id}, member {member} also uses "
                    f"{_INTERFACE_DECORATIONS[conflicts[0].kind]}"
                )
            continue
        if decorations:
            raise SpirvLocationError(
                "member-level interface semantics are unsupported: "
                f"target ID {target_id}, member {member}, "
                f"{_INTERFACE_DECORATIONS[decorations[0].kind]}"
            )

    inspected: list[_InspectedInterface] = []
    names: dict[str, int] = {}
    for target_id in entry_point.interface_ids:
        built_in = _single_decoration(parsed, target_id, DECORATION_BUILT_IN)
        location = _single_decoration(parsed, target_id, DECORATION_LOCATION)
        if built_in is not None:
            if location is not None:
                raise SpirvLocationError(
                    f"entry-point interface ID {target_id} has both BuiltIn and "
                    "Location decorations"
                )
            continue

        semantic_records = [
            decoration
            for decoration in parsed.decorations.get(target_id, [])
            if decoration.kind in _INTERFACE_DECORATIONS
        ]
        if location is None:
            if semantic_records:
                raise SpirvLocationError(
                    f"entry-point interface ID {target_id} has interface semantics "
                    "without a Location decoration"
                )
            continue
        if location.indirect:
            raise SpirvLocationError(
                f"entry-point interface ID {target_id} uses an indirect grouped "
                "Location decoration"
            )
        if location.value is None:
            raise SpirvLocationError("Location decoration unexpectedly has no literal")

        target_names = parsed.names.get(target_id, [])
        if len(target_names) != 1 or not target_names[0]:
            raise SpirvLocationError(
                f"location-decorated interface ID {target_id} must have exactly one "
                "non-empty OpName"
            )
        name = target_names[0]
        previous_target = names.get(name)
        if previous_target is not None:
            raise SpirvLocationError(
                f"entry-point interface name {name!r} is ambiguous between target "
                f"IDs {previous_target} and {target_id}"
            )
        names[name] = target_id

        component = _single_decoration(parsed, target_id, DECORATION_COMPONENT)
        index = _single_decoration(parsed, target_id, DECORATION_INDEX)
        for decoration in semantic_records:
            if decoration.indirect:
                raise SpirvLocationError(
                    f"entry-point interface {name!r} uses an indirect grouped "
                    f"{_INTERFACE_DECORATIONS[decoration.kind]} decoration"
                )
        semantics = InterfaceSemantics(
            component=component.value if component is not None else None,
            index=index.value if index is not None else None,
            flat=_flag_decoration(parsed, target_id, DECORATION_FLAT),
            no_perspective=_flag_decoration(
                parsed, target_id, DECORATION_NO_PERSPECTIVE
            ),
            centroid=_flag_decoration(parsed, target_id, DECORATION_CENTROID),
            sample=_flag_decoration(parsed, target_id, DECORATION_SAMPLE),
            patch=_flag_decoration(parsed, target_id, DECORATION_PATCH),
            invariant=_flag_decoration(parsed, target_id, DECORATION_INVARIANT),
        )
        inspected.append(
            _InspectedInterface(
                public=EntryPointInterface(
                    name=name,
                    target_id=target_id,
                    location=location.value,
                    semantics=semantics,
                ),
                location_decoration=location,
                storage_class=parsed.variable_storage_classes.get(target_id),
            )
        )

    return tuple(sorted(inspected, key=lambda item: item.public.name))


def inspect_entry_point_interfaces(module: bytes) -> tuple[EntryPointInterface, ...]:
    """Return the named, location-decorated user interfaces of ``main``.

    Direct built-ins and entry-point records without ``Location`` are excluded.
    Component and Index are reported so callers can fail before attempting a
    generic allocation that cannot preserve their packed layout.
    """

    return tuple(item.public for item in _inspect_module(module))


def _validate_requested_locations(
    requested_locations: Mapping[str, int],
) -> dict[str, int]:
    validated: dict[str, int] = {}
    locations_to_names: dict[int, str] = {}
    for name, location in requested_locations.items():
        if not isinstance(name, str) or not name:
            raise SpirvLocationError(
                "requested interface names must be non-empty strings"
            )
        if not isinstance(location, int) or isinstance(location, bool):
            raise SpirvLocationError(
                f"requested location for {name!r} must be an integer"
            )
        if not 0 <= location <= MAX_WORD:
            raise SpirvLocationError(
                f"requested location for {name!r} must fit in one unsigned word"
            )
        duplicate_name = locations_to_names.get(location)
        if duplicate_name is not None:
            raise SpirvLocationError(
                f"requested location {location} is duplicated by "
                f"{duplicate_name!r} and {name!r}"
            )
        validated[name] = location
        locations_to_names[location] = name
    return validated


def _resolve_location_remap(
    inspected: tuple[_InspectedInterface, ...], requested: Mapping[str, int]
) -> tuple[tuple[_InspectedInterface, LocationRemap], ...]:
    interfaces = {item.public.name: item for item in inspected}
    requested_names = set(requested)
    resolved: list[tuple[_InspectedInterface, LocationRemap]] = []
    for name, new_location in sorted(requested.items()):
        interface = interfaces.get(name)
        if interface is None:
            raise SpirvLocationError(
                f"requested interface {name!r} is not a named, "
                "location-decorated user interface of entry point 'main'"
            )
        semantics = interface.public.semantics
        if semantics.component is not None or semantics.index is not None:
            unsupported = []
            if semantics.component is not None:
                unsupported.append("Component")
            if semantics.index is not None:
                unsupported.append("Index")
            raise SpirvLocationError(
                f"requested interface {name!r} uses unsupported "
                + " and ".join(unsupported)
                + " decoration"
            )
        conflicting_interface = next(
            (
                item
                for item in inspected
                if item.public.name not in requested_names
                and item.public.location == new_location
                and (
                    interface.storage_class is None
                    or item.storage_class is None
                    or item.storage_class == interface.storage_class
                )
            ),
            None,
        )
        if conflicting_interface is not None:
            raise SpirvLocationError(
                f"requested location {new_location} for {name!r} collides with "
                f"unchanged interface {conflicting_interface.public.name!r}"
            )
        resolved.append(
            (
                interface,
                LocationRemap(
                    name=name,
                    target_id=interface.public.target_id,
                    old_location=interface.public.location,
                    new_location=new_location,
                ),
            )
        )
    return tuple(resolved)


def describe_location_remap(
    module: bytes, requested_locations: Mapping[str, int]
) -> tuple[LocationRemap, ...]:
    """Resolve and validate a remap without modifying *module*."""

    requested = _validate_requested_locations(requested_locations)
    return tuple(
        remap
        for _, remap in _resolve_location_remap(_inspect_module(module), requested)
    )


def remap_interface_locations(
    module: bytes, requested_locations: Mapping[str, int]
) -> bytes:
    """Return *module* with selected ``main`` interface locations replaced.

    Resolution and validation finish before any output bytes are changed. All bytes
    outside the selected location literal words are copied exactly from *module*.
    """

    requested = _validate_requested_locations(requested_locations)
    resolved = _resolve_location_remap(_inspect_module(module), requested)
    output = bytearray(module)
    for interface, remap in resolved:
        word_offset = interface.location_decoration.value_word_offset
        if word_offset is None:
            raise SpirvLocationError("Location decoration unexpectedly has no offset")
        struct.pack_into("<I", output, word_offset * 4, remap.new_location)
    return bytes(output)
