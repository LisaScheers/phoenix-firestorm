#!/usr/bin/env python3
"""Generate a deterministic inventory of Firestorm's OpenGL renderer surface.

The scanner reads blobs from a pinned Git commit rather than the working tree.
That makes a baseline reproducible after the Metal implementation starts to
change the files being measured.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

SCHEMA_VERSION = 4
SOURCE_EXTENSIONS = frozenset(
    {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".inl", ".m", ".mm"}
)
SHADER_ROOT = "indra/newview/app_settings/shaders"

OPENGL_API_CALL_RE = re.compile(r"\b((?:gl|glu|CGL)[A-Z][A-Za-z0-9_]*)\s*\(")
OPENGL_TYPE_NAMES = (
    "GLDEBUGPROC",
    "GLDEBUGPROCAMD",
    "GLDEBUGPROCARB",
    "GLDEBUGPROCKHR",
    "GLVULKANPROCNV",
    "GLbitfield",
    "GLboolean",
    "GLbyte",
    "GLchar",
    "GLcharARB",
    "GLclampd",
    "GLclampf",
    "GLdouble",
    "GLeglClientBuffer",
    "GLeglImageOES",
    "GLenum",
    "GLfixed",
    "GLfloat",
    "GLhalf",
    "GLhalfARB",
    "GLhalfNV",
    "GLhandleARB",
    "GLint",
    "GLint64",
    "GLint64EXT",
    "GLint64NV",
    "GLintptr",
    "GLintptrARB",
    "GLshort",
    "GLsizei",
    "GLsizeiptr",
    "GLsizeiptrARB",
    "GLsync",
    "GLubyte",
    "GLuint",
    "GLuint64",
    "GLuint64EXT",
    "GLuint64NV",
    "GLushort",
    "GLvdpauSurfaceNV",
    "GLvoid",
)
OPENGL_TYPE_ALTERNATION = "|".join(
    sorted((re.escape(name) for name in OPENGL_TYPE_NAMES), key=len, reverse=True)
)
GL_SYMBOL_RE = re.compile(rf"\b(?:GL_[A-Z0-9_]+|{OPENGL_TYPE_ALTERNATION})\b")
GLU_TYPE_NAMES = (
    "GLUnurbs",
    "GLUnurbsObj",
    "GLUquadric",
    "GLUquadricObj",
    "GLUtesselator",
    "GLUtriangulatorObj",
)
GLU_TYPE_ALTERNATION = "|".join(
    sorted((re.escape(name) for name in GLU_TYPE_NAMES), key=len, reverse=True)
)
GLU_SYMBOL_RE = re.compile(rf"\b(?:GLU_[A-Z0-9_]+|{GLU_TYPE_ALTERNATION})\b")
CGL_TYPE_NAMES = (
    "CGLContextObj",
    "CGLContextParameter",
    "CGLError",
    "CGLGlobalOption",
    "CGLPBufferObj",
    "CGLPixelFormatAttribute",
    "CGLPixelFormatObj",
    "CGLRendererInfoObj",
    "CGLRendererProperty",
    "CGLShareGroupObj",
)
CGL_TYPE_ALTERNATION = "|".join(
    sorted((re.escape(name) for name in CGL_TYPE_NAMES), key=len, reverse=True)
)
CGL_SYMBOL_RE = re.compile(rf"\b(?:kCGL[A-Z][A-Za-z0-9_]*|{CGL_TYPE_ALTERNATION})\b")
OPENGL_HEADER_INCLUDE_RE = re.compile(
    r'^\s*#\s*(?:include|import)\s*[<"](?:OpenGL|GL)/[^>"]+[>"]', re.MULTILINE
)
PROGRAM_SHADER_FILES_RE = re.compile(
    r"\b(g[A-Za-z0-9_]+Program)(?:\s*\[[^]\n]+\])?\s*\.mShaderFiles"
)
INDEXED_PROGRAM_SHADER_FILES_RE = re.compile(
    r"\b(g[A-Za-z0-9_]+Program)\s*\[[^]\n]+\]\s*\.mShaderFiles"
)
SHADER_FILE_ASSIGNMENT_RE = re.compile(r"\bmShaderFiles\.push_back\s*\(")
CREATE_SHADER_CALL_RE = re.compile(r"\bcreateShader\s*\(")
COMMENT_RE = re.compile(r"//[^\r\n]*|/\*.*?\*/", re.DOTALL)
COMMENT_OR_LITERAL_RE = re.compile(
    r"//[^\r\n]*|/\*.*?\*/|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'",
    re.DOTALL,
)

WINDOW_CONTEXT_ANCHORS = (
    (
        "window_implementation",
        "indra/llwindow/llwindowmacosx.cpp",
        "mContext = getCGLContextObj",
    ),
    (
        "window_class",
        "indra/llwindow/llwindowmacosx.h",
        "class LLWindowMacOSX",
    ),
    (
        "objective_c_bridge",
        "indra/llwindow/llwindowmacosx-objc.mm",
        "CGLContextObj getCGLContextObj",
    ),
    (
        "opengl_view",
        "indra/llwindow/llopenglview-objc.h",
        "LLOpenGLView : NSOpenGLView",
    ),
    (
        "context_owner",
        "indra/llwindow/llopenglview-objc.mm",
        "- (CGLContextObj)getCGLContextObj",
    ),
    (
        "darwin_build_sources",
        "indra/llwindow/CMakeLists.txt",
        "llopenglview-objc.mm",
    ),
)

SHADER_RUNTIME_ANCHORS = (
    (
        "program_creation",
        "indra/llrender/llglslshader.cpp",
        "bool LLGLSLShader::createShader()",
    ),
    (
        "feature_assembly",
        "indra/llrender/llshadermgr.cpp",
        "bool LLShaderMgr::attachShaderFeatures",
    ),
    (
        "source_loading",
        "indra/llrender/llshadermgr.cpp",
        "GLuint LLShaderMgr::loadShaderFile",
    ),
    (
        "recipe_dispatch",
        "indra/newview/llviewershadermgr.cpp",
        "void LLViewerShaderMgr::setShaders()",
    ),
)


class InventoryError(RuntimeError):
    """Raised when the requested baseline cannot be inventoried exactly."""


@dataclass(frozen=True)
class CommitMetadata:
    commit: str
    committed_at: str
    subject: str


def _run_git(
    repo: Path, arguments: Sequence[str], *, input_bytes: bytes | None = None
) -> bytes:
    process = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        input=input_bytes,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        raise InventoryError(f"git {' '.join(arguments)} failed: {detail}")
    return process.stdout


def repository_root(start: Path) -> Path:
    root = _run_git(start, ("rev-parse", "--show-toplevel"))
    return Path(root.decode("utf-8").strip()).resolve()


def resolve_commit(repo: Path, ref: str) -> CommitMetadata:
    commit = _run_git(repo, ("rev-parse", "--verify", f"{ref}^{{commit}}"))
    commit_hash = commit.decode("ascii").strip()
    raw_metadata = (
        _run_git(
            repo,
            ("show", "-s", "--format=%H%x00%cI%x00%s", commit_hash),
        )
        .decode("utf-8", errors="replace")
        .rstrip("\n")
    )
    fields = raw_metadata.split("\0", maxsplit=2)
    if len(fields) != 3 or fields[0] != commit_hash:
        raise InventoryError(f"unexpected metadata for commit {commit_hash}")
    return CommitMetadata(commit=fields[0], committed_at=fields[1], subject=fields[2])


def tracked_paths(repo: Path, commit: str) -> list[str]:
    raw_paths = _run_git(repo, ("ls-tree", "-r", "--name-only", "-z", commit))
    return sorted(
        path.decode("utf-8", errors="surrogateescape")
        for path in raw_paths.split(b"\0")
        if path
    )


def read_blobs(repo: Path, commit: str, paths: Iterable[str]) -> dict[str, str]:
    ordered_paths = sorted(set(paths))
    for path in ordered_paths:
        if "\n" in path or "\r" in path:
            raise InventoryError(f"unsupported newline in tracked path: {path!r}")

    requests = "".join(f"{commit}:{path}\n" for path in ordered_paths).encode("utf-8")
    output = _run_git(
        repo,
        (
            "cat-file",
            "--batch",
        ),
        input_bytes=requests,
    )
    position = 0
    blobs: dict[str, str] = {}

    for path in ordered_paths:
        header_end = output.find(b"\n", position)
        if header_end < 0:
            raise InventoryError(f"missing cat-file header for {path}")
        header = output[position:header_end].decode("ascii", errors="replace")
        position = header_end + 1
        header_fields = header.split()
        if len(header_fields) != 3 or header_fields[1] != "blob":
            raise InventoryError(f"unexpected cat-file response for {path}: {header}")
        try:
            size = int(header_fields[2])
        except ValueError as error:
            raise InventoryError(
                f"invalid blob size for {path}: {header_fields[2]}"
            ) from error
        blob_end = position + size
        if blob_end >= len(output) or output[blob_end : blob_end + 1] != b"\n":
            raise InventoryError(f"truncated cat-file response for {path}")
        blobs[path] = output[position:blob_end].decode("utf-8", errors="replace")
        position = blob_end + 1

    if position != len(output):
        raise InventoryError("unexpected trailing data from git cat-file")
    return blobs


def _blank_preserving_newlines(match: re.Match[str]) -> str:
    return "".join("\n" if character == "\n" else " " for character in match.group(0))


def strip_comments(source: str) -> str:
    """Replace C-family comments while preserving preprocessor strings and newlines."""

    return COMMENT_RE.sub(_blank_preserving_newlines, source)


def strip_comments_and_literals(source: str) -> str:
    """Replace comments and ordinary quoted literals while preserving newlines."""

    return COMMENT_OR_LITERAL_RE.sub(_blank_preserving_newlines, source)


def _subsystem(path: str) -> str:
    parts = PurePosixPath(path).parts
    return "/".join(parts[:2]) if len(parts) >= 2 else path


def _histogram(matches: Iterable[str]) -> dict[str, int]:
    return dict(sorted(Counter(matches).items()))


def _most_frequent(
    histogram: Mapping[str, int], limit: int = 25
) -> list[dict[str, int | str]]:
    return [
        {"name": name, "occurrences": count}
        for name, count in sorted(
            histogram.items(), key=lambda item: (-item[1], item[0])
        )[:limit]
    ]


def reference_inventory(
    sources: Mapping[str, str], pattern: re.Pattern[str]
) -> dict[str, object]:
    matches_by_file = {path: pattern.findall(sources[path]) for path in sorted(sources)}
    return _reference_inventory_from_matches(matches_by_file)


def _reference_inventory_from_matches(
    matches_by_file: Mapping[str, Sequence[str]],
) -> dict[str, object]:
    file_histogram: dict[str, int] = {}
    names: list[str] = []
    for path in sorted(matches_by_file):
        matches = matches_by_file[path]
        if matches:
            file_histogram[path] = len(matches)
            names.extend(matches)

    name_histogram = _histogram(names)
    subsystem_histogram: Counter[str] = Counter()
    for path, count in file_histogram.items():
        subsystem_histogram[_subsystem(path)] += count

    return {
        "file_count": len(file_histogram),
        "files": sorted(file_histogram),
        "occurrences": sum(file_histogram.values()),
        "occurrences_by_file": dict(sorted(file_histogram.items())),
        "occurrences_by_name": name_histogram,
        "occurrences_by_subsystem": dict(sorted(subsystem_histogram.items())),
        "most_frequent": _most_frequent(name_histogram),
    }


def _opengl_api_category(name: str) -> str:
    if name.startswith("CGL"):
        return "cgl"
    if name.startswith("glu"):
        return "glu"
    return "gl"


def opengl_call_inventory(sources: Mapping[str, str]) -> dict[str, object]:
    matches_by_file = {
        path: OPENGL_API_CALL_RE.findall(sources[path]) for path in sorted(sources)
    }
    result = _reference_inventory_from_matches(matches_by_file)
    occurrences_by_api: Counter[str] = Counter()
    files_by_api: dict[str, set[str]] = {"cgl": set(), "gl": set(), "glu": set()}
    for path, matches in matches_by_file.items():
        for name in matches:
            category = _opengl_api_category(name)
            occurrences_by_api[category] += 1
            files_by_api[category].add(path)

    result["file_count_by_api"] = {
        category: len(paths) for category, paths in sorted(files_by_api.items())
    }
    result["files_by_api"] = {
        category: sorted(paths) for category, paths in sorted(files_by_api.items())
    }
    result["occurrences_by_api"] = dict(sorted(occurrences_by_api.items()))
    return result


def opengl_surface(sources: Mapping[str, str]) -> dict[str, object]:
    active_sources = {
        path: strip_comments_and_literals(source) for path, source in sources.items()
    }
    return {
        "cgl_types_and_constants": {
            "active_code_estimate": reference_inventory(active_sources, CGL_SYMBOL_RE),
            "lexical": reference_inventory(sources, CGL_SYMBOL_RE),
            "pattern": CGL_SYMBOL_RE.pattern,
            "recognized_typedefs": list(CGL_TYPE_NAMES),
        },
        "direct_opengl_api_call_shaped_references": {
            "active_code_estimate": opengl_call_inventory(active_sources),
            "lexical": opengl_call_inventory(sources),
            "pattern": OPENGL_API_CALL_RE.pattern,
        },
        "gl_types_and_constants": {
            "active_code_estimate": reference_inventory(active_sources, GL_SYMBOL_RE),
            "lexical": reference_inventory(sources, GL_SYMBOL_RE),
            "pattern": GL_SYMBOL_RE.pattern,
            "recognized_typedefs": list(OPENGL_TYPE_NAMES),
        },
        "glu_types_and_constants": {
            "active_code_estimate": reference_inventory(active_sources, GLU_SYMBOL_RE),
            "lexical": reference_inventory(sources, GLU_SYMBOL_RE),
            "pattern": GLU_SYMBOL_RE.pattern,
            "recognized_typedefs": list(GLU_TYPE_NAMES),
        },
        "scan_note": (
            "Call counts cover gl*, glu*, and CGL* APIs; symbol counts cover exact GL/GLU "
            "typedef allowlists plus GL_* and GLU_* constants, and exact CGL typedefs plus "
            "kCGL* constants. Lexical counts are the canonical migration search surface. "
            "Active-code estimates remove comments and ordinary string/character literals, "
            "but remain text-based rather than AST-based."
        ),
        "scan_root": "indra",
        "source_extensions": sorted(SOURCE_EXTENSIONS),
    }


def shader_inventory(shader_paths: Iterable[str]) -> dict[str, object]:
    classes: Counter[str] = Counter()
    categories: Counter[str] = Counter()
    stages: Counter[str] = Counter()
    by_class_and_category: dict[str, Counter[str]] = {}
    paths = sorted(shader_paths)

    for path in paths:
        relative = PurePosixPath(path).relative_to(SHADER_ROOT)
        parts = relative.parts
        shader_class = (
            parts[0] if parts and re.fullmatch(r"class\d+", parts[0]) else "root"
        )
        category = parts[1] if shader_class != "root" and len(parts) > 2 else "root"
        filename = parts[-1]
        if filename.endswith("V.glsl"):
            stage = "vertex"
        elif filename.endswith("F.glsl"):
            stage = "fragment"
        else:
            stage = "shared_or_unknown"

        classes[shader_class] += 1
        categories[category] += 1
        stages[stage] += 1
        by_class_and_category.setdefault(shader_class, Counter())[category] += 1

    return {
        "by_category": dict(sorted(categories.items())),
        "by_class": dict(sorted(classes.items())),
        "by_class_and_category": {
            shader_class: dict(sorted(counts.items()))
            for shader_class, counts in sorted(by_class_and_category.items())
        },
        "by_stage": dict(sorted(stages.items())),
        "extension": ".glsl",
        "root": SHADER_ROOT,
        "total_files": len(paths),
    }


def _line_for_anchor(source: str, anchor: str, path: str) -> int:
    offset = source.find(anchor)
    if offset < 0:
        raise InventoryError(f"required anchor {anchor!r} is missing from {path}")
    return source.count("\n", 0, offset) + 1


def anchored_entry_points(
    blobs: Mapping[str, str], anchors: Iterable[tuple[str, str, str]]
) -> list[dict[str, int | str]]:
    return [
        {
            "line": _line_for_anchor(blobs[path], anchor, path),
            "path": path,
            "role": role,
            "symbol": anchor,
        }
        for role, path, anchor in anchors
    ]


def program_recipe_inventory(sources: Mapping[str, str]) -> dict[str, object]:
    recipe_sources: list[dict[str, object]] = []
    program_symbols: set[str] = set()
    indexed_program_symbols: set[str] = set()
    assignment_count = 0
    create_shader_count = 0

    for path in sorted(sources):
        source = sources[path]
        source_assignment_count = len(SHADER_FILE_ASSIGNMENT_RE.findall(source))
        if source_assignment_count == 0:
            continue
        source_create_shader_count = len(CREATE_SHADER_CALL_RE.findall(source))
        source_program_symbols = set(PROGRAM_SHADER_FILES_RE.findall(source))
        source_indexed_symbols = set(INDEXED_PROGRAM_SHADER_FILES_RE.findall(source))
        if path == "indra/newview/llviewershadermgr.cpp":
            role = "viewer_shader_manager"
        elif path == "indra/newview/llglsandbox.cpp":
            role = "benchmark_sandbox_reinitialization"
        else:
            role = "additional_runtime_assembly"

        assignment_count += source_assignment_count
        create_shader_count += source_create_shader_count
        program_symbols.update(source_program_symbols)
        indexed_program_symbols.update(source_indexed_symbols)
        recipe_sources.append(
            {
                "create_shader_call_count": source_create_shader_count,
                "indexed_program_symbols": sorted(source_indexed_symbols),
                "mShaderFiles_assignment_count": source_assignment_count,
                "path": path,
                "program_symbols": sorted(source_program_symbols),
                "role": role,
            }
        )

    return {
        "create_shader_call_count": create_shader_count,
        "indexed_program_symbol_count": len(indexed_program_symbols),
        "indexed_program_symbols": sorted(indexed_program_symbols),
        "mShaderFiles_assignment_count": assignment_count,
        "program_symbol_count": len(program_symbols),
        "program_symbols": sorted(program_symbols),
        "recipe_source_count": len(recipe_sources),
        "recipe_sources": recipe_sources,
        "scope": (
            "All tracked source files with mShaderFiles.push_back at the pinned commit. "
            "Named symbols cover global g*Program expressions, including indexed arrays; "
            "local shader variables remain represented in assignment totals."
        ),
    }


def shader_runtime_inventory(blobs: Mapping[str, str]) -> dict[str, object]:
    recipe_path = "indra/newview/llviewershadermgr.cpp"
    recipe_source = blobs[recipe_path]
    loader_pattern = re.compile(
        r"^(?:bool|std::string) LLViewerShaderMgr::(load[A-Za-z0-9_]+)\(", re.MULTILINE
    )
    loader_entries = [
        {
            "line": recipe_source.count("\n", 0, match.start()) + 1,
            "symbol": f"LLViewerShaderMgr::{match.group(1)}",
        }
        for match in loader_pattern.finditer(recipe_source)
    ]
    program_recipes = program_recipe_inventory(blobs)
    program_recipes["loader_entry_points"] = loader_entries
    return {
        "assembly_entry_points": anchored_entry_points(blobs, SHADER_RUNTIME_ANCHORS),
        "program_recipes": program_recipes,
    }


def build_constraints(
    all_paths: Sequence[str], blobs: Mapping[str, str], cmake_paths: Sequence[str]
) -> dict[str, object]:
    variables_path = "indra/cmake/Variables.cmake"
    variables = blobs[variables_path]
    architecture_match = re.search(
        r'set\s*\(\s*CMAKE_OSX_ARCHITECTURES\s+"([^"]+)"', variables
    )
    if architecture_match is None:
        raise InventoryError(
            f"CMAKE_OSX_ARCHITECTURES is missing from {variables_path}"
        )
    architectures = architecture_match.group(1).split(";")

    deployment_match = re.search(
        r'string\s*\(REGEX MATCH "([^"]*mmacosx-version-min[^"]*)"[^\n]*\$ENV\{LL_BUILD\}',
        variables,
    )
    if deployment_match is None:
        raise InventoryError(
            f"LL_BUILD deployment-target extraction is missing from {variables_path}"
        )

    opengl_cmake_consumers: list[dict[str, object]] = []
    for path in sorted(cmake_paths):
        source = blobs[path]
        evidence: list[str] = []
        if re.search(r"\binclude\s*\(\s*OpenGL\s*\)", source):
            evidence.append("include(OpenGL)")
        if "OpenGL::GL" in source:
            evidence.append("OpenGL::GL")
        if "OpenGL::GLU" in source:
            evidence.append("OpenGL::GLU")
        if evidence:
            opengl_cmake_consumers.append({"evidence": evidence, "path": path})

    objective_cpp_sources = sorted(
        path for path in all_paths if path.startswith("indra/") and path.endswith(".mm")
    )
    metal_sources = sorted(path for path in all_paths if path.endswith(".metal"))
    opengl_framework_sources = sorted(
        path
        for path, source in blobs.items()
        if path.startswith("indra/")
        and PurePosixPath(path).suffix.lower() in SOURCE_EXTENSIONS
        and OPENGL_HEADER_INCLUDE_RE.search(strip_comments(source)) is not None
    )

    return {
        "darwin": {
            "architectures": architectures,
            "architectures_source": variables_path,
            "deployment_target_input": "LL_BUILD",
            "deployment_target_regex": deployment_match.group(1),
            "deployment_target_source": variables_path,
        },
        "metal_shader_sources": {
            "file_count": len(metal_sources),
            "files": metal_sources,
        },
        "objective_cxx_sources": {
            "file_count": len(objective_cpp_sources),
            "files": objective_cpp_sources,
        },
        "opengl_cmake_consumers": opengl_cmake_consumers,
        "opengl_framework_include_sources": {
            "file_count": len(opengl_framework_sources),
            "files": opengl_framework_sources,
        },
    }


def build_inventory(repo: Path, ref: str) -> dict[str, object]:
    root = repository_root(repo)
    metadata = resolve_commit(root, ref)
    all_paths = tracked_paths(root, metadata.commit)
    source_paths = [
        path
        for path in all_paths
        if path.startswith("indra/")
        and PurePosixPath(path).suffix.lower() in SOURCE_EXTENSIONS
    ]
    shader_paths = [
        path
        for path in all_paths
        if path.startswith(f"{SHADER_ROOT}/") and path.endswith(".glsl")
    ]
    cmake_paths = [
        path
        for path in all_paths
        if path.startswith("indra/") and path.endswith(("CMakeLists.txt", ".cmake"))
    ]
    required_paths = {
        path for _, path, _ in (*WINDOW_CONTEXT_ANCHORS, *SHADER_RUNTIME_ANCHORS)
    }
    required_paths.add("indra/newview/llviewershadermgr.cpp")
    required_paths.add("indra/cmake/Variables.cmake")
    paths_to_read = sorted(set(source_paths) | set(cmake_paths) | required_paths)
    blobs = read_blobs(root, metadata.commit, paths_to_read)
    sources = {path: blobs[path] for path in source_paths}

    return {
        "baseline": {
            "commit": metadata.commit,
            "committed_at": metadata.committed_at,
            "scope": "tracked repository blobs at the pinned commit",
            "subject": metadata.subject,
        },
        "build_constraints": build_constraints(all_paths, blobs, cmake_paths),
        "generator": {
            "regenerate": (
                "python3 scripts/metal/inventory.py "
                f"--ref {metadata.commit} --output doc/metal/inventory-baseline.json"
            ),
            "script": "scripts/metal/inventory.py",
        },
        "macos_window_context": {
            "entry_points": anchored_entry_points(blobs, WINDOW_CONTEXT_ANCHORS),
            "summary": (
                "LLWindowMacOSX owns a CGL context obtained through an Objective-C bridge; "
                "LLOpenGLView combines NSOpenGLView presentation with NSTextInputClient input."
            ),
        },
        "opengl_surface": opengl_surface(sources),
        "schema": SCHEMA_VERSION,
        "shader_runtime": shader_runtime_inventory(blobs),
        "shader_sources": shader_inventory(shader_paths),
    }


def render_inventory(inventory: Mapping[str, object]) -> str:
    return json.dumps(inventory, indent=2, sort_keys=True) + "\n"


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="Git commit or ref to inventory")
    parser.add_argument(
        "--output",
        type=Path,
        help="write JSON to this path instead of stdout",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_arguments(arguments if arguments is not None else sys.argv[1:])
    try:
        root = repository_root(Path.cwd())
        rendered = render_inventory(build_inventory(root, options.ref))
        if options.output is None:
            sys.stdout.write(rendered)
        else:
            options.output.write_text(rendered, encoding="utf-8")
    except (InventoryError, OSError) as error:
        print(f"inventory: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
