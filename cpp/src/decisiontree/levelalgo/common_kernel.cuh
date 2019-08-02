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
#pragma once
#include "cuda_utils.h"
#define LEAF 0xFFFFFFFF
#define PUSHRIGHT 0x00000001
//Setup how many times a sample is being used.
//This is due to bootstrap nature of Random Forest.
__global__ void setup_counts_kernel(unsigned int* sample_cnt,
                                    const unsigned int* __restrict__ rowids,
                                    const int n_sampled_rows) {
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  for (int tid = threadid; tid < n_sampled_rows;
       tid += blockDim.x * gridDim.x) {
    unsigned int stid = rowids[tid];
    atomicAdd(&sample_cnt[stid], 1);
  }
}
//This initializes the flags to 0x00000000. IF a sample is not used at all we Leaf out.
__global__ void setup_flags_kernel(const unsigned int* __restrict__ sample_cnt,
                                   unsigned int* flags, const int nrows) {
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  for (int tid = threadid; tid < nrows; tid += blockDim.x * gridDim.x) {
    unsigned int local_cnt = sample_cnt[tid];
    unsigned int local_flag = LEAF;
    if (local_cnt != 0) local_flag = 0x00000000;
    flags[tid] = local_flag;
  }
}

// This make actual split. A split is done using bits.
//Least significant Bit 0 means left and 1 means right.
//As a result a max depth of 32 is supported for now.
template <typename T>
__global__ void split_level_kernel(
  const T* __restrict__ data, const T* __restrict__ quantile,
  const int* __restrict__ split_col_index,
  const int* __restrict__ split_bin_index, const int nrows, const int ncols,
  const int nbins, const int n_nodes,
  const unsigned int* __restrict__ new_node_flags,
  unsigned int* __restrict__ flags) {
  unsigned int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  unsigned int local_flag = LEAF;

  for (int tid = threadid; tid < nrows; tid += gridDim.x * blockDim.x) {
    local_flag = flags[tid];

    if (local_flag != LEAF) {
      unsigned int local_leaf_flag = new_node_flags[local_flag];
      if (local_leaf_flag != LEAF) {
        int colidx = split_col_index[local_flag];
        T quesval = quantile[colidx * nbins + split_bin_index[local_flag]];
        T local_data = data[colidx * nrows + tid];
        //The inverse comparision here to push right instead of left
        if (local_data <= quesval) {
          local_flag = local_leaf_flag << 1;
        } else {
          local_flag = (local_leaf_flag << 1) | PUSHRIGHT;
        }
      } else {
        local_flag = LEAF;
      }
      flags[tid] = local_flag;
    }
  }
}

struct GainIdxPair {
  float gain;
  int idx;
};

template <typename KeyReduceOp>
struct ReducePair {
  KeyReduceOp op;
  DI ReducePair() {}
  DI ReducePair(KeyReduceOp op) : op(op) {}
  DI GainIdxPair operator()(const GainIdxPair& a, const GainIdxPair& b) {
    GainIdxPair retval;
    retval.gain = op(a.gain, b.gain);
    if (retval.gain == a.gain) {
      retval.idx = a.idx;
    } else {
      retval.idx = b.idx;
    }
    return retval;
  }
};
