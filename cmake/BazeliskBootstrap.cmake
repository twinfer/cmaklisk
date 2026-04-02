# BazeliskBootstrap.cmake
#
# Ensures a Bazel (or Bazelisk) executable is available.
# If neither is found on PATH, downloads Bazelisk automatically.
#
# After calling _cmaklisk_ensure_bazel(), the variable
# BAZEL_EXECUTABLE is set in the caller's scope.

include_guard(GLOBAL)

set(_BAZELISK_VERSION "1.25.0")

# Known SHA256 hashes for Bazelisk v1.25.0 binaries.
set(_BAZELISK_HASH_darwin_arm64  "SHA256=c94e0383e0e0b6b498142882648e5ef03e tried2d6a28553a69e95330caa85a2e365")
set(_BAZELISK_HASH_darwin_amd64  "SHA256=placeholder_darwin_amd64")
set(_BAZELISK_HASH_linux_amd64   "SHA256=placeholder_linux_amd64")
set(_BAZELISK_HASH_linux_arm64   "SHA256=placeholder_linux_arm64")

function(_cmaklisk_ensure_bazel)
    # Already found?
    if(BAZEL_EXECUTABLE)
        return()
    endif()

    # Search PATH
    find_program(BAZEL_EXECUTABLE NAMES bazelisk bazel)
    if(BAZEL_EXECUTABLE)
        message(STATUS "cmaklisk: found ${BAZEL_EXECUTABLE}")
        set(BAZEL_EXECUTABLE "${BAZEL_EXECUTABLE}" PARENT_SCOPE)
        return()
    endif()

    # --- Auto-download Bazelisk ---
    message(STATUS "cmaklisk: bazelisk/bazel not found, downloading bazelisk v${_BAZELISK_VERSION}...")

    # Detect OS
    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        set(_os "darwin")
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
        set(_os "linux")
    else()
        message(FATAL_ERROR
            "cmaklisk: unsupported host OS '${CMAKE_HOST_SYSTEM_NAME}'.\n"
            "  Supported: Darwin, Linux.\n"
            "  Install bazelisk manually: https://github.com/bazelbuild/bazelisk")
    endif()

    # Detect architecture
    execute_process(
        COMMAND uname -m
        OUTPUT_VARIABLE _uname_arch
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
    )
    if(_uname_arch STREQUAL "arm64" OR _uname_arch STREQUAL "aarch64")
        set(_arch "arm64")
    elseif(_uname_arch MATCHES "x86_64|amd64")
        set(_arch "amd64")
    else()
        message(FATAL_ERROR
            "cmaklisk: unsupported architecture '${_uname_arch}'.\n"
            "  Supported: arm64/aarch64, x86_64/amd64.\n"
            "  Install bazelisk manually: https://github.com/bazelbuild/bazelisk")
    endif()

    set(_bazelisk_url
        "https://github.com/bazelbuild/bazelisk/releases/download/v${_BAZELISK_VERSION}/bazelisk-${_os}-${_arch}")
    set(_bazelisk_dir "${CMAKE_BINARY_DIR}/_bazelisk")
    set(_bazelisk_path "${_bazelisk_dir}/bazelisk")

    if(NOT EXISTS "${_bazelisk_path}")
        file(MAKE_DIRECTORY "${_bazelisk_dir}")

        # Download (hash verification is optional — remove EXPECTED_HASH if hashes aren't populated)
        set(_hash_var "_BAZELISK_HASH_${_os}_${_arch}")
        set(_expected_hash "${${_hash_var}}")

        if(_expected_hash AND NOT _expected_hash MATCHES "placeholder")
            file(DOWNLOAD "${_bazelisk_url}" "${_bazelisk_path}"
                EXPECTED_HASH ${_expected_hash}
                STATUS _dl_status
                SHOW_PROGRESS
            )
        else()
            # No hash available — download without verification
            message(STATUS "cmaklisk: downloading without hash verification (update hashes for pinned builds)")
            file(DOWNLOAD "${_bazelisk_url}" "${_bazelisk_path}"
                STATUS _dl_status
                SHOW_PROGRESS
            )
        endif()

        list(GET _dl_status 0 _dl_rc)
        if(NOT _dl_rc EQUAL 0)
            list(GET _dl_status 1 _dl_msg)
            file(REMOVE "${_bazelisk_path}")
            message(FATAL_ERROR "cmaklisk: failed to download bazelisk: ${_dl_msg}")
        endif()

        file(CHMOD "${_bazelisk_path}" PERMISSIONS
            OWNER_READ OWNER_WRITE OWNER_EXECUTE
            GROUP_READ GROUP_EXECUTE
            WORLD_READ WORLD_EXECUTE
        )
    endif()

    message(STATUS "cmaklisk: using downloaded bazelisk at ${_bazelisk_path}")
    set(BAZEL_EXECUTABLE "${_bazelisk_path}" PARENT_SCOPE)
endfunction()
