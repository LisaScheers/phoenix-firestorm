"""Focused and adversarial tests for the Metal shader translation gate."""

from __future__ import annotations

import copy
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

    @staticmethod
    def _stage_msl_sources(
        vertex: dict[str, object], fragment: dict[str, object]
    ) -> dict[str, str]:
        result: dict[str, str] = {}
        for stage, reflection in (("vertex", vertex), ("fragment", fragment)):
            arguments = shader_spike._expected_arguments(reflection, stage)
            result[stage] = ", ".join(
                f"{argument['kind']}_{argument['index']} "
                f"[[{argument['kind']}({argument['index']})]]"
                for argument in arguments
            )
        return result

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

    def _assert_manifest_rejected(
        self, document: dict[str, object], pattern: str
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory, "manifest.json")
            manifest.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(shader_spike.ManifestError, pattern):
                shader_spike.load_manifest(manifest)

    def test_manifest_preserves_original_recipes_and_adds_exact_aa_variants(
        self,
    ) -> None:
        source_root, programs = self._programs()
        shader_spike.validate_sources(source_root, programs)
        self.assertEqual(30, len(programs))
        self.assertEqual(
            shader_spike.REQUIRED_PROGRAM_IDS
            | shader_spike.REQUIRED_FXAA_VARIANT_IDS
            | shader_spike.REQUIRED_SMAA_VARIANT_IDS,
            {item.program_id for item in programs},
        )
        self.assertEqual(
            shader_spike.REQUIRED_FAMILIES, {item.family for item in programs}
        )
        self.assertEqual({400}, {item.glsl_version for item in programs})

    def test_manifest_stage_roles_are_explicit_complete_and_duplicate_free(
        self,
    ) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(5, document["schema"])
        original_program_sources = {
            "ui_font": ("interface/uiV.glsl", "interface/uiF.glsl"),
            "indexed_material": (
                "deferred/diffuseV.glsl",
                "deferred/diffuseIndexedF.glsl",
            ),
            "indexed_material_stress_16": (
                "deferred/diffuseV.glsl",
                "deferred/diffuseIndexedF.glsl",
            ),
            "deferred_diffuse": ("deferred/bumpV.glsl", "deferred/bumpF.glsl"),
            "pbr_opaque": (
                "deferred/pbropaqueV.glsl",
                "deferred/pbropaqueF.glsl",
            ),
            "pbr_alpha": ("deferred/pbralphaV.glsl", "deferred/pbralphaF.glsl"),
            "terrain": ("deferred/terrainV.glsl", "deferred/terrainF.glsl"),
            "avatar_skinning": (
                "deferred/avatarV.glsl",
                "deferred/avatarF.glsl",
            ),
            "shadow_alpha_mask": (
                "deferred/shadowAlphaMaskV.glsl",
                "deferred/shadowAlphaMaskF.glsl",
            ),
            "shadow_alpha_receiver": (
                "deferred/alphaV.glsl",
                "deferred/alphaF.glsl",
            ),
            "reflection_probe": (
                "interface/radianceGenV.glsl",
                "interface/radianceGenF.glsl",
            ),
            "presentation_copy": ("interface/copyV.glsl", "interface/copyF.glsl"),
            "depth_copy": ("interface/copyV.glsl", "interface/copyF.glsl"),
            "fxaa_low": ("deferred/postDeferredV.glsl", "deferred/fxaaF.glsl"),
            "fxaa_medium": ("deferred/postDeferredV.glsl", "deferred/fxaaF.glsl"),
            "fxaa_high": ("deferred/postDeferredV.glsl", "deferred/fxaaF.glsl"),
            "fxaa": ("deferred/postDeferredV.glsl", "deferred/fxaaF.glsl"),
            "fxaa_depth_write": (
                "deferred/postDeferredV.glsl",
                "deferred/fxaaF.glsl",
            ),
        }
        for program in document["programs"]:
            for stage in ("vertex", "fragment"):
                with self.subTest(program=program["id"], stage=stage):
                    roles = program["stages"][stage]
                    self.assertEqual({"program", "features"}, set(roles))
                    self.assertTrue(roles["program"])
                    combined = [*roles["program"], *roles["features"]]
                    self.assertEqual(len(combined), len(set(combined)))
                    expected_count = (
                        2
                        if program["id"] in shader_spike.REQUIRED_SMAA_VARIANT_IDS
                        else 1
                    )
                    self.assertEqual(expected_count, len(roles["program"]))
                    if program["id"] in original_program_sources:
                        stage_index = 0 if stage == "vertex" else 1
                        self.assertEqual(
                            [original_program_sources[program["id"]][stage_index]],
                            roles["program"],
                        )

    def test_malformed_empty_duplicate_and_aliased_stage_roles_fail_closed(
        self,
    ) -> None:
        original = json.loads(self.manifest.read_text(encoding="utf-8"))

        def mutated_stage(value: object) -> dict[str, object]:
            document = copy.deepcopy(original)
            ui = next(item for item in document["programs"] if item["id"] == "ui_font")
            ui["stages"]["vertex"] = value
            return document

        valid = original["programs"][0]["stages"]["vertex"]
        mutations = (
            (
                "legacy positional array",
                [*valid["program"], *valid["features"]],
                "must be an object",
            ),
            ("missing role", {"program": valid["program"]}, "keys do not match schema"),
            ("unknown role", {**valid, "shared": []}, "keys do not match schema"),
            (
                "empty program",
                {"program": [], "features": valid["features"]},
                "non-empty string array",
            ),
            (
                "malformed features",
                {"program": valid["program"], "features": "x"},
                "must be a string array",
            ),
            (
                "duplicate program source",
                {
                    "program": [valid["program"][0], valid["program"][0]],
                    "features": valid["features"],
                },
                "duplicate sources across roles",
            ),
            (
                "duplicate across roles",
                {
                    "program": valid["program"],
                    "features": [valid["program"][0], *valid["features"]],
                },
                "duplicate sources across roles",
            ),
            (
                "canonical alias across roles",
                {
                    "program": ["deferred/SMAA.glsl"],
                    "features": ["deferred/./SMAA.glsl"],
                },
                "canonical repository-relative shader path",
            ),
            (
                "backslash path",
                {"program": [r"interface\\uiV.glsl"], "features": []},
                "canonical repository-relative shader path",
            ),
            (
                "class-prefixed program bypass",
                {"program": ["class1/interface/uiV.glsl"], "features": []},
                "canonical repository-relative shader path",
            ),
            (
                "class-prefixed feature bypass",
                {
                    "program": valid["program"],
                    "features": ["class1/deferred/textureUtilV.glsl"],
                },
                "canonical repository-relative shader path",
            ),
            (
                "uppercase class-prefixed program bypass",
                {"program": ["CLASS1/interface/uiV.glsl"], "features": []},
                "canonical repository-relative shader path",
            ),
            (
                "mixed-case class-prefixed feature bypass",
                {
                    "program": valid["program"],
                    "features": ["cLaSs1/deferred/textureUtilV.glsl"],
                },
                "canonical repository-relative shader path",
            ),
            (
                "wrong-case program source",
                {
                    "program": ["interface/uiv.glsl"],
                    "features": valid["features"],
                },
                "cannot resolve class2 shader source",
            ),
            (
                "unknown feature",
                {"program": valid["program"], "features": ["missing/feature.glsl"]},
                "has no declared baseline class",
            ),
        )
        for label, stage, pattern in mutations:
            with self.subTest(label=label):
                self._assert_manifest_rejected(mutated_stage(stage), pattern)

        unsupported_class = copy.deepcopy(original)
        unsupported_class["feature_classes"]["deferred/globalF.glsl"] = 4
        self._assert_manifest_rejected(
            unsupported_class, r"supported source range \[1, 3\]"
        )

        lower_class_program = copy.deepcopy(original)
        pbr_alpha = next(
            item
            for item in lower_class_program["programs"]
            if item["id"] == "pbr_alpha"
        )
        pbr_alpha["stages"]["fragment"]["program"][0] = "class1/deferred/pbralphaF.glsl"
        self._assert_manifest_rejected(
            lower_class_program, "canonical repository-relative shader path"
        )

        wrong_case_feature = copy.deepcopy(original)
        wrong_case_feature["feature_classes"]["deferred/textureutilV.glsl"] = 1
        ui = next(
            item for item in wrong_case_feature["programs"] if item["id"] == "ui_font"
        )
        ui["stages"]["vertex"]["features"][0] = "deferred/textureutilV.glsl"
        self._assert_manifest_rejected(
            wrong_case_feature, "cannot resolve class1 shader source"
        )

        mixed_case_alias = copy.deepcopy(original)
        mixed_case_alias["feature_classes"]["interface/uiv.glsl"] = 1
        ui = next(
            item for item in mixed_case_alias["programs"] if item["id"] == "ui_font"
        )
        ui["stages"]["vertex"]["features"].append("interface/uiv.glsl")
        self._assert_manifest_rejected(
            mixed_case_alias,
            "duplicate physical shader sources|cannot resolve class1 shader source",
        )

    def test_baseline_settings_and_runtime_overrides_are_machine_read(self) -> None:
        _, programs = self._programs()
        baseline = programs[0].baseline_settings
        self.assertEqual(set(shader_spike.BASELINE_SETTING_TYPES), set(baseline))
        self.assertTrue(baseline["RenderHDREnabled"])
        self.assertFalse(baseline["RenderEnableEmissiveBuffer"])
        self.assertEqual(0, baseline["RenderFSAASamples"])
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
        self.assertEqual(
            {"RenderFSAASamples": 3, "RenderFSAAType": 1},
            fxaa.settings_overrides,
        )

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
        self.assertEqual((("bgra8unorm",), None), actual["presentation_copy"])
        self.assertEqual((("rgba16float",), "depth32float"), actual["depth_copy"])
        for program_id in ("fxaa_low", "fxaa_medium", "fxaa_high", "fxaa"):
            self.assertEqual((("rgba8unorm",), None), actual[program_id])
        self.assertEqual((("bgra8unorm",), None), actual["ui_font"])

    def test_presentation_copy_recipe_is_the_uniform_free_frame_contract(self) -> None:
        _, programs = self._programs()
        recipe = next(
            item for item in programs if item.program_id == "presentation_copy"
        )
        self.assertEqual(
            {"presentation_copy"}, shader_spike.REQUIRED_BUFFER_FREE_PROGRAM_IDS
        )
        self.assertEqual("Depth write and copy", recipe.family)
        self.assertEqual("runtime", recipe.recipe_kind)
        self.assertEqual("not_run", recipe.semantic_parity)
        self.assertEqual(
            "indra/newview/llviewershadermgr.cpp:3468", recipe.source_reference
        )
        self.assertEqual("gCopyProgram", recipe.source_symbol)
        self.assertEqual(2, recipe.shader_class)
        self.assertEqual({}, recipe.settings_overrides)
        self.assertEqual({}, recipe.defines)
        self.assertEqual(0, recipe.indexed_texture_channels)
        self.assertEqual(
            {
                "vertex": (
                    "interface/copyV.glsl",
                    "deferred/textureUtilV.glsl",
                    "objects/nonindexedTextureV.glsl",
                ),
                "fragment": (
                    "interface/copyF.glsl",
                    "deferred/globalF.glsl",
                ),
            },
            recipe.stages,
        )
        self.assertEqual(
            {("textures", "diffuseMap", "sampler2D")},
            {
                (requirement.group, requirement.name, requirement.resource_type)
                for requirement in recipe.required_reflection["fragment"]
            },
        )
        self.assertEqual(("bgra8unorm",), recipe.pipeline.color_formats)
        self.assertIsNone(recipe.pipeline.depth_format)
        self.assertEqual(1, recipe.pipeline.sample_count)
        self.assertEqual(1, len(recipe.pipeline.vertex_layouts))
        layout = recipe.pipeline.vertex_layouts[0]
        self.assertEqual(
            (16, 16, "per_vertex"),
            (
                layout.buffer_index,
                layout.stride,
                layout.step_function,
            ),
        )
        self.assertEqual(
            [("position", 0, "float3", 0, 16)],
            [
                (
                    attribute.name,
                    attribute.location,
                    attribute.format_name,
                    attribute.offset,
                    attribute.buffer_index,
                )
                for attribute in layout.attributes
            ],
        )

    def test_presentation_copy_pipeline_descriptor_is_uniform_free(self) -> None:
        _, programs = self._programs()
        recipe = next(
            item for item in programs if item.program_id == "presentation_copy"
        )
        vertex = {"inputs": [{"name": "position", "type": "vec3", "location": 0}]}
        fragment = {
            "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
            "textures": [{"name": "diffuseMap", "type": "sampler2D", "binding": 0}],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "presentation-copy.json")
            shader_spike.write_pipeline_spec(
                recipe,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                Path(directory, "presentation-copy.metallib"),
                path,
            )
            spec = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(["bgra8unorm"], spec["color_formats"])
        self.assertIsNone(spec["depth_format"])
        self.assertEqual(1, spec["sample_count"])
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
            spec["vertex_attributes"],
        )
        self.assertEqual(
            [{"buffer_index": 16, "step_function": "per_vertex", "stride": 16}],
            spec["vertex_layouts"],
        )
        self.assertEqual([], spec["expected_arguments"]["vertex"])
        self.assertEqual(
            [("sampler", "diffuseMap", 0), ("texture", "diffuseMap", 0)],
            [
                (argument["kind"], argument["name"], argument["index"])
                for argument in spec["expected_arguments"]["fragment"]
            ],
        )

    def test_presentation_copy_rejects_uniform_reflection(self) -> None:
        _, programs = self._programs()
        recipe = next(
            item for item in programs if item.program_id == "presentation_copy"
        )
        vertex = {
            "inputs": [{"name": "position", "type": "vec3", "location": 0}],
            "types": {
                "_ubo": {"members": [{"name": "value", "type": "vec4", "offset": 0}]}
            },
            "ubos": [
                {
                    "name": "UnexpectedUniforms",
                    "type": "_ubo",
                    "binding": 24,
                    "block_size": 16,
                }
            ],
        }
        fragment = {
            "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
            "textures": [{"name": "diffuseMap", "type": "sampler2D", "binding": 0}],
        }
        with (
            tempfile.TemporaryDirectory() as directory,
            self.assertRaisesRegex(
                shader_spike.ManifestError, "must not expose uniform buffers"
            ),
        ):
            shader_spike.write_pipeline_spec(
                recipe,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                Path(directory, "presentation-copy.metallib"),
                Path(directory, "presentation-copy.json"),
            )

    def test_stress_and_semantic_states_are_honest(self) -> None:
        _, programs = self._programs()
        by_id = {item.program_id: item for item in programs}
        actual_kinds = {item.program_id: item.recipe_kind for item in programs}
        self.assertEqual(
            shader_spike.REQUIRED_RECIPE_KINDS,
            {
                program_id: actual_kinds[program_id]
                for program_id in shader_spike.REQUIRED_RECIPE_KINDS
            },
        )
        for program_id in ("fxaa_low", "fxaa_medium", "fxaa_high"):
            self.assertEqual("runtime_variant", actual_kinds[program_id])
        self.assertEqual("stress", by_id["indexed_material_stress_16"].recipe_kind)
        self.assertEqual(
            16, by_id["indexed_material_stress_16"].indexed_texture_channels
        )
        self.assertEqual("capability", by_id["fxaa_depth_write"].recipe_kind)
        self.assertEqual(
            "cpu_runtime_layout_open", by_id["avatar_skinning"].semantic_parity
        )
        self.assertTrue(all(item.semantic_parity != "passed" for item in programs))

    def test_original_recipe_kind_relabel_cannot_escape_frozen_inventory(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        by_id = {item["id"]: item for item in document["programs"]}
        by_id["terrain"]["recipe_kind"] = "runtime_variant"
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory, "manifest.json")
            manifest.write_text(json.dumps(document), encoding="utf-8")
            source_root, programs = shader_spike.load_manifest(manifest)
            with self.assertRaisesRegex(shader_spike.ManifestError, "recipe inventory"):
                shader_spike.validate_sources(source_root, programs)

    def test_original_fifteen_recipes_remain_a_mandatory_subset(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        document["programs"] = [
            item for item in document["programs"] if item["id"] != "depth_copy"
        ]
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory, "manifest.json")
            manifest.write_text(json.dumps(document), encoding="utf-8")
            source_root, programs = shader_spike.load_manifest(manifest)
            with self.assertRaisesRegex(
                shader_spike.ManifestError, "missing required recipes: depth_copy"
            ):
                shader_spike.validate_sources(source_root, programs)

    def test_program_family_labels_cannot_be_swapped(self) -> None:
        document = json.loads(self.manifest.read_text(encoding="utf-8"))
        by_id = {item["id"]: item for item in document["programs"]}
        by_id["avatar_skinning"]["family"] = "Terrain"
        by_id["terrain"]["family"] = "Avatar skinning"
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory, "manifest.json")
            manifest.write_text(json.dumps(document), encoding="utf-8")
            source_root, programs = shader_spike.load_manifest(manifest)
            with self.assertRaisesRegex(shader_spike.ManifestError, "recipe inventory"):
                shader_spike.validate_sources(source_root, programs)

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

    def test_msl_translation_commands_fix_vertex_clipspace_only(self) -> None:
        common = [
            "spirv-cross",
            "example.spv",
            "--msl",
            "--msl-version",
            "23000",
            "--msl-decoration-binding",
            "--rename-entry-point",
            "main",
        ]
        vertex = shader_spike._spirv_cross_msl_command(
            "example", "vertex", Path("example.spv"), Path("example.metal")
        )
        fragment = shader_spike._spirv_cross_msl_command(
            "example", "fragment", Path("example.spv"), Path("example.metal")
        )

        self.assertEqual(
            [
                *common,
                "example_vertex",
                "vert",
                "--fixup-clipspace",
                "--output",
                "example.metal",
            ],
            vertex,
        )
        self.assertEqual(
            [
                *common,
                "example_fragment",
                "frag",
                "--output",
                "example.metal",
            ],
            fragment,
        )
        self.assertEqual(1, vertex.count("--fixup-clipspace"))
        self.assertNotIn("--flip-vert-y", vertex)
        self.assertNotIn("--fixup-clipspace", fragment)
        self.assertNotIn("--flip-vert-y", fragment)

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

    def test_explicit_stage_roles_isolate_defines_and_shader_classes(self) -> None:
        source_root, programs = self._programs()
        smaa = next(item for item in programs if item.program_id == "smaa_edge_low")
        self.assertEqual({"vertex": 2, "fragment": 2}, smaa.stage_program_counts)
        canonical_path = source_root / "class1/deferred/SMAA.glsl"
        canonical_before = canonical_path.read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            wrappers = shader_spike.write_shader_objects(
                source_root, smaa, "vertex", Path(directory)
            )
            contents = [path.read_text(encoding="utf-8") for path in wrappers]
        self.assertEqual(canonical_before, canonical_path.read_bytes())
        for wrapper in contents:
            self.assertIn(
                "#extension GL_ARB_shading_language_420pack : enable", wrapper
            )
        for program_object in contents[:2]:
            self.assertIn("#define SMAA_GLSL_4 1", program_object)
            self.assertIn("#define SMAA_PRESET_LOW 1", program_object)
            self.assertNotIn("#define REFMAP_LEVEL 3", program_object)
        for feature_object in contents[2:]:
            self.assertIn("#define REFMAP_LEVEL 3", feature_object)
            self.assertNotIn("#define SMAA_PRESET_LOW 1", feature_object)
        self.assertIn("/class1/deferred/SMAA.glsl", contents[1])
        self.assertIn("/class1/windlight/atmosphericsVarsV.glsl", contents[2])
        ascii_art_line = next(
            line
            for line in canonical_before.decode("utf-8").splitlines()
            if "|_______/" in line
        )
        self.assertTrue(ascii_art_line.endswith("\\"))
        self.assertIn(f"{ascii_art_line}\n", contents[1])

    def test_source_resolution_uses_class_fallback_and_confines_paths(self) -> None:
        source_root, _ = self._programs()
        resolved = shader_spike.resolve_source(source_root, 3, "interface/uiV.glsl")
        self.assertEqual("class1", resolved.parts[-3])
        with self.assertRaisesRegex(shader_spike.ManifestError, "escapes source_root"):
            shader_spike.resolve_source(source_root, 3, "../../README.md")

        with tempfile.TemporaryDirectory() as directory:
            fallback_root = Path(directory)
            wrong_case = fallback_root / "class3/Foo.glsl"
            exact_lower = fallback_root / "class2/foo.glsl"
            wrong_case.parent.mkdir(parents=True)
            exact_lower.parent.mkdir(parents=True)
            wrong_case.write_text("class3 wrong case", encoding="utf-8")
            exact_lower.write_text("class2 exact", encoding="utf-8")
            self.assertEqual(
                exact_lower.resolve(),
                shader_spike.resolve_source(fallback_root, 3, "foo.glsl"),
            )

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
                ui,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                root / "ui.metallib",
                spec_path,
            )
            spec = json.loads(spec_path.read_text(encoding="utf-8"))
        self.assertEqual(5, spec["schema"])
        self.assertEqual(
            {
                "source_symbol": "gUIProgram",
                "source_index": None,
                "shader_class": 2,
                "boolean_settings": [],
                "integer_settings": [],
            },
            spec["selection"],
        )
        self.assertEqual(
            [16, 18, 20], [item["buffer_index"] for item in spec["vertex_layouts"]]
        )
        color = next(
            item
            for item in spec["vertex_attributes"]
            if item["name"] == "diffuse_color"
        )
        self.assertEqual("uchar4normalized", color["format"])
        uniform = spec["expected_arguments"]["vertex"][0]
        self.assertEqual(
            {
                "name": "matrix",
                "offset": 0,
                "type": "mat4",
                "matrix_stride": 16,
                "matrix_major": "column",
            },
            uniform["members"][0],
        )
        kinds = {
            (item["kind"], item["index"])
            for item in spec["expected_arguments"]["fragment"]
        }
        self.assertEqual({("texture", 0), ("sampler", 0)}, kinds)
        self.assertEqual(
            {"texture_0", "sampler_0"},
            {item["metal_name"] for item in spec["expected_arguments"]["fragment"]},
        )

    def test_generated_msl_native_binding_names_are_exact_and_unique(self) -> None:
        source = (
            "constant Uniforms& _19 [[buffer(24)]], "
            "texture2d<float> diffuseMap [[texture(0)]], "
            "sampler diffuseMapSmplr [[sampler(0)]]"
        )
        self.assertEqual(
            {
                ("buffer", 24): "_19",
                ("texture", 0): "diffuseMap",
                ("sampler", 0): "diffuseMapSmplr",
            },
            shader_spike.extract_metal_binding_names(source, "fragment"),
        )
        with self.assertRaisesRegex(shader_spike.ManifestError, "duplicate native"):
            shader_spike.extract_metal_binding_names(
                "same [[texture(0)]], same [[sampler(0)]]", "fragment"
            )

    def test_native_validator_compares_exact_generated_metal_name(self) -> None:
        source = (
            Path(shader_spike.__file__)
            .with_name("validate_metal_pipeline.mm")
            .read_text(encoding="utf-8")
        )
        self.assertIn('binding.name isEqualToString:argument[@"metal_name"]', source)

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
                shadow,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                Path(directory, "x.metallib"),
                path,
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

        nested = shader_spike._expected_arguments(
            {
                "types": {
                    "_inner": {
                        "members": [{"name": "value", "type": "float", "offset": 0}]
                    },
                    "_outer": {
                        "members": [{"name": "nested", "type": "_inner", "offset": 0}]
                    },
                },
                "ubos": [
                    {
                        "name": "Nested",
                        "type": "_outer",
                        "binding": 24,
                        "block_size": 4,
                    }
                ],
            },
            "vertex",
        )
        self.assertEqual(16, nested[0]["buffer_alignment"])
        self.assertEqual(16, nested[0]["buffer_size"])

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

    def test_v1_matrix_layout_is_canonical_and_noncanonical_forms_reject(self) -> None:
        members = shader_spike._buffer_members(
            {
                "types": {
                    "_ubo": {
                        "members": [
                            {
                                "name": "transform",
                                "type": "mat3",
                                "offset": 0,
                                "matrix_stride": 16,
                            }
                        ]
                    }
                }
            },
            {"name": "U", "type": "_ubo"},
        )
        self.assertEqual("column", members[0]["matrix_major"])
        self.assertEqual(16, members[0]["matrix_stride"])
        for expected, mutation in (
            ("column-major", {"row_major": True}),
            ("stride 16", {"matrix_stride": 32}),
            ("only mat3 and mat4", {"type": "mat2x3"}),
            ("non-matrix.*matrix layout", {"type": "float4x4"}),
        ):
            member = {
                "name": "transform",
                "type": "mat4",
                "offset": 0,
                "matrix_stride": 16,
                **mutation,
            }
            with (
                self.subTest(mutation=mutation),
                self.assertRaisesRegex(shader_spike.ManifestError, expected),
            ):
                shader_spike._buffer_members(
                    {"types": {"_ubo": {"members": [member]}}},
                    {"name": "U", "type": "_ubo"},
                )

        with self.assertRaisesRegex(shader_spike.ManifestError, "stride 16"):
            shader_spike._expected_arguments(
                {
                    "types": {
                        "_ubo": {
                            "members": [
                                {"name": "transform", "type": "mat4", "offset": 0}
                            ]
                        }
                    },
                    "ubos": [
                        {
                            "name": "U",
                            "type": "_ubo",
                            "binding": 24,
                            "block_size": 64,
                        }
                    ],
                },
                "vertex",
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
                self._stage_msl_sources(vertex, fragment),
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

    def test_build_system_may_supply_only_an_empty_output_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            output = root / "cmake-created"
            output.mkdir()
            Path(output, "nested-generated-parent").mkdir()
            shader_spike._prepare_output(output, allow_empty=True)
            self.assertTrue(Path(output, shader_spike.OUTPUT_MARKER).is_file())
            nonempty = root / "nonempty"
            nonempty.mkdir()
            Path(nonempty, "foreign").write_text("do not remove")
            with self.assertRaisesRegex(RuntimeError, "unmarked"):
                shader_spike._prepare_output(nonempty, allow_empty=True)

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

    def test_bundled_source_indices_and_selection_keys_are_exact(self) -> None:
        _, programs = self._programs()
        bundled = [
            item
            for item in programs
            if item.recipe_kind in shader_spike.BUNDLED_RECIPE_KINDS
        ]
        self.assertEqual(28, len(bundled))
        scalar = [item for item in bundled if item.source_index is None]
        indexed = [item for item in bundled if item.source_index is not None]
        self.assertEqual(12, len(scalar))
        self.assertEqual(16, len(indexed))
        self.assertTrue(all(item.source_index is None for item in scalar))
        self.assertEqual(
            len(bundled),
            len({shader_spike.program_selection_key(item) for item in bundled}),
        )

    def test_program_selection_partitions_and_sorts_setting_types(self) -> None:
        _, programs = self._programs()
        ui = next(item for item in programs if item.program_id == "ui_font")
        recipe = replace(
            ui,
            settings_overrides={
                "RenderUIBuffer": True,
                "RenderShadowDetail": 2,
                "RenderHDREnabled": False,
                "RenderFSAASamples": 1,
            },
        )
        self.assertEqual(
            {
                "source_symbol": "gUIProgram",
                "source_index": None,
                "shader_class": 2,
                "boolean_settings": [
                    {"name": "RenderHDREnabled", "value": False},
                    {"name": "RenderUIBuffer", "value": True},
                ],
                "integer_settings": [
                    {"name": "RenderFSAASamples", "value": 1},
                    {"name": "RenderShadowDetail", "value": 2},
                ],
            },
            shader_spike.program_selection(recipe),
        )

    def test_fxaa_variants_emit_exact_typed_selections(self) -> None:
        _, programs = self._programs()
        by_id = {item.program_id: item for item in programs}
        expected = {
            "fxaa_low": (0, "12"),
            "fxaa_medium": (1, "23"),
            "fxaa_high": (2, "28"),
            "fxaa": (3, "39"),
        }
        vertex = {"inputs": [{"name": "position", "type": "vec3", "location": 0}]}
        fragment = {
            "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
            "textures": [{"name": "diffuseMap", "type": "sampler2D", "binding": 0}],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for program_id, (source_index, preset) in expected.items():
                recipe = by_id[program_id]
                path = root / f"{program_id}.json"
                shader_spike.write_pipeline_spec(
                    recipe,
                    vertex,
                    fragment,
                    self._stage_msl_sources(vertex, fragment),
                    root / f"{program_id}.metallib",
                    path,
                )
                spec = json.loads(path.read_text(encoding="utf-8"))
                with self.subTest(program_id=program_id):
                    self.assertEqual(5, spec["schema"])
                    self.assertEqual(
                        {
                            "source_symbol": "gFXAAProgram",
                            "source_index": source_index,
                            "shader_class": 3,
                            "boolean_settings": [],
                            "integer_settings": [
                                {
                                    "name": "RenderFSAASamples",
                                    "value": source_index,
                                },
                                {"name": "RenderFSAAType", "value": 1},
                            ],
                        },
                        spec["selection"],
                    )
                    self.assertEqual(preset, recipe.defines["FXAA_QUALITY__PRESET"])

    def test_smaa_variants_emit_exact_typed_selections_and_stage_contracts(
        self,
    ) -> None:
        _, programs = self._programs()
        by_id = {item.program_id: item for item in programs}
        self.assertEqual(12, len(shader_spike.SMAA_VARIANT_CONTRACT))
        vertex = {"inputs": [{"name": "position", "type": "vec3", "location": 0}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for program_id, (
                source_symbol,
                source_index,
                preset,
                vertex_source,
                fragment_source,
                source_reference,
            ) in shader_spike.SMAA_VARIANT_CONTRACT.items():
                recipe = by_id[program_id]
                fragment = {
                    "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
                    "textures": [
                        {
                            "name": requirement.name,
                            "type": requirement.resource_type,
                            "binding": index,
                        }
                        for index, requirement in enumerate(
                            recipe.required_reflection["fragment"]
                        )
                    ],
                }
                path = root / f"{program_id}.json"
                shader_spike.write_pipeline_spec(
                    recipe,
                    vertex,
                    fragment,
                    self._stage_msl_sources(vertex, fragment),
                    root / f"{program_id}.metallib",
                    path,
                )
                spec = json.loads(path.read_text(encoding="utf-8"))
                with self.subTest(program_id=program_id):
                    self.assertEqual(5, spec["schema"])
                    self.assertEqual(source_reference, recipe.source_reference)
                    self.assertEqual(
                        {
                            "source_symbol": source_symbol,
                            "source_index": source_index,
                            "shader_class": 3,
                            "boolean_settings": [],
                            "integer_settings": [
                                {
                                    "name": "RenderFSAASamples",
                                    "value": source_index,
                                },
                                {"name": "RenderFSAAType", "value": 2},
                            ],
                        },
                        spec["selection"],
                    )
                    self.assertEqual("1", recipe.defines[preset])
                    self.assertEqual(
                        (vertex_source, "deferred/SMAA.glsl"),
                        recipe.stages["vertex"][:2],
                    )
                    self.assertEqual(
                        (fragment_source, "deferred/SMAA.glsl"),
                        recipe.stages["fragment"][:2],
                    )
                    self.assertEqual(
                        {"vertex": 2, "fragment": 2}, recipe.stage_program_counts
                    )

    def test_nonbundled_pipeline_specs_remain_schema_four_without_selection(
        self,
    ) -> None:
        _, programs = self._programs()
        capability = next(
            item for item in programs if item.program_id == "fxaa_depth_write"
        )
        vertex = {"inputs": [{"name": "position", "type": "vec3", "location": 0}]}
        fragment = {
            "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
            "textures": [
                {"name": "diffuseMap", "type": "sampler2D", "binding": 0},
                {"name": "depthMap", "type": "sampler2D", "binding": 1},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "capability.json")
            shader_spike.write_pipeline_spec(
                capability,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                Path(directory, "capability.metallib"),
                path,
            )
            spec = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(4, spec["schema"])
        self.assertNotIn("selection", spec)

    def test_manifest_selection_and_aa_mutations_fail_closed(self) -> None:
        original = json.loads(self.manifest.read_text(encoding="utf-8"))

        def mutate(
            program_id: str, field: tuple[str, ...], value: object
        ) -> dict[str, object]:
            document = copy.deepcopy(original)
            programs = {item["id"]: item for item in document["programs"]}
            target = programs[program_id]
            for key in field[:-1]:
                target = target[key]
            target[field[-1]] = value
            return document

        mutations = (
            (
                "wrong FXAA index",
                mutate("fxaa_high", ("source_index",), 1),
                "selection key collides|exact FXAA mapping",
            ),
            (
                "wrong FXAA preset",
                mutate("fxaa_medium", ("defines", "FXAA_QUALITY__PRESET"), "28"),
                "exact FXAA mapping",
            ),
            (
                "wrong FXAA sample setting",
                mutate("fxaa_low", ("settings_overrides", "RenderFSAASamples"), 1),
                "exact FXAA mapping",
            ),
            (
                "wrong FXAA type setting",
                mutate("fxaa", ("settings_overrides", "RenderFSAAType"), 2),
                "exact FXAA mapping",
            ),
            (
                "wrong FXAA symbol",
                mutate("fxaa", ("source_symbol",), "gUIProgram"),
                "scalar source_symbol|exact FXAA mapping",
            ),
            (
                "wrong FXAA class",
                mutate("fxaa", ("shader_class",), 2),
                "exact FXAA mapping",
            ),
            (
                "wrong SMAA index",
                mutate("smaa_edge_high", ("source_index",), 1),
                "selection key collides|exact SMAA mapping",
            ),
            (
                "wrong SMAA preset",
                mutate("smaa_weights_medium", ("defines", "SMAA_PRESET_MEDIUM"), "0"),
                "exact SMAA mapping",
            ),
            (
                "unknown SMAA macro",
                mutate("smaa_edge_low", ("defines", "UNKNOWN_SMAA_MACRO"), "1"),
                "exact SMAA mapping",
            ),
            (
                "wrong SMAA sample setting",
                mutate(
                    "smaa_neighborhood_low",
                    ("settings_overrides", "RenderFSAASamples"),
                    1,
                ),
                "exact SMAA mapping|selection key collides",
            ),
            (
                "wrong SMAA type setting",
                mutate("smaa_edge_ultra", ("settings_overrides", "RenderFSAAType"), 1),
                "exact SMAA mapping",
            ),
            (
                "wrong SMAA source symbol",
                mutate(
                    "smaa_weights_high", ("source_symbol",), "gSMAAEdgeDetectProgram"
                ),
                "exact SMAA mapping|selection key collides",
            ),
            (
                "wrong SMAA class",
                mutate("smaa_neighborhood_medium", ("shader_class",), 2),
                "exact SMAA mapping",
            ),
            (
                "wrong SMAA program source",
                mutate(
                    "smaa_edge_low",
                    ("stages", "vertex", "program"),
                    ["deferred/SMAABlendWeightsV.glsl", "deferred/SMAA.glsl"],
                ),
                "exact SMAA mapping",
            ),
            (
                "wrong SMAA reflection",
                mutate(
                    "smaa_weights_low",
                    ("required_reflection", "fragment", 0, "name"),
                    "diffuseRect",
                ),
                "exact SMAA pipeline contract",
            ),
            (
                "wrong SMAA pipeline format",
                mutate(
                    "smaa_neighborhood_high",
                    ("pipeline", "color_formats"),
                    ["rgba16float"],
                ),
                "exact SMAA pipeline contract",
            ),
            (
                "scalar numeric index",
                mutate("ui_font", ("source_index",), 0),
                "scalar source_symbol",
            ),
            (
                "capability class outside source range",
                mutate("fxaa_depth_write", ("shader_class",), 4),
                r"supported source range \[1, 3\]",
            ),
            (
                "stress class outside source range",
                mutate("indexed_material_stress_16", ("shader_class",), 4),
                r"supported source range \[1, 3\]",
            ),
        )
        for label, document, pattern in mutations:
            with self.subTest(label=label):
                self._assert_manifest_rejected(document, pattern)

        missing_index = copy.deepcopy(original)
        ui = next(item for item in missing_index["programs"] if item["id"] == "ui_font")
        del ui["source_index"]
        self._assert_manifest_rejected(missing_index, "source_index is required")

        capability_index = copy.deepcopy(original)
        depth_probe = next(
            item
            for item in capability_index["programs"]
            if item["id"] == "fxaa_depth_write"
        )
        depth_probe["source_index"] = None
        self._assert_manifest_rejected(
            capability_index, "source_index is only valid for bundled"
        )

        collision = copy.deepcopy(original)
        depth_copy = next(
            item for item in collision["programs"] if item["id"] == "depth_copy"
        )
        depth_copy["source_symbol"] = "gCopyProgram"
        self._assert_manifest_rejected(collision, "selection key collides")

        for schema in (4, 6):
            with self.subTest(schema=schema):
                wrong_schema = copy.deepcopy(original)
                wrong_schema["schema"] = schema
                self._assert_manifest_rejected(
                    wrong_schema, "manifest schema must be 5"
                )

        missing_smaa = copy.deepcopy(original)
        missing_smaa["programs"] = [
            item for item in missing_smaa["programs"] if item["id"] != "smaa_edge_low"
        ]
        self._assert_manifest_rejected(
            missing_smaa, "antialiasing variant contract is incomplete"
        )

        unknown_smaa = copy.deepcopy(original)
        custom_smaa = copy.deepcopy(
            next(
                item
                for item in unknown_smaa["programs"]
                if item["id"] == "smaa_edge_low"
            )
        )
        custom_smaa["id"] = "smaa_edge_custom"
        unknown_smaa["programs"].append(custom_smaa)
        self._assert_manifest_rejected(
            unknown_smaa, "unexpected bundled SMAA source variant"
        )

    @unittest.skipUnless(
        sys.platform == "darwin", "native Metal validator is macOS-only"
    )
    def test_native_validator_rejects_selection_contract_inversions(self) -> None:
        _, programs = self._programs()
        fxaa = next(item for item in programs if item.program_id == "fxaa_high")
        smaa = next(item for item in programs if item.program_id == "smaa_weights_high")
        capability = next(
            item for item in programs if item.program_id == "fxaa_depth_write"
        )
        vertex = {"inputs": [{"name": "position", "type": "vec3", "location": 0}]}
        fragment = {
            "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
            "textures": [{"name": "diffuseMap", "type": "sampler2D", "binding": 0}],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec_path = root / "fxaa-high.json"
            shader_spike.write_pipeline_spec(
                fxaa,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                root / "not-loaded.metallib",
                spec_path,
            )
            validator = shader_spike.build_pipeline_validator(
                root, programs[0].input_snapshot
            )

            def validate(
                document: dict[str, object],
            ) -> subprocess.CompletedProcess[str]:
                spec_path.write_text(json.dumps(document), encoding="utf-8")
                return subprocess.run(
                    [str(validator), str(spec_path)],
                    check=False,
                    capture_output=True,
                    text=True,
                )

            fxaa_spec = json.loads(spec_path.read_text(encoding="utf-8"))
            mismatched_settings = copy.deepcopy(fxaa_spec)
            mismatched_settings["selection"]["integer_settings"][0]["value"] = 1
            result = validate(mismatched_settings)
            self.assertEqual(2, result.returncode)
            self.assertIn("exact FXAA settings mapping", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            downgraded = copy.deepcopy(fxaa_spec)
            downgraded["schema"] = 4
            del downgraded["selection"]
            result = validate(downgraded)
            self.assertEqual(2, result.returncode)
            self.assertIn("bundled pipeline spec requires schema 5", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            smaa_fragment = {
                "outputs": [{"name": "frag_color", "type": "vec4", "location": 0}],
                "textures": [
                    {"name": "edgesTex", "type": "sampler2D", "binding": 0},
                    {"name": "areaTex", "type": "sampler2D", "binding": 1},
                    {"name": "searchTex", "type": "sampler2D", "binding": 2},
                ],
            }
            smaa_path = root / "smaa-weights-high.json"
            shader_spike.write_pipeline_spec(
                smaa,
                vertex,
                smaa_fragment,
                self._stage_msl_sources(vertex, smaa_fragment),
                root / "not-loaded.metallib",
                smaa_path,
            )
            smaa_spec = json.loads(smaa_path.read_text(encoding="utf-8"))

            smaa_wrong_pass = copy.deepcopy(smaa_spec)
            smaa_wrong_pass["selection"]["source_symbol"] = "gSMAAEdgeDetectProgram"
            result = validate(smaa_wrong_pass)
            self.assertEqual(2, result.returncode)
            self.assertIn("exact SMAA source mapping", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            smaa_wrong_index = copy.deepcopy(smaa_spec)
            smaa_wrong_index["selection"]["source_index"] = 1
            result = validate(smaa_wrong_index)
            self.assertEqual(2, result.returncode)
            self.assertIn("exact SMAA source mapping", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            smaa_wrong_settings = copy.deepcopy(smaa_spec)
            smaa_wrong_settings["selection"]["integer_settings"][1]["value"] = 1
            result = validate(smaa_wrong_settings)
            self.assertEqual(2, result.returncode)
            self.assertIn("exact SMAA settings mapping", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            smaa_downgraded = copy.deepcopy(smaa_spec)
            smaa_downgraded["schema"] = 4
            del smaa_downgraded["selection"]
            result = validate(smaa_downgraded)
            self.assertEqual(2, result.returncode)
            self.assertIn("bundled pipeline spec requires schema 5", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            unknown_program = copy.deepcopy(smaa_spec)
            unknown_program["id"] = "smaa_unknown"
            result = validate(unknown_program)
            self.assertEqual(2, result.returncode)
            self.assertIn("not in the frozen program inventory", result.stderr)
            self.assertNotIn("cannot load metallib", result.stderr)

            capability_path = root / "fxaa-depth-write.json"
            shader_spike.write_pipeline_spec(
                capability,
                vertex,
                fragment,
                self._stage_msl_sources(vertex, fragment),
                root / "not-loaded.metallib",
                capability_path,
            )
            upgraded = json.loads(capability_path.read_text(encoding="utf-8"))
            upgraded["schema"] = 5
            upgraded["selection"] = {
                "source_symbol": "gCapabilityProbe",
                "source_index": None,
                "shader_class": 3,
                "boolean_settings": [],
                "integer_settings": [],
            }
            result = validate(upgraded)
            self.assertEqual(2, result.returncode)
            self.assertIn(
                "selector-free pipeline spec requires schema 4", result.stderr
            )
            self.assertNotIn("cannot load metallib", result.stderr)

    def test_fxaa_variants_preserve_default_gl_depth_behavior(self) -> None:
        _, programs = self._programs()
        by_id = {item.program_id: item for item in programs}
        for program_id in ("fxaa_low", "fxaa_medium", "fxaa_high", "fxaa"):
            self.assertEqual("1", by_id[program_id].defines["FXAA_NO_DEPTH_WRITE"])
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
