"""Focused and adversarial tests for the Metal shader translation gate."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).with_name("shader_spike.py")
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("shader_spike", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
shader_spike = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = shader_spike
SPEC.loader.exec_module(shader_spike)

from spirv_locations import EntryPointInterface, InterfaceSemantics


class ShaderSpikeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = shader_spike.repository_root() / "doc/metal/shader-spike.json"

    def _programs(self) -> tuple[Path, list[shader_spike.ProgramRecipe]]:
        return shader_spike.load_manifest(self.manifest)

    def _mutated_manifest(self, mutation: object) -> tempfile.TemporaryDirectory[str]:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        assert isinstance(mutation, tuple)
        path, value = mutation
        target = document
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        directory = tempfile.TemporaryDirectory()
        Path(directory.name, "manifest.json").write_text(
            json.dumps(document), encoding="utf-8"
        )
        return directory

    def test_manifest_is_exact_fourteen_recipe_ten_family_contract(self) -> None:
        source_root, programs = self._programs()
        shader_spike.validate_sources(source_root, programs)
        self.assertEqual(14, len(programs))
        self.assertEqual(
            shader_spike.REQUIRED_PROGRAM_IDS, {item.program_id for item in programs}
        )
        self.assertEqual(
            shader_spike.REQUIRED_FAMILIES, {item.family for item in programs}
        )
        self.assertEqual({400}, {item.glsl_version for item in programs})

    def test_baseline_settings_and_runtime_overrides_are_machine_read(self) -> None:
        _, programs = self._programs()
        baseline = programs[0].baseline_settings
        self.assertEqual(set(shader_spike.BASELINE_SETTING_TYPES), set(baseline))
        self.assertTrue(baseline["RenderHDREnabled"])
        self.assertFalse(baseline["RenderEnableEmissiveBuffer"])
        self.assertEqual(0, baseline["RenderShadowDetail"])
        shadow = next(
            item for item in programs if item.program_id == "shadow_alpha_mask"
        )
        shadow_receiver = next(
            item for item in programs if item.program_id == "shadow_alpha_receiver"
        )
        pbr_alpha = next(item for item in programs if item.program_id == "pbr_alpha")
        fxaa = next(item for item in programs if item.program_id == "fxaa")
        self.assertEqual({"RenderShadowDetail": 2}, shadow.settings_overrides)
        self.assertEqual({"RenderShadowDetail": 1}, shadow_receiver.settings_overrides)
        self.assertEqual("1", shadow_receiver.global_defines["SUN_SHADOW"])
        self.assertNotIn("SPOT_SHADOW", shadow_receiver.global_defines)
        self.assertEqual({"RenderShadowDetail": 1}, pbr_alpha.settings_overrides)
        self.assertEqual("1", pbr_alpha.global_defines["SUN_SHADOW"])
        self.assertNotIn("SPOT_SHADOW", pbr_alpha.global_defines)
        self.assertEqual({"RenderFSAAType": 1}, fxaa.settings_overrides)

    def test_runtime_pipeline_formats_match_manifest_contract(self) -> None:
        _, programs = self._programs()
        actual = {
            item.program_id: (item.pipeline.color_formats, item.pipeline.depth_format)
            for item in programs
        }
        gbuffer = (("rgba8unorm", "rgba8unorm", "rgba16unorm"), "depth32float")
        for program_id in (
            "indexed_material",
            "indexed_material_stress_16",
            "deferred_diffuse",
            "pbr_opaque",
            "terrain",
            "avatar_skinning",
        ):
            self.assertEqual(gbuffer, actual[program_id])
        self.assertEqual((("rgba16float",), "depth32float"), actual["pbr_alpha"])
        self.assertEqual(((), "depth32float"), actual["shadow_alpha_mask"])
        self.assertEqual(
            (("rgba16float",), "depth32float"), actual["shadow_alpha_receiver"]
        )
        self.assertEqual((("rg11b10float",), None), actual["reflection_probe"])
        self.assertEqual((("rgba16float",), "depth32float"), actual["depth_copy"])
        self.assertEqual((("rgba8unorm",), None), actual["fxaa"])
        self.assertEqual((("bgra8unorm",), None), actual["ui_font"])

    def test_stress_and_semantic_states_are_honest(self) -> None:
        _, programs = self._programs()
        by_id = {item.program_id: item for item in programs}
        self.assertEqual("stress", by_id["indexed_material_stress_16"].recipe_kind)
        self.assertEqual(
            16, by_id["indexed_material_stress_16"].indexed_texture_channels
        )
        self.assertEqual("capability", by_id["fxaa_depth_write"].recipe_kind)
        self.assertEqual(
            "cpu_runtime_layout_open", by_id["avatar_skinning"].semantic_parity
        )
        self.assertTrue(all(item.semantic_parity != "passed" for item in programs))

    def test_shadowed_pbr_recipe_requires_real_comparison_resources(self) -> None:
        _, programs = self._programs()
        recipe = next(item for item in programs if item.program_id == "pbr_alpha")
        self.assertEqual("1", recipe.defines["HAS_SUN_SHADOW"])
        self.assertIn("deferred/shadowUtil.glsl", recipe.stages["fragment"])
        required = {
            (item.name, item.resource_type)
            for item in recipe.required_reflection["fragment"]
        }
        for index in range(4):
            self.assertIn((f"shadowMap{index}", "sampler2DShadow"), required)
        self.assertEqual({"fragment": 20}, recipe.comparison_sample_counts)

    def test_shadow_alpha_receiver_matches_real_indexed_program(self) -> None:
        _, programs = self._programs()
        recipe = next(
            item for item in programs if item.program_id == "shadow_alpha_receiver"
        )
        self.assertEqual("Shadow alpha mask", recipe.family)
        self.assertEqual("gDeferredAlphaProgram", recipe.source_symbol)
        self.assertEqual(
            {
                "HAS_ALPHA_MASK": "1",
                "HAS_SUN_SHADOW": "1",
                "USE_INDEXED_TEX": "1",
                "USE_VERTEX_COLOR": "1",
            },
            recipe.defines,
        )
        self.assertEqual("1", recipe.global_defines["SUN_SHADOW"])
        self.assertEqual(4, recipe.indexed_texture_channels)
        self.assertEqual(
            (
                "deferred/alphaV.glsl",
                "windlight/atmosphericsVarsV.glsl",
                "windlight/atmosphericsHelpersV.glsl",
                "environment/srgbF.glsl",
                "windlight/atmosphericsFuncs.glsl",
                "windlight/atmosphericsV.glsl",
                "deferred/textureUtilV.glsl",
                "objects/indexedTextureV.glsl",
            ),
            recipe.stages["vertex"],
        )
        self.assertEqual(
            (
                "deferred/alphaF.glsl",
                "deferred/globalF.glsl",
                "environment/srgbF.glsl",
                "windlight/atmosphericsVarsF.glsl",
                "windlight/atmosphericsHelpersF.glsl",
                "deferred/deferredUtil.glsl",
                "deferred/screenSpaceReflUtil.glsl",
                "deferred/shadowUtil.glsl",
                "deferred/reflectionProbeF.glsl",
                "windlight/gammaF.glsl",
                "windlight/atmosphericsFuncs.glsl",
                "windlight/atmosphericsF.glsl",
                "environment/waterFogF.glsl",
            ),
            recipe.stages["fragment"],
        )
        required = {
            (item.name, item.resource_type)
            for item in recipe.required_reflection["fragment"]
        }
        self.assertEqual(
            {
                ("shadowMap0", "sampler2DShadow"),
                ("shadowMap1", "sampler2DShadow"),
                ("shadowMap2", "sampler2DShadow"),
                ("shadowMap3", "sampler2DShadow"),
                ("tex3", "sampler2D"),
            },
            required,
        )
        self.assertEqual({"fragment": 20}, recipe.comparison_sample_counts)

    def test_spirv_comparison_sampling_is_machine_counted(self) -> None:
        def module(opcode: int, word_count: int = 1) -> bytes:
            words = [shader_spike.SPIRV_MAGIC, 0x00010600, 0, 1, 0]
            words.append((word_count << 16) | opcode)
            words.extend([0] * (word_count - 1))
            return b"".join(word.to_bytes(4, "little") for word in words)

        self.assertEqual(
            1, shader_spike.count_comparison_sample_instructions(module(89))
        )
        self.assertEqual(
            0, shader_spike.count_comparison_sample_instructions(module(87))
        )
        with self.assertRaisesRegex(shader_spike.ManifestError, "malformed"):
            shader_spike.count_comparison_sample_instructions(module(89, 0))

    def test_comparison_sampling_requires_exact_manifest_count(self) -> None:
        source = "a.sample_compare(x);\nb.sample_compare(y);\nc.sample(z);\n"
        self.assertEqual(2, shader_spike.count_msl_sample_compare_calls(source))
        self.assertEqual(0, shader_spike.count_msl_sample_compare_calls("a.sample(x);"))
        self.assertEqual(
            [
                "expected 20 SPIR-V comparison samples; found 0",
                "expected 20 generated MSL sample_compare calls; found 0",
            ],
            shader_spike.comparison_sample_errors(20, 0, 0),
        )
        self.assertEqual(
            [
                "expected 20 SPIR-V comparison samples; found 5",
                "expected 20 generated MSL sample_compare calls; found 5",
            ],
            shader_spike.comparison_sample_errors(20, 5, 5),
        )
        self.assertEqual([], shader_spike.comparison_sample_errors(None, 0, 0))

    def test_manifest_owns_soa_storage_and_position_index_alias(self) -> None:
        _, programs = self._programs()
        indexed = next(
            item for item in programs if item.program_id == "indexed_material"
        )
        attributes = {
            attribute.name: (layout.stride, attribute)
            for layout in indexed.pipeline.vertex_layouts
            for attribute in layout.attributes
        }
        self.assertEqual(
            (16, "float3", 0, 16), self._attribute_tuple(attributes["position"])
        )
        self.assertEqual(
            (16, "float3", 0, 17), self._attribute_tuple(attributes["normal"])
        )
        self.assertEqual(
            (4, "uchar4normalized", 0, 20),
            self._attribute_tuple(attributes["diffuse_color"]),
        )
        self.assertEqual(
            (16, "int", 12, 16), self._attribute_tuple(attributes["texture_index"])
        )
        avatar = next(item for item in programs if item.program_id == "avatar_skinning")
        avatar_attributes = {
            attribute.name: (layout.stride, attribute)
            for layout in avatar.pipeline.vertex_layouts
            for attribute in layout.attributes
        }
        self.assertEqual(
            (4, "float", 0, 22), self._attribute_tuple(avatar_attributes["weight"])
        )
        self.assertEqual(
            (16, "float4", 0, 23), self._attribute_tuple(avatar_attributes["clothing"])
        )

    @staticmethod
    def _attribute_tuple(
        item: tuple[int, shader_spike.VertexAttribute],
    ) -> tuple[int, str, int, int]:
        stride, attribute = item
        return stride, attribute.format_name, attribute.offset, attribute.buffer_index

    def test_marker_line_is_replaced_at_runtime_location(self) -> None:
        source = (
            "// header\n/*[EXTRA_CODE_HERE]*/\n"
            "#extension GL_EXT_one : enable\n"
            "#extension GL_EXT_two : enable\nvoid main() {}\n"
        )
        assembled = shader_spike.assemble_shader_source(
            source, "#define FLAG 1\n", 400, "x"
        )
        self.assertNotIn("[EXTRA_CODE_HERE]", assembled)
        self.assertNotIn("/*#define FLAG", assembled)
        self.assertLess(
            assembled.index("#define FLAG 1"), assembled.index("#extension GL_EXT_one")
        )
        self.assertLess(assembled.index("GL_EXT_one"), assembled.index("GL_EXT_two"))
        self.assertTrue(assembled.startswith("#version 400 core\n"))

    def test_source_without_marker_injects_immediately_after_version(self) -> None:
        assembled = shader_spike.assemble_shader_source(
            "#extension GL_EXT_one : enable\nvoid main() {}\n",
            "#define FLAG 1\n",
            400,
            "x",
        )
        self.assertEqual("#define FLAG 1", assembled.splitlines()[1])
        self.assertLess(
            assembled.index("#define FLAG 1"), assembled.index("#extension")
        )

    def test_multiple_markers_are_rejected(self) -> None:
        with self.assertRaisesRegex(shader_spike.ManifestError, "2 literal"):
            shader_spike.assemble_shader_source(
                "[EXTRA_CODE_HERE]\n[EXTRA_CODE_HERE]\n", "x", 400, "bad"
            )

    def test_macro_names_and_values_cannot_inject_lines(self) -> None:
        for value in (
            {"BAD-NAME": "1"},
            {"OK": "1\n#error injected"},
            {"OK": "1\\\nX"},
        ):
            with (
                self.subTest(value=value),
                self.assertRaises(shader_spike.ManifestError),
            ):
                shader_spike._require_defines(value, "defines")

    def test_shader_objects_keep_separate_preprocessor_environments(self) -> None:
        source_root, programs = self._programs()
        indexed = next(
            item for item in programs if item.program_id == "indexed_material"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrappers = shader_spike.write_shader_objects(
                source_root, indexed, "fragment", Path(directory)
            )
            contents = [path.read_text(encoding="utf-8") for path in wrappers]
        self.assertIn("uniform sampler2D tex3;", contents[0])
        self.assertNotIn("uniform sampler2D tex3;", contents[1])
        self.assertNotIn("[EXTRA_CODE_HERE]", contents[0])
        self.assertIn("#version 400 core", contents[0])

    def test_source_resolution_uses_class_fallback_and_confines_paths(self) -> None:
        source_root, _ = self._programs()
        resolved = shader_spike.resolve_source(source_root, 3, "interface/uiV.glsl")
        self.assertEqual("class1", resolved.parts[-3])
        with self.assertRaisesRegex(shader_spike.ManifestError, "escapes source_root"):
            shader_spike.resolve_source(source_root, 3, "../../README.md")

    def test_interface_map_and_semantics_are_structural(self) -> None:
        vertex = {
            "inputs": [{"name": "position", "type": "vec3", "location": 7}],
            "outputs": [{"name": "vary_uv", "type": "vec2", "location": 4}],
        }
        fragment = {"inputs": [{"name": "vary_uv", "type": "vec2", "location": 2}]}
        inputs, varyings = shader_spike.build_interface_maps(vertex, fragment)
        self.assertEqual({"position": 0}, inputs)
        self.assertEqual({"vary_uv": 0}, varyings)
        semantics = InterfaceSemantics(flat=True)
        inspected = (EntryPointInterface("vary_uv", 3, 4, semantics),)
        result = shader_spike.validate_interface_semantics(
            vertex, fragment, inspected, inspected
        )
        self.assertTrue(result["vary_uv"]["flat"])

    def test_interface_semantic_mismatch_is_rejected(self) -> None:
        vertex = {"outputs": [{"name": "vary_uv", "type": "vec2", "location": 0}]}
        fragment = {"inputs": [{"name": "vary_uv", "type": "vec2", "location": 0}]}
        vertex_item = (EntryPointInterface("vary_uv", 3, 0, InterfaceSemantics()),)
        fragment_item = (
            EntryPointInterface("vary_uv", 4, 0, InterfaceSemantics(flat=True)),
        )
        with self.assertRaisesRegex(shader_spike.ManifestError, "semantic mismatch"):
            shader_spike.validate_interface_semantics(
                vertex, fragment, vertex_item, fragment_item
            )

    def test_pipeline_spec_uses_manifest_soa_and_complete_arguments(self) -> None:
        _, programs = self._programs()
        ui = next(item for item in programs if item.program_id == "ui_font")
        vertex = {
            "types": {
                "_ubo": {
                    "members": [
                        {
                            "name": "matrix",
                            "type": "mat4",
                            "offset": 0,
                            "matrix_stride": 16,
                        }
                    ]
                }
            },
            "inputs": [
                {"name": "position", "type": "vec3", "location": 0},
                {"name": "texcoord0", "type": "vec2", "location": 2},
                {"name": "diffuse_color", "type": "vec4", "location": 6},
            ],
            "ubos": [
                {
                    "name": "FirestormVertexUniforms",
                    "type": "_ubo",
                    "binding": 24,
                    "block_size": 64,
                }
            ],
        }
        fragment = {
            "types": {},
            "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
            "textures": [{"name": "diffuseMap", "type": "sampler2D", "binding": 0}],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            spec_path = root / "pipeline.json"
            shader_spike.write_pipeline_spec(
                ui, vertex, fragment, root / "ui.metallib", spec_path
            )
            spec = json.loads(spec_path.read_text(encoding="utf-8"))
        self.assertEqual(2, spec["schema"])
        self.assertEqual(
            [16, 18, 20], [item["buffer_index"] for item in spec["vertex_layouts"]]
        )
        color = next(
            item
            for item in spec["vertex_attributes"]
            if item["name"] == "diffuse_color"
        )
        self.assertEqual("uchar4normalized", color["format"])
        kinds = {
            (item["kind"], item["index"])
            for item in spec["expected_arguments"]["fragment"]
        }
        self.assertEqual({("texture", 0), ("sampler", 0)}, kinds)

    def test_pipeline_permits_fewer_conditional_color_attachments(self) -> None:
        _, programs = self._programs()
        shadow = next(
            item for item in programs if item.program_id == "shadow_alpha_mask"
        )
        vertex = {
            "inputs": [
                {"name": "position", "type": "vec3", "location": 0},
                {"name": "texture_index", "type": "int", "location": 13},
                {"name": "texcoord0", "type": "vec2", "location": 2},
                {"name": "diffuse_color", "type": "vec4", "location": 6},
            ]
        }
        fragment = {
            "outputs": [
                {"name": "frag_data", "type": "vec4", "array": [4], "location": 0}
            ]
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "spec.json")
            shader_spike.write_pipeline_spec(
                shadow, vertex, fragment, Path(directory, "x.metallib"), path
            )
            self.assertEqual([], json.loads(path.read_text())["color_formats"])

    def test_binding_limits_and_collisions_fail_closed(self) -> None:
        with self.assertRaisesRegex(shader_spike.ManifestError, "duplicate texture"):
            shader_spike._expected_arguments(
                {
                    "textures": [
                        {"name": "a", "type": "sampler2D", "binding": 0},
                        {"name": "b", "type": "sampler2D", "binding": 0},
                    ]
                },
                "fragment",
            )
        with self.assertRaisesRegex(shader_spike.ManifestError, "exceeds Metal limits"):
            shader_spike._expected_arguments(
                {"textures": [{"name": "a", "type": "sampler2D", "binding": 16}]},
                "fragment",
            )

    def test_buffer_alignment_is_derived_from_member_types(self) -> None:
        arguments = shader_spike._expected_arguments(
            {
                "types": {
                    "_ubo": {
                        "members": [
                            {"name": "a", "type": "vec2", "offset": 0},
                            {"name": "b", "type": "vec2", "offset": 8},
                        ]
                    }
                },
                "ubos": [
                    {"name": "U", "type": "_ubo", "binding": 24, "block_size": 16}
                ],
            },
            "vertex",
        )
        self.assertEqual(8, arguments[0]["buffer_alignment"])
        self.assertEqual(16, arguments[0]["buffer_size"])

    def test_texture_contract_includes_typed_resource_metadata(self) -> None:
        cube = shader_spike._texture_metadata(
            {"name": "probes", "type": "samplerCubeArray"}
        )
        self.assertEqual(
            {
                "access": "read_only",
                "texture_type": "cube_array",
                "texture_data_type": "float",
                "array_length": 1,
                "is_depth_texture": False,
            },
            cube,
        )
        depth = shader_spike._texture_metadata(
            {"name": "shadow", "type": "sampler2DShadow", "array": [3]}
        )
        self.assertEqual("2d", depth["texture_type"])
        self.assertEqual("float", depth["texture_data_type"])
        self.assertEqual(3, depth["array_length"])
        self.assertTrue(depth["is_depth_texture"])
        for reflected_type, expected in (
            ("isampler2D", "int"),
            ("usampler2D", "uint"),
            ("hsampler2D", "half"),
        ):
            with self.subTest(reflected_type=reflected_type):
                metadata = shader_spike._texture_metadata({"type": reflected_type})
                self.assertEqual(expected, metadata["texture_data_type"])
        with self.assertRaisesRegex(
            shader_spike.ManifestError, "depth textures must have float"
        ):
            shader_spike._texture_metadata({"type": "isampler2DShadow"})

    def test_buffer_array_contract_includes_element_length_and_stride(self) -> None:
        members = shader_spike._buffer_members(
            {
                "types": {
                    "_ubo": {
                        "members": [
                            {
                                "name": "matrixPalette",
                                "type": "vec4",
                                "array": [45],
                                "array_size_is_literal": [True],
                                "array_stride": 16,
                                "offset": 112,
                            }
                        ]
                    }
                }
            },
            {"name": "U", "type": "_ubo"},
        )
        self.assertEqual(
            {
                "name": "matrixPalette",
                "offset": 112,
                "type": "array",
                "array_length": 45,
                "array_stride": 16,
                "element": {"type": "vec4"},
            },
            members[0],
        )

    def test_complex_buffer_member_without_layout_fails_closed(self) -> None:
        with self.assertRaisesRegex(shader_spike.ManifestError, "stride"):
            shader_spike._buffer_members(
                {
                    "types": {
                        "_ubo": {
                            "members": [
                                {
                                    "name": "values",
                                    "type": "vec4",
                                    "array": [4],
                                    "offset": 0,
                                }
                            ]
                        }
                    }
                },
                {"name": "U", "type": "_ubo"},
            )

    def test_std140_vec2_array_uses_metal_padded_element_type(self) -> None:
        members = shader_spike._buffer_members(
            {
                "types": {
                    "_ubo": {
                        "members": [
                            {
                                "name": "values",
                                "type": "vec2",
                                "array": [8],
                                "array_stride": 16,
                                "offset": 0,
                            }
                        ]
                    }
                }
            },
            {"name": "U", "type": "_ubo"},
        )
        self.assertEqual({"type": "vec4"}, members[0]["element"])

    def test_pipeline_rejects_vertex_stream_shader_buffer_collision(self) -> None:
        _, programs = self._programs()
        ui = next(item for item in programs if item.program_id == "ui_font")
        colliding_layout = replace(ui.pipeline.vertex_layouts[0], buffer_index=24)
        colliding_attributes = tuple(
            replace(item, buffer_index=24) for item in colliding_layout.attributes
        )
        colliding_layout = replace(colliding_layout, attributes=colliding_attributes)
        pipeline = replace(
            ui.pipeline,
            vertex_layouts=(colliding_layout, *ui.pipeline.vertex_layouts[1:]),
        )
        recipe = replace(ui, pipeline=pipeline)
        vertex = {
            "types": {"_u": {"members": [{"name": "x", "type": "float", "offset": 0}]}},
            "inputs": [
                {"name": "position", "type": "vec3", "location": 0},
                {"name": "texcoord0", "type": "vec2", "location": 2},
                {"name": "diffuse_color", "type": "vec4", "location": 6},
            ],
            "ubos": [{"name": "U", "type": "_u", "binding": 24, "block_size": 4}],
        }
        fragment = {"outputs": [{"name": "color", "type": "vec4", "location": 0}]}
        with (
            tempfile.TemporaryDirectory() as directory,
            self.assertRaisesRegex(shader_spike.ManifestError, "collide"),
        ):
            shader_spike.write_pipeline_spec(
                recipe,
                vertex,
                fragment,
                Path(directory, "x.metallib"),
                Path(directory, "x.json"),
            )

    def test_uninitialized_metal_diagnostics_always_fail_classification(self) -> None:
        self.assertTrue(
            shader_spike.has_uninitialized_diagnostic("warning: uninitialized value")
        )
        self.assertTrue(shader_spike.has_uninitialized_diagnostic("UNINITIALIZED"))
        self.assertFalse(
            shader_spike.has_uninitialized_diagnostic("warning: unused variable")
        )

    def test_output_replacement_requires_marker_and_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            unmarked = root / "unmarked"
            unmarked.mkdir()
            with self.assertRaisesRegex(RuntimeError, "unmarked"):
                shader_spike._prepare_output(unmarked)
            target = root / "target"
            target.mkdir()
            symlink = root / "link"
            symlink.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "symlinked"):
                shader_spike._prepare_output(symlink)
            nested = root / "nested-target"
            nested.mkdir()
            nested_link = root / "nested-link"
            nested_link.symlink_to(nested, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "component"):
                shader_spike._prepare_output(nested_link / "output")
            wrong_marker = root / "wrong-marker"
            wrong_marker.mkdir()
            Path(wrong_marker, shader_spike.OUTPUT_MARKER).write_text("not our marker")
            with self.assertRaisesRegex(RuntimeError, "unmarked"):
                shader_spike._prepare_output(wrong_marker)
            marked = root / "marked"
            marked.mkdir()
            Path(marked, shader_spike.OUTPUT_MARKER).write_text(
                shader_spike.OUTPUT_MARKER_CONTENT
            )
            Path(marked, "old").write_text("old")
            shader_spike._prepare_output(marked)
            self.assertFalse(Path(marked, "old").exists())
            self.assertTrue(Path(marked, shader_spike.OUTPUT_MARKER).is_file())

    def test_output_refuses_repository_and_shader_source_roots(self) -> None:
        root = shader_spike.repository_root()
        with self.assertRaisesRegex(RuntimeError, "unsafe"):
            shader_spike._prepare_output(root)
        with self.assertRaisesRegex(RuntimeError, "unsafe"):
            shader_spike._prepare_output(root.parent)
        with self.assertRaisesRegex(RuntimeError, "unsafe"):
            shader_spike._prepare_output(root / "indra/newview/app_settings/shaders")

    def test_output_identity_policy_rejects_aliases_and_protected_descendants(
        self,
    ) -> None:
        repository = (1, 10)
        repository_parent = (1, 9)
        source = (1, 20)
        build = (1, 30)
        protected = {repository, repository_parent}
        self.assertTrue(
            shader_spike._output_identity_is_unsafe(
                True, repository, (repository_parent, repository), protected, source
            )
        )
        self.assertTrue(
            shader_spike._output_identity_is_unsafe(
                False, source, (repository, source), protected, source
            )
        )
        self.assertFalse(
            shader_spike._output_identity_is_unsafe(
                False, repository, (repository_parent, repository), protected, source
            )
        )
        self.assertFalse(
            shader_spike._output_identity_is_unsafe(
                True, build, (repository_parent, repository, build), protected, source
            )
        )

    def test_output_rejects_real_case_insensitive_alias_when_supported(self) -> None:
        root = shader_spike.repository_root().resolve()
        alias = None
        for index, part in enumerate(root.parts[1:], 1):
            swapped = part.swapcase()
            if swapped == part:
                continue
            parts = list(root.parts)
            parts[index] = swapped
            candidate = Path(*parts)
            try:
                if candidate.exists() and candidate.samefile(root):
                    alias = candidate
                    break
            except OSError:
                continue
        if alias is None:
            self.skipTest("filesystem has no case-insensitive repository alias")
        with self.assertRaisesRegex(RuntimeError, "unsafe"):
            shader_spike._validated_output_path(alias)
        source_relative = Path("indra/newview/app_settings/shaders")
        with self.assertRaisesRegex(RuntimeError, "unsafe"):
            shader_spike._validated_output_path(
                alias / source_relative / "snapshot-test-output"
            )

    def test_source_contract_hash_detects_stale_recipe(self) -> None:
        directory = self._mutated_manifest(
            (("source_contracts", 0, "sha256"), "0" * 64)
        )
        try:
            with self.assertRaisesRegex(shader_spike.ManifestError, "stale"):
                shader_spike.load_manifest(Path(directory.name, "manifest.json"))
        finally:
            directory.cleanup()

    def test_vertex_location_authorities_are_exact_source_contracts(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        contracts = {item["path"] for item in document["source_contracts"]}
        self.assertIn("indra/llrender/llshadermgr.cpp", contracts)
        self.assertIn("indra/llrender/llvertexbuffer.h", contracts)

    def test_translation_and_report_hashes_use_one_frozen_input_snapshot(self) -> None:
        _, programs = self._programs()
        template = next(item for item in programs if item.program_id == "ui_font")
        manifest_a = b'{"snapshot":"manifest-a"}\n'
        source_a = b"/*[EXTRA_CODE_HERE]*/\nvoid main() { gl_Position = vec4(1.0); }\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest = root / "manifest.json"
            source_root = root / "shaders"
            source = source_root / "class1/fake.glsl"
            source.parent.mkdir(parents=True)
            manifest.write_bytes(manifest_a)
            source.write_bytes(source_a)
            with mock.patch.object(shader_spike, "repository_root", return_value=root):
                inputs = shader_spike.InputSnapshot.capture_manifest(manifest)
                shader_spike.resolve_source(source_root, 1, "fake.glsl", inputs)
                recipe = replace(
                    template,
                    shader_class=1,
                    stages={
                        "vertex": ("fake.glsl",),
                        "fragment": template.stages["fragment"],
                    },
                    input_snapshot=inputs,
                )
                inputs.freeze()

                manifest.write_bytes(b'{"snapshot":"manifest-b"}\n')
                source.write_bytes(b"this is not valid GLSL\n")
                first_root = root / "first"
                second_root = root / "second"
                with mock.patch.object(
                    shader_spike.InputSnapshot,
                    "_read_stable_file",
                    side_effect=AssertionError("repository input was reopened"),
                ):
                    first = shader_spike.write_shader_objects(
                        source_root, recipe, "vertex", first_root
                    )[0].read_bytes()
                    second = shader_spike.write_shader_objects(
                        source_root, recipe, "vertex", second_root
                    )[0].read_bytes()
                    manifest_hash = inputs.digest(inputs.manifest_path)
                    source_hashes = inputs.shader_hashes()
                    captured_hashes = inputs.captured_hashes()

        self.assertEqual(first, second)
        self.assertIn(b"void main() { gl_Position = vec4(1.0); }", first)
        self.assertNotIn(b"not valid GLSL", first)
        self.assertEqual(hashlib.sha256(manifest_a).hexdigest(), manifest_hash)
        self.assertEqual(
            hashlib.sha256(source_a).hexdigest(),
            source_hashes["shaders/class1/fake.glsl"],
        )
        self.assertEqual(manifest_hash, captured_hashes["manifest.json"])

    def test_default_uniform_buffer_slot_is_reserved_by_schema(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        document["vertex_streams"]["position"]["buffer_index"] = 24
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "manifest.json")
            path.write_text(json.dumps(document))
            with self.assertRaisesRegex(shader_spike.ManifestError, "default UBO"):
                shader_spike.load_manifest(path)

    def test_git_provenance_is_one_snapshot_despite_later_head_status_change(
        self,
    ) -> None:
        source_root, programs = self._programs()
        head = "a" * 40
        status = subprocess.CompletedProcess(
            [],
            0,
            f"# branch.oid {head}\n# branch.head lis/captured\n? captured-dirty\n",
            "",
        )
        completed = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(
            shader_spike, "_run", side_effect=[status, completed, completed]
        ) as run:
            provenance = shader_spike._capture_git_provenance(
                programs[0].baseline_commit
            )
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(
            [
                "git",
                "merge-base",
                "--is-ancestor",
                programs[0].baseline_commit,
                head,
            ],
            commands,
        )
        changed = subprocess.CompletedProcess(
            [],
            0,
            f"# branch.oid {'b' * 40}\n# branch.head lis/changed\n",
            "",
        )
        with mock.patch.object(shader_spike, "_run", return_value=changed) as later:
            self.assertIs(
                provenance,
                shader_spike.validate_sources(source_root, programs, provenance),
            )
            report = provenance.report()
        later.assert_not_called()
        self.assertEqual(head, report["head_commit"])
        self.assertEqual("lis/captured", report["branch"])
        self.assertTrue(report["dirty"])
        self.assertEqual(["? captured-dirty"], report["status_porcelain"])

    def test_skip_metal_report_never_claims_full_translation(self) -> None:
        source_root, programs = self._programs()

        def frontend_result(
            _source_root: Path,
            recipe: shader_spike.ProgramRecipe,
            _output_root: Path,
            compile_metal: bool,
            pipeline_validator: Path | None,
        ) -> dict[str, object]:
            self.assertFalse(compile_metal)
            self.assertIsNone(pipeline_validator)
            return {
                "id": recipe.program_id,
                "frontend_passed": True,
                "metal_pipeline_passed": None,
                "passed": True,
                "stages": {},
            }

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve() / "out"
            with (
                mock.patch.object(
                    shader_spike, "load_manifest", return_value=(source_root, programs)
                ),
                mock.patch.object(shader_spike, "validate_sources"),
                mock.patch.object(shader_spike, "validate_tools"),
                mock.patch.object(
                    shader_spike, "translate_program", side_effect=frontend_result
                ),
                mock.patch.object(shader_spike, "_tool_versions", return_value={}),
            ):
                code = shader_spike.main(["--skip-metal", "--output", str(output)])
            report = json.loads(Path(output, "report.json").read_text())
        self.assertEqual(0, code)
        self.assertTrue(report["frontend_gate_passed"])
        self.assertIsNone(report["metal_pso_gate_passed"])
        self.assertIsNone(report["full_translation_gate_passed"])
        self.assertEqual("not_run", report["semantic_parity_gate"])

    def test_fxaa_variants_preserve_default_gl_depth_behavior(self) -> None:
        _, programs = self._programs()
        by_id = {item.program_id: item for item in programs}
        self.assertEqual("1", by_id["fxaa"].defines["FXAA_NO_DEPTH_WRITE"])
        depth_probe = by_id["fxaa_depth_write"]
        self.assertEqual("capability", depth_probe.recipe_kind)
        self.assertNotIn("FXAA_NO_DEPTH_WRITE", depth_probe.defines)
        self.assertNotIn(
            "indra/newview/llgltfmaterialpreviewmgr.cpp",
            {item.path for item in depth_probe.pipeline.source_evidence},
        )
        source = (
            shader_spike.repository_root()
            / "indra/newview/app_settings/shaders/class1/deferred/fxaaF.glsl"
        ).read_text()
        self.assertIn(
            "#ifndef FXAA_NO_DEPTH_WRITE\nuniform sampler2D depthMap;", source
        )
        self.assertIn("gl_FragDepth = texture(depthMap, vary_fragcoord.xy).r;", source)

    def test_calc_diffuse_specular_qualifiers_are_source_wide_consistent(self) -> None:
        shader_root = (
            shader_spike.repository_root() / "indra/newview/app_settings/shaders"
        )
        sources = (
            path.read_text(encoding="utf-8") for path in shader_root.rglob("*.glsl")
        )
        declarations = [source for source in sources if "calcDiffuseSpecular" in source]
        joined = "\n".join(declarations)
        self.assertNotIn("inout vec3 diffuseColor", joined)
        self.assertGreaterEqual(joined.count("out vec3 diffuseColor"), 5)


if __name__ == "__main__":
    unittest.main()
