from __future__ import annotations

import csv
import json
import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import inventory


class InventoryUnitTests(unittest.TestCase):
    def test_opengl_header_include_pattern_covers_supported_delimiters(self) -> None:
        accepted = (
            "#include <OpenGL/OpenGL.h>",
            '# include "OpenGL/gl.h"',
            "#include <GL/glu.h>",
            '#import "GL/glext.h"',
        )
        rejected = (
            "// #include <OpenGL/OpenGL.h>",
            '/*\n#include "GL/gl.h"\n*/',
            '#include "GLTF/asset.h"',
            'const char* path = "OpenGL/OpenGL.h";',
        )

        self.assertTrue(
            all(
                inventory.OPENGL_HEADER_INCLUDE_RE.search(source) for source in accepted
            )
        )
        self.assertTrue(
            all(
                inventory.OPENGL_HEADER_INCLUDE_RE.search(
                    inventory.strip_comments(source)
                )
                is None
                for source in rejected
            )
        )

    def test_program_recipe_inventory_covers_indexed_and_sandbox_programs(self) -> None:
        sources = {
            "indra/newview/llviewershadermgr.cpp": """
gDirectProgram.mShaderFiles.push_back(vertex);
gFXAAProgram[index].mShaderFiles.push_back(fragment);
shader.mShaderFiles.push_back(shared);
gDirectProgram.createShader();
""",
            "indra/newview/llglsandbox.cpp": """
gBenchmarkProgram.mShaderFiles.push_back(vertex);
gBenchmarkProgram.createShader();
""",
        }

        result = inventory.program_recipe_inventory(sources)

        self.assertEqual(result["recipe_source_count"], 2)
        self.assertEqual(result["mShaderFiles_assignment_count"], 4)
        self.assertEqual(result["create_shader_call_count"], 2)
        self.assertEqual(
            result["program_symbols"],
            ["gBenchmarkProgram", "gDirectProgram", "gFXAAProgram"],
        )
        self.assertEqual(result["indexed_program_symbols"], ["gFXAAProgram"])
        self.assertIn("local shader variables", result["scope"])

    def test_comments_and_literals_are_excluded_from_active_estimate(self) -> None:
        source = """
glDrawArrays(GL_TRIANGLES, 0, 3);
// glDeleteBuffers(1, &buffer);
/* glBindTexture(GL_TEXTURE_2D, texture); */
const char* diagnostic = "glUseProgram(GL_FRAGMENT_SHADER)";
GLfloat weight = 1.0f;
GLuint buffer = 0;
GLenum mode = GL_TRIANGLES;
GLWidget unrelated_project_type;
gluErrorString(GL_INVALID_ENUM);
CGLSetCurrentContext(context);
CGLContextObj context = nullptr;
CGLError cgl_error = kCGLNoError;
GLUquadric* quadric = nullptr;
CGLWidget unrelated_cgl_project_type;
GLUWidget unrelated_glu_project_type;
"""
        surface = inventory.opengl_surface({"indra/example.cpp": source})
        calls = surface["direct_opengl_api_call_shaped_references"]
        gl_symbols = surface["gl_types_and_constants"]
        glu_symbols = surface["glu_types_and_constants"]
        cgl_symbols = surface["cgl_types_and_constants"]

        self.assertEqual(calls["lexical"]["occurrences"], 6)
        self.assertEqual(calls["active_code_estimate"]["occurrences"], 3)
        self.assertEqual(
            calls["active_code_estimate"]["occurrences_by_api"],
            {"cgl": 1, "gl": 1, "glu": 1},
        )
        self.assertEqual(gl_symbols["lexical"]["occurrences"], 8)
        self.assertEqual(gl_symbols["active_code_estimate"]["occurrences"], 6)
        self.assertNotIn("GLWidget", gl_symbols["lexical"]["occurrences_by_name"])
        for typedef in ("GLenum", "GLfloat", "GLuint"):
            self.assertEqual(
                gl_symbols["active_code_estimate"]["occurrences_by_name"][typedef], 1
            )
        self.assertEqual(glu_symbols["active_code_estimate"]["occurrences"], 1)
        self.assertNotIn("GLUWidget", glu_symbols["lexical"]["occurrences_by_name"])
        self.assertEqual(cgl_symbols["active_code_estimate"]["occurrences"], 3)
        self.assertNotIn("CGLWidget", cgl_symbols["lexical"]["occurrences_by_name"])

    def test_shader_categories_ignore_class_fallback_level(self) -> None:
        paths = [
            f"{inventory.SHADER_ROOT}/class1/interface/fontV.glsl",
            f"{inventory.SHADER_ROOT}/class2/interface/fontF.glsl",
            f"{inventory.SHADER_ROOT}/class3/deferred/lightF.glsl",
            f"{inventory.SHADER_ROOT}/error.glsl",
        ]

        result = inventory.shader_inventory(reversed(paths))

        self.assertEqual(result["total_files"], 4)
        self.assertEqual(
            result["by_class"], {"class1": 1, "class2": 1, "class3": 1, "root": 1}
        )
        self.assertEqual(
            result["by_category"], {"deferred": 1, "interface": 2, "root": 1}
        )
        self.assertEqual(
            result["by_stage"], {"fragment": 2, "shared_or_unknown": 1, "vertex": 1}
        )

    def test_inventory_json_is_stably_sorted_and_newline_terminated(self) -> None:
        rendered = inventory.render_inventory({"z": 1, "a": {"y": 2, "b": 3}})
        self.assertEqual(
            rendered, '{\n  "a": {\n    "b": 3,\n    "y": 2\n  },\n  "z": 1\n}\n'
        )


class CheckedInBaselineTests(unittest.TestCase):
    def test_checked_in_baseline_matches_pinned_git_tree(self) -> None:
        baseline_path = REPOSITORY_ROOT / "doc/metal/inventory-baseline.json"
        checked_in = json.loads(baseline_path.read_text(encoding="utf-8"))

        generated = inventory.build_inventory(
            REPOSITORY_ROOT, checked_in["baseline"]["commit"]
        )

        self.assertEqual(checked_in, generated)
        calls = checked_in["opengl_surface"]["direct_opengl_api_call_shaped_references"]
        self.assertEqual(calls["lexical"]["occurrences"], 900)
        self.assertEqual(calls["lexical"]["file_count"], 69)
        self.assertEqual(
            calls["lexical"]["occurrences_by_api"],
            {"cgl": 22, "gl": 873, "glu": 5},
        )
        self.assertEqual(calls["active_code_estimate"]["occurrences"], 796)
        self.assertEqual(calls["active_code_estimate"]["file_count"], 62)
        self.assertEqual(
            calls["active_code_estimate"]["occurrences_by_api"],
            {"cgl": 21, "gl": 772, "glu": 3},
        )
        cgl_symbols = checked_in["opengl_surface"]["cgl_types_and_constants"]
        self.assertEqual(cgl_symbols["lexical"]["occurrences"], 54)
        self.assertEqual(cgl_symbols["active_code_estimate"]["occurrences"], 52)
        include_sources = checked_in["build_constraints"][
            "opengl_framework_include_sources"
        ]
        self.assertEqual(include_sources["file_count"], 7)
        self.assertEqual(
            include_sources["files"],
            [
                "indra/llrender/llglheaders.h",
                "indra/llrender/llglslshader.cpp",
                "indra/llrender/llshadermgr.cpp",
                "indra/llwindow/llwindowmacosx-objc.h",
                "indra/llwindow/llwindowmacosx.cpp",
                "indra/llwindow/llwindowmacosx.h",
                "indra/llwindow/llwindowmesaheadless.h",
            ],
        )
        recipes = checked_in["shader_runtime"]["program_recipes"]
        self.assertEqual(recipes["recipe_source_count"], 2)
        self.assertEqual(recipes["mShaderFiles_assignment_count"], 265)
        self.assertEqual(recipes["create_shader_call_count"], 131)
        self.assertEqual(recipes["program_symbol_count"], 120)
        self.assertEqual(
            recipes["indexed_program_symbols"],
            [
                "gDeferredMaterialProgram",
                "gDeferredMultiLightProgram",
                "gFXAAProgram",
                "gSMAABlendWeightsProgram",
                "gSMAAEdgeDetectProgram",
                "gSMAANeighborhoodBlendProgram",
            ],
        )
        self.assertEqual(
            [source["path"] for source in recipes["recipe_sources"]],
            [
                "indra/newview/llglsandbox.cpp",
                "indra/newview/llviewershadermgr.cpp",
            ],
        )

    def test_feature_ledger_has_unique_complete_scope(self) -> None:
        ledger_path = REPOSITORY_ROOT / "doc/metal/feature-ledger.csv"
        with ledger_path.open(newline="", encoding="utf-8") as ledger_file:
            rows = list(csv.DictReader(ledger_file))

        feature_ids = [row["feature_id"] for row in rows]
        self.assertEqual(
            set(rows[0]),
            {
                "baseline_status",
                "evidence",
                "feature_id",
                "milestone",
                "owner",
                "parity_gate",
                "parity_status",
                "scope",
            },
        )
        self.assertEqual(len(feature_ids), len(set(feature_ids)))
        self.assertEqual(
            set(feature_ids),
            {
                "avatars_skinning",
                "buffers_vertex_layouts",
                "command_submission_sync",
                "cutover_cleanup",
                "deferred_lighting_shadows",
                "platform_build_contract",
                "post_processing_picking_debug",
                "pbr_reflections",
                "pipeline_state_cache",
                "profiling_capabilities",
                "renderer_abstraction",
                "resource_lifetime",
                "shader_translation_toolchain",
                "terrain_water_sky",
                "textures_samplers_uploads",
                "ui_fonts",
                "window_input_lifecycle",
                "world_opaque_alpha",
            },
        )
        self.assertTrue(all(row["baseline_status"] == "opengl_only" for row in rows))
        self.assertTrue(all(row["owner"] == "unassigned" for row in rows))
        self.assertTrue(all(row["milestone"] for row in rows))
        self.assertTrue(all(row["parity_gate"] for row in rows))
        status_by_feature = {row["feature_id"]: row["parity_status"] for row in rows}
        self.assertEqual(
            status_by_feature["platform_build_contract"], "bootstrap_in_progress"
        )
        self.assertEqual(
            status_by_feature["window_input_lifecycle"], "bootstrap_in_progress"
        )
        self.assertEqual(
            status_by_feature["shader_translation_toolchain"],
            "compiler_spike_verified",
        )
        self.assertEqual(
            set(status_by_feature.values()),
            {"bootstrap_in_progress", "compiler_spike_verified", "not_started"},
        )


if __name__ == "__main__":
    unittest.main()
