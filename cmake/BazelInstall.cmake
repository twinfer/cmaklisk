# BazelInstall.cmake
#
# Build-time install script invoked by ExternalProject_Add INSTALL_COMMAND.
# Runs bazel aquery, parses the output to discover archives and include dirs,
# merges archives into a fat static library, and copies headers.
#
# Input variables (passed via -D):
#   BAZEL_EXECUTABLE  - path to bazel/bazelisk
#   SRC_DIR           - Bazel workspace root (ExternalProject source dir)
#   INSTALL_DIR       - output install prefix
#   TARGET_EXPR       - Bazel targets (semicolon-separated list)
#   BAZEL_ARGS        - extra bazel build args (semicolon-separated)
#   CMAKE_SYSTEM_NAME - Darwin or Linux
#   EXCLUDE_PATTERNS  - semicolon-separated regexes to exclude archives
#   AQUERY_PARSER     - path to BazelAqueryParse.py (optional)
#   PYTHON_EXECUTABLE - path to python3 (optional)
#   LIB_NAME          - output library name (e.g., "cel-cpp" → libcel-cpp.a)
#   LIST_SEP          - placeholder used to escape semicolons through ExternalProject

cmake_minimum_required(VERSION 3.21)

# Restore semicolons from escaped list values (ExternalProject splits on ;)
if(LIST_SEP)
    string(REPLACE "${LIST_SEP}" ";" TARGET_EXPR "${TARGET_EXPR}")
    string(REPLACE "${LIST_SEP}" ";" BAZEL_ARGS "${BAZEL_ARGS}")
    string(REPLACE "${LIST_SEP}" ";" EXCLUDE_PATTERNS "${EXCLUDE_PATTERNS}")
endif()

message(STATUS "cmaklisk: packaging ${LIB_NAME}...")

file(MAKE_DIRECTORY "${INSTALL_DIR}/lib")
file(MAKE_DIRECTORY "${INSTALL_DIR}/include")

# ---------------------------------------------------------------------------
# Step 1: Run bazel aquery to discover artifacts
# ---------------------------------------------------------------------------

# Build the target union expression for aquery: //a + //b + //c
list(JOIN TARGET_EXPR " + " _aquery_targets)

set(_aquery_cmd
    "${BAZEL_EXECUTABLE}" aquery
    --output=jsonproto
    --noshow_progress
    --curses=no
)
# Append any extra bazel args (startup options, configs, etc.)
if(BAZEL_ARGS)
    list(APPEND _aquery_cmd ${BAZEL_ARGS})
endif()
list(APPEND _aquery_cmd "deps(${_aquery_targets})")

# Get the Bazel execution root for resolving artifact paths
execute_process(
    COMMAND "${BAZEL_EXECUTABLE}" info execution_root
        --noshow_progress --curses=no
    WORKING_DIRECTORY "${SRC_DIR}"
    OUTPUT_VARIABLE _exec_root
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _info_rc
)
if(NOT _info_rc EQUAL 0)
    # Fallback to SRC_DIR
    set(_exec_root "${SRC_DIR}")
endif()
message(STATUS "cmaklisk: execution root: ${_exec_root}")

set(_aquery_json_file "${INSTALL_DIR}/_aquery_input.json")

message(STATUS "cmaklisk: running aquery...")
execute_process(
    COMMAND ${_aquery_cmd}
    WORKING_DIRECTORY "${SRC_DIR}"
    OUTPUT_FILE "${_aquery_json_file}"
    ERROR_VARIABLE _aquery_err
    RESULT_VARIABLE _aquery_rc
)
if(NOT _aquery_rc EQUAL 0)
    message(FATAL_ERROR "cmaklisk: bazel aquery failed (rc=${_aquery_rc}):\n${_aquery_err}")
endif()

# ---------------------------------------------------------------------------
# Step 2: Parse aquery JSON — try Python first, fall back to pure CMake
# ---------------------------------------------------------------------------

set(_archives_file "${INSTALL_DIR}/_archives.txt")
set(_include_dirs_file "${INSTALL_DIR}/_include_dirs.txt")
set(_used_python FALSE)

if(PYTHON_EXECUTABLE AND AQUERY_PARSER AND EXISTS "${AQUERY_PARSER}")
    message(STATUS "cmaklisk: parsing aquery with Python (fast path)")
    # Build exclude args
    set(_exclude_args "")
    if(EXCLUDE_PATTERNS)
        foreach(_pat IN LISTS EXCLUDE_PATTERNS)
            list(APPEND _exclude_args "--exclude=${_pat}")
        endforeach()
    endif()

    execute_process(
        COMMAND "${PYTHON_EXECUTABLE}" "${AQUERY_PARSER}"
            --input "${_aquery_json_file}"
            --archives "${_archives_file}"
            --include-dirs "${_include_dirs_file}"
            --src-dir "${SRC_DIR}"
            ${_exclude_args}
        RESULT_VARIABLE _py_rc
        ERROR_VARIABLE _py_err
    )
    if(_py_rc EQUAL 0)
        set(_used_python TRUE)
    else()
        message(WARNING "cmaklisk: Python parser failed, falling back to CMake:\n${_py_err}")
    endif()
endif()

if(NOT _used_python)
    message(STATUS "cmaklisk: parsing aquery with CMake string(JSON) (flatten-and-prefix)")

    file(READ "${_aquery_json_file}" _aquery_json)

    # --- Build path fragment index: _FRAG_<id>_LABEL, _FRAG_<id>_PARENT ---
    string(JSON _frag_count LENGTH "${_aquery_json}" "pathFragments")
    if(NOT _frag_count)
        set(_frag_count 0)
    endif()
    message(STATUS "cmaklisk: indexing ${_frag_count} path fragments...")
    math(EXPR _frag_last "${_frag_count} - 1")
    if(_frag_count GREATER 0)
        foreach(_i RANGE 0 ${_frag_last})
            string(JSON _fid GET "${_aquery_json}" "pathFragments" ${_i} "id")
            string(JSON _flabel GET "${_aquery_json}" "pathFragments" ${_i} "label")
            set(_FRAG_${_fid}_LABEL "${_flabel}")
            # parentId may not exist (root fragments)
            string(JSON _fparent ERROR_VARIABLE _perr GET "${_aquery_json}" "pathFragments" ${_i} "parentId")
            if(_perr)
                set(_FRAG_${_fid}_PARENT "0")
            else()
                set(_FRAG_${_fid}_PARENT "${_fparent}")
            endif()
        endforeach()
    endif()

    # --- Build artifact index: _ART_<id>_PATH ---
    # Resolve each artifact's path by walking the fragment parent chain.
    string(JSON _art_count LENGTH "${_aquery_json}" "artifacts")
    if(NOT _art_count)
        set(_art_count 0)
    endif()
    message(STATUS "cmaklisk: resolving ${_art_count} artifact paths...")
    math(EXPR _art_last "${_art_count} - 1")
    if(_art_count GREATER 0)
        foreach(_i RANGE 0 ${_art_last})
            string(JSON _aid GET "${_aquery_json}" "artifacts" ${_i} "id")
            string(JSON _afrag GET "${_aquery_json}" "artifacts" ${_i} "pathFragmentId")

            # Walk parent chain to build full path
            set(_parts "")
            set(_cur_frag "${_afrag}")
            while(_cur_frag AND NOT _cur_frag STREQUAL "0")
                if(DEFINED _FRAG_${_cur_frag}_LABEL)
                    list(PREPEND _parts "${_FRAG_${_cur_frag}_LABEL}")
                    set(_cur_frag "${_FRAG_${_cur_frag}_PARENT}")
                else()
                    break()
                endif()
            endwhile()
            list(JOIN _parts "/" _resolved_path)
            set(_ART_${_aid}_PATH "${_resolved_path}")
        endforeach()
    endif()

    # --- Extract archive paths from CppArchive actions ---
    string(JSON _action_count LENGTH "${_aquery_json}" "actions")
    if(NOT _action_count)
        set(_action_count 0)
    endif()
    message(STATUS "cmaklisk: scanning ${_action_count} actions...")

    # Collect both .a and .o — Bazel only materializes the direct target's .a,
    # transitive deps are available as .o files.
    set(_link_input_paths "")
    set(_include_dirs "")

    math(EXPR _action_last "${_action_count} - 1")
    if(_action_count GREATER 0)
        foreach(_i RANGE 0 ${_action_last})
            string(JSON _mnemonic GET "${_aquery_json}" "actions" ${_i} "mnemonic")

            if(_mnemonic STREQUAL "CppArchive" OR
               _mnemonic STREQUAL "CppCompile" OR
               _mnemonic STREQUAL "ObjcCompile")
                # Get output .a and .o artifact IDs
                string(JSON _out_count LENGTH "${_aquery_json}" "actions" ${_i} "outputIds")
                if(_out_count GREATER 0)
                    math(EXPR _out_last "${_out_count} - 1")
                    foreach(_j RANGE 0 ${_out_last})
                        string(JSON _out_id GET "${_aquery_json}" "actions" ${_i} "outputIds" ${_j})
                        if(DEFINED _ART_${_out_id}_PATH)
                            set(_path "${_ART_${_out_id}_PATH}")
                            if(_path MATCHES "\\.(a|o)$")
                                list(APPEND _link_input_paths "${_path}")
                            endif()
                        endif()
                    endforeach()
                endif()
            endif()

            if(_mnemonic STREQUAL "CppCompile" OR _mnemonic STREQUAL "ObjcCompile")
                # Extract -I and -iquote flags from arguments
                string(JSON _arg_count ERROR_VARIABLE _argerr LENGTH "${_aquery_json}" "actions" ${_i} "arguments")
                if(NOT _argerr AND _arg_count GREATER 0)
                    math(EXPR _arg_last "${_arg_count} - 1")
                    set(_next_is_include FALSE)
                    set(_next_is_iquote FALSE)
                    set(_next_is_isystem FALSE)
                    foreach(_k RANGE 0 ${_arg_last})
                        string(JSON _arg GET "${_aquery_json}" "actions" ${_i} "arguments" ${_k})
                        if(_next_is_include)
                            list(APPEND _include_dirs "${_arg}")
                            set(_next_is_include FALSE)
                        elseif(_next_is_iquote)
                            list(APPEND _include_dirs "${_arg}")
                            set(_next_is_iquote FALSE)
                        elseif(_next_is_isystem)
                            list(APPEND _include_dirs "${_arg}")
                            set(_next_is_isystem FALSE)
                        elseif(_arg STREQUAL "-I")
                            set(_next_is_include TRUE)
                        elseif(_arg STREQUAL "-iquote")
                            set(_next_is_iquote TRUE)
                        elseif(_arg STREQUAL "-isystem")
                            set(_next_is_isystem TRUE)
                        elseif(_arg MATCHES "^-I(.+)" AND NOT _arg MATCHES "^-isystem")
                            list(APPEND _include_dirs "${CMAKE_MATCH_1}")
                        elseif(_arg MATCHES "^-iquote(.+)")
                            list(APPEND _include_dirs "${CMAKE_MATCH_1}")
                        elseif(_arg MATCHES "^-isystem(.+)")
                            list(APPEND _include_dirs "${CMAKE_MATCH_1}")
                        endif()
                    endforeach()
                endif()
            endif()
        endforeach()
    endif()

    # Apply exclusion filters
    if(EXCLUDE_PATTERNS AND _link_input_paths)
        foreach(_pat IN LISTS EXCLUDE_PATTERNS)
            list(FILTER _link_input_paths EXCLUDE REGEX "${_pat}")
        endforeach()
    endif()

    # Deduplicate
    list(REMOVE_DUPLICATES _link_input_paths)
    list(REMOVE_DUPLICATES _include_dirs)

    # Write output files
    list(JOIN _link_input_paths "\n" _archives_content)
    file(WRITE "${_archives_file}" "${_archives_content}")

    list(JOIN _include_dirs "\n" _includes_content)
    file(WRITE "${_include_dirs_file}" "${_includes_content}")
endif()

# ---------------------------------------------------------------------------
# Step 3: Read parsed results
# ---------------------------------------------------------------------------

file(STRINGS "${_archives_file}" ALL_LINK_INPUTS)
file(STRINGS "${_include_dirs_file}" ALL_INCLUDE_DIRS)

# Separate .a and .o files
set(ALL_ARCHIVES "")
set(ALL_OBJECTS "")
foreach(_f IN LISTS ALL_LINK_INPUTS)
    if(_f MATCHES "\\.a$")
        list(APPEND ALL_ARCHIVES "${_f}")
    elseif(_f MATCHES "\\.o$")
        list(APPEND ALL_OBJECTS "${_f}")
    endif()
endforeach()

list(LENGTH ALL_ARCHIVES ARCHIVE_COUNT)
list(LENGTH ALL_OBJECTS OBJECT_COUNT)
list(LENGTH ALL_INCLUDE_DIRS INCLUDE_DIR_COUNT)
message(STATUS "cmaklisk: found ${ARCHIVE_COUNT} archives, ${OBJECT_COUNT} objects, ${INCLUDE_DIR_COUNT} include dirs")

math(EXPR _total_inputs "${ARCHIVE_COUNT} + ${OBJECT_COUNT}")
if(_total_inputs EQUAL 0)
    message(FATAL_ERROR "cmaklisk: no archives found. Check TARGETS and BAZEL_ARGS.")
endif()

# ---------------------------------------------------------------------------
# Step 4: Merge .a archives and .o objects into a single fat static library
# ---------------------------------------------------------------------------

set(_fat_lib "${INSTALL_DIR}/lib/lib${LIB_NAME}.a")
set(_filelist "${INSTALL_DIR}/lib/_filelist.txt")

# Resolve paths — try execution root first, then SRC_DIR
set(_abs_inputs "")
foreach(_f IN LISTS ALL_ARCHIVES ALL_OBJECTS)
    if(IS_ABSOLUTE "${_f}")
        list(APPEND _abs_inputs "${_f}")
    elseif(EXISTS "${_exec_root}/${_f}")
        list(APPEND _abs_inputs "${_exec_root}/${_f}")
    elseif(EXISTS "${SRC_DIR}/${_f}")
        list(APPEND _abs_inputs "${SRC_DIR}/${_f}")
    endif()
endforeach()

# Verify inputs exist, filter out missing
set(_valid_inputs "")
set(_missing_count 0)
foreach(_f IN LISTS _abs_inputs)
    if(EXISTS "${_f}")
        list(APPEND _valid_inputs "${_f}")
    else()
        math(EXPR _missing_count "${_missing_count} + 1")
    endif()
endforeach()
if(_missing_count GREATER 0)
    message(WARNING "cmaklisk: ${_missing_count} files not found on disk (skipped)")
endif()
set(_abs_inputs "${_valid_inputs}")

list(LENGTH _abs_inputs _input_count)
message(STATUS "cmaklisk: merging ${_input_count} files into lib${LIB_NAME}.a")

# Write filelist (one path per line) — works for both .a and .o
file(WRITE "${_filelist}" "")
foreach(_f IN LISTS _abs_inputs)
    file(APPEND "${_filelist}" "${_f}\n")
endforeach()

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    # macOS libtool: -static handles both .a and .o, deduplicates symbols
    execute_process(
        COMMAND libtool -static -o "${_fat_lib}" -filelist "${_filelist}"
        RESULT_VARIABLE _ar_rc
        ERROR_VARIABLE _ar_err
    )
else()
    # Linux: ar rcs for .o files first, then merge .a files via MRI script
    # Separate into archives and objects
    set(_linux_archives "")
    set(_linux_objects "")
    foreach(_f IN LISTS _abs_inputs)
        if(_f MATCHES "\\.a$")
            list(APPEND _linux_archives "${_f}")
        else()
            list(APPEND _linux_objects "${_f}")
        endif()
    endforeach()

    # Start with objects
    if(_linux_objects)
        execute_process(
            COMMAND ar rcs "${_fat_lib}" ${_linux_objects}
            RESULT_VARIABLE _ar_rc
            ERROR_VARIABLE _ar_err
        )
    endif()

    # Merge in archives via MRI
    if(_linux_archives AND (NOT DEFINED _ar_rc OR _ar_rc EQUAL 0))
        set(_mri_script "${INSTALL_DIR}/lib/_combine.mri")
        if(_linux_objects)
            file(WRITE "${_mri_script}" "OPEN ${_fat_lib}\n")
        else()
            file(WRITE "${_mri_script}" "CREATE ${_fat_lib}\n")
        endif()
        foreach(_ar IN LISTS _linux_archives)
            file(APPEND "${_mri_script}" "ADDLIB ${_ar}\n")
        endforeach()
        file(APPEND "${_mri_script}" "SAVE\nEND\n")
        execute_process(
            COMMAND ar -M
            INPUT_FILE "${_mri_script}"
            RESULT_VARIABLE _ar_rc
            ERROR_VARIABLE _ar_err
        )
        file(REMOVE "${_mri_script}")
    endif()
endif()

file(REMOVE "${_filelist}")

if(NOT _ar_rc EQUAL 0)
    message(FATAL_ERROR "cmaklisk: archive merge failed (rc=${_ar_rc}):\n${_ar_err}")
endif()

file(SIZE "${_fat_lib}" _lib_size)
math(EXPR _lib_size_mb "${_lib_size} / 1048576")
message(STATUS "cmaklisk: created lib${LIB_NAME}.a (${_lib_size_mb} MB)")

# ---------------------------------------------------------------------------
# Step 5: Copy headers based on aquery-discovered include directories
# ---------------------------------------------------------------------------

message(STATUS "cmaklisk: copying headers from ${INCLUDE_DIR_COUNT} include dirs...")

# Find the Bazel external directory via convenience symlink, resolve to real path
set(_bazel_external "")
file(GLOB _bazel_links "${SRC_DIR}/bazel-*/external")
foreach(_link IN LISTS _bazel_links)
    string(FIND "${_link}" "bazel-bin" _is_bin)
    if(_is_bin EQUAL -1)
        file(REAL_PATH "${_link}" _bazel_external)
        break()
    endif()
endforeach()
if(_bazel_external)
    message(STATUS "cmaklisk: using Bazel external: ${_bazel_external}")
endif()

foreach(_inc_dir IN LISTS ALL_INCLUDE_DIRS)
    # Skip empty
    if(NOT _inc_dir)
        continue()
    endif()

    # Classify the include directory
    if(_inc_dir STREQUAL ".")
        # Workspace root — copy headers from source tree
        # First, copy any .h files directly in SRC_DIR
        file(GLOB _root_headers "${SRC_DIR}/*.h")
        foreach(_h IN LISTS _root_headers)
            file(COPY "${_h}" DESTINATION "${INSTALL_DIR}/include")
        endforeach()
        # Then, copy subdirectories that contain .h files
        file(GLOB _top_entries LIST_DIRECTORIES true "${SRC_DIR}/*")
        foreach(_entry IN LISTS _top_entries)
            if(IS_DIRECTORY "${_entry}")
                get_filename_component(_dirname "${_entry}" NAME)
                # Skip bazel-* symlinks, hidden dirs, and build artifacts
                if(_dirname MATCHES "^(bazel-|\\.|MODULE\\.bazel|BUILD)")
                    continue()
                endif()
                file(GLOB_RECURSE _has_headers "${_entry}/*.h")
                if(_has_headers)
                    file(COPY "${_entry}"
                        DESTINATION "${INSTALL_DIR}/include"
                        FILES_MATCHING
                        PATTERN "*.h"
                        PATTERN "*.inc"
                    )
                endif()
            endif()
        endforeach()

    elseif(_inc_dir MATCHES "^external/(.+)")
        # External dependency headers — resolve symlinks before copying
        set(_ext_path "${CMAKE_MATCH_1}")
        set(_ext_src "")
        if(_bazel_external AND EXISTS "${_bazel_external}/${_ext_path}")
            file(REAL_PATH "${_bazel_external}/${_ext_path}" _ext_src)
        endif()
        if(_ext_src AND EXISTS "${_ext_src}")
            file(COPY "${_ext_src}/"
                DESTINATION "${INSTALL_DIR}/include"
                FILES_MATCHING
                PATTERN "*.h"
                PATTERN "*.inc"
                PATTERN "BUILD" EXCLUDE
                PATTERN "BUILD.bazel" EXCLUDE
            )
        endif()

    elseif(_inc_dir MATCHES "_virtual_(includes|imports)/[^/]+/(.*)" OR
           _inc_dir MATCHES "_virtual_(includes|imports)/[^/]+$")
        # Virtual includes/imports from bazel-bin
        set(_vi_path "${SRC_DIR}/${_inc_dir}")
        if(EXISTS "${_vi_path}")
            file(GLOB_RECURSE _vi_headers "${_vi_path}/*.h" "${_vi_path}/*.inc")
            foreach(_h IN LISTS _vi_headers)
                # The path after _virtual_includes/<target>/ is the real include path
                string(REGEX MATCH "_virtual_(includes|imports)/[^/]+/(.*)" _match "${_h}")
                if(_match)
                    set(_rel "${CMAKE_MATCH_2}")
                    get_filename_component(_dir "${_rel}" DIRECTORY)
                    file(MAKE_DIRECTORY "${INSTALL_DIR}/include/${_dir}")
                    file(COPY "${_h}" DESTINATION "${INSTALL_DIR}/include/${_dir}")
                endif()
            endforeach()
        endif()

    elseif(_inc_dir MATCHES "^bazel-out/")
        # Generated headers (e.g., proto-generated .pb.h)
        set(_gen_path "${SRC_DIR}/${_inc_dir}")
        if(EXISTS "${_gen_path}")
            file(GLOB_RECURSE _gen_headers "${_gen_path}/*.h")
            foreach(_h IN LISTS _gen_headers)
                # Compute relative path from the include dir
                string(REPLACE "${_gen_path}/" "" _rel "${_h}")
                get_filename_component(_dir "${_rel}" DIRECTORY)
                file(MAKE_DIRECTORY "${INSTALL_DIR}/include/${_dir}")
                file(COPY "${_h}" DESTINATION "${INSTALL_DIR}/include/${_dir}")
            endforeach()
        endif()
    endif()
endforeach()

# Cleanup temp files
file(REMOVE "${_archives_file}" "${_include_dirs_file}" "${_aquery_json_file}")

message(STATUS "cmaklisk: ${LIB_NAME} install complete → ${INSTALL_DIR}")
