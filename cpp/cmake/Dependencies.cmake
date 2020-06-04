#=============================================================================
# Copyright (c) 2020, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#=============================================================================

include(ExternalProject)

##############################################################################
# - raft - (header only) -----------------------------------------------------

# Only cloned if RAFT_PATH env variable is not defined

if(DEFINED ENV{RAFT_PATH})
  message(STATUS "RAFT_PATH environment variable detected.")
  message(STATUS "RAFT_DIR set to $ENV{RAFT_PATH}")
  set(RAFT_DIR ENV{RAFT_PATH})

  ExternalProject_Add(raft
    DOWNLOAD_COMMAND  ""
    SOURCE_DIR        ${RAFT_DIR}
    CONFIGURE_COMMAND ""
    BUILD_COMMAND     ""
    INSTALL_COMMAND   "")

else(DEFINED ENV{RAFT_PATH})
  message(STATUS "RAFT_PATH environment variable NOT detected, cloning RAFT")
  set(RAFT_DIR ${CMAKE_CURRENT_BINARY_DIR}/raft CACHE STRING "Path to RAFT repo")

  ExternalProject_Add(raft
    GIT_REPOSITORY    https://github.com/rapidsai/raft.git
    GIT_TAG           b58f97f2b5382a633e43daec31b26adf52e19a3b
    PREFIX            ${RAFT_DIR}
    CONFIGURE_COMMAND ""
    BUILD_COMMAND     ""
    INSTALL_COMMAND   "")

  # Redefining RAFT_DIR so it coincides with the one inferred by env variable.
  set(RAFT_DIR ${RAFT_DIR}/src/raft/ CACHE STRING "Path to RAFT repo")
endif(DEFINED ENV{RAFT_PATH})


##############################################################################
# - cub - (header only) ------------------------------------------------------

if(NOT CUB_IS_PART_OF_CTK)
  set(CUB_DIR ${CMAKE_CURRENT_BINARY_DIR}/cub CACHE STRING "Path to cub repo")
  ExternalProject_Add(cub
    GIT_REPOSITORY    https://github.com/thrust/cub.git
    GIT_TAG           1.8.0
    PREFIX            ${CUB_DIR}
    CONFIGURE_COMMAND ""
    BUILD_COMMAND     ""
    INSTALL_COMMAND   "")
endif(NOT CUB_IS_PART_OF_CTK)

##############################################################################
# - cutlass - (header only) --------------------------------------------------

set(CUTLASS_DIR ${CMAKE_CURRENT_BINARY_DIR}/cutlass CACHE STRING
  "Path to the cutlass repo")
ExternalProject_Add(cutlass
  GIT_REPOSITORY    https://github.com/NVIDIA/cutlass.git
  GIT_TAG           v1.0.1
  PREFIX            ${CUTLASS_DIR}
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   "")

##############################################################################
# - spdlog -------------------------------------------------------------------

set(SPDLOG_DIR ${CMAKE_CURRENT_BINARY_DIR}/spdlog CACHE STRING
  "Path to spdlog install directory")
ExternalProject_Add(spdlog
  GIT_REPOSITORY    https://github.com/gabime/spdlog.git
  GIT_TAG           v1.x
  PREFIX            ${SPDLOG_DIR}
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   "")

##############################################################################
# - nvgraph ------------------------------------------------------------------

# set(NVGRAPH_DIR ${CMAKE_CURRENT_BINARY_DIR}/nvgraph CACHE STRING
#   "Path to nvgraph install directory")
# ExternalProject_Add(nvgraph
#     GIT_REPOSITORY    https://github.com/rapidsai/nvgraph.git
#     GIT_TAG           feb0c5721e6e0e27ee51b2f56fd39c7d1e805a64
#     PREFIX            ${NVGRAPH_DIR}
#     CMAKE_ARGS        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
#                       -DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}
#                       ${NVGRAPH_DIR}/src/nvgraph/cpp
#     UPDATE_COMMAND    "")

# add_library(nvgraphlib STATIC IMPORTED)

# add_dependencies(nvgraphlib nvgraph)

# set_property(TARGET nvgraphlib
#   PROPERTY IMPORTED_LOCATION ${NVGRAPH_DIR}/lib64/libnvgraph.so)

##############################################################################
# - faiss --------------------------------------------------------------------

set(FAISS_DIR ${CMAKE_CURRENT_BINARY_DIR}/faiss CACHE STRING
  "Path to FAISS source directory")
ExternalProject_Add(faiss
  GIT_REPOSITORY    https://github.com/facebookresearch/faiss.git
  GIT_TAG           v1.6.2
  CONFIGURE_COMMAND LIBS=-pthread
                    CPPFLAGS=-w
                    LDFLAGS=-L${CMAKE_INSTALL_PREFIX}/lib
                            ${CMAKE_CURRENT_BINARY_DIR}/faiss/src/faiss/configure
                            --prefix=${CMAKE_CURRENT_BINARY_DIR}/faiss
                            --with-blas=${BLAS_LIBRARIES}
                            --with-cuda=${CUDA_TOOLKIT_ROOT_DIR}
                            --with-cuda-arch=${FAISS_GPU_ARCHS}
                            -v
  PREFIX            ${FAISS_DIR}
  BUILD_COMMAND     make -j${PARALLEL_LEVEL} VERBOSE=1
  BUILD_BYPRODUCTS  ${FAISS_DIR}/lib/libfaiss.a
  INSTALL_COMMAND   make -s install > /dev/null
  UPDATE_COMMAND    ""
  BUILD_IN_SOURCE   1
  PATCH_COMMAND     patch -p1 -N < ${CMAKE_CURRENT_SOURCE_DIR}/cmake/faiss_cuda11.patch || true)

ExternalProject_Get_Property(faiss install_dir)

add_library(faisslib STATIC IMPORTED)

set_property(TARGET faisslib PROPERTY
  IMPORTED_LOCATION ${FAISS_DIR}/lib/libfaiss.a)

##############################################################################
# - treelite build -----------------------------------------------------------

set(TREELITE_DIR ${CMAKE_CURRENT_BINARY_DIR}/treelite CACHE STRING
  "Path to treelite install directory")
ExternalProject_Add(treelite
    GIT_REPOSITORY    https://github.com/dmlc/treelite.git
    GIT_TAG           6fd01e4f1890950bbcf9b124da24e886751bffe6
    PREFIX            ${TREELITE_DIR}
    CMAKE_ARGS        -DBUILD_SHARED_LIBS=OFF
                      -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
                      -DENABLE_PROTOBUF=ON
                      -DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}
    BUILD_BYPRODUCTS  ${TREELITE_DIR}/lib/libtreelite.a
                      ${TREELITE_DIR}/lib/libdmlc.a
                      ${TREELITE_DIR}/lib/libtreelite_runtime.so
    UPDATE_COMMAND    ""
    PATCH_COMMAND     patch -p1 -N < ${CMAKE_CURRENT_SOURCE_DIR}/cmake/treelite_protobuf.patch || true)

add_library(dmlclib STATIC IMPORTED)
add_library(treelitelib STATIC IMPORTED)
add_library(treelite_runtimelib SHARED IMPORTED)

set_property(TARGET dmlclib PROPERTY
  IMPORTED_LOCATION ${TREELITE_DIR}/lib/libdmlc.a)
set_property(TARGET treelitelib PROPERTY
  IMPORTED_LOCATION ${TREELITE_DIR}/lib/libtreelite.a)
set_property(TARGET treelite_runtimelib PROPERTY
  IMPORTED_LOCATION ${TREELITE_DIR}/lib/libtreelite_runtime.so)

add_dependencies(dmlclib treelite)
add_dependencies(treelitelib treelite)
add_dependencies(treelite_runtimelib treelite)

##############################################################################
# - googletest ---------------------------------------------------------------

set(GTEST_DIR ${CMAKE_CURRENT_BINARY_DIR}/googletest CACHE STRING
  "Path to googletest repo")
set(GTEST_BINARY_DIR ${PROJECT_BINARY_DIR}/googletest)
set(GTEST_INSTALL_DIR ${GTEST_BINARY_DIR}/install)
set(GTEST_LIB ${GTEST_INSTALL_DIR}/lib/libgtest_main.a)
include(ExternalProject)
ExternalProject_Add(googletest
  GIT_REPOSITORY    https://github.com/google/googletest.git
  GIT_TAG           6ce9b98f541b8bcd84c5c5b3483f29a933c4aefb
  PREFIX            ${GTEST_DIR}
  CMAKE_ARGS        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
                    -DBUILD_SHARED_LIBS=OFF
                    -DCMAKE_INSTALL_LIBDIR=lib
  BUILD_BYPRODUCTS  ${GTEST_DIR}/lib/libgtest.a
                    ${GTEST_DIR}/lib/libgtest_main.a
  UPDATE_COMMAND    "")

add_library(gtestlib STATIC IMPORTED)
add_library(gtest_mainlib STATIC IMPORTED)

set_property(TARGET gtestlib PROPERTY
  IMPORTED_LOCATION ${GTEST_DIR}/lib/libgtest.a)
set_property(TARGET gtest_mainlib PROPERTY
  IMPORTED_LOCATION ${GTEST_DIR}/lib/libgtest_main.a)

add_dependencies(gtestlib googletest)
add_dependencies(gtest_mainlib googletest)

##############################################################################
# - googlebench ---------------------------------------------------------------

set(GBENCH_DIR ${CMAKE_CURRENT_BINARY_DIR}/benchmark CACHE STRING
  "Path to google benchmark repo")
set(GBENCH_BINARY_DIR ${PROJECT_BINARY_DIR}/benchmark)
set(GBENCH_INSTALL_DIR ${GBENCH_BINARY_DIR}/install)
set(GBENCH_LIB ${GBENCH_INSTALL_DIR}/lib/libbenchmark.a)
include(ExternalProject)
ExternalProject_Add(benchmark
  GIT_REPOSITORY    https://github.com/google/benchmark.git
  GIT_TAG           bf4f2ea0bd1180b34718ac26eb79b170a4f6290e
  PREFIX            ${GBENCH_DIR}
  CMAKE_ARGS        -DBENCHMARK_ENABLE_GTEST_TESTS=OFF
                    -DBENCHMARK_ENABLE_TESTING=OFF
                    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
                    -DCMAKE_BUILD_TYPE=Release
                    -DCMAKE_INSTALL_LIBDIR=lib
  BUILD_BYPRODUCTS  ${GBENCH_DIR}/lib/libbenchmark.a
  UPDATE_COMMAND    "")
add_library(benchmarklib STATIC IMPORTED)
add_dependencies(benchmarklib benchmark)
set_property(TARGET benchmarklib PROPERTY
  IMPORTED_LOCATION ${GBENCH_DIR}/lib/libbenchmark.a)

# dependencies will be added in sequence, so if a new project `project_b` is added
# after `project_a`, please add the dependency add_dependencies(project_b project_a)
# This allows the cloning to happen sequentially, enhancing the printing at
# compile time, helping significantly to troubleshoot build issues.

# TODO: Change to using build.sh and make targets instead of this

if(CUB_IS_PART_OF_CTK)
  add_dependencies(cutlass raft)
else()
  add_dependencies(cub raft)
  add_dependencies(cutlass cub)
endif(CUB_IS_PART_OF_CTK)
add_dependencies(spdlog cutlass)
add_dependencies(googletest spdlog)
add_dependencies(benchmark googletest)
add_dependencies(faiss benchmark)
add_dependencies(faisslib faiss)
add_dependencies(treelite faiss)
