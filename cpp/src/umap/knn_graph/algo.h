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

#include "umap/umapparams.h"
#include "ml_cuda_utils.h"
#include "knn/knn.hpp"
#include "linalg/unary_op.h"
#include <iostream>
#include <cuda_utils.h>

#pragma once

namespace UMAPAlgo {

namespace kNNGraph {

	namespace Algo {

		using namespace ML;

		/**
		 * Initial implementation calls out to FAISS to do its work.
		 * TODO: cuML kNN implementation should support FAISS' approx NN variants (e.g. IVFPQ GPU).
		 */
		template<typename T>
		void launcher(
		        float *X, int x_n, int d,
					  long *knn_indices, T *knn_dists,
					  kNN *knn,
					  int n_neighbors,
					  UMAPParams *params, cudaStream_t stream) {

		    ArrayPtr<float> *p = new ArrayPtr<float>[1];
			p[0].ptr = X;
			p[0].N = x_n;

			knn->fit(p, 1);
			knn->search(X, x_n, knn_indices, knn_dists, n_neighbors);

			CUDA_CHECK(cudaDeviceSynchronize());

            auto adjust_vals_op = [] __device__(T input) {
                return sqrt(input);
            };

            MLCommon::LinAlg::unaryOp<T>(knn_dists, knn_dists, x_n*n_neighbors,
                                          adjust_vals_op, stream);

			delete p;
		}
	}
}
};

