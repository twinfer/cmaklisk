#!/usr/bin/env python3
"""
Parse bazel aquery --output=jsonproto and extract archive paths and include directories.

This is an optional accelerator for BazelInstall.cmake. When python3 is available,
it runs much faster than the pure CMake string(JSON) fallback on large outputs.

Usage:
    python3 BazelAqueryParse.py \
        --input aquery_output.json \
        --archives archives.txt \
        --include-dirs include_dirs.txt \
        --src-dir /path/to/workspace \
        [--exclude "-exec-" --exclude "some_pattern"]
"""

import argparse
import json
import os
import re
import sys

def resolve_path(frag_id: int, frag_map: dict[int, dict], cache: dict[int, str]) -> str:
    """Resolve a pathFragmentId to a full path by walking the parent chain."""
    if frag_id in cache:
        return cache[frag_id]

    parts: list[str] = []
    current = frag_id
    while current and current != 0:
        frag = frag_map.get(current)
        if not frag:
            break
        parts.append(frag["label"])
        current = frag.get("parentId", 0)

    result = "/".join(reversed(parts))
    cache[frag_id] = result
    return result


def parse_aquery(data: dict) -> tuple[list[str], list[str]]:
    """Extract link inputs (.a and .o) and include directories from aquery jsonproto.

    Returns:
        (link_inputs, include_dirs) where link_inputs contains both .a and .o paths.
    """
    # Build lookup maps
    frag_map: dict[int, dict] = {}
    for f in data.get("pathFragments", []):
        frag_map[f["id"]] = f

    art_map: dict[int, dict] = {}
    for a in data.get("artifacts", []):
        art_map[a["id"]] = a

    path_cache: dict[int, str] = {}

    # Collect both .a (from CppArchive) and .o (from CppCompile) since
    # Bazel only materializes the direct target's .a — transitive deps
    # are only available as .o files.
    link_inputs: list[str] = []
    include_dirs: set[str] = set()

    for action in data.get("actions", []):
        mnemonic = action.get("mnemonic", "")

        if mnemonic in ("CppArchive", "CppCompile", "ObjcCompile"):
            for out_id in action.get("outputIds", []):
                art = art_map.get(out_id)
                if art:
                    path = resolve_path(art["pathFragmentId"], frag_map, path_cache)
                    if path.endswith(".a") or path.endswith(".o"):
                        link_inputs.append(path)

        if mnemonic in ("CppCompile", "ObjcCompile"):
            args = action.get("arguments", [])
            i = 0
            while i < len(args):
                arg = args[i]
                if arg in ("-I", "-iquote", "-isystem") and i + 1 < len(args):
                    include_dirs.add(args[i + 1])
                    i += 2
                elif arg.startswith("-I") and not arg.startswith("-isystem") and len(arg) > 2:
                    include_dirs.add(arg[2:])
                    i += 1
                elif arg.startswith("-iquote") and len(arg) > 7:
                    include_dirs.add(arg[7:])
                    i += 1
                elif arg.startswith("-isystem") and len(arg) > 8:
                    include_dirs.add(arg[8:])
                    i += 1
                else:
                    i += 1

    return sorted(set(link_inputs)), sorted(include_dirs)


def generate_compile_commands(data: dict, exec_root: str, exclude_patterns: list[re.Pattern]) -> list[dict]:
    """Generate compile_commands.json entries from CppCompile actions."""
    entries = []

    for action in data.get("actions", []):
        mnemonic = action.get("mnemonic", "")
        if mnemonic not in ("CppCompile", "ObjcCompile"):
            continue

        args = action.get("arguments", [])
        if not args:
            continue

        # Find the source file: last argument that looks like a source file
        source_file = ""
        for a in reversed(args):
            if a.endswith((".cc", ".cpp", ".c", ".cxx", ".m", ".mm")):
                source_file = a
                break

        if not source_file:
            continue

        # Skip exec-config actions (build tools, not target code)
        command = " ".join(args)
        if any(p.search(command) for p in exclude_patterns):
            continue

        # Resolve source path
        if not os.path.isabs(source_file):
            source_file = os.path.join(exec_root, source_file)

        entries.append({
            "directory": exec_root,
            "command": command,
            "file": source_file,
        })

    return entries


def main() -> None:
    parser = argparse.ArgumentParser(description="Parse bazel aquery jsonproto output")
    parser.add_argument("--input", required=True, help="Path to aquery JSON file")
    parser.add_argument("--archives", required=True, help="Output file for archive paths")
    parser.add_argument("--include-dirs", required=True, help="Output file for include directories")
    parser.add_argument("--src-dir", default=".", help="Bazel workspace root (for path context)")
    parser.add_argument("--exclude", action="append", default=[], help="Regex patterns to exclude")
    parser.add_argument("--compile-commands", default="", help="Output compile_commands.json path")
    parser.add_argument("--exec-root", default="", help="Bazel execution root for compile_commands")
    args = parser.parse_args()

    with open(args.input) as f:
        data = json.load(f)

    link_inputs, include_dirs = parse_aquery(data)

    # Apply exclusion filters
    exclude_regexes = [re.compile(p) for p in args.exclude]
    for regex in exclude_regexes:
        link_inputs = [p for p in link_inputs if not regex.search(p)]

    with open(args.archives, "w") as f:
        f.write("\n".join(link_inputs))

    with open(args.include_dirs, "w") as f:
        f.write("\n".join(include_dirs))

    # Generate compile_commands.json
    if args.compile_commands and args.exec_root:
        entries = generate_compile_commands(data, args.exec_root, exclude_regexes)
        with open(args.compile_commands, "w") as f:
            json.dump(entries, f, indent=2)
        print(f"BazelAqueryParse: wrote {len(entries)} compile commands", file=sys.stderr)

    archives = [p for p in link_inputs if p.endswith(".a")]
    objects = [p for p in link_inputs if p.endswith(".o")]
    print(f"BazelAqueryParse: {len(archives)} archives, {len(objects)} objects, {len(include_dirs)} include dirs", file=sys.stderr)


if __name__ == "__main__":
    main()
