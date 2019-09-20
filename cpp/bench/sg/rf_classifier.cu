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

#include <cuML.hpp>
#include <randomforest/randomforest.hpp>
#include <utility>
#include "benchmark.cuh"

namespace ML {
namespace Bench {
namespace rf {

struct Params {
  DatasetParams data;
  BlobsParams blobs;
  RF_params rf;
};

template <typename D>
struct RFClassifierModel {};

template <>
struct RFClassifierModel<float> {
  ML::RandomForestClassifierF model;
};

template <>
struct RFClassifierModel<double> {
  ML::RandomForestClassifierD model;
};

template <typename D>
class RFClassifier : public BlobsFixture<D> {
 public:
  RFClassifier(const std::string& name, const Params& p)
    : BlobsFixture<D>(p.data, p.blobs), dParams(p.rf) {
    this->SetName(name.c_str());
  }

 protected:
  void runBenchmark(::benchmark::State& state) override {
    if (this->params.rowMajor) {
      state.SkipWithError("RFClassifier only supports col-major inputs");
    }
    auto& handle = *this->handle;
    auto stream = handle.getStream();
    auto* mPtr = &model.model;
    for (auto _ : state) {
      CudaEventTimer timer(handle, state, true, stream);
      mPtr->trees = nullptr;
      RF(handle, this->data.X, this->params.nrows, this->params.ncols,
                D(dParams.eps), dParams.min_pts, labels,
                dParams.max_bytes_per_batch);
      CUDA_CHECK(cudaStreamSynchronize(stream));
      delete [] mPtr->trees;
    }
  }

  void allocateBuffers(const ::benchmark::State& state) override {
    auto allocator = this->handle->getDeviceAllocator();
    auto stream = this->handle->getStream();
    labels =
      (int*)allocator->allocate(this->params.nrows * sizeof(int), stream);
  }

  void deallocateBuffers(const ::benchmark::State& state) override {
    auto allocator = this->handle->getDeviceAllocator();
    auto stream = this->handle->getStream();
    allocator->deallocate(labels, this->params.nrows * sizeof(int), stream);
  }

 private:
  int* labels;
  RFClassifierModel<D> model;
};

std::vector<Params> getInputs() {
  struct Triplets {
    int nrows, ncols, nclasses;
  };
  std::vector<Params> out;
  Params p;
  p.data.rowMajor = false;
  p.blobs.cluster_std = 10.0;
  p.blobs.shuffle = false;
  p.blobs.center_box_min = -10.0;
  p.blobs.center_box_max = 10.0;
  p.blobs.seed = 12345ULL;
  p.rf.bootstrap = true;
  p.rf.rows_sample = 1.f;
  p.rf.tree_params.max_leaves = 1 << 20;
  p.rf.tree_params.max_features = 1.f;
  p.rf.tree_params.min_rows_per_node = 3;
  p.rf.tree_params.n_bins = 32;
  p.rf.tree_params.bootstrap_features = true;
  p.rf.tree_params.quantile_per_tree = false;
  p.rf.tree_params.split_algo = 1;
  p.rf.tree_params.split_criterion = (ML::CRITERION)0;
  p.rf.n_trees = 500;
  p.rf.n_streams = 8;
  std::vector<Triplets> rowcols = {
    {160000, 64, 2},
    {640000, 64, 8},
    {1184000, 968, 2},  // Mimicking Bosch dataset
  };
  for (auto& rc : rowcols) {
    // Let's run Bosch only for float type
    if (!std::is_same<D, float>::value && rc.ncols == 968) continue;
    p.data.nrows = rc.nrows;
    p.data.ncols = rc.ncols;
    p.data.nclasses = rc.nclasses;
    for (auto max_depth : std::vector<int>({8, 10})) {
      p.rf.tree_params.max_depth = max_depth;
      out.push_back(p);
    }
  }
  return out;
}

CUML_BENCH_REGISTER(Params, RFClassifier<float>, "blobs", getInputs());
CUML_BENCH_REGISTER(Params, RFClassifier<double>, "blobs", getInputs());

}  // end namespace rf
}  // end namespace Bench
}  // end namespace ML
