#pragma once

#include "cuda_utils.h"
#include "linalg/gemm.h"

namespace MLCommon {
namespace LinAlg {

template <typename IType,
          typename AccType,
          typename OType,
          typename OutputTile_,
          typename EpilogueFunctor_ = cutlass::gemm::LinearScaling<OType>,
          typename AccumulatorsPerThread_ = cutlass::Shape<8,8,8>,
          typename MainLoopFunctor_ =
              cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                               cutlass::Shape<1,4,8>,
                                               IType, IType, AccType> >
void row_gemm(cublasOperation_t transA, cublasOperation_t transB,
          int m, int n, int k,
          OType alpha,
          IType const* A, int lda,
          IType const* B, int ldb,
          OType beta,
          OType const* C, int ldc,
          OType* D) {
  gemm<IType, AccType, OType, OutputTile_,
    EpilogueFunctor_, AccumulatorsPerThread_, MainLoopFunctor_>
    (transB, transA, n, m, k, alpha, B, ldb, A, lda, beta, C, ldc, D);

}

template <typename IType,
          typename AccType,
          typename OType,
          typename OutputTile_,
          typename EpilogueFunctor_ = cutlass::gemm::LinearScaling<OType>,
          typename AccumulatorsPerThread_ = cutlass::Shape<8,8,8>,
          typename MainLoopFunctor_ =
              cutlass::gemm::ThreadMultiplyAdd<AccumulatorsPerThread_,
                                               cutlass::Shape<1,4,8>,
                                               IType, IType, AccType> >
void row_gemm(cublasOperation_t transA, cublasOperation_t transB,
          int m, int n, int k,
          OType alpha,
          IType const* A,
          IType const* B,
          OType beta,
          OType const* C,
          OType* D) {
  int lda = (transA == CUBLAS_OP_N) ? k : m;
  int ldb = (transB == CUBLAS_OP_N) ? n : k;
  int ldc = n;  // output is always row-major!
  row_gemm<IType, AccType, OType, OutputTile_,
    EpilogueFunctor_, AccumulatorsPerThread_, MainLoopFunctor_>
    (transA, transB, m, n, k, alpha, A, lda, B, ldb, beta, C, ldc, D);
}

}; // end namespace LinAlg
}; // end namespace MLCommon
