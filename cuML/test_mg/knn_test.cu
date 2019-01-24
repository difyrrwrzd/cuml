
#include "knn/knn.cu"
#include <vector>
#include <gtest/gtest.h>
#include <cuda_utils.h>
#include <test_utils.h>
#include <iostream>

namespace ML {

using namespace MLCommon;


/**
 *
 * NOTE: Not exhaustively testing the kNN implementation since
 * we are using FAISS for this. Just testing API to verify the
 * knn.cu class is accepting inputs and providing outputs as
 * expected.
 */
template<typename T>
class KNN_MGTest: public ::testing::Test {
protected:
	void basicTest() {

		std::cout << "Running knn test" << std::endl;

		// Allocate input
        allocate(d_train_inputs, n * d);

        // Allocate reference arrays
        allocate<long>(d_ref_I, n*n);
        allocate(d_ref_D, n*n);

        // Allocate predicted arrays
        allocate<long>(d_pred_I, n*n);
        allocate(d_pred_D, n*n);

        // make testdata on host
        std::vector<T> h_train_inputs = {1.0, 50.0, 51.0};
        h_train_inputs.resize(n);
        updateDevice(d_train_inputs, h_train_inputs.data(), n*d);

        std::vector<T> h_res_D = { 0.0, 2401.0, 2500.0, 0.0, 1.0, 2401.0, 0.0, 1.0, 2500.0 };
        h_res_D.resize(n*n);
        updateDevice(d_ref_D, h_res_D.data(), n*n);

        std::vector<long> h_res_I = { 0, 1, 2, 1, 2, 0, 2, 1, 0 };
        h_res_I.resize(n*n);
        updateDevice<long>(d_ref_I, h_res_I.data(), n*n);

        std::cout << "Allocations done. Fitting..." << std::endl;

        kNNParams params[1];
        params[0] = { d_train_inputs, n };

        knn->fit(params, 1);

        std::cout << "Done fitting. Searching..." << std::endl;

        knn->search(d_train_inputs, n, d_pred_I, d_pred_D, n);


        std::cout << "Done." << std::endl;
    }

 	void SetUp() override {
		basicTest();
	}

	void TearDown() override {
		CUDA_CHECK(cudaFree(d_train_inputs));
		CUDA_CHECK(cudaFree(d_pred_I));
		CUDA_CHECK(cudaFree(d_pred_D));
		CUDA_CHECK(cudaFree(d_ref_I));
		CUDA_CHECK(cudaFree(d_ref_D));
	}

protected:

	T* d_train_inputs;

	int n = 3;
	int d = 1;

    long *d_pred_I;
    T* d_pred_D;

    long *d_ref_I;
    T* d_ref_D;

    kNN *knn = new kNN(d);
};


typedef KNN_MGTest<float> KNNTestF;
TEST_F(KNNTestF, Fit) {
	ASSERT_TRUE(
			devArrMatch(d_ref_D, d_pred_D, n*n, Compare<float>()));
	ASSERT_TRUE(
			devArrMatch(d_ref_I, d_pred_I, n*n, Compare<long>()));
}

} // end namespace ML
