#pragma once
#include "cub/cub.cuh"

#define LEAF 0xFFFFFFFF
#define PUSHRIGHT 0x00000001

__global__ void setup_counts_kernel(int* sample_cnt,
                                    const unsigned int* __restrict__ rowids,
                                    const int n_sampled_rows) {
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  for (int tid = threadid; tid < n_sampled_rows;
       tid += blockDim.x * gridDim.x) {
    unsigned int stid = rowids[tid];
    atomicAdd(&sample_cnt[stid], 1);
  }
}
__global__ void setup_flags_kernel(const int* __restrict__ sample_cnt,
                                   unsigned int* flags, const int nrows) {
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  for (int tid = threadid; tid < nrows; tid += blockDim.x * gridDim.x) {
    int local_cnt = sample_cnt[tid];
    unsigned int local_flag = LEAF;
    if (local_cnt != 0) local_flag = 0x00000000;
    flags[tid] = local_flag;
  }
}

template <typename T>
__global__ void get_me_hist_kernel(
  const T* __restrict__ data, const int* __restrict__ labels,
  const unsigned int* __restrict__ flags, const int* __restrict__ sample_cnt,
  const int nrows, const int ncols, const int n_unique_labels, const int nbins,
  const int n_nodes, const T* __restrict__ quantile, unsigned int* histout) {
  extern __shared__ unsigned int shmemhist[];
  unsigned int local_flag = LEAF;
  int local_label = -1;
  int local_cnt;
  int tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid < nrows) {
    local_flag = flags[tid];
    local_label = labels[tid];
    local_cnt = sample_cnt[tid];
  }

  for (unsigned int colid = 0; colid < ncols; colid++) {
    for (unsigned int i = threadIdx.x; i < nbins * n_nodes * n_unique_labels;
         i += blockDim.x) {
      shmemhist[i] = 0;
    }
    __syncthreads();

    //Check if leaf
    if (local_flag != LEAF) {
      T local_data = data[tid + colid * nrows];

#pragma unroll(8)
      for (unsigned int binid = 0; binid < nbins; binid++) {
        T quesval = quantile[colid * nbins + binid];
        if (local_data <= quesval) {
          unsigned int nodeoff = local_flag * nbins * n_unique_labels;
          atomicAdd(&shmemhist[nodeoff + binid * n_unique_labels + local_label],
                    local_cnt);
        }
      }
    }

    __syncthreads();
    for (unsigned int i = threadIdx.x; i < nbins * n_nodes * n_unique_labels;
         i += blockDim.x) {
      unsigned int offset = colid * nbins * n_nodes * n_unique_labels;
      atomicAdd(&histout[offset + i], shmemhist[i]);
    }
    __syncthreads();
  }
}

template <typename T>
__global__ void get_me_hist_kernel_global(
  const T* __restrict__ data, const int* __restrict__ labels,
  const unsigned int* __restrict__ flags, const int* __restrict__ sample_cnt,
  const int nrows, const int ncols, const int n_unique_labels, const int nbins,
  const int n_nodes, const T* __restrict__ quantile, unsigned int* histout) {
  unsigned int local_flag;
  int local_label;
  int local_cnt;
  int threadid = threadIdx.x + blockIdx.x * blockDim.x;

  for (int tid = threadid; tid < nrows; tid += gridDim.x * blockDim.x) {
    local_flag = flags[tid];
    local_label = labels[tid];
    local_cnt = sample_cnt[tid];
    for (unsigned int colid = 0; colid < ncols; colid++) {
      //Check if leaf
      if (local_flag != LEAF) {
        T local_data = data[tid + colid * nrows];
        //Loop over nbins

#pragma unroll(8)
        for (unsigned int binid = 0; binid < nbins; binid++) {
          T quesval = quantile[colid * nbins + binid];
          if (local_data <= quesval) {
            unsigned int coloff = colid * nbins * n_nodes * n_unique_labels;
            unsigned int nodeoff = local_flag * nbins * n_unique_labels;
            atomicAdd(&histout[coloff + nodeoff + binid * n_unique_labels +
                               local_label],
                      local_cnt);
          }
        }
      }
    }
  }
}

template <typename T>
__global__ void split_level_kernel(
  const T* __restrict__ data, const T* __restrict__ quantile,
  const int* __restrict__ split_col_index,
  const int* __restrict__ split_bin_index, const int nrows, const int ncols,
  const int nbins, const int n_nodes,
  const unsigned int* __restrict__ new_node_flags,
  unsigned int* __restrict__ flags) {
  unsigned int threadid = threadIdx.x + blockIdx.x * blockDim.x;
  unsigned int local_flag;

  for (int tid = threadid; tid < nrows; tid += gridDim.x * blockDim.x) {
    if (tid < nrows) {
      local_flag = flags[tid];
    } else {
      local_flag = LEAF;
    }

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

struct GiniDevFunctor {
  static __device__ __forceinline__ float exec(unsigned int* hist, int nrows,
                                               int n_unique_labels) {
    float gval = 1.0;
    for (int i = 0; i < n_unique_labels; i++) {
      float prob = ((float)hist[i]) / nrows;
      gval -= prob * prob;
    }
    return gval;
  }
};

struct EntropyDevFunctor {
  static __device__ __forceinline__ float exec(unsigned int* hist, int nrows,
                                               int n_unique_labels) {
    float eval = 0.0;
    for (int i = 0; i < n_unique_labels; i++) {
      if (hist[i] != 0) {
        float prob = ((float)hist[i]) / nrows;
        eval += prob * logf(prob);
      }
    }
    return (-1 * eval);
  }
};

struct GainIdxPair {
  float gain;
  int idx;
};
template <typename KeyReduceOp>
struct ReducePair {
  KeyReduceOp op;
  __device__ __forceinline__ ReducePair() {}
  __device__ __forceinline__ ReducePair(KeyReduceOp op) : op(op) {}
  __device__ __forceinline__ GainIdxPair operator()(const GainIdxPair& a,
                                                    const GainIdxPair& b) {
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

template <typename T, typename F>
__global__ void get_me_best_split_kernel(
  const unsigned int* __restrict__ hist,
  const unsigned int* __restrict__ parent_hist,
  const T* __restrict__ parent_metric, const int nbins, const int ncols,
  const int n_nodes, const int n_unique_labels, float* outgain,
  int* best_col_id, int* best_bin_id, unsigned int* child_hist,
  T* child_best_metric) {
  extern __shared__ unsigned int shmem_split_eval[];
  __shared__ int best_nrows[2];
  typedef cub::BlockReduce<GainIdxPair, 64> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage;

  unsigned int* tmp_histleft =
    &shmem_split_eval[threadIdx.x * 2 * n_unique_labels];
  unsigned int* tmp_histright =
    &shmem_split_eval[threadIdx.x * 2 * n_unique_labels + n_unique_labels];
  unsigned int* best_split_hist =
    &shmem_split_eval[2 * n_unique_labels * blockDim.x];
  unsigned int* parent_hist_local =
    &shmem_split_eval[2 * n_unique_labels * (blockDim.x + 1)];

  for (unsigned int nodeid = blockIdx.x; nodeid < n_nodes;
       nodeid += gridDim.x) {
    if (threadIdx.x < 2) {
      best_nrows[threadIdx.x] = 0;
    }

    int nodeoffset = nodeid * nbins * n_unique_labels;
    float parent_metric_local = parent_metric[nodeid];

    for (int j = threadIdx.x; j < n_unique_labels; j += blockDim.x) {
      parent_hist_local[j] = parent_hist[nodeid * n_unique_labels + j];
    }

    __syncthreads();

    GainIdxPair tid_pair;
    tid_pair.gain = 0.0;
    tid_pair.idx = -1;
    for (int id = threadIdx.x; id < nbins * ncols; id += blockDim.x) {
      int coloffset = ((int)(id / nbins)) * nbins * n_unique_labels * n_nodes;
      int binoffset = (id % nbins) * n_unique_labels;
      int tmp_lnrows = 0;
      int tmp_rnrows = 0;
      for (int j = 0; j < n_unique_labels; j++) {
        tmp_histleft[j] = hist[coloffset + binoffset + nodeoffset + j];
        tmp_lnrows += tmp_histleft[j];
        tmp_histright[j] = parent_hist_local[j] - tmp_histleft[j];
        tmp_rnrows += tmp_histright[j];
      }

      int totalrows = tmp_lnrows + tmp_rnrows;
      if (tmp_lnrows == 0 || tmp_rnrows == 0) continue;

      float tmp_gini_left = F::exec(tmp_histleft, tmp_lnrows, n_unique_labels);
      float tmp_gini_right =
        F::exec(tmp_histright, tmp_rnrows, n_unique_labels);

      float impurity = (tmp_lnrows * 1.0f / totalrows) * tmp_gini_left +
                       (tmp_rnrows * 1.0f / totalrows) * tmp_gini_right;
      float info_gain = parent_metric_local - impurity;
      if (info_gain > tid_pair.gain) {
        tid_pair.gain = info_gain;
        tid_pair.idx = id;
      }
    }
    __syncthreads();
    GainIdxPair ans =
      BlockReduce(temp_storage).Reduce(tid_pair, ReducePair<cub::Max>());
    __syncthreads();

    if (threadIdx.x == 0) {
      outgain[nodeid] = ans.gain;
      best_col_id[nodeid] = (int)(ans.idx / nbins);
      best_bin_id[nodeid] = ans.idx % nbins;
    }

    int coloffset =
      ((int)(ans.idx / nbins)) * nbins * n_unique_labels * n_nodes;
    int binoffset = (ans.idx % nbins) * n_unique_labels;

    for (int j = threadIdx.x; j < n_unique_labels; j += blockDim.x) {
      unsigned int val_left = hist[coloffset + binoffset + nodeoffset + j];
      unsigned int val_right = parent_hist_local[j] - val_left;
      best_split_hist[j] = val_left;
      atomicAdd(&best_nrows[0], val_left);
      best_split_hist[j + n_unique_labels] = val_right;
      atomicAdd(&best_nrows[1], val_right);
    }
    __syncthreads();

    for (int j = threadIdx.x; j < 2 * n_unique_labels; j += blockDim.x) {
      child_hist[2 * n_unique_labels * nodeid + j] = best_split_hist[j];
    }

    if (threadIdx.x < 2) {
      child_best_metric[2 * nodeid + threadIdx.x] =
        F::exec(&best_split_hist[threadIdx.x * n_unique_labels],
                best_nrows[threadIdx.x], n_unique_labels);
    }
  }
}

__device__ __forceinline__ bool check_condition(unsigned int local_flag,
                                                unsigned int nodectr,
                                                int batch_nodes) {
  if (local_flag == LEAF) return false;
  if (local_flag < nodectr * batch_nodes) return false;
  if (local_flag >= (nodectr + 1) * batch_nodes) return false;
  return true;
}

template <typename T>
__global__ void get_me_hist_kernel_batched(
  const T* __restrict__ data, const int* __restrict__ labels,
  const unsigned int* __restrict__ flags, const int nrows, const int ncols,
  const int n_unique_labels, const int nbins, const int n_nodes,
  const T* __restrict__ quantile, int batch_nodes, unsigned int* histout) {
  extern __shared__ unsigned int shmemhist[];
  unsigned int local_flag;
  int local_label;
  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  int max_node_itr = (int)(n_nodes / batch_nodes);
  if (n_nodes % batch_nodes != 0) max_node_itr++;

  if (tid < nrows) {
    local_flag = flags[tid];
    local_label = labels[tid];
  } else {
    local_flag = LEAF;
    local_label = -1;
  }

  for (unsigned int colid = 0; colid < ncols; colid++) {
    int nodecnt = batch_nodes;
    for (unsigned int nodectr = 0; nodectr < max_node_itr; nodectr++) {
      if (nodectr == (max_node_itr - 1) && ((n_nodes % batch_nodes) != 0))
        nodecnt = n_nodes % batch_nodes;

      for (unsigned int i = threadIdx.x; i < nbins * nodecnt * n_unique_labels;
           i += blockDim.x) {
        shmemhist[i] = 0;
      }
      __syncthreads();

      //Check if leaf
      if (check_condition(local_flag, nodectr, batch_nodes)) {
        T local_data = data[tid + colid * nrows];
        //Loop over nbins

#pragma unroll(8)
        for (unsigned int binid = 0; binid < nbins; binid++) {
          T quesval = quantile[colid * nbins + binid];
          if (local_data <= quesval) {
            unsigned int nodeoff =
              (local_flag % nodecnt) * nbins * n_unique_labels;
            atomicAdd(
              &shmemhist[nodeoff + binid * n_unique_labels + local_label], 1);
          }
        }
      }

      __syncthreads();
      for (unsigned int i = threadIdx.x; i < nbins * nodecnt * n_unique_labels;
           i += blockDim.x) {
        unsigned int offset = colid * nbins * n_nodes * n_unique_labels;
        offset += nodectr * nbins * batch_nodes * n_unique_labels;
        atomicAdd(&histout[offset + i], shmemhist[i]);
      }
      __syncthreads();
    }
  }
}
