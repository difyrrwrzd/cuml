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

#include <cuda_runtime.h>
#include <common/device_buffer.hpp>
#include <cuML.hpp>

namespace ML {
namespace Bench {

struct Dataset {
  int nrows, ncols;
  float* X;
  int* y;

  void allocate(int nr, int nc, const cumlHandle& handle);
  void deallocate(const cumlHandle& handle);
};

bool blobs(Dataset& ret, const cumlHandle& handle, char** argv, int start,
           int end);
bool load(Dataset& ret, const cumlHandle& handle, char** argv, int start,
          int end);

}  // end namespace Bench
}  // end namespace ML
