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
#include <cuML.hpp>
#include <vector>

namespace ML {

//! Compute the loglikelihood of the given parameter on the given time series in a batched context.
//! @param y series to fit: shape = (nobs, num_bathces) and expects column major data layout. Memory on Device.
//! @param num_batches number of time series
//! @param order ARIMA order (p: number of ar-parameters, d: difference parameter, q: number of ma-parameters)
//! @param params parameters to evaluate group by series: [mu0, ar.., ma.., mu1, ..] Memory on host.
//! @param h_vs The residual between model and original signal. shape = (nobs, num_batches) Memory on host.
//! @param trans run `jones_transform` on params
//! @return vector of log likelihood, one for each series (size: num_batches). Memory on host.
//! @return kalman residual, shape = (nobs, num_batches) Memory on device.
void batched_loglike(cumlHandle& handle, double* d_y, int num_batches, int nobs,
                     int p, int d, int q, double* h_params,
                     std::vector<double>& loglike, double*& d_vs,
                     bool trans = true);

void update_host(cumlHandle& handle, double* d_vs, int N, double* h_vs);

}  // namespace ML
