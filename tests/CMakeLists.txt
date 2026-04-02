cmake_minimum_required(VERSION 3.25)
project(cmaklisk_test LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Include the cmaklisk module
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/cmaklisk.cmake")

message(STATUS "cmaklisk test: BAZEL_EXECUTABLE = ${BAZEL_EXECUTABLE}")

# Import the test Bazel library via file:// URL to the local git repo
set(_test_workspace "${CMAKE_CURRENT_SOURCE_DIR}/test_workspace")

cmaklisk(
    NAME         testlib
    GIT_REPOSITORY "file://${_test_workspace}"
    GIT_TAG      main
    TARGETS      //:testlib
    NAMESPACE    testlib
)

# Build a consumer executable that links to the Bazel-built library
add_executable(test_consumer "${_test_workspace}/main.cc")
target_link_libraries(test_consumer PRIVATE testlib::testlib)
