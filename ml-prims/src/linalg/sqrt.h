/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
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
#include "unary_op.h"


namespace MLCommon {
namespace LinAlg {

/**
 * @defgroup ScalarOps Scalar operations on the input buffer
 * @param out the output buffer
 * @param in the input buffer
 * @param len number of elements in the input buffer
 * @param stream cuda stream where to launch work
 * @{
 */
template <typename math_t>
void sqrt(math_t *out, const math_t *in, int len,
          cudaStream_t stream = 0) {
  unaryOp(out, in, len,
          [] __device__(math_t in) { return mySqrt(in); },
          stream);
}
/** @} */

}; // end namespace LinAlg
}; // end namespace MLCommon
