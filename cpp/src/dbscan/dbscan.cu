/*
 * Copyright (c) 2018-2019, NVIDIA CORPORATION.
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
#include <cuML_api.h>
#include <common/cumlHandle.hpp>
#include "dbscan.h"
#include "dbscan.hpp"
#include "runner.h"
#include "utils.h"

namespace ML {

using namespace Dbscan;

// @todo
// In the below 2 calls, the Index type has been hard-coded to `int64_t`
// We should pick the right Index type based on the input dimensions.
void dbscanFit(const cumlHandle &handle, float *input, long n_rows, long n_cols,
               float eps, int min_pts, long *labels, size_t max_bytes_per_batch,
               bool verbose) {
  dbscanFitImpl<float, int64_t>(handle.getImpl(), input, n_rows, n_cols, eps,
                                min_pts, labels, max_bytes_per_batch,
                                handle.getStream(), verbose);
}

void dbscanFit(const cumlHandle &handle, double *input, long n_rows,
               long n_cols, double eps, int min_pts, long *labels,
               size_t max_bytes_per_batch, bool verbose) {
  dbscanFitImpl<double, int64_t>(handle.getImpl(), input, n_rows, n_cols, eps,
                                 min_pts, labels, max_bytes_per_batch,
                                 handle.getStream(), verbose);
}

};  // end namespace ML
