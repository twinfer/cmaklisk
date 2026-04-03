# cmaklisk

CMake module for importing Bazel-built C/C++ libraries. One function call to clone, build, package, and link any Bazel project as a static library in your CMake build.

Auto-downloads [Bazelisk](https://github.com/bazelbuild/bazelisk) if Bazel isn't installed.

## Quick Start

### Via CPM (recommended)

```cmake
# Download cmaklisk
CPMAddPackage("gh:twinfer/cmaklisk@0.1.0")
include(${cmaklisk_SOURCE_DIR}/cmake/cmaklisk.cmake)

# Import a Bazel library
cmaklisk(
    NAME         cel-cpp
    GIT_REPOSITORY https://github.com/google/cel-cpp.git
    GIT_TAG      0fc37152
    TARGETS      //eval/public:cel_expression //parser:parser
    BAZEL_ARGS   --compilation_mode=opt
    NAMESPACE    cel
    LINK_LIBRARIES "$<$<PLATFORM_ID:Darwin>:-framework CoreFoundation>"
)

target_link_libraries(my_app PRIVATE cel::cel)
```

### Via FetchContent

```cmake
include(FetchContent)
FetchContent_Declare(cmaklisk GIT_REPOSITORY https://github.com/twinfer/cmaklisk.git GIT_TAG v0.1.0)
FetchContent_MakeAvailable(cmaklisk)
include(${cmaklisk_SOURCE_DIR}/cmake/cmaklisk.cmake)
```

## API

```cmake
cmaklisk(
    NAME <name>                    # Required. Library name (used for target and paths).
    GIT_REPOSITORY <url>           # Required. Git URL to clone.
    GIT_TAG <tag>                  # Required. Commit hash, tag, or branch.
    TARGETS <target>...            # Required. Bazel targets to build.
    BAZEL_ARGS <arg>...            # Optional. Extra args for `bazel build`.
    NAMESPACE <ns>                 # Optional. Target namespace (default: NAME).
    LINK_LIBRARIES <lib>...        # Optional. Extra link libraries for the target.
    EXCLUDE_ARTIFACTS <regex>...   # Optional. Patterns to exclude from archive merge.
    EXT_ARGS <arg>...              # Optional. Extra args passed to ExternalProject_Add.
)
```

`EXT_ARGS` passes any additional options directly to `ExternalProject_Add`, e.g.:

```cmake
cmaklisk(
    NAME cel-cpp
    ...
    EXT_ARGS
        PATCH_COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_SOURCE_DIR}/feel_parser <SOURCE_DIR>/feel_parser
        GIT_SHALLOW TRUE
)
```

Creates an `IMPORTED STATIC` target named `<namespace>::<namespace>`.

## How It Works

1. **Bazelisk bootstrap** -- finds `bazelisk`/`bazel` on PATH, or downloads Bazelisk automatically
2. **ExternalProject** -- clones the repo and runs `bazel build` at build time (not configure time)
3. **`bazel aquery --output=jsonproto`** -- queries the action graph to discover exact archive/object paths and include directories (replaces brittle globbing)
4. **Archive merge** -- combines all `.a` and `.o` files into a single fat static library (`libtool` on macOS, `ar` on Linux)
5. **Header collection** -- copies headers from aquery-discovered include dirs (workspace root, external deps, virtual includes, generated headers)

### Aquery parsing

The aquery JSON is parsed using a **layered approach**:
- **Python (fast path)** -- `BazelAqueryParse.py` processes the JSON natively when `python3` is available
- **Pure CMake (fallback)** -- `string(JSON)` with a flatten-and-prefix strategy indexes `pathFragments` and `artifacts` by ID for O(1) lookup

## Requirements

- CMake 3.25+
- macOS (arm64, x86_64) or Linux (amd64, arm64)
- Python 3 (optional, speeds up aquery parsing)
- Bazel or Bazelisk (auto-downloaded if not found)

## Build Layout

For `cmaklisk(NAME cel-cpp ...)`, files are placed under:

```
${CMAKE_BINARY_DIR}/cel-cpp/
  src/cel-cpp_ext/        # Bazel workspace (ExternalProject source)
  install/
    lib/libcel-cpp.a      # Merged fat static library
    include/              # Collected headers
```

## Testing

```sh
cmake -B build-test -S tests
cmake --build build-test
./build-test/test_consumer   # prints "Hello, cmaklisk!"
```

## License

MIT
