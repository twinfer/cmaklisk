# cmaklisk.cmake
#
# CMake module for importing Bazel-built C/C++ libraries.
# Clones a Bazel project, builds specified targets with Bazel (via Bazelisk),
# packages the result as a single static library, and exports an IMPORTED
# CMake target.
#
# Requirements:
#   - CMake 3.25+
#   - Bazel or Bazelisk (auto-downloaded if not found)
#   - Python 3 (optional, speeds up aquery parsing)
#
# Usage:
#   include(cmaklisk)
#
#   cmaklisk(
#       NAME         cel-cpp
#       GIT_REPOSITORY https://github.com/google/cel-cpp.git
#       GIT_TAG      0fc37152
#       TARGETS      //eval/public:cel_expression //parser:parser
#       BAZEL_ARGS   --compilation_mode=opt
#       NAMESPACE    cel
#       LINK_LIBRARIES "-framework CoreFoundation"
#       EXCLUDE_ARTIFACTS "-exec-"
#       EXT_ARGS     GIT_SHALLOW TRUE PATCH_COMMAND ...
#   )
#
#   target_link_libraries(my_app PRIVATE cel::cel)

include_guard(GLOBAL)
cmake_minimum_required(VERSION 3.25)

include(ExternalProject)
include("${CMAKE_CURRENT_LIST_DIR}/BazeliskBootstrap.cmake")

# Eagerly ensure Bazel is available at include time
_cmaklisk_ensure_bazel()

# Find optional Python for fast aquery parsing
find_program(_CMAKLISK_PYTHON NAMES python3 python)

function(cmaklisk)
    # --- Parse arguments ---
    cmake_parse_arguments(
        PARSE_ARGV 0 ARG
        ""                                                   # options
        "NAME;GIT_REPOSITORY;GIT_TAG;NAMESPACE"              # one-value
        "TARGETS;BAZEL_ARGS;LINK_LIBRARIES;EXCLUDE_ARTIFACTS;EXT_ARGS" # multi-value
    )

    # --- Validate required args ---
    foreach(_required NAME GIT_REPOSITORY GIT_TAG TARGETS)
        if(NOT ARG_${_required})
            message(FATAL_ERROR "cmaklisk: ${_required} is required")
        endif()
    endforeach()

    # --- Compute paths ---
    set(_prefix "${CMAKE_BINARY_DIR}/${ARG_NAME}")
    set(_src_dir "${_prefix}/src/${ARG_NAME}_ext")
    set(_install_dir "${_prefix}/install")
    set(_static_lib "${_install_dir}/lib/lib${ARG_NAME}.a")

    # --- Determine namespace ---
    if(NOT ARG_NAMESPACE)
        set(ARG_NAMESPACE "${ARG_NAME}")
    endif()
    set(_target_name "${ARG_NAMESPACE}::${ARG_NAMESPACE}")

    # --- Default exclude patterns ---
    if(NOT ARG_EXCLUDE_ARTIFACTS)
        set(ARG_EXCLUDE_ARTIFACTS "-exec-")
    endif()

    # --- Build the INSTALL_COMMAND ---
    # Pass all context to BazelInstall.cmake via -D variables.
    # Semicolon-separated lists are passed as-is (CMake handles this in -P mode).
    set(_install_script "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/BazelInstall.cmake")
    set(_aquery_parser "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/BazelAqueryParse.py")

    set(_install_cmd
        "${CMAKE_COMMAND}"
        "-DBAZEL_EXECUTABLE=${BAZEL_EXECUTABLE}"
        "-DSRC_DIR=${_src_dir}"
        "-DINSTALL_DIR=${_install_dir}"
        "-DTARGET_EXPR=${ARG_TARGETS}"
        "-DBAZEL_ARGS=${ARG_BAZEL_ARGS}"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        "-DEXCLUDE_PATTERNS=${ARG_EXCLUDE_ARTIFACTS}"
        "-DLIB_NAME=${ARG_NAME}"
    )

    # Pass Python and parser script if available
    if(_CMAKLISK_PYTHON AND EXISTS "${_aquery_parser}")
        list(APPEND _install_cmd
            "-DPYTHON_EXECUTABLE=${_CMAKLISK_PYTHON}"
            "-DAQUERY_PARSER=${_aquery_parser}"
        )
    endif()

    list(APPEND _install_cmd "-P" "${_install_script}")

    # --- Build the BUILD_COMMAND ---
    set(_build_cmd "${BAZEL_EXECUTABLE}" build --noshow_progress --curses=no)
    if(ARG_BAZEL_ARGS)
        list(APPEND _build_cmd ${ARG_BAZEL_ARGS})
    endif()
    list(APPEND _build_cmd ${ARG_TARGETS})

    # --- ExternalProject: clone + build with Bazel ---
    ExternalProject_Add(${ARG_NAME}_ext
        GIT_REPOSITORY  ${ARG_GIT_REPOSITORY}
        GIT_TAG         ${ARG_GIT_TAG}
        PREFIX          ${_prefix}
        UPDATE_DISCONNECTED TRUE
        CONFIGURE_COMMAND ""
        BUILD_COMMAND     ${_build_cmd}
        BUILD_IN_SOURCE   TRUE
        INSTALL_COMMAND   ${_install_cmd}
        LOG_BUILD         TRUE
        LOG_INSTALL       TRUE
        ${ARG_EXT_ARGS}
    )

    # --- Create IMPORTED target ---
    # Pre-create include dir so CMake's path validation passes at configure time.
    file(MAKE_DIRECTORY "${_install_dir}/include")

    add_library(${_target_name} STATIC IMPORTED GLOBAL)
    set_target_properties(${_target_name} PROPERTIES
        IMPORTED_LOCATION "${_static_lib}"
        INTERFACE_INCLUDE_DIRECTORIES "${_install_dir}/include"
        INTERFACE_SYSTEM_INCLUDE_DIRECTORIES "${_install_dir}/include"
    )

    if(ARG_LINK_LIBRARIES)
        set_property(TARGET ${_target_name} APPEND PROPERTY
            INTERFACE_LINK_LIBRARIES ${ARG_LINK_LIBRARIES})
    endif()

    add_dependencies(${_target_name} ${ARG_NAME}_ext)

    message(STATUS "cmaklisk: configured ${_target_name} from ${ARG_GIT_REPOSITORY} @ ${ARG_GIT_TAG}")
endfunction()
