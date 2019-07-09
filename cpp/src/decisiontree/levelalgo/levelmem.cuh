#pragma once

struct LevelTemporaryMemory {
  cudaStream_t stream;
  MLCommon::device_buffer<unsigned int> *d_flags;
  MLCommon::device_buffer<unsigned int> *d_histogram;
  MLCommon::host_buffer<unsigned int> *h_histogram;
  MLCommon::host_buffer<int> *h_split_colidx;
  MLCommon::host_buffer<int> *h_split_binidx;
  MLCommon::device_buffer<int> *d_split_colidx;
  MLCommon::device_buffer<int> *d_split_binidx;
  MLCommon::host_buffer<unsigned int> *h_new_node_flags;
  MLCommon::device_buffer<unsigned int> *d_new_node_flags;
  MLCommon::host_buffer<unsigned int> *h_parent_hist, *h_child_hist;
  MLCommon::device_buffer<unsigned int> *d_parent_hist, *d_child_hist;
  MLCommon::host_buffer<float> *h_parent_metric, *h_outgain,
    *h_child_best_metric;
  MLCommon::device_buffer<float> *d_parent_metric, *d_outgain,
    *d_child_best_metric;

  int max_nodes = 0;
  LevelTemporaryMemory(const ML::cumlHandle_impl &handle, const int nrows,
                       const int ncols, const int nbins,
                       const int n_unique_labels, const int depth) {
    int maxnodes = pow(2, depth);
    size_t histcount = ncols * nbins * n_unique_labels * maxnodes;
    stream = handle.getStream();
    d_flags = new MLCommon::device_buffer<unsigned int>(
      handle.getDeviceAllocator(), stream, nrows);
    d_histogram = new MLCommon::device_buffer<unsigned int>(
      handle.getDeviceAllocator(), stream, histcount);
    h_histogram = new MLCommon::host_buffer<unsigned int>(
      handle.getHostAllocator(), stream, histcount);
    h_split_colidx = new MLCommon::host_buffer<int>(
      handle.getHostAllocator(), stream, maxnodes);
    h_split_binidx = new MLCommon::host_buffer<int>(
      handle.getHostAllocator(), stream, maxnodes);

    d_split_colidx = new MLCommon::device_buffer<int>(
      handle.getDeviceAllocator(), stream, maxnodes);
    d_split_binidx = new MLCommon::device_buffer<int>(
      handle.getDeviceAllocator(), stream, maxnodes);

    h_new_node_flags = new MLCommon::host_buffer<unsigned int>(
      handle.getHostAllocator(), stream, maxnodes);

    d_new_node_flags = new MLCommon::device_buffer<unsigned int>(
      handle.getDeviceAllocator(), stream, maxnodes);

    h_parent_hist = new MLCommon::host_buffer<unsigned int>(
      handle.getHostAllocator(), stream, maxnodes * n_unique_labels);
    h_child_hist = new MLCommon::host_buffer<unsigned int>(
      handle.getHostAllocator(), stream, 2 * maxnodes * n_unique_labels);
    h_parent_metric = new MLCommon::host_buffer<float>(
      handle.getHostAllocator(), stream, maxnodes);
    h_child_best_metric = new MLCommon::host_buffer<float>(
      handle.getHostAllocator(), stream, 2 * maxnodes);
    h_outgain = new MLCommon::host_buffer<float>(handle.getHostAllocator(),
                                                 stream, maxnodes);

    d_parent_hist = new MLCommon::device_buffer<unsigned int>(
      handle.getDeviceAllocator(), stream, maxnodes * n_unique_labels);
    d_child_hist = new MLCommon::device_buffer<unsigned int>(
      handle.getDeviceAllocator(), stream, 2 * maxnodes * n_unique_labels);
    d_parent_metric = new MLCommon::device_buffer<float>(
      handle.getDeviceAllocator(), stream, maxnodes);
    d_child_best_metric = new MLCommon::device_buffer<float>(
      handle.getDeviceAllocator(), stream, 2 * maxnodes);
    d_outgain = new MLCommon::device_buffer<float>(handle.getDeviceAllocator(),
                                                 stream, maxnodes);

    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, handle.getDevice()));
    size_t max_shared_mem = prop.sharedMemPerBlock;
    max_nodes = max_shared_mem / (nbins * n_unique_labels * sizeof(int));
  }

  ~LevelTemporaryMemory() {
    //Free
    h_new_node_flags->release(stream);
    d_new_node_flags->release(stream);
    h_histogram->release(stream);
    d_histogram->release(stream);
    h_split_colidx->release(stream);
    d_split_colidx->release(stream);
    h_split_binidx->release(stream);
    d_split_binidx->release(stream);
    h_parent_hist->release(stream);
    h_child_hist->release(stream);
    h_parent_metric->release(stream);
    h_child_best_metric->release(stream);
    h_outgain->release(stream);
    d_parent_hist->release(stream);
    d_child_hist->release(stream);
    d_parent_metric->release(stream);
    d_child_best_metric->release(stream);
    d_outgain->release(stream);
    d_flags->release(stream);
	
    delete h_new_node_flags;
    delete d_new_node_flags;
    delete d_histogram;
    delete h_histogram;
    delete h_split_colidx;
    delete d_split_colidx;
    delete h_split_binidx;
    delete d_split_binidx;
    delete h_parent_hist;
    delete h_child_hist;
    delete h_parent_metric;
    delete h_child_best_metric;
    delete h_outgain;
    delete d_parent_hist;
    delete d_child_hist;
    delete d_parent_metric;
    delete d_child_best_metric;
    delete d_outgain;
    delete d_flags;
  }
};
