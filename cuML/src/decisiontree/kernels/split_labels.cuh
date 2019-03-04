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

__global__ void flag_kernel(float* column,char* leftflag,char* rightflag,float quesval,const int nrows)
{
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	if(tid < nrows)
		{
			char lflag,rflag;
			float data = column[tid];
			if(data <= quesval)
				{
					lflag = 1;
					rflag = 0;
				}
			else
				{
					lflag = 0;
					rflag = 1;
				}
			leftflag[tid] = lflag;
			rightflag[tid] = rflag;
			
		}
	return;
}

int get_class(int *labels)
{
	int classval;
	CUDA_CHECK(cudaMemcpy(&classval,&labels[0],sizeof(int),cudaMemcpyDeviceToHost));
	
	return classval;
}
void split_labels(float *column,int* labels,int* leftlabels,int* rightlabels,const int nrows,int& leftnrows,int& rightnrows,float quesval)
{
	
	char *d_flags_left;
	char *d_flags_right;
	
	CUDA_CHECK(cudaMalloc(&d_flags_left,nrows*sizeof(char)));
	CUDA_CHECK(cudaMalloc(&d_flags_right,nrows*sizeof(char)));
	
	flag_kernel<<< (int)(nrows/128) + 1,128>>>(column,d_flags_left,d_flags_right,quesval,nrows);
	CUDA_CHECK(cudaGetLastError());
	CUDA_CHECK(cudaDeviceSynchronize());
	
	void *d_temp_storage = NULL;
	size_t temp_storage_bytes = 0;
	
	int *d_num_selected_out;
	CUDA_CHECK(cudaMalloc(&d_num_selected_out,sizeof(int)));
	CUDA_CHECK(cudaMemset(d_num_selected_out,0,sizeof(int)));
	cub::DeviceSelect::Flagged(d_temp_storage, temp_storage_bytes, labels, d_flags_left, leftlabels,d_num_selected_out, nrows);
	CUDA_CHECK(cudaMalloc(&d_temp_storage, temp_storage_bytes));
	cub::DeviceSelect::Flagged(d_temp_storage, temp_storage_bytes, labels, d_flags_left, leftlabels,d_num_selected_out, nrows);
	CUDA_CHECK(cudaMemcpy(&leftnrows,d_num_selected_out,sizeof(int),cudaMemcpyDeviceToHost));

	
	CUDA_CHECK(cudaMemset(d_num_selected_out,0,sizeof(int)));
	cub::DeviceSelect::Flagged(d_temp_storage, temp_storage_bytes, labels, d_flags_right, rightlabels,d_num_selected_out, nrows);
	CUDA_CHECK(cudaFree(d_temp_storage));
	CUDA_CHECK(cudaMemcpy(&rightnrows,d_num_selected_out,sizeof(int),cudaMemcpyDeviceToHost));
	
	CUDA_CHECK(cudaFree(d_num_selected_out));
	
	return;
}

void make_split(float *column,const float quesval,const int nrows,int& nrowsleft,int& nrowsright,unsigned int* rowids)
{
	
	char *d_flags_left;
	char *d_flags_right;
	int *temprowids;
	
	CUDA_CHECK(cudaMalloc(&d_flags_left,nrows*sizeof(char)));
	CUDA_CHECK(cudaMalloc(&d_flags_right,nrows*sizeof(char)));
	CUDA_CHECK(cudaMalloc(&temprowids,nrows*sizeof(int)));
	
	
	flag_kernel<<< (int)(nrows/128) + 1,128>>>(column,d_flags_left,d_flags_right,quesval,nrows);
	CUDA_CHECK(cudaGetLastError());
	CUDA_CHECK(cudaDeviceSynchronize());
	

	void *d_temp_storage = NULL;
	size_t temp_storage_bytes = 0;
	
	int *d_num_selected_out;
	CUDA_CHECK(cudaMalloc(&d_num_selected_out,sizeof(int)));
	CUDA_CHECK(cudaMemset(d_num_selected_out,0,sizeof(int)));

	cub::DeviceSelect::Flagged(d_temp_storage, temp_storage_bytes, rowids, d_flags_left, temprowids,d_num_selected_out, nrows);
	CUDA_CHECK(cudaMalloc(&d_temp_storage, temp_storage_bytes));
	cub::DeviceSelect::Flagged(d_temp_storage, temp_storage_bytes, rowids, d_flags_left, temprowids,d_num_selected_out, nrows);
	
	CUDA_CHECK(cudaMemcpy(&nrowsleft,d_num_selected_out,sizeof(int),cudaMemcpyDeviceToHost));
	
	CUDA_CHECK(cudaMemset(d_num_selected_out,0,sizeof(int)));
	
	cub::DeviceSelect::Flagged(d_temp_storage, temp_storage_bytes, rowids, d_flags_right, &temprowids[nrowsleft],d_num_selected_out, nrows);
	CUDA_CHECK(cudaFree(d_temp_storage));
	CUDA_CHECK(cudaMemcpy(&nrowsright,d_num_selected_out,sizeof(int),cudaMemcpyDeviceToHost));

	CUDA_CHECK(cudaMemcpy(rowids,temprowids,nrows*sizeof(int),cudaMemcpyDeviceToDevice));

	CUDA_CHECK(cudaFree(temprowids));
	CUDA_CHECK(cudaFree(d_num_selected_out));
	return;
}
