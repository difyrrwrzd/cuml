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

#include <cutlass/gemm/gemm_traits.h>
#include <cutlass/gemm/thread_multiply_add.h>
#include <cutlass/gemm/linear_scaling.h>
#include <cutlass/gemm/gemm_epilogue_traits.h>
#include <cutlass/gemm/gemm_epilogue.h>
#include <cutlass/gemm/gemm.h>
#include "cuda_utils.h"
#include <cublas_v2.h>
#include "cublas_wrappers.h"


namespace MLCommon {
namespace LinAlg {

struct NullInParams {};
struct NullOutParams {};


/**
 * this type has been mostly customized for float/double data-types
 * might require changes to the template params for others!
 */
template <
    /// Input type
    typename IType,
    /// Output type
    typename OType,
    /// The tile size for the GEMM KxNxM.
    typename OutputTile_,
    /// The number of accumulators per thread.
    typename AccumulatorsPerThread_,
    /// main loop functor
    typename MainLoopFunctor_,
    /// The number of scalars per LDG for A.
    int kScalarsPerLdgA_ = 1,
    /// The number of scalars per LDG for B.
    int kScalarsPerLdgB_ = 1,
    /// The number of scalars per LDG/STG/LDS for C or D.
    int kScalarsPerLdgC_ = 1>
struct CustomGemmConfig: public cutlass::gemm::GemmConfig<
    /// The scalar type for A.
    IType,
    /// The scalar type for B.
    IType,
    /// The scalar type for C.
    OType,
    /// The scalar type for D.
    OType,
    /// The tile size for the GEMM KxNxM.
    OutputTile_,
    /// The functor to do the math in the main loop.
    MainLoopFunctor_,
    /// The number of scalars per LDG for A.
    kScalarsPerLdgA_,
    /// The number of scalars per STS for A.
    kScalarsPerLdgA_,
    /// The number of scalars per LDS for A.
    16 / sizeof(IType),
    /// The number of scalars per LDG for B.
    kScalarsPerLdgB_,
    /// The number of scalars per STS for B.
    kScalarsPerLdgB_,
    /// The number of scalars per LDS for B.
    16 / sizeof(IType),
    /// The number of scalars per LDG for C and STG for D.
    kScalarsPerLdgC_,
    /// The number of scalars per STS for D.
    16 / sizeof(OType),
    /// The number of scalars per LDS for D.
    kScalarsPerLdgC_,
    /// The number of stages in shared memory.
    2> {
};


/**
 * main traits to customize cutlass gemm kernel
 * this type has been mostly customized for float/double data-types
 * might require changes to the template params for others!
 */
template <
    /// Input type
    typename IType,
    /// Accumulation type
    typename AccType,
    /// Output type
    typename OType,
    /// The layout for A.
    cutlass::MatrixLayout::Kind kLayoutA_,
    /// The layout for B.
    cutlass::MatrixLayout::Kind kLayoutB_,
    /// The output tile.
    typename OutputTile_,
    /// The number of accumulators per thread.
    typename AccumulatorsPerThread_ = cutlass::Shape<8, 8, 8>,
    /// the functor to use in main loop
    typename MainLoopFunctor_ =
        cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                         cutlass::Shape<1, 4, 8>,
                                         IType, IType, AccType>,
    /// The index.
    typename Index_ = int,
    /// The GEMM config.
    typename GemmConfig_ =
        CustomGemmConfig<IType, OType, OutputTile_,
                         AccumulatorsPerThread_,
                         MainLoopFunctor_>,
    /// The functor to use in the epilogue.
    typename EpilogueFunctor_ = cutlass::gemm::LinearScaling<OType>,
    /// The traits class for the epilogue.
    typename GemmEpilogueTraits_ =
        cutlass::gemm::SimplifiedGemmEpilogueTraits<GemmConfig_,
                                                    EpilogueFunctor_,
                                                    Index_>,
    /// The class for the epilogue.
    typename GemmEpilogue_ = 
        cutlass::gemm::GemmEpilogue<GemmEpilogueTraits_> >
struct CustomGemmTraits: public cutlass::gemm::SimplifiedGemmTraits<
    // The layout for A.
    kLayoutA_,
    // The layout for B.
    kLayoutB_,
    // The config.
    GemmConfig_,
    // The epilogue.
    GemmEpilogue_,
    // The index.
    Index_> {
};


/**
 * @brief main function to launch cutlass-gemm kernel. It computes the following
 *  equation: D = alpha . opA(A) * opB(B) + beta . C
 * @tparam IType input data-type (for A and B matrices)
 * @tparam AccType accumulation data-type
 * @tparam OType output data-type (for C and D matrices)
 * @tparam kLayoutA layout for A
 * @tparam kLayoutB layout for B
 * @tparam OutputTile_ output tile size for the thread block
 * @tparam EpilogueFunctor_ custom epilogue functor
 * @tparam AccumulatorsPerThread_ number of accumulators per thread
 * @tparam MainLoopFunctor_ custom functor to be used in the main loop
 * @tparam Lambda lambda to set any custom params inside EpilogueFunctor_
 * @param transA cublas transpose op for A
 * @param transB cublas transpose op for B
 * @param m number of rows of A and C/D
 * @param n number of columns of B and C/D
 * @param k number of cols of A and rows of B
 * @param alpha scalar
 * @param A input matrix
 * @param lda leading dim for A
 * @param B input matrix
 * @param ldb leading dim for B
 * @param beta scalar
 * @param C input matrix
 * @param ldc leading dim for C and D
 * @param D output matrix
 * @param op lambda function to set any custom params inside EpilogueFunctor_
 * @{
 */
template <typename IType,
          typename AccType,
          typename OType,
          cutlass::MatrixLayout::Kind kLayoutA,
          cutlass::MatrixLayout::Kind kLayoutB,
          typename OutputTile_,
          typename AccumulatorsPerThread_ = cutlass::Shape<8,8,8>,
          typename MainLoopFunctor_ =
              cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                               cutlass::Shape<1,4,8>,
                                               IType, IType, AccType>,
          typename InParams_ = NullInParams,
          typename OutParams_ = NullOutParams,
          typename Index_ = int,
          typename GemmConfig_ =
              CustomGemmConfig<IType, OType, OutputTile_,
                               AccumulatorsPerThread_,
                               MainLoopFunctor_>,
          typename EpilogueFunctor_ = cutlass::gemm::LinearScaling<OType>,
          typename GemmEpilogueTraits_ =
              cutlass::gemm::SimplifiedGemmEpilogueTraits<GemmConfig_,
                                                          EpilogueFunctor_,
                                                          Index_>,
          typename GemmEpilogue_ = 
              cutlass::gemm::GemmEpilogue<GemmEpilogueTraits_>,
          typename Lambda>
void gemmLauncher(cublasOperation_t transA, cublasOperation_t transB,
              int m, int n, int k,
              OType alpha,
              IType const* A, int lda,
              IType const* B, int ldb,
              OType beta,
              OType const* C, int ldc,
              OType* D,
              Lambda op,
              InParams_ const& in_params,
              OutParams_& out_params) {
    typedef CustomGemmTraits<IType, AccType, OType,
                             kLayoutA, kLayoutB,
                             OutputTile_,
                             AccumulatorsPerThread_,
                             MainLoopFunctor_,
                             Index_,
                             GemmConfig_,
                             EpilogueFunctor_,
                             GemmEpilogueTraits_,
                             GemmEpilogue_> GemmTraits;
    typedef typename cutlass::gemm::Gemm<GemmTraits> Gemm;
    typename Gemm::Params params;
    int err = params.initialize(m, n, k, alpha, A, lda, B, ldb, beta,
                                C, ldc, D, ldc);
    ASSERT(err == 0, "gemmLauncher: params.initialize failed err=%d", err);
    err = op(params.epilogue.functor, in_params, out_params);
    ASSERT(err == 0, "gemmLauncher: op(epiloguefunctor) failed err=%d", err);
    Gemm::launch(params);
}

template <typename IType,
          typename AccType,
          typename OType,
          typename OutputTile_,
          typename AccumulatorsPerThread_ = cutlass::Shape<8,8,8>,
          typename MainLoopFunctor_ =
              cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                               cutlass::Shape<1,4,8>,
                                               IType, IType, AccType>,
          typename InParams_ = NullInParams,
          typename OutParams_ = NullOutParams,
          typename Index_ = int,
          typename GemmConfig_ =
              CustomGemmConfig<IType, OType, OutputTile_,
                               AccumulatorsPerThread_,
                               MainLoopFunctor_>,
          typename EpilogueFunctor_ = cutlass::gemm::LinearScaling<OType>,
          typename GemmEpilogueTraits_ =
              cutlass::gemm::SimplifiedGemmEpilogueTraits<GemmConfig_,
                                                          EpilogueFunctor_,
                                                          Index_>,
          typename GemmEpilogue_ = 
              cutlass::gemm::GemmEpilogue<GemmEpilogueTraits_>,
          typename Lambda>
void baseGemm(cublasOperation_t transA, cublasOperation_t transB,
              int m, int n, int k,
              OType alpha,
              IType const* A, int lda,
              IType const* B, int ldb,
              OType beta,
              OType const* C, int ldc,
              OType* D,
              Lambda op,
              InParams_ const& in_params,
              OutParams_& out_params) {
    if(transA == CUBLAS_OP_N && transB == CUBLAS_OP_N) {
        gemmLauncher<IType, AccType, OType,
                     cutlass::MatrixLayout::kColumnMajor,
                     cutlass::MatrixLayout::kColumnMajor,
                     OutputTile_,
                     AccumulatorsPerThread_,
                     MainLoopFunctor_,
                     InParams_,
                     OutParams_,
                     Index_,
                     GemmConfig_,
                     EpilogueFunctor_,
                     GemmEpilogueTraits_,
                     GemmEpilogue_,
                     Lambda>(transA, transB, m, n, k, alpha, A, lda,
                             B, ldb, beta, C, ldc, D,
                             op, in_params, out_params);
    } else if(transA == CUBLAS_OP_N && transB == CUBLAS_OP_T) {
        gemmLauncher<IType, AccType, OType,
                     cutlass::MatrixLayout::kColumnMajor,
                     cutlass::MatrixLayout::kRowMajor,
                     OutputTile_,
                     AccumulatorsPerThread_,
                     MainLoopFunctor_,
                     InParams_,
                     OutParams_,
                     Index_,
                     GemmConfig_,
                     EpilogueFunctor_,
                     GemmEpilogueTraits_,
                     GemmEpilogue_,
                     Lambda>(transA, transB, m, n, k, alpha, A, lda,
                             B, ldb, beta, C, ldc, D,
                             op, in_params, out_params);
    } else if(transA == CUBLAS_OP_T && transB == CUBLAS_OP_N) {
        gemmLauncher<IType, AccType, OType,
                     cutlass::MatrixLayout::kRowMajor,
                     cutlass::MatrixLayout::kColumnMajor,
                     OutputTile_,
                     AccumulatorsPerThread_,
                     MainLoopFunctor_,
                     InParams_,
                     OutParams_,
                     Index_,
                     GemmConfig_,
                     EpilogueFunctor_,
                     GemmEpilogueTraits_,
                     GemmEpilogue_,
                     Lambda>(transA, transB, m, n, k, alpha, A, lda,
                             B, ldb, beta, C, ldc, D,
                             op, in_params, out_params);
    } else if(transA == CUBLAS_OP_T && transB == CUBLAS_OP_T) {
        gemmLauncher<IType, AccType, OType,
                     cutlass::MatrixLayout::kRowMajor,
                     cutlass::MatrixLayout::kRowMajor,
                     OutputTile_,
                     AccumulatorsPerThread_,
                     MainLoopFunctor_,
                     InParams_,
                     OutParams_,
                     Index_,
                     GemmConfig_,
                     EpilogueFunctor_,
                     GemmEpilogueTraits_,
                     GemmEpilogue_,
                     Lambda>(transA, transB, m, n, k, alpha, A, lda,
                             B, ldb, beta, C, ldc, D,
                             op, in_params, out_params);
    } else {
        ASSERT(false, "runGemm: Bad cublasOperation_t a=%d b=%d\n",
               (int)transA, (int)transB);
    }
    CUDA_CHECK(cudaPeekAtLastError());
}

template <typename IType,
          typename AccType,
          typename OType,
          typename OutputTile_,
          typename AccumulatorsPerThread_ = cutlass::Shape<8,8,8>,
          typename MainLoopFunctor_ =
              cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                               cutlass::Shape<1,4,8>,
                                               IType, IType, AccType>,
          typename InParams_ = NullInParams,
          typename OutParams_ = NullOutParams,
          typename Index_ = int,
          typename GemmConfig_ =
              CustomGemmConfig<IType, OType, OutputTile_,
                               AccumulatorsPerThread_,
                               MainLoopFunctor_>,
          typename EpilogueFunctor_ = cutlass::gemm::LinearScaling<OType>,
          typename GemmEpilogueTraits_ =
              cutlass::gemm::SimplifiedGemmEpilogueTraits<GemmConfig_,
                                                          EpilogueFunctor_,
                                                          Index_>,
          typename GemmEpilogue_ = 
              cutlass::gemm::GemmEpilogue<GemmEpilogueTraits_>,
          typename Lambda>
void gemm(cublasOperation_t transA, cublasOperation_t transB,
          int m, int n, int k,
          OType alpha,
          IType const* A, int lda,
          IType const* B, int ldb,
          OType beta,
          OType const* C, int ldc,
          OType* D,
          Lambda op,
          InParams_ const& in_params,
          OutParams_& out_params) {
    baseGemm<IType, AccType, OType, OutputTile_,
             AccumulatorsPerThread_, MainLoopFunctor_,
             InParams_,
             OutParams_,
             Index_,
             GemmConfig_,
             EpilogueFunctor_,
             GemmEpilogueTraits_,
             GemmEpilogue_,
             Lambda>
        (transA, transB, m, n, k, alpha, A, lda, B, ldb, beta, C, ldc, D,
         op,
         in_params,
         out_params);
}

template <typename IType,
          typename AccType,
          typename OType,
          typename OutputTile_,
          typename AccumulatorsPerThread_ = cutlass::Shape<8,8,8>,
          typename MainLoopFunctor_ =
              cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                               cutlass::Shape<1,4,8>,
                                               IType, IType, AccType>,
          typename EpilogueFunctor_ =
              cutlass::gemm::LinearScaling<OType> >
void gemm(cublasOperation_t transA, cublasOperation_t transB,
          int m, int n, int k,
          OType alpha,
          IType const* A, int lda,
          IType const* B, int ldb,
          OType beta,
          OType const* C, int ldc,
          OType* D) {
    typedef CustomGemmConfig<IType, OType, OutputTile_,
                                      AccumulatorsPerThread_,
                                      MainLoopFunctor_> GemmConfig_;

    NullInParams in_params;
    NullOutParams out_params;
    gemm<IType, AccType, OType, OutputTile_,
         AccumulatorsPerThread_,
         MainLoopFunctor_,
         NullInParams,
         NullOutParams,
         int,
         GemmConfig_,
         EpilogueFunctor_>
        (transA, transB, m, n, k, alpha, A, lda, B, ldb, beta, C, ldc, D,
         [] (typename EpilogueFunctor_::Params& p,
             NullInParams const& in_params, NullOutParams& out_params) {
             return 0;
         },
         in_params,
         out_params);
}

template <typename math_t>
void gemm(const math_t* a, int n_rows_a, int n_cols_a, const math_t* b, math_t* c, int n_rows_c, int n_cols_c,
		      bool trans_a, bool trans_b, math_t alpha, math_t beta, cublasHandle_t cublas_h) {

	cublasOperation_t op_a = trans_a ? CUBLAS_OP_T : CUBLAS_OP_N;
	cublasOperation_t op_b = trans_b ? CUBLAS_OP_T : CUBLAS_OP_N;

	int m = n_rows_c;
	int n = n_cols_c;
	int k = trans_a ? n_rows_a : n_cols_a;
	int lda = trans_a ? k : m;
	int ldb = trans_b ? n : k;
	int ldc = m;

	CUBLAS_CHECK(
			LinAlg::cublasgemm(cublas_h, op_a, op_b, m, n, k, &alpha, a, lda, b, ldb, &beta, c, ldc));
}

}; // end namespace LinAlg
}; // end namespace MLCommon
