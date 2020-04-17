/*
 * Copyright (c) 2019-2020, NVIDIA CORPORATION.
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

#include <algorithm>
#include <cmath>
#include <iostream>
#include <vector>

#include <thrust/device_ptr.h>
#include <thrust/fill.h>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>

#include <cuml/cuml.hpp>
#include <cuml/tsa/batched_arima.hpp>
#include <cuml/tsa/batched_kalman.hpp>

#include "common/cumlHandle.hpp"
#include "common/device_buffer.hpp"
#include "common/nvtx.hpp"
#include "cuda_utils.h"
#include "linalg/batched/matrix.h"
#include "linalg/matrix_vector_op.h"
#include "metrics/batched/information_criterion.h"
#include "timeSeries/arima_helpers.h"
#include "utils.h"

namespace ML {

void predict(cumlHandle& handle, const double* d_y, int batch_size, int n_obs,
             int start, int end, const ARIMAOrder& order,
             const ARIMAParams<double>& params, double* d_vs, double* d_y_p) {
  ML::PUSH_RANGE(__func__);
  auto allocator = handle.getDeviceAllocator();
  const auto stream = handle.getStream();

  // Prepare data
  int diff_obs = order.lost_in_diff();
  int ld_yprep = n_obs - diff_obs;
  double* d_y_prep = (double*)allocator->allocate(
    ld_yprep * batch_size * sizeof(double), stream);
  MLCommon::TimeSeries::prepare_data(d_y_prep, d_y, batch_size, n_obs, order.d,
                                     order.D, order.s, stream, order.k,
                                     params.mu);

  // Create temporary array for the forecasts
  int num_steps = std::max(end - n_obs, 0);
  double* d_y_fc = nullptr;
  if (num_steps) {
    d_y_fc = (double*)allocator->allocate(
      num_steps * batch_size * sizeof(double), stream);
  }

  // Compute the residual and forecast - provide already prepared data and
  // extracted parameters
  ARIMAOrder order_after_prep = {order.p, 0,       order.q, order.P,
                                 0,       order.Q, order.s, 0};
  std::vector<double> loglike = std::vector<double>(batch_size);
  /// TODO: use device loglike to avoid useless copy
  batched_loglike(handle, d_y_prep, batch_size, n_obs - diff_obs,
                  order_after_prep, params, loglike.data(), d_vs, false, true,
                  MLE, num_steps, d_y_fc);

  auto counting = thrust::make_counting_iterator(0);
  int predict_ld = end - start;

  //
  // In-sample prediction
  //

  int p_start = std::max(start, diff_obs);
  int p_end = std::min(n_obs, end);

  // The prediction loop starts by filling undefined predictions with NaN,
  // then computes the predictions from the observations and residuals
  if (start < n_obs) {
    thrust::for_each(thrust::cuda::par.on(stream), counting,
                     counting + batch_size, [=] __device__(int bid) {
                       d_y_p[0] = 0.0;
                       for (int i = 0; i < diff_obs - start; i++) {
                         d_y_p[bid * predict_ld + i] = nan("");
                       }
                       for (int i = p_start; i < p_end; i++) {
                         d_y_p[bid * predict_ld + i - start] =
                           d_y[bid * n_obs + i] -
                           d_vs[bid * ld_yprep + i - diff_obs];
                       }
                     });
  }

  //
  // Finalize out-of-sample forecast and copy in-sample predictions
  //

  if (num_steps) {
    // Add trend and/or undiff
    MLCommon::TimeSeries::finalize_forecast(
      d_y_fc, d_y, num_steps, batch_size, n_obs, n_obs, order.d, order.D,
      order.s, stream, order.k, params.mu);

    // Copy forecast in d_y_p
    thrust::for_each(thrust::cuda::par.on(stream), counting,
                     counting + batch_size, [=] __device__(int bid) {
                       for (int i = 0; i < num_steps; i++) {
                         d_y_p[bid * predict_ld + n_obs - start + i] =
                           d_y_fc[num_steps * bid + i];
                       }
                     });

    allocator->deallocate(d_y_fc, num_steps * batch_size * sizeof(double),
                          stream);
  }

  allocator->deallocate(d_y_prep, ld_yprep * batch_size * sizeof(double),
                        stream);
  ML::POP_RANGE();
}

/**
 * @todo: docs
 */
template <typename DataT>
__global__ void sum_of_squares_kernel(const DataT* d_y, const DataT* d_phi,
                                      const DataT* d_theta, const DataT* d_mu,
                                      DataT* d_loglike, int n_obs, int n_phi,
                                      int n_theta, int k, int start) {
  // Load phi, theta and mu to registers
  DataT phi, theta;
  if (threadIdx.x < n_phi) {
    phi = d_phi[n_phi * blockIdx.x + threadIdx.x];
  }
  if (threadIdx.x < n_theta) {
    theta = d_theta[n_theta * blockIdx.x + threadIdx.x];
  }
  DataT mu = k ? d_mu[blockIdx.x] : (DataT)0;

  // Shared memory: load y and initialize the residuals
  extern __shared__ DataT shared_mem[];
  DataT* b_y = shared_mem;
  DataT* b_vs = shared_mem + n_obs;
  for (int i = threadIdx.x; i < n_obs; i += blockDim.x) {
    b_y[i] = d_y[n_obs * blockIdx.x + i];
  }
  for (int i = threadIdx.x; i < start; i += blockDim.x) {
    b_vs[i] = (DataT)0;
  }

  // Main loop
  char* temp_smem = (char*)(shared_mem + 2 * n_obs);
  DataT res, ssq = 0;
  for (int i = start; i < n_obs; i++) {
    __syncthreads();
    res = (DataT)0;
    res -= threadIdx.x < n_phi ? phi * b_y[i - threadIdx.x - 1] : (DataT)0;
    res -= threadIdx.x < n_theta ? theta * b_vs[i - threadIdx.x - 1] : (DataT)0;
    res = MLCommon::blockReduce(res, temp_smem);
    if (threadIdx.x == 0) {
      res += b_y[i] - mu;
      b_vs[i] = res;
      ssq += res * res;
    }
  }

  // Compute log-likelihood and write it to global memory
  if (threadIdx.x == 0) {
    d_loglike[blockIdx.x] =
      -0.5 * static_cast<DataT>(n_obs) *
      MLCommon::myLog(ssq / static_cast<DataT>(n_obs - start));
  }
}

void conditional_sum_of_squares(cumlHandle& handle, const double* d_y,
                                int batch_size, int n_obs,
                                const ARIMAOrder& order,
                                const ARIMAParams<double>& Tparams,
                                double* d_loglike) {
  ML::PUSH_RANGE(__func__);
  auto allocator = handle.getDeviceAllocator();
  auto stream = handle.getStream();
  auto counting = thrust::make_counting_iterator(0);

  // Compute phi and theta (AR-SAR and MA-SMA polynomials)
  int n_phi = order.n_phi();
  int n_theta = order.n_theta();
  MLCommon::device_buffer<double> phi(allocator, stream, n_phi * batch_size);
  MLCommon::device_buffer<double> theta(allocator, stream,
                                        n_theta * batch_size);
  double* d_phi = phi.data();
  double* d_theta = theta.data();
  thrust::for_each(
    thrust::cuda::par.on(stream), counting, counting + batch_size,
    [=] __device__(int bid) {
      double* b_phi = d_phi + bid * n_phi;
      double* b_theta = d_theta + bid * n_theta;
      for (int i = 0; i < n_phi; i++) {
        b_phi[i] = MLCommon::TimeSeries::reduced_polynomial<true>(
          bid, Tparams.ar, order.p, Tparams.sar, order.P, order.s, i + 1);
      }
      for (int i = 0; i < n_theta; i++) {
        b_theta[i] = MLCommon::TimeSeries::reduced_polynomial<false>(
          bid, Tparams.ma, order.q, Tparams.sma, order.Q, order.s, i + 1);
      }
    });

  int max_lags = std::max(n_phi, n_theta);
  int start = max_lags + 1;

  // Compute the sum-of-squares and the log-likelihood
  /// TODO: error if max_lags > 1024 (if that's even possible)
  int n_warps = std::max(MLCommon::ceildiv<int>(max_lags, 32), 1);
  size_t shared_mem_size = (2 * n_obs + n_warps) * sizeof(double);
  sum_of_squares_kernel<<<batch_size, 32 * n_warps, shared_mem_size, stream>>>(
    d_y, d_phi, d_theta, Tparams.mu, d_loglike, n_obs, n_phi, n_theta, order.k,
    start);
  CUDA_CHECK(cudaPeekAtLastError());

  ML::POP_RANGE();
}

void batched_loglike(cumlHandle& handle, const double* d_y, int batch_size,
                     int n_obs, const ARIMAOrder& order,
                     const ARIMAParams<double>& params, double* loglike,
                     double* d_vs, bool trans, bool host_loglike,
                     LoglikeMethod method, int fc_steps, double* d_fc) {
  ML::PUSH_RANGE(__func__);

  auto allocator = handle.getDeviceAllocator();
  auto stream = handle.getStream();
  ARIMAParams<double> Tparams;

  if (method != MLE && fc_steps) {
    /// TODO: warning
    method = MLE;
  }

  /* Create log-likelihood device array if host pointer is provided */
  double* d_loglike;
  MLCommon::device_buffer<double> loglike_buffer(allocator, stream);
  if (host_loglike) {
    loglike_buffer.resize(batch_size, stream);
    d_loglike = loglike_buffer.data();
  } else {
    d_loglike = loglike;
  }

  if (trans) {
    Tparams.allocate(order, batch_size, allocator, stream, true);

    MLCommon::TimeSeries::batched_jones_transform(
      order, batch_size, false, params, Tparams, allocator, stream);

    // TODO: should remove when merging intercept PR
    Tparams.mu = params.mu;
  } else {
    // non-transformed case: just use original parameters
    Tparams = params;
  }

  if (!order.need_prep()) {
    if (method == CSS) {
      conditional_sum_of_squares(handle, d_y, batch_size, n_obs, order, Tparams,
                                 d_loglike);
    } else {
      batched_kalman_filter(handle, d_y, n_obs, Tparams, order, batch_size,
                            d_loglike, d_vs, fc_steps, d_fc);
    }
  } else {
    MLCommon::device_buffer<double> y_prep(
      allocator, stream, batch_size * (n_obs - order.lost_in_diff()));
    double* d_y_prep = y_prep.data();

    MLCommon::TimeSeries::prepare_data(d_y_prep, d_y, batch_size, n_obs,
                                       order.d, order.D, order.s, stream,
                                       order.k, params.mu);

    if (method == CSS) {
      conditional_sum_of_squares(handle, d_y_prep, batch_size,
                                 n_obs - order.lost_in_diff(), order, Tparams,
                                 d_loglike);
    } else {
      batched_kalman_filter(handle, d_y_prep, n_obs - order.lost_in_diff(),
                            Tparams, order, batch_size, d_loglike, d_vs,
                            fc_steps, d_fc);
    }
  }

  if (host_loglike) {
    /* Tranfer log-likelihood device -> host */
    MLCommon::updateHost(loglike, d_loglike, batch_size, stream);
  }

  if (trans) {
    Tparams.deallocate(order, batch_size, allocator, stream, true);
  }
  ML::POP_RANGE();
}

void batched_loglike(cumlHandle& handle, const double* d_y, int batch_size,
                     int n_obs, const ARIMAOrder& order, const double* d_params,
                     double* loglike, double* d_vs, bool trans,
                     bool host_loglike, LoglikeMethod method, int fc_steps,
                     double* d_fc) {
  ML::PUSH_RANGE(__func__);

  // unpack parameters
  auto allocator = handle.getDeviceAllocator();
  auto stream = handle.getStream();
  ARIMAParams<double> params;
  params.allocate(order, batch_size, allocator, stream, false);
  params.unpack(order, batch_size, d_params, stream);

  batched_loglike(handle, d_y, batch_size, n_obs, order, params, loglike, d_vs,
                  trans, host_loglike, method, fc_steps, d_fc);

  params.deallocate(order, batch_size, allocator, stream, false);
  ML::POP_RANGE();
}

void information_criterion(cumlHandle& handle, const double* d_y,
                           int batch_size, int n_obs, const ARIMAOrder& order,
                           const ARIMAParams<double>& params, double* d_ic,
                           int ic_type) {
  ML::PUSH_RANGE(__func__);
  auto allocator = handle.getDeviceAllocator();
  auto stream = handle.getStream();
  double* d_vs = (double*)allocator->allocate(
    sizeof(double) * (n_obs - order.lost_in_diff()) * batch_size, stream);

  /* Compute log-likelihood in d_ic */
  batched_loglike(handle, d_y, batch_size, n_obs, order, params, d_ic, d_vs,
                  false, false);

  /* Compute information criterion from log-likelihood and base term */
  MLCommon::Metrics::Batched::information_criterion(
    d_ic, d_ic, static_cast<MLCommon::Metrics::IC_Type>(ic_type),
    order.complexity(), batch_size, n_obs - order.lost_in_diff(), stream);

  allocator->deallocate(
    d_vs, sizeof(double) * (n_obs - order.lost_in_diff()) * batch_size, stream);
  ML::POP_RANGE();
}

/**
 * Test that the parameters are valid for the inverse transform
 * 
 * @tparam isAr        Are these (S)AR or (S)MA parameters?
 * @param[in]  params  Parameters
 * @param[in]  pq      p for AR, q for MA, P for SAR, Q for SMA
 */
template <bool isAr>
DI bool test_invparams(const double* params, int pq) {
  double new_params[4];
  double tmp[4];

  constexpr double coef = isAr ? 1 : -1;

  for (int i = 0; i < pq; i++) {
    tmp[i] = params[i];
    new_params[i] = tmp[i];
  }

  // Perform inverse transform and stop before atanh step
  for (int j = pq - 1; j > 0; --j) {
    double a = new_params[j];
    for (int k = 0; k < j; ++k) {
      tmp[k] =
        (new_params[k] + coef * a * new_params[j - k - 1]) / (1 - (a * a));
    }
    for (int iter = 0; iter < j; ++iter) {
      new_params[iter] = tmp[iter];
    }
  }

  // Verify that the values are between -1 and 1
  bool result = true;
  for (int i = 0; i < pq; i++) {
    result = result && !(new_params[i] <= -1 || new_params[i] >= 1);
  }
  return result;
}

/**
 * Auxiliary function of _start_params: least square approximation of an
 * ARMA model (with or without seasonality)
 * @note: in this function the non-seasonal case has s=1, not s=0!
 */
void _arma_least_squares(cumlHandle& handle, double* d_ar, double* d_ma,
                         double* d_sigma2,
                         const MLCommon::LinAlg::Batched::Matrix<double>& bm_y,
                         int p, int q, int s, bool estimate_sigma2, int k = 0,
                         double* d_mu = nullptr) {
  const auto& handle_impl = handle.getImpl();
  auto stream = handle_impl.getStream();
  auto cublas_handle = handle_impl.getCublasHandle();
  auto allocator = handle_impl.getDeviceAllocator();
  auto counting = thrust::make_counting_iterator(0);

  int batch_size = bm_y.batches();
  int n_obs = bm_y.shape().first;

  int ps = p * s, qs = q * s;
  int p_ar = std::max(ps, 2 * qs);
  int r = std::max(p_ar + qs, ps);

  if ((q && p_ar >= n_obs - p_ar) || p + q + k >= n_obs - r) {
    // Too few observations for the estimate, fill with 0 (1 for sigma2)
    if (k)
      CUDA_CHECK(cudaMemsetAsync(d_mu, 0, sizeof(double) * batch_size, stream));
    if (p)
      CUDA_CHECK(
        cudaMemsetAsync(d_ar, 0, sizeof(double) * p * batch_size, stream));
    if (q)
      CUDA_CHECK(
        cudaMemsetAsync(d_ma, 0, sizeof(double) * q * batch_size, stream));
    if (estimate_sigma2) {
      thrust::device_ptr<double> sigma2_thrust =
        thrust::device_pointer_cast(d_sigma2);
      thrust::fill(thrust::cuda::par.on(stream), sigma2_thrust,
                   sigma2_thrust + batch_size, 1.0);
    }
    return;
  }

  /* Matrix formed by lag matrices of y and the residuals respectively,
   * side by side. The left side will be used to estimate AR, the right
   * side to estimate MA */
  MLCommon::LinAlg::Batched::Matrix<double> bm_ls_ar_res(
    n_obs - r, p + q + k, batch_size, cublas_handle, allocator, stream, false);
  int ar_offset = r - ps;
  int res_offset = r - p_ar - qs;

  // Get residuals from an AR(p_ar) model to estimate the MA parameters
  if (q) {
    // Create lagged y
    int ls_height = n_obs - p_ar;
    MLCommon::LinAlg::Batched::Matrix<double> bm_ls =
      MLCommon::LinAlg::Batched::b_lagged_mat(bm_y, p_ar);

    /* Matrix for the initial AR fit, initialized by copy of y
     * (note: this is because gels works in-place ; the matrix has larger
     *  dimensions than the actual AR fit) */
    MLCommon::LinAlg::Batched::Matrix<double> bm_ar_fit =
      MLCommon::LinAlg::Batched::b_2dcopy(bm_y, p_ar, 0, ls_height, 1);

    // Residual, initialized as offset y to avoid one kernel call
    MLCommon::LinAlg::Batched::Matrix<double> bm_residual(bm_ar_fit);

    // Initial AR fit
    MLCommon::LinAlg::Batched::b_gels(bm_ls, bm_ar_fit);

    // Compute residual (technically a gemv)
    MLCommon::LinAlg::Batched::b_gemm(false, false, ls_height, 1, p_ar, -1.0,
                                      bm_ls, bm_ar_fit, 1.0, bm_residual);

    // Lags of the residual
    MLCommon::LinAlg::Batched::b_lagged_mat(bm_residual, bm_ls_ar_res, q,
                                            n_obs - r, res_offset,
                                            (n_obs - r) * (k + p), s);
  }

  // Fill the first column of the matrix with 1 if we fit an intercept
  if (k) {
    double* d_ls_ar_res = bm_ls_ar_res.raw_data();
    thrust::for_each(thrust::cuda::par.on(stream), counting,
                     counting + batch_size, [=] __device__(int bid) {
                       double* b_ls_ar_res =
                         d_ls_ar_res + bid * (n_obs - r) * (p + q + k);
                       for (int i = 0; i < n_obs - r; i++) {
                         b_ls_ar_res[i] = 1.0;
                       }
                     });
  }

  // Lags of y
  MLCommon::LinAlg::Batched::b_lagged_mat(bm_y, bm_ls_ar_res, p, n_obs - r,
                                          ar_offset, (n_obs - r) * k, s);

  /* Initializing the vector for the ARMA fit
   * (note: also in-place as described for AR fit) */
  MLCommon::LinAlg::Batched::Matrix<double> bm_arma_fit =
    MLCommon::LinAlg::Batched::b_2dcopy(bm_y, r, 0, n_obs - r, 1);

  // The residuals will be computed only if sigma2 is requested
  MLCommon::LinAlg::Batched::Matrix<double> bm_final_residual(
    n_obs - r, 1, batch_size, cublas_handle, allocator, stream, false);
  if (estimate_sigma2) {
    MLCommon::copy(bm_final_residual.raw_data(), bm_arma_fit.raw_data(),
                   (n_obs - r) * batch_size, stream);
  }

  // ARMA fit
  MLCommon::LinAlg::Batched::b_gels(bm_ls_ar_res, bm_arma_fit);

  // Copy the results in the parameter vectors
  const double* d_arma_fit = bm_arma_fit.raw_data();
  thrust::for_each(thrust::cuda::par.on(stream), counting,
                   counting + batch_size, [=] __device__(int bid) {
                     const double* b_arma_fit = d_arma_fit + bid * (n_obs - r);
                     if (k) {
                       d_mu[bid] = b_arma_fit[0];
                     }
                     if (p) {
                       double* b_ar = d_ar + bid * p;
                       for (int i = 0; i < p; i++) {
                         b_ar[i] = b_arma_fit[i + k];
                       }
                     }
                     if (q) {
                       double* b_ma = d_ma + bid * q;
                       for (int i = 0; i < q; i++) {
                         b_ma[i] = b_arma_fit[i + p + k];
                       }
                     }
                   });

  if (estimate_sigma2) {
    // Compute final residual (technically a gemv)
    MLCommon::LinAlg::Batched::b_gemm(false, false, n_obs - r, 1, p + q + k,
                                      -1.0, bm_ls_ar_res, bm_arma_fit, 1.0,
                                      bm_final_residual);

    // Compute variance
    double* d_residual = bm_final_residual.raw_data();
    thrust::for_each(thrust::cuda::par.on(stream), counting,
                     counting + batch_size, [=] __device__(int bid) {
                       double acc = 0.0;
                       const double* b_residual =
                         d_residual + (n_obs - r) * bid;
                       for (int i = q; i < n_obs - r; i++) {
                         double res = b_residual[i];
                         acc += res * res;
                       }
                       d_sigma2[bid] = acc / static_cast<double>(n_obs - r - q);
                     });
  }

  // If (S)AR or (S)MA are not valid for the inverse transform, set them to zero
  thrust::for_each(thrust::cuda::par.on(stream), counting,
                   counting + batch_size, [=] __device__(int bid) {
                     if (p) {
                       double* b_ar = d_ar + bid * p;
                       bool valid = test_invparams<true>(b_ar, p);
                       if (!valid) {
                         for (int ip = 0; ip < p; ip++) b_ar[ip] = 0;
                       }
                     }
                     if (q) {
                       double* b_ma = d_ma + bid * q;
                       bool valid = test_invparams<false>(b_ma, q);
                       if (!valid) {
                         for (int iq = 0; iq < q; iq++) b_ma[iq] = 0;
                       }
                     }
                   });
}

/**
 * Auxiliary function of estimate_x0: compute the starting parameters for
 * the series pre-processed by estimate_x0
 */
void _start_params(cumlHandle& handle, ARIMAParams<double>& params,
                   const MLCommon::LinAlg::Batched::Matrix<double>& bm_y,
                   const ARIMAOrder& order) {
  // Estimate an ARMA fit without seasonality
  if (order.p + order.q + order.k)
    _arma_least_squares(handle, params.ar, params.ma, params.sigma2, bm_y,
                        order.p, order.q, 1, true, order.k, params.mu);

  // Estimate a seasonal ARMA fit independantly
  if (order.P + order.Q)
    _arma_least_squares(handle, params.sar, params.sma, params.sigma2, bm_y,
                        order.P, order.Q, order.s,
                        order.p + order.q + order.k == 0);
}

void estimate_x0(cumlHandle& handle, ARIMAParams<double>& params,
                 const double* d_y, int batch_size, int n_obs,
                 const ARIMAOrder& order) {
  ML::PUSH_RANGE(__func__);
  const auto& handle_impl = handle.getImpl();
  auto stream = handle_impl.getStream();
  auto cublas_handle = handle_impl.getCublasHandle();
  auto allocator = handle_impl.getDeviceAllocator();

  // Difference if necessary, copy otherwise
  MLCommon::LinAlg::Batched::Matrix<double> bm_yd(
    n_obs - order.d - order.s * order.D, 1, batch_size, cublas_handle,
    allocator, stream, false);
  MLCommon::TimeSeries::prepare_data(bm_yd.raw_data(), d_y, batch_size, n_obs,
                                     order.d, order.D, order.s, stream);
  // Note: mu is not known yet! We just want to difference the data

  // Do the computation of the initial parameters
  _start_params(handle, params, bm_yd, order);
  ML::POP_RANGE();
}

}  // namespace ML
