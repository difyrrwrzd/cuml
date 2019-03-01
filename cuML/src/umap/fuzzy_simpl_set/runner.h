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
#include "naive.h"

#pragma once

namespace UMAPAlgo {

namespace FuzzySimplSet {

	using namespace ML;

    /** number of threads in a CTA along X dim */
    static const int TPB_X = 32;


	/**
	 * Calculates a fuzzy simplicial set of the input X and kNN results
	 * @param n: number of rows in X
	 * @param knn_indices: matrix of kNN indices size (nxn)
	 * @param knn_dists: matrix of kNN dists size (nxn)
	 * @param sigmas: output sigma params
	 * @param rhos: output rho params
	 * @param algorithm: the algorithm to use (allows easy comparisons)
	 */
	template<typename T>
	void run(int n,
			 const long *knn_indices, const T *knn_dists,
			 int *rows, int *cols, T *vals,
			 UMAPParams *params, int *nnz,
			 int algorithm = 0) {

		switch(algorithm) {
		case 0:
			Naive::launcher<TPB_X>(n, knn_indices, knn_dists,
					       rows, cols, vals, nnz,
					       params);
			break;
		}
	}
}
};
