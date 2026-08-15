"""Focused and adversarial tests for generated Metal runtime artifacts."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("runtime_programs.py")
SPEC = importlib.util.spec_from_file_location("runtime_programs", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
runtime_programs = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime_programs
SPEC.loader.exec_module(runtime_programs)


class RuntimeProgramsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repository = Path(__file__).resolve().parents[2]
        manifest_path = self.repository / "doc/metal/shader-spike.json"
        self.manifest_bytes = manifest_path.read_bytes()
        self.manifest = json.loads(self.manifest_bytes.decode("utf-8"))

    @staticmethod
    def _spec(program_id: str = "ui_font") -> dict[str, object]:
        return {
            "schema": 4,
            "id": program_id,
            "metallib": "/deliberately/not/copied/to/runtime/catalog.metallib",
            "vertex_function": f"{program_id}_vertex",
            "fragment_function": f"{program_id}_fragment",
            "color_formats": ["bgra8unorm"],
            "depth_format": None,
            "sample_count": 1,
            "vertex_attributes": [
                {
                    "name": "position",
                    "location": 0,
                    "format": "float3",
                    "offset": 0,
                    "buffer_index": 16,
                },
                {
                    "name": "texcoord0",
                    "location": 2,
                    "format": "float2",
                    "offset": 0,
                    "buffer_index": 18,
                },
                {
                    "name": "diffuse_color",
                    "location": 6,
                    "format": "uchar4normalized",
                    "offset": 0,
                    "buffer_index": 20,
                },
            ],
            "vertex_layouts": [
                {"buffer_index": 16, "stride": 16, "step_function": "per_vertex"},
                {"buffer_index": 18, "stride": 8, "step_function": "per_vertex"},
                {"buffer_index": 20, "stride": 4, "step_function": "per_vertex"},
            ],
            "expected_arguments": {
                "vertex": [
                    {
                        "name": "FirestormVertexUniforms",
                        "metal_name": "_uniform_24",
                        "kind": "buffer",
                        "index": 24,
                        "access": "read_only",
                        "buffer_size": 16,
                        "buffer_alignment": 16,
                        "members": [{"name": "modelView", "offset": 0, "type": "vec4"}],
                    }
                ],
                "fragment": [
                    {
                        "name": "diffuseMap",
                        "metal_name": "diffuseMapSmplr",
                        "kind": "sampler",
                        "index": 0,
                    },
                    {
                        "name": "diffuseMap",
                        "metal_name": "diffuseMap",
                        "kind": "texture",
                        "index": 0,
                        "access": "read_only",
                        "texture_type": "2d",
                        "texture_data_type": "float",
                        "array_length": 1,
                        "is_depth_texture": False,
                    },
                ],
            },
        }

    @staticmethod
    def _reflections(marker: str = "base") -> dict[str, object]:
        return {
            "vertex": {
                "entryPoints": [{"name": "main", "mode": "vert"}],
                "types": {"_1": {"name": marker}},
            },
            "fragment": {
                "entryPoints": [{"name": "main", "mode": "frag"}],
                "types": {"_2": {"name": marker}},
            },
        }

    @staticmethod
    def _presentation_spec() -> dict[str, object]:
        spec = RuntimeProgramsTest._spec("presentation_copy")
        spec["vertex_attributes"] = [spec["vertex_attributes"][0]]
        spec["vertex_layouts"] = [spec["vertex_layouts"][0]]
        spec["expected_arguments"]["vertex"] = []
        return spec

    def _record(self, program_id: str = "ui_font") -> dict[str, object]:
        return runtime_programs.make_program_record(
            "UI and font glyph", self._spec(program_id), self._reflections()
        )

    def _document(self, records: list[dict[str, object]]) -> dict[str, object]:
        return runtime_programs.make_artifact_document(
            records,
            "1" * 64,
            self.manifest["schema"],
            hashlib.sha256(self.manifest_bytes).hexdigest(),
            self.manifest["baseline_commit"],
        )

    def test_manifest_has_exact_runtime_string_ids_and_ten_families(self) -> None:
        runtime = [
            item
            for item in self.manifest["programs"]
            if item["recipe_kind"] == "runtime"
        ]
        self.assertEqual(
            [
                "avatar_skinning",
                "deferred_diffuse",
                "depth_copy",
                "fxaa",
                "indexed_material",
                "pbr_alpha",
                "pbr_opaque",
                "presentation_copy",
                "reflection_probe",
                "shadow_alpha_mask",
                "shadow_alpha_receiver",
                "terrain",
                "ui_font",
            ],
            sorted(item["id"] for item in runtime),
        )
        self.assertEqual(13, len(runtime))
        self.assertEqual(10, len({item["family"] for item in runtime}))
        self.assertTrue(
            all("runtime_id" not in item for item in self.manifest["programs"])
        )

    def test_manifest_layout_contract_keeps_required_slots_and_formats(self) -> None:
        streams = self.manifest["vertex_streams"]
        self.assertEqual(16, streams["position"]["buffer_index"])
        self.assertEqual(18, streams["texcoord0"]["buffer_index"])
        self.assertEqual(20, streams["color"]["buffer_index"])
        self.assertEqual(22, streams["weight"]["buffer_index"])
        self.assertEqual(23, streams["clothing"]["buffer_index"])
        indexed = streams["position_indexed"]
        texture_index = next(
            item for item in indexed["attributes"] if item["name"] == "texture_index"
        )
        self.assertEqual((12, 16), (texture_index["offset"], indexed["stride"]))
        by_id = {item["id"]: item for item in self.manifest["programs"]}
        deferred = ["rgba8unorm", "rgba8unorm", "rgba16unorm"]
        self.assertEqual(
            deferred, by_id["deferred_diffuse"]["pipeline"]["color_formats"]
        )
        self.assertEqual(
            "depth32float", by_id["deferred_diffuse"]["pipeline"]["depth_format"]
        )
        self.assertEqual(
            {
                "color_formats": ["bgra8unorm"],
                "depth_format": None,
                "sample_count": 1,
                "source_evidence": [
                    {
                        "contains": "return MTLPixelFormatBGRA8Unorm;",
                        "path": "indra/llwindow/metal/llmetalbootstrap-objc.mm",
                    }
                ],
                "vertex_contract": "position_only",
            },
            by_id["presentation_copy"]["pipeline"],
        )

    def test_presentation_copy_record_needs_no_uniform_packer(self) -> None:
        spec = self._presentation_spec()
        record = runtime_programs.make_program_record(
            "Depth write and copy", spec, self._reflections()
        )
        self.assertEqual("presentation_copy", record["id"])
        self.assertEqual("Depth write and copy", record["family"])
        self.assertEqual(["bgra8unorm"], record["color_formats"])
        self.assertIsNone(record["depth_format"])
        self.assertEqual(1, record["sample_count"])
        self.assertEqual(
            [
                {
                    "buffer_index": 16,
                    "format": "float3",
                    "location": 0,
                    "name": "position",
                    "offset": 0,
                }
            ],
            record["vertex_attributes"],
        )
        self.assertEqual(
            [{"buffer_index": 16, "step_function": "per_vertex", "stride": 16}],
            record["vertex_layouts"],
        )
        self.assertEqual([], record["stage_bindings"]["vertex"])
        self.assertEqual(
            [("sampler", "diffuseMap", 0), ("texture", "diffuseMap", 0)],
            [
                (binding["kind"], binding["name"], binding["index"])
                for binding in record["stage_bindings"]["fragment"]
            ],
        )
        self.assertFalse(
            any(
                binding["kind"] == "buffer"
                for stage in ("vertex", "fragment")
                for binding in record["stage_bindings"][stage]
            )
        )

    def test_presentation_copy_rejects_unpaired_diffuse_map(self) -> None:
        spec = self._presentation_spec()
        spec["expected_arguments"]["fragment"] = [
            argument
            for argument in spec["expected_arguments"]["fragment"]
            if argument["kind"] != "sampler"
        ]
        with self.assertRaisesRegex(
            runtime_programs.RuntimeProgramError,
            "texture and sampler bindings do not pair",
        ):
            runtime_programs.make_program_record(
                "Depth write and copy", spec, self._reflections()
            )

    def test_cmake_tracks_every_captured_non_shader_source_contract(self) -> None:
        cmake = (self.repository / "indra/llwindow/metal/CMakeLists.txt").read_text(
            encoding="utf-8"
        )
        for relative in (
            "indra/llwindow/metal/llmetalbootstrap-objc.mm",
            "indra/newview/llreflectionmapmanager.cpp",
        ):
            self.assertIn(
                f'"${{FIRESTORM_REPOSITORY_ROOT}}/{relative}"',
                cmake,
            )

    def test_cmake_canonicalizes_artifact_output_before_generation(self) -> None:
        cmake = (self.repository / "indra/llwindow/metal/CMakeLists.txt").read_text(
            encoding="utf-8"
        )
        canonicalization = """get_filename_component(FIRESTORM_METAL_PROGRAM_BINARY_DIR
                         "${CMAKE_CURRENT_BINARY_DIR}"
                         REALPATH)
  set(FIRESTORM_METAL_PROGRAM_OUTPUT_DIR
      "${FIRESTORM_METAL_PROGRAM_BINARY_DIR}/declared-program-artifacts")"""
        self.assertIn(canonicalization, cmake)
        self.assertLess(
            cmake.index(canonicalization),
            cmake.index('--output "${FIRESTORM_METAL_PROGRAM_OUTPUT_DIR}"'),
        )

    def test_document_and_cpp_are_lexical_path_free_and_self_describing(self) -> None:
        alpha = self._record("alpha_program")
        zulu = self._record("zulu_program")
        document = self._document([zulu, alpha])
        self.assertEqual(
            ["alpha_program", "zulu_program"],
            [item["id"] for item in document["programs"]],
        )
        self.assertEqual(
            "firestorm-declared-programs.metallib", document["library_resource"]
        )
        self.assertEqual(self.manifest["schema"], document["source_manifest_schema"])
        self.assertEqual(
            hashlib.sha256(self.manifest_bytes).hexdigest(),
            document["source_manifest_sha256"],
        )
        self.assertEqual(self.manifest["baseline_commit"], document["baseline_commit"])
        header = runtime_programs.render_header(document).decode()
        source = runtime_programs.render_source(
            document, "firestorm-declared-programs.h"
        ).decode()
        self.assertIn("alpha_program = 1", header)
        self.assertIn("zulu_program = 2", header)
        self.assertIn("Values are deterministic lexical ordinals", header)
        self.assertNotIn("/deliberately/", source)
        self.assertNotIn(str(self.repository), header + source)

    def test_json_and_cpp_bytes_are_deterministic_across_roots(self) -> None:
        document = self._document([self._record()])
        with (
            tempfile.TemporaryDirectory() as first,
            tempfile.TemporaryDirectory() as second,
        ):
            roots = [Path(first), Path(second)]
            for root in roots:
                runtime_programs.write_json(
                    document, root / "firestorm-declared-programs.json"
                )
                runtime_programs.write_cpp(document, root)
                (root / "firestorm-declared-programs.metallib").write_bytes(
                    b"deterministic-metallib"
                )
            first_hashes = runtime_programs.artifact_hashes(roots[0])
            second_hashes = runtime_programs.artifact_hashes(roots[1])
        self.assertEqual(first_hashes, second_hashes)

    def test_complete_reflection_and_buffer_layout_change_identity(self) -> None:
        original = self._record()
        changed_reflection = runtime_programs.make_program_record(
            "UI and font glyph", self._spec(), self._reflections("changed")
        )
        changed_spec = self._spec()
        changed_spec["expected_arguments"]["vertex"][0]["members"][0]["type"] = "vec3"
        changed_layout = runtime_programs.make_program_record(
            "UI and font glyph", changed_spec, self._reflections()
        )
        self.assertNotEqual(
            original["reflection_sha256"], changed_reflection["reflection_sha256"]
        )
        self.assertNotEqual(
            original["stage_bindings"]["vertex"][0]["layout_sha256"],
            changed_layout["stage_bindings"]["vertex"][0]["layout_sha256"],
        )
        changed_native_spec = self._spec()
        changed_native_spec["expected_arguments"]["vertex"][0]["metal_name"] = (
            "_different_uniform"
        )
        changed_native = runtime_programs.make_program_record(
            "UI and font glyph", changed_native_spec, self._reflections()
        )
        self.assertNotEqual(
            original["reflection_sha256"], changed_native["reflection_sha256"]
        )

        matrix_spec = self._spec()
        matrix_binding = matrix_spec["expected_arguments"]["vertex"][0]
        matrix_binding["buffer_size"] = 128
        matrix_binding["members"] = [
            {
                "name": "projection",
                "offset": 0,
                "type": "mat4",
                "matrix_stride": 16,
                "matrix_major": "column",
            }
        ]
        matrix_record = runtime_programs.make_program_record(
            "UI and font glyph", matrix_spec, self._reflections()
        )
        changed_matrix_spec = copy.deepcopy(matrix_spec)
        changed_matrix_spec["expected_arguments"]["vertex"][0]["members"][0]["type"] = (
            "mat3"
        )
        changed_matrix_record = runtime_programs.make_program_record(
            "UI and font glyph", changed_matrix_spec, self._reflections()
        )
        matrix_member = matrix_record["stage_bindings"]["vertex"][0]["members"][0]
        self.assertEqual(
            (16, "column"),
            (matrix_member["matrix_stride"], matrix_member["matrix_major"]),
        )
        self.assertNotEqual(
            matrix_record["stage_bindings"]["vertex"][0]["layout_sha256"],
            changed_matrix_record["stage_bindings"]["vertex"][0]["layout_sha256"],
        )

    def test_buffer_member_matrix_overlap_and_bounds_fail_closed(self) -> None:
        malformed: list[tuple[str, dict[str, object]]] = []

        missing_matrix_stride = self._spec()
        missing_matrix_stride["expected_arguments"]["vertex"][0]["members"] = [
            {
                "name": "projection",
                "offset": 0,
                "type": "mat4",
                "matrix_major": "column",
            }
        ]
        malformed.append(("keys do not match schema", missing_matrix_stride))

        invalid_matrix_major = self._spec()
        invalid_matrix_major["expected_arguments"]["vertex"][0]["buffer_size"] = 64
        invalid_matrix_major["expected_arguments"]["vertex"][0]["members"] = [
            {
                "name": "projection",
                "offset": 0,
                "type": "mat4",
                "matrix_stride": 16,
                "matrix_major": "row",
            }
        ]
        malformed.append(("matrix_major must be column", invalid_matrix_major))

        invalid_matrix_stride = self._spec()
        invalid_matrix_stride["expected_arguments"]["vertex"][0]["buffer_size"] = 128
        invalid_matrix_stride["expected_arguments"]["vertex"][0]["members"] = [
            {
                "name": "projection",
                "offset": 0,
                "type": "mat4",
                "matrix_stride": 32,
                "matrix_major": "column",
            }
        ]
        malformed.append(("matrix_stride must be 16", invalid_matrix_stride))

        invalid_matrix_type = self._spec()
        invalid_matrix_type["expected_arguments"]["vertex"][0]["buffer_size"] = 64
        invalid_matrix_type["expected_arguments"]["vertex"][0]["members"] = [
            {
                "name": "projection",
                "offset": 0,
                "type": "mat2x3",
                "matrix_stride": 16,
                "matrix_major": "column",
            }
        ]
        malformed.append(("unsupported by the v1 matrix layout", invalid_matrix_type))

        invalid_matrix_alias = self._spec()
        invalid_matrix_alias["expected_arguments"]["vertex"][0]["members"] = [
            {"name": "projection", "offset": 0, "type": "float4x4"}
        ]
        malformed.append(("type is unsupported", invalid_matrix_alias))

        overlap = self._spec()
        overlap["expected_arguments"]["vertex"][0]["buffer_size"] = 32
        overlap["expected_arguments"]["vertex"][0]["members"] = [
            {"name": "first", "offset": 0, "type": "vec4"},
            {"name": "second", "offset": 0, "type": "vec4"},
        ]
        malformed.append(("overlapping members", overlap))

        out_of_bounds = self._spec()
        out_of_bounds["expected_arguments"]["vertex"][0]["members"][0]["offset"] = 16
        malformed.append(("exceeds its buffer size", out_of_bounds))

        for expected, spec in malformed:
            with (
                self.subTest(expected=expected),
                self.assertRaisesRegex(runtime_programs.RuntimeProgramError, expected),
            ):
                runtime_programs.make_program_record(
                    "UI and font glyph", spec, self._reflections()
                )

    def test_nested_struct_extent_is_aligned_before_parent_overlap_checks(self) -> None:
        valid = self._spec()
        binding = valid["expected_arguments"]["vertex"][0]
        binding["buffer_size"] = 32
        binding["members"] = [
            {
                "name": "nested",
                "offset": 0,
                "type": "struct",
                "members": [
                    {"name": "direction", "offset": 0, "type": "vec3"},
                    {"name": "scale", "offset": 12, "type": "float"},
                ],
            },
            {"name": "tail", "offset": 16, "type": "float"},
        ]
        valid_record = runtime_programs.make_program_record(
            "UI and font glyph", valid, self._reflections()
        )

        changed = copy.deepcopy(valid)
        changed["expected_arguments"]["vertex"][0]["members"][0]["members"][1][
            "type"
        ] = "uint"
        changed_record = runtime_programs.make_program_record(
            "UI and font glyph", changed, self._reflections()
        )
        self.assertNotEqual(
            valid_record["stage_bindings"]["vertex"][0]["layout_sha256"],
            changed_record["stage_bindings"]["vertex"][0]["layout_sha256"],
        )

        overlap = copy.deepcopy(valid)
        overlap["expected_arguments"]["vertex"][0]["members"][1]["offset"] = 12
        with self.assertRaisesRegex(
            runtime_programs.RuntimeProgramError, "overlapping members"
        ):
            runtime_programs.make_program_record(
                "UI and font glyph", overlap, self._reflections()
            )

        scalar_nested = self._spec()
        scalar_binding = scalar_nested["expected_arguments"]["vertex"][0]
        scalar_binding["buffer_size"] = 32
        scalar_binding["members"] = [
            {
                "name": "nested",
                "offset": 0,
                "type": "struct",
                "members": [{"name": "value", "offset": 0, "type": "float"}],
            },
            {"name": "tail", "offset": 16, "type": "float"},
        ]
        runtime_programs.make_program_record(
            "UI and font glyph", scalar_nested, self._reflections()
        )
        scalar_overlap = copy.deepcopy(scalar_nested)
        scalar_overlap["expected_arguments"]["vertex"][0]["members"][1]["offset"] = 4
        with self.assertRaisesRegex(
            runtime_programs.RuntimeProgramError, "overlapping members"
        ):
            runtime_programs.make_program_record(
                "UI and font glyph", scalar_overlap, self._reflections()
            )

    def test_malformed_layout_attribute_binding_enum_and_collision_reject(self) -> None:
        mutations: list[tuple[str, object]] = []

        duplicate_layout = self._spec()
        duplicate_layout["vertex_layouts"].append(
            copy.deepcopy(duplicate_layout["vertex_layouts"][0])
        )
        mutations.append(("duplicate vertex buffer", duplicate_layout))

        duplicate_attribute = self._spec()
        duplicate_attribute["vertex_attributes"].append(
            copy.deepcopy(duplicate_attribute["vertex_attributes"][0])
        )
        mutations.append(("duplicate vertex attributes", duplicate_attribute))

        wrong_reserved_attribute = self._spec()
        wrong_reserved_attribute["vertex_attributes"][1]["location"] = 0
        mutations.append(("reserved Firestorm attribute", wrong_reserved_attribute))

        bad_stride = self._spec()
        bad_stride["vertex_layouts"][0]["stride"] = 8
        mutations.append(("exceeds its vertex stride", bad_stride))

        bad_enum = self._spec()
        bad_enum["vertex_attributes"][0]["format"] = "half3"
        mutations.append(("format is unsupported", bad_enum))

        unsafe_resource = self._spec()
        unsafe_resource["expected_arguments"]["fragment"][0]["name"] = "../sampler"
        mutations.append(("name is invalid", unsafe_resource))

        unsafe_native_resource = self._spec()
        unsafe_native_resource["expected_arguments"]["fragment"][0]["metal_name"] = (
            "../sampler"
        )
        mutations.append(("metal_name is invalid", unsafe_native_resource))

        duplicate_native_name = self._spec()
        duplicate_native_name["expected_arguments"]["fragment"][0]["metal_name"] = (
            "diffuseMap"
        )
        mutations.append(
            ("duplicate native Metal binding names", duplicate_native_name)
        )

        duplicate_binding = self._spec()
        duplicate_binding["expected_arguments"]["vertex"].append(
            copy.deepcopy(duplicate_binding["expected_arguments"]["vertex"][0])
        )
        mutations.append(("duplicate binding slots", duplicate_binding))

        collision = self._spec()
        collision["expected_arguments"]["vertex"][0]["index"] = 16
        mutations.append(("collide", collision))

        unsafe_identifier = self._spec("ui_font")
        unsafe_identifier["id"] = "../ui"
        mutations.append(("pipeline spec.id is invalid", unsafe_identifier))

        for expected, spec in mutations:
            with (
                self.subTest(expected=expected),
                self.assertRaisesRegex(runtime_programs.RuntimeProgramError, expected),
            ):
                runtime_programs.make_program_record(
                    "UI and font glyph", spec, self._reflections()
                )

    def test_duplicate_ids_and_invalid_catalog_identity_reject(self) -> None:
        record = self._record()
        with self.assertRaisesRegex(
            runtime_programs.RuntimeProgramError, "duplicate program IDs"
        ):
            self._document([record, copy.deepcopy(record)])
        with self.assertRaisesRegex(
            runtime_programs.RuntimeProgramError, "metallib digest"
        ):
            runtime_programs.make_artifact_document(
                [record], "not-a-digest", 3, "2" * 64, "3" * 40
            )

    def test_path_scan_rejects_absolute_build_or_source_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "artifact.cpp")
            path.write_text('const char* p = "/Users/lisa/build/source.metal";')
            with self.assertRaisesRegex(
                runtime_programs.RuntimeProgramError, "embeds forbidden path"
            ):
                runtime_programs.reject_embedded_paths([path], ["/Users/"])


if __name__ == "__main__":
    unittest.main()
