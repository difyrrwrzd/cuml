
#include <sstream>

#include <faiss/gpu/StandardGpuResources.h>
#include <faiss/gpu/GpuIndexFlat.h>
#include <faiss/gpu/GpuResources.h>

#ifndef _KNN_H
#define _KNN_H
namespace ML {

	using namespace faiss;

	class kNNParams {
	public:
		float *ptr;
		int N;
		std::ostream & operator<<(std::ostream & Str, kNNParams const & v) {
			std::stringstream ss;
			ss << "kNNParams {ptr=" << v.ptr << ", N=" << v.N << "}";
			return ss.str();
		}
	};

    class kNN {

		std::vector<long> id_ranges;

		std::vector<faiss::gpu::GpuResources* > res;
		std::vector<faiss::gpu::GpuIndexFlatL2* > sub_indices;

		int total_n;
		int indices;
		int D;

    private:
		template <class C>
		void merge_tables(long n, long k, long nshard,
							   float *distances, long *labels,
							   float *all_distances,
							   long *all_labels,
							   long *translations);

    public:
		kNN(int D);
		~kNN();
		void search(float *search_items, int search_items_size, long *res_I, float *res_D, int k);
		void fit(kNNParams *input, int N);

    };
}

#endif
