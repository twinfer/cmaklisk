cmake_minimum_required(VERSION 3.25)
project(cmaklisk VERSION 0.1.0 LANGUAGES NONE)

# cmaklisk — CMake module for importing Bazel-built C/C++ libraries.
#
# Consumption methods:
#
#   1. CPM / FetchContent:
#      CPMAddPackage("gh:twinfer/cmaklisk@0.1.0")
#      include(${cmaklisk_SOURCE_DIR}/cmake/cmaklisk.cmake)
#
#   2. Installed:
#      find_package(cmaklisk REQUIRED)
#      include(cmaklisk)

# --- Install module files ---
install(
    FILES
        cmake/cmaklisk.cmake
        cmake/BazeliskBootstrap.cmake
        cmake/BazelAqueryParse.py
        cmake/BazelInstall.cmake
    DESTINATION lib/cmake/cmaklisk
)

# Generate a minimal config file so find_package(cmaklisk) works
install(CODE "
    file(WRITE \"\${CMAKE_INSTALL_PREFIX}/lib/cmake/cmaklisk/cmakliskConfig.cmake\"
        \"# cmaklisk - CMake module for importing Bazel-built libraries\\n\"
        \"list(APPEND CMAKE_MODULE_PATH \\\"\\\${CMAKE_CURRENT_LIST_DIR}\\\")\\n\"
    )
")

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR AND BUILD_TESTING)
    enable_testing()
    add_subdirectory(tests)
endif()
