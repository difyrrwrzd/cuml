#ifndef ARIMA_BATCHED_KALMAN_H
#define ARIMA_BATCHED_KALMAN_H

#include <vector>

void batched_kalman_filter_cpu(const std::vector<double*>& h_ys_b, // { vector size batches, each item size nobs }
                               int nobs,
                               const std::vector<double*>& h_Zb, // { vector size batches, each item size Zb }
                               const std::vector<double*>& h_Rb, // { vector size batches, each item size Rb }
                               const std::vector<double*>& h_Tb, // { vector size batches, each item size Tb }
                               int r,
                               std::vector<double>& h_loglike_b,
                               std::vector<double>& h_sigma2_b);

void batched_kalman_filter(const std::vector<double*>& ptr_ys_b,
                           int nobs,
                           const std::vector<double*>& ptr_Zb,
                           const std::vector<double*>& ptr_Rb,
                           const std::vector<double*>& ptr_Tb,
                           int r,
                           std::vector<double>& ptr_loglike_b,
                           std::vector<double>& ptr_sigma2_b);

void batched_kalman_filter_cudf(double* d_ys_b,
                                int nobs,
                                const std::vector<double*>& h_Zb, // { vector size batches, each item size Zb }
                                const std::vector<double*>& h_Rb, // { vector size batches, each item size Rb }
                                const std::vector<double*>& h_Tb, // { vector size batches, each item size Tb }
                                // double* h_Zb,
                                // double* h_Rb,
                                // double* h_Tb,
                                int r,
                                int num_batches,
                                std::vector<double>& loglike_b);


#endif
