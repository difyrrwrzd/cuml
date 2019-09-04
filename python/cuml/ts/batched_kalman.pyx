#
# Copyright (c) 2019, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# cython: language_level = 3

import numpy as np

import ctypes
cimport numpy as np
from libcpp.vector cimport vector
from libc.stdlib cimport malloc, free
from libcpp cimport bool
from libcpp.string cimport string
cimport cython

cdef extern from "ts/batched_kalman.h" namespace "ML":

  void batched_kalman_filter(double* ptr_ys_b,
                             int nobs,
                             const vector[double]& b_ar_params,
                             const vector[double]& b_ma_params,
                             int p, int q,
                             int num_batches,
                             vector[double]& vec_loglike_b,
                             vector[vector[double]]& vec_vs_b,
                             bool initP_with_kalman_iterations)

  void nvtx_range_push(string msg)

  void nvtx_range_pop()

  void batched_jones_transform(int p, int q,
                               int batchSize,
                               bool isInv,
                               const vector[double]& ar,
                               const vector[double]& ma,
                               vector[double]& Tar,
                               vector[double]& Tma)


def unpack(p, d, q, nb, np.ndarray[double, ndim=1] x):
    """Unpack linearized parameters into mu, ar, and ma batched-groupings"""
    pynvtx_range_push("unpack(x) -> (ar,ma,mu)")
    num_parameters = d + p + q
    mu = np.zeros(nb)
    ar = []
    ma = []
    for i in range(nb):
        xi = x[i*num_parameters:(i+1)*num_parameters]
        if d>0:
            mu[i] = xi[0]
        if p>0:
            ar.append(xi[d:(d+p)])
        ma.append(xi[d+p:])

    pynvtx_range_pop()
    return (mu, ar, ma)


def pack(p, d, q, nb, mu, ar, ma):
    """Pack mu, ar, and ma batched-groupings into a linearized vector `x`"""
    pynvtx_range_push("pack(ar,ma,mu) -> x")
    num_parameters = d + p + q
    x = np.zeros(num_parameters*nb)
    for i in range(nb):
        xi = np.zeros(num_parameters)
        if d>0:
            xi[0] = mu[i]
        
        for j in range(p):
            xi[j+d] = ar[i][j]
        for j in range(q):
            xi[j+p+d] = ma[i][j]
        # xi = np.array([mu[i]])
        # xi = np.r_[xi, ar[i]]
        # xi = np.r_[xi, ma[i]]
        x[i*num_parameters:(i+1)*num_parameters] = xi

    pynvtx_range_pop()
    return x

def batched_transform(p, d, q, nb, np.ndarray[double] x, isInv):
    cdef vector[double] vec_ar
    cdef vector[double] vec_ma
    cdef vector[double] vec_Tar
    cdef vector[double] vec_Tma

    pynvtx_range_push("batched_transform")
    # pack ar & ma into C++ vectors
    for ib in range(nb):
        for ip in range(p):
            vec_ar.push_back(x[(d+p+q)*ib + d + ip])
        for iq in range(q):
            vec_ma.push_back(x[(d+p+q)*ib + d + p + iq])

    batched_jones_transform(p, q, nb, isInv, vec_ar, vec_ma, vec_Tar, vec_Tma)

    # unpack Tar & Tma results into [np.ndarray]
    Tx = np.zeros(nb*(d+p+q))
    for ib in range(nb):

        # copy mu
        Tx[(d+p+q)*ib] = x[(d+p+q)*ib]

        # copy ar
        for ip in range(p):
            Tx[(d+p+q)*ib + d + ip] = vec_Tar[ib*p + ip]

        # copy ma
        for iq in range(q):
            Tx[(d+p+q)*ib + d + p + iq] = vec_Tma[ib*q + iq]

    pynvtx_range_pop()
    return (Tx)

def pynvtx_range_push(msg):
    cdef string s = msg.encode("UTF-8")
    nvtx_range_push(s)

def pynvtx_range_pop():
    nvtx_range_pop()


def batched_kfilter(np.ndarray[double, ndim=2] y,
                    np.ndarray[double, ndim=1] mu_ar_ma_params_x, # [mu, ar.., ma..., mu, ar.., ma.., ...]
                    int p, int d, int q,
                    initP_with_kalman_iterations=False):

    cdef vector[double] vec_loglike_b
    
    cdef int nobs = y.shape[0]
    cdef int num_batches = y.shape[1]

    # cuDF wasn't working well, comment out for now
    # # Extract device pointer from DataFrame. Careful: `y_mat` temporary is to
    # # avoid the "gpu_matrix" object from getting garbage collected. `ytmp`
    # # simply satisfies the Cython compiler.
    # y_mat = y.as_gpu_matrix()
    # cdef unsigned long long ytmp = y_mat.gpu_data.device_pointer.value
    # cdef double* y_ptr = <double*>ytmp

    cdef vector[double] vec_b_ar_params
    cdef vector[double] vec_b_ma_params

    cdef vector[double*] vec_ys_b

    cdef vector[vector[double]] vec_vs_b

    pynvtx_range_push("batched_kfilter")

    pynvtx_range_push("batched_kfilter_copy_input")
    vec_b_ar_params.resize(p * num_batches)
    vec_b_ma_params.resize(q * num_batches)

    for i in range(num_batches):
        for ip in range(p):
            vec_b_ar_params[i*p + ip] = mu_ar_ma_params_x[i*(d+p+q) + d + ip]
        for iq in range(q):
            vec_b_ma_params[i*q + iq] = mu_ar_ma_params_x[i*(d+p+q) + d + p + iq]

    ll_b = np.zeros(num_batches)
    vs = np.zeros((nobs, num_batches))
    pynvtx_range_pop()

    batched_kalman_filter(&y[0,0],
                          nobs,
                          vec_b_ar_params,
                          vec_b_ma_params,
                          p, q,
                          num_batches,
                          vec_loglike_b,
                          vec_vs_b,
                          initP_with_kalman_iterations)

    # convert C++-results to numpy arrays
    pynvtx_range_push("batched_kfilter_copy_results")
    for i in range(num_batches):
        ll_b[i] = vec_loglike_b[i]
        for j in range(nobs):
            vs[j,i] = vec_vs_b[i][j]
    pynvtx_range_pop()

    pynvtx_range_pop()
    return ll_b, vs



# def kfilter_reference(ys, Z, R, T, r):
#     """Reference kalman filter implementation"""
#     loglikelihood = 0
#     alpha = np.zeros((r, 1))

#     # see D&K's TSA 5.6.2 for this formula
#     # TODO: Why use psuedo-inverse (seems to be just regular inverse in book)

#     invImTT = np.linalg.pinv(np.eye(r**2) - np.kron(T, T))
#     P0 = np.reshape(invImTT @ (R @ R.T).ravel(), (r, r))

#     # original:
#     #  P0 = np.reshape(np.dot(np.linalg.pinv(np.eye(r**2) - np.kron(T, T)),
#     #                         np.dot(R, R.T).ravel()), (r, r))

#     # if P0[0, 0] < 0.0:
#     #     print("WARNING: Proposed initial covariance P has negative diagonal entry, switching to P0=I")
#     #     P = P0
#     # else:

#     # use a single kalman iteration as covariance (P) initialization
#     P = np.copy(P0)

#     nobs = len(ys)
#     Fs = np.ones(nobs)
#     vs = np.zeros(nobs)
#     it = 0
#     F = 0

#     Ptm1 = np.copy(P)

#     # TODO: Why stop at F==1.0? (and it's basically never exactly 1.0)
#     while F != 1.0 and it < nobs:
#         v = ys[it] - alpha[0, 0]
#         F = P[0, 0]

#         if F < 0:
#             raise AssertionError("ERROR: F must be > 0. Possible non-positive definite covariance P: {}".format(P))

#         Fs[it] = F
#         vs[it] = v

#         # Recall: '@' is Python3 matrix multiplication operator
#         # set_trace()
#         K = 1.0/Fs[it] * (T @ P @ Z.T)
#         alpha = T*alpha + K*vs[it]
#         L = T - K @ Z
#         P = T @ P @ L.T + R @ R.T

#         # print("||P-Pm||=", np.linalg.norm(P-Ptm1))()
#         # print("P=\n{}\nPm1=\n{}\n--------------".format(P, Ptm1))
#         # set_trace()
#         Ptm1 = np.copy(P)

#         loglikelihood += np.log(F)
#         it += 1

#     for i in range(it, nobs):
#         v = ys[i] - alpha[0, 0]
#         vs[i] = v
#         alpha = T @ alpha + K * v

#     sigma2 = np.mean(vs**2 / Fs)
#     assert(sigma2 > 0)
#     loglike = -.5 * (loglikelihood + nobs * np.log(sigma2))
#     loglike -= nobs / 2. * (np.log(2 * np.pi) + 1)
#     # print("P vs P0 ||P-P0||", P, P0, np.linalg.norm(P-P0))
#     return vs, Fs, loglike, sigma2
