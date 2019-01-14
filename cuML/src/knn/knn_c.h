
#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/gpu/GpuIndexFlat.h>
#include <iostream>

#ifndef _KNN_H
#define _KNN_H
namespace ML {

    class kNN {
       
        faiss::gpu::StandardGpuResources res;  
        faiss::gpu::GpuIndexFlatL2 index_flat;

        public:
        kNN(int D);
        ~kNN();
        void search(float *search_items, int search_items_size, long *res_I, float *res_D, int k);
        void fit(float *input, int N);

    };
}

#endif
