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
#include <utils.h>
#include "cub/cub.cuh"

struct TemporaryMemory
{
	//Below four are for tree building
	int *leftlabels;
	int *rightlabels;
	int *sampledlabels;
	float *sampledcolumns;

	//Below are for gini & get_class functions
	int *ginilabels;
	int *d_unique_out;      
	int *d_counts_out;      
	int *d_num_runs_out;    
  	void *d_gini_temp_storage = NULL;
	size_t gini_temp_storage_bytes = 0;

	//Below pointers are shared for split functions
	char *d_flags_left;
	char *d_flags_right;
	void *d_split_temp_storage = NULL;
	size_t split_temp_storage_bytes = 0;
	int *d_num_selected_out;
	int *temprowids;
	
	TemporaryMemory(int N)
	{
		CUDA_CHECK(cudaMalloc((void**)&leftlabels,N*sizeof(int)));
		CUDA_CHECK(cudaMalloc((void**)&rightlabels,N*sizeof(int)));
		CUDA_CHECK(cudaMalloc((void**)&sampledcolumns,N*sizeof(float)));
		CUDA_CHECK(cudaMalloc((void**)&sampledlabels,N*sizeof(int)));

		// Allocate temporary storage for gini		
		CUDA_CHECK(cub::DeviceRunLengthEncode::Encode(d_gini_temp_storage, gini_temp_storage_bytes, ginilabels, d_unique_out, d_counts_out, d_num_runs_out, N));
		
		CUDA_CHECK(cudaMalloc((void**)(&ginilabels),N*sizeof(int)));
		CUDA_CHECK(cudaMalloc((void**)(&d_unique_out),N*sizeof(int)));
		CUDA_CHECK(cudaMalloc((void**)(&d_counts_out),N*sizeof(int)));
		CUDA_CHECK(cudaMalloc((void**)(&d_num_runs_out),sizeof(int)));
		CUDA_CHECK(cudaMalloc(&d_gini_temp_storage, gini_temp_storage_bytes));

		//Allocate Temporary for split functions
		cub::DeviceSelect::Flagged(d_split_temp_storage, split_temp_storage_bytes, ginilabels, d_flags_left, ginilabels,d_num_selected_out, N);
		
		CUDA_CHECK(cudaMalloc(&d_split_temp_storage, split_temp_storage_bytes));
		CUDA_CHECK(cudaMalloc(&d_num_selected_out,sizeof(int)));
		CUDA_CHECK(cudaMalloc(&d_flags_left,N*sizeof(char)));
		CUDA_CHECK(cudaMalloc(&d_flags_right,N*sizeof(char)));
		CUDA_CHECK(cudaMalloc(&temprowids,N*sizeof(int)));
	
	}
	
	~TemporaryMemory()
	{
		cudaFree(ginilabels);
		cudaFree(d_unique_out);
		cudaFree(d_counts_out);
		cudaFree(d_num_runs_out);
		cudaFree(d_gini_temp_storage);
		cudaFree(sampledcolumns);
		cudaFree(sampledlabels);
		cudaFree(leftlabels);
		cudaFree(rightlabels);
		cudaFree(d_split_temp_storage);
		cudaFree(d_num_selected_out);
		cudaFree(d_flags_left);
		cudaFree(d_flags_right);
		cudaFree(temprowids);
	}
	
};
