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
#include "common_kernel.cuh"
#include "cub/cub.cuh"

template <typename T>
__global__ void pred_kernel_level(const T *__restrict__ labels,
                                  const unsigned int *__restrict__ sample_cnt,
                                  const int nrows, T *predout,
                                  unsigned int *countout) {
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  __shared__ T shmempred;
  __shared__ unsigned int shmemcnt;
  if (threadIdx.x == 0) {
    shmempred = 0;
    shmemcnt = 0;
  }
  __syncthreads();

  for (int tid = threadid; tid < nrows; tid += blockDim.x * gridDim.x) {
    T label = labels[tid];
    unsigned int count = sample_cnt[tid];
    atomicAdd(&shmemcnt, count);
    atomicAdd(&shmempred, label * count);
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    atomicAdd(predout, shmempred);
    atomicAdd(countout, shmemcnt);
  }
  return;
}

template <typename T, typename F>
__global__ void mse_kernel_level(const T *__restrict__ labels,
                                 const unsigned int *__restrict__ sample_cnt,
                                 const int nrows, const T *predout,
                                 const unsigned int *count, T *mseout) {
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  __shared__ T shmemmse;

  if (threadIdx.x == 0) shmemmse = 0;
  T mean = predout[0] / count[0];
  __syncthreads();

  for (int tid = threadid; tid < nrows; tid += blockDim.x * gridDim.x) {
    T label = labels[tid];
    unsigned int count = sample_cnt[tid];
    T value = F::exec(label - mean);
    atomicAdd(&shmemmse, count * value);
  }

  __syncthreads();

  if (threadIdx.x == 0) {
    atomicAdd(mseout, shmemmse);
  }
  return;
}

template <typename T>
__global__ void get_pred_kernel(const T *__restrict__ data,
                                const T *__restrict__ labels,
                                const unsigned int *__restrict__ flags,
                                const unsigned int *__restrict__ sample_cnt,
                                const unsigned int *__restrict__ colids,
                                const int nrows, const int ncols,
                                const int nbins, const int n_nodes,
                                const T *__restrict__ quantile, T *predout,
                                unsigned int *countout) {
  extern __shared__ char shmem_pred_kernel[];
  T *shmempred = (T *)shmem_pred_kernel;
  unsigned int *shmemcount =
    (unsigned int *)(shmem_pred_kernel + nbins * n_nodes * sizeof(T));
  unsigned int local_flag = LEAF;
  T local_label;
  int local_cnt;
  int tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid < nrows) {
    local_flag = flags[tid];
    local_label = labels[tid];
    local_cnt = sample_cnt[tid];
  }

  for (unsigned int colcnt = 0; colcnt < ncols; colcnt++) {
    unsigned int colid = colids[colcnt];
    for (unsigned int i = threadIdx.x; i < nbins * n_nodes; i += blockDim.x) {
      shmempred[i] = (T)0;
      shmemcount[i] = 0;
    }
    __syncthreads();

    //Check if leaf
    if (local_flag != LEAF) {
      T local_data = data[tid + colid * nrows];

#pragma unroll(8)
      for (unsigned int binid = 0; binid < nbins; binid++) {
        T quesval = quantile[colid * nbins + binid];
        if (local_data <= quesval) {
          unsigned int nodeoff = local_flag * nbins;
          atomicAdd(&shmempred[nodeoff + binid], local_label * local_cnt);
          atomicAdd(&shmemcount[nodeoff + binid], local_cnt);
        }
      }
    }

    __syncthreads();
    for (unsigned int i = threadIdx.x; i < nbins * n_nodes; i += blockDim.x) {
      unsigned int offset = colcnt * nbins * n_nodes;
      atomicAdd(&predout[offset + i], shmempred[i]);
      atomicAdd(&countout[offset + i], shmemcount[i]);
    }
    __syncthreads();
  }
}

template <typename T, typename F>
__global__ void get_mse_kernel(
  const T *__restrict__ data, const T *__restrict__ labels,
  const unsigned int *__restrict__ flags,
  const unsigned int *__restrict__ sample_cnt,
  const unsigned int *__restrict__ colids, const int nrows, const int ncols,
  const int nbins, const int n_nodes, const T *__restrict__ quantile,
  const T *__restrict__ parentpred, const T *__restrict__ predout,
  const unsigned int *__restrict__ countout, T *mseout) {
  extern __shared__ T shmem_mse_kernel[];
  T *shmem_parentpred = (T *)shmem_mse_kernel;
  T *shmem_predout = (T *)(shmem_mse_kernel + n_nodes * sizeof(T));
  T *shmem_mse =
    (T *)(shmem_mse_kernel + n_nodes * sizeof(T) + n_nodes * nbins * sizeof(T));
  unsigned int *shmem_countout = (T *)(shmem_mse_kernel + n_nodes * sizeof(T) +
                                       3 * n_nodes * nbins * sizeof(T));

  unsigned int local_flag = LEAF;
  T local_label;
  int local_cnt;
  int tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid < nrows) {
    local_flag = flags[tid];
    local_label = labels[tid];
    local_cnt = sample_cnt[tid];
  }
  for (unsigned int i = threadIdx.x; i < n_nodes; i += blockDim.x) {
    shmem_parentpred[i] = parentpred[i];
  }
  for (unsigned int i = threadIdx.x; i < nbins * n_nodes; i += blockDim.x) {
    shmem_predout[i] = predout[i];
    shmem_countout[i] = countout[i];
  }
  __syncthreads();

  for (unsigned int colcnt = 0; colcnt < ncols; colcnt++) {
    unsigned int colid = colids[colcnt];
    for (unsigned int i = threadIdx.x; i < 2 * nbins * n_nodes;
         i += blockDim.x) {
      shmem_mse[i] = (T)0;
    }
    __syncthreads();

    //Check if leaf
    if (local_flag != LEAF) {
      T local_data = data[tid + colid * nrows];

#pragma unroll(8)
      for (unsigned int binid = 0; binid < nbins; binid++) {
        T quesval = quantile[colid * nbins + binid];
        unsigned int nodeoff = local_flag * 2 * nbins;
        T leftmean = shmem_predout[local_flag * nbins + binid] /
                     shmem_countout[local_flag * nbins + binid];
        if (local_data <= quesval) {
          atomicAdd(&shmem_mse[nodeoff + binid],
                    local_cnt * F::exec(local_label - leftmean));
        } else {
          T rightmean = shmem_parentpred[local_flag] - leftmean;
          atomicAdd(&shmem_mse[nodeoff + binid + 1],
                    local_cnt * F::exec(local_label - rightmean));
        }
      }
    }

    __syncthreads();
    for (unsigned int i = threadIdx.x; i < 2 * nbins * n_nodes;
         i += blockDim.x) {
      unsigned int offset = colcnt * nbins * 2 * n_nodes;
      atomicAdd(&mseout[offset + i], shmem_mse[i]);
    }
    __syncthreads();
  }
}
