/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <common/cudart_utils.h>
#include <cuda_utils.h>
#include <gtest/gtest.h>
#include <test_utils.h>
#include <iostream>
#include <vector>
#include "random/rng_impl.h"

#include "cuml/neighbors/knn.hpp"

#include <random/make_blobs.h>

namespace ML {

using namespace MLCommon;
using namespace Random;
using namespace std;

struct KNNInputs {
  int n_rows;
  int n_cols;
  int n_centers;

  int n_query_row;

  int n_neighbors;
  int n_parts;
};

template <typename T, typename IdxT>
::std::ostream &operator<<(::std::ostream &os, const KNNInputs &dims) {
  return os;
}

template <typename T>
void gen_blobs(cumlHandle &handle, T *out, int *l, int rows, int cols,
               int centers, const T *centroids) {
  make_blobs<float, int>(
    out, l, rows, cols, centers, handle.getDeviceAllocator(),
    handle.getStream(), centroids, nullptr, 0.1f, true, -10.0f, 10.0f, 1234ULL);
}

void create_index_parts(cumlHandle &handle, float *query_data,
                        int *query_labels, vector<float *> &part_inputs,
                        vector<int *> &part_labels, vector<int> &part_sizes,
                        const KNNInputs &params, const float *centers) {
  gen_blobs<float>(handle, query_data, query_labels, params.n_rows,
                   params.n_cols, params.n_centers, centers);

  for (int i = 0; i < params.n_parts; i++) {
    part_inputs.push_back(query_data + (i * params.n_rows * params.n_cols));
    part_labels.push_back(query_labels + (i * params.n_rows));
    part_sizes.push_back(params.n_rows);
  }
}

__global__ void build_actual_output(int *output, int n_rows, int k,
                                    const int *idx_labels,
                                    const int64_t *indices) {
  int element = threadIdx.x + blockDim.x * blockIdx.x;
  if (element >= n_rows * k) return;

  int64_t ind = indices[element];
  output[element] = idx_labels[ind];
}

__global__ void build_expected_output(int *output, int n_rows, int k,
                                      const int *labels) {
  int row = threadIdx.x + blockDim.x * blockIdx.x;
  if (row >= n_rows) return;

  int cur_label = labels[row];
  for (int i = 0; i < k; i++) output[row * k + i] = cur_label;
}

template <typename T>
class KNNTest : public ::testing::TestWithParam<KNNInputs> {
 protected:
  void testQuery() {
    cudaStream_t stream = handle.getStream();

    device_buffer<T> out(handle.getDeviceAllocator(), handle.getStream(),
                         params.n_rows * params.n_cols);
    device_buffer<int> l(handle.getDeviceAllocator(), handle.getStream(),
                         params.n_rows);

    device_buffer<T> rand_centers(handle.getDeviceAllocator(), stream,
                                  params.n_centers * params.n_cols);
    Rng r(0, GeneratorType::GenPhilox);
    r.uniform(rand_centers.data(), params.n_centers * params.n_cols, -10.0f,
              10.0f, stream);

    // Create index parts
    create_index_parts(handle, index_data, index_labels, part_inputs,
                       part_labels, part_sizes, params, rand_centers.data());

    gen_blobs(handle, search_data, search_labels, params.n_query_row,
              params.n_cols, params.n_centers, rand_centers.data());

    device_buffer<int64_t> indices(handle.getDeviceAllocator(),
                                   handle.getStream(),
                                   params.n_query_row * params.n_neighbors);
    device_buffer<float> dists(handle.getDeviceAllocator(), handle.getStream(),
                               params.n_query_row * params.n_neighbors);

    brute_force_knn(handle, part_inputs, part_sizes, params.n_cols, search_data,
                    params.n_query_row, output_indices, output_dists,
                    params.n_neighbors, true, true);

    CUDA_CHECK(cudaPeekAtLastError());
    CUDA_CHECK(cudaStreamSynchronize(stream));

    dim3 grid_elm(
      MLCommon::ceildiv(params.n_query_row * params.n_neighbors, 32), 1, 1);
    dim3 blk_elm(32, 1, 1);

    build_actual_output<<<grid_elm, blk_elm, 0, stream>>>(
      actual_labels, params.n_query_row, params.n_neighbors, index_labels,
      output_indices);

    CUDA_CHECK(cudaPeekAtLastError());
    CUDA_CHECK(cudaStreamSynchronize(stream));

    dim3 grid_row(MLCommon::ceildiv(params.n_query_row, 32), 1, 1);
    dim3 blk_row(32, 1, 1);

    build_expected_output<<<grid_row, blk_row, 0, stream>>>(
      expected_labels, params.n_query_row, params.n_neighbors, search_labels);

    CUDA_CHECK(cudaPeekAtLastError());
    CUDA_CHECK(cudaStreamSynchronize(stream));
  }

  void SetUp() override {
    cudaStream_t stream = handle.getStream();

    params = ::testing::TestWithParam<KNNInputs>::GetParam();

    allocate(index_data, params.n_rows * params.n_cols * params.n_parts,
             stream);
    allocate(index_labels, params.n_rows * params.n_parts, stream);

    allocate(search_data, params.n_query_row * params.n_cols, stream);
    allocate(search_labels, params.n_query_row, stream);

    allocate(output_indices,
             params.n_query_row * params.n_cols * params.n_parts, stream);
    allocate(output_dists, params.n_query_row * params.n_cols * params.n_parts,
             stream);

    allocate(actual_labels,
             params.n_query_row * params.n_neighbors * params.n_parts, stream);
    allocate(expected_labels,
             params.n_query_row * params.n_neighbors * params.n_parts, stream);
  }

  void TearDown() override {

	  CUDA_CHECK(cudaFree(index_data));
	  CUDA_CHECK(cudaFree(index_labels));
	  CUDA_CHECK(cudaFree(search_data));
	  CUDA_CHECK(cudaFree(search_labels));
	  CUDA_CHECK(cudaFree(output_dists));
	  CUDA_CHECK(cudaFree(output_indices));
	  CUDA_CHECK(cudaFree(actual_labels));
	  CUDA_CHECK(cudaFree(expected_labels));
  }

 protected:
  cumlHandle handle;

  KNNInputs params;

  float *index_data;
  int *index_labels;

  vector<float *> part_inputs;
  vector<int *> part_labels;
  vector<int> part_sizes;

  float *search_data;
  int *search_labels;

  float *output_dists;
  int64_t *output_indices;

  int *actual_labels;
  int *expected_labels;
};

const std::vector<KNNInputs> inputs = {
  {50, 5, 2, 25, 5, 2},    {50, 5, 2, 25, 10, 2}, {500, 5, 2, 25, 5, 7},
  {500, 50, 2, 25, 10, 7}, {500, 5, 6, 25, 5, 7},
};

typedef KNNTest<float> KNNTestF;
TEST_P(KNNTestF, Query) {
  this->testQuery();
  ASSERT_TRUE(devArrMatch(expected_labels, actual_labels,
                          params.n_query_row * params.n_neighbors,
                          Compare<int>()));
}

INSTANTIATE_TEST_CASE_P(KNNTest, KNNTestF, ::testing::ValuesIn(inputs));

}  // end namespace ML
