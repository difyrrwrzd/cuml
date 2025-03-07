#
# Copyright (c) 2019-2024, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# distutils: language = c++

from cuml.internals.safe_imports import cpu_only_import
np = cpu_only_import('numpy')
from cuml.internals.safe_imports import gpu_only_import
rmm = gpu_only_import('rmm')
import typing

IF GPUBUILD == 1:
    from cython.operator cimport dereference as deref
    from libcpp cimport bool
    from libc.stdint cimport uintptr_t, int64_t
    from libc.stdlib cimport calloc, free
    from pylibraft.common.handle cimport handle_t

    from cuml.cluster.cpp.kmeans cimport fit_predict as cpp_fit_predict
    from cuml.cluster.cpp.kmeans cimport predict as cpp_predict
    from cuml.cluster.cpp.kmeans cimport transform as cpp_transform
    from cuml.cluster.cpp.kmeans cimport KMeansParams
    from cuml.metrics.distance_type cimport DistanceType
    from cuml.cluster.kmeans_utils cimport *

from cuml.internals.array import CumlArray
from cuml.common.array_descriptor import CumlArrayDescriptor
from cuml.internals.base import Base
from cuml.common.doc_utils import generate_docstring
from cuml.internals.mixins import ClusterMixin
from cuml.internals.mixins import CMajorInputTagMixin
from cuml.common import input_to_cuml_array
from cuml.internals.api_decorators import device_interop_preparation
from cuml.internals.api_decorators import enable_device_interop


class KMeans(Base,
             ClusterMixin,
             CMajorInputTagMixin):

    """
    KMeans is a basic but powerful clustering method which is optimized via
    Expectation Maximization. It randomly selects K data points in X, and
    computes which samples are close to these points.
    For every cluster of points, a mean is computed (hence the name), and this
    becomes the new centroid.

    cuML's KMeans expects an array-like object or cuDF DataFrame, and supports
    the scalable KMeans++ initialization method. This method is more stable
    than randomly selecting K points.

    Examples
    --------

    .. code-block:: python

        >>> # Both import methods supported
        >>> from cuml import KMeans
        >>> from cuml.cluster import KMeans
        >>> import cudf
        >>> import numpy as np
        >>> import pandas as pd
        >>>
        >>> a = np.asarray([[1.0, 1.0], [1.0, 2.0], [3.0, 2.0], [4.0, 3.0]],
        ...                dtype=np.float32)
        >>> b = cudf.DataFrame(a)
        >>> # Input:
        >>> b
            0    1
        0  1.0  1.0
        1  1.0  2.0
        2  3.0  2.0
        3  4.0  3.0
        >>>
        >>> # Calling fit
        >>> kmeans_float = KMeans(n_clusters=2)
        >>> kmeans_float.fit(b)
        KMeans()
        >>>
        >>> # Labels:
        >>> kmeans_float.labels_
        0    0
        1    0
        2    1
        3    1
        dtype: int32
        >>> # cluster_centers:
        >>> kmeans_float.cluster_centers_
            0    1
        0  1.0  1.5
        1  3.5  2.5

    Parameters
    ----------
    handle : cuml.Handle
        Specifies the cuml.handle that holds internal CUDA state for
        computations in this model. Most importantly, this specifies the CUDA
        stream that will be used for the model's computations, so users can
        run different models concurrently in different streams by creating
        handles in several streams.
        If it is None, a new one is created.
    n_clusters : int (default = 8)
        The number of centroids or clusters you want.
    max_iter : int (default = 300)
        The more iterations of EM, the more accurate, but slower.
    tol : float64 (default = 1e-4)
        Stopping criterion when centroid means do not change much.
    verbose : int or boolean, default=False
        Sets logging level. It must be one of `cuml.common.logger.level_*`.
        See :ref:`verbosity-levels` for more info.
    random_state : int (default = 1)
        If you want results to be the same when you restart Python, select a
        state.
    init : {'scalable-kmeans++', 'k-means||', 'random'} or an \
            ndarray (default = 'scalable-k-means++')

         - ``'scalable-k-means++'`` or ``'k-means||'``: Uses fast and stable
           scalable kmeans++ initialization.
         - ``'random'``: Choose `n_cluster` observations (rows) at random
           from data for the initial centroids.
         - If an ndarray is passed, it should be of
           shape (`n_clusters`, `n_features`) and gives the initial centers.

    n_init: int (default = 1)
        Number of instances the k-means algorithm will be called with
        different seeds. The final results will be from the instance
        that produces lowest inertia out of n_init instances.
    oversampling_factor : float64 (default = 2.0)
        The amount of points to sample
        in scalable k-means++ initialization for potential centroids.
        Increasing this value can lead to better initial centroids at the
        cost of memory. The total number of centroids sampled in scalable
        k-means++ is oversampling_factor * n_clusters * 8.
    max_samples_per_batch : int (default = 32768)
        The number of data samples to use for batches of the pairwise distance
        computation. This computation is done throughout both fit predict. The
        default should suit most cases. The total number of elements in the
        batched pairwise distance computation is :py:`max_samples_per_batch *
        n_clusters`. It might become necessary to lower this number when
        `n_clusters` becomes prohibitively large.
    output_type : {'input', 'array', 'dataframe', 'series', 'df_obj', \
        'numba', 'cupy', 'numpy', 'cudf', 'pandas'}, default=None
        Return results and set estimator attributes to the indicated output
        type. If None, the output type set at the module level
        (`cuml.global_settings.output_type`) will be used. See
        :ref:`output-data-type-configuration` for more info.

    Attributes
    ----------
    cluster_centers_ : array
        The coordinates of the final clusters. This represents of "mean" of
        each data cluster.
    labels_ : array
        Which cluster each datapoint belongs to.

    Notes
    -----
    KMeans requires `n_clusters` to be specified. This means one needs to
    approximately guess or know how many clusters a dataset has. If one is not
    sure, one can start with a small number of clusters, and visualize the
    resulting clusters with PCA, UMAP or T-SNE, and verify that they look
    appropriate.

    **Applications of KMeans**

        The biggest advantage of KMeans is its speed and simplicity. That is
        why KMeans is many practitioner's first choice of a clustering
        algorithm. KMeans has been extensively used when the number of clusters
        is approximately known, such as in big data clustering tasks,
        image segmentation and medical clustering.


    For additional docs, see `scikitlearn's Kmeans
    <http://scikit-learn.org/stable/modules/generated/sklearn.cluster.KMeans.html>`_.
    """

    _cpu_estimator_import_path = 'sklearn.cluster.KMeans'
    labels_ = CumlArrayDescriptor()
    cluster_centers_ = CumlArrayDescriptor()

    def _get_kmeans_params(self):
        IF GPUBUILD == 1:
            cdef KMeansParams* params = \
                <KMeansParams*>calloc(1, sizeof(KMeansParams))
            params.n_clusters = <int>self.n_clusters
            params.init = self._params_init
            params.max_iter = <int>self.max_iter
            params.tol = <double>self.tol
            params.verbosity = <int>self.verbose
            params.rng_state.seed = self.random_state
            params.metric = DistanceType.L2Expanded   # distance metric as squared L2: @todo - support other metrics # noqa: E501
            params.batch_samples = <int>self.max_samples_per_batch
            params.oversampling_factor = <double>self.oversampling_factor
            params.n_init = <int>self.n_init
            return <size_t>params
        ELSE:
            return None

    @device_interop_preparation
    def __init__(self, *, handle=None, n_clusters=8, max_iter=300, tol=1e-4,
                 verbose=False, random_state=1,
                 init='scalable-k-means++', n_init=1, oversampling_factor=2.0,
                 max_samples_per_batch=1<<15, convert_dtype=True,
                 output_type=None):
        super().__init__(handle=handle,
                         verbose=verbose,
                         output_type=output_type)
        self.n_clusters = n_clusters
        self.random_state = random_state
        self.max_iter = max_iter
        self.tol = tol
        self.n_init = n_init
        self.inertia_ = 0
        self.n_iter_ = 0
        self.oversampling_factor=oversampling_factor
        self.max_samples_per_batch=int(max_samples_per_batch)

        # internal array attributes
        self.labels_ = None
        self.cluster_centers_ = None

        # cuPy does not allow comparing with string. See issue #2372
        init_str = init if isinstance(init, str) else None

        # K-means++ is the constrained case of k-means||
        # w/ oversampling factor = 0
        if (init_str == 'k-means++'):
            init_str = 'k-means||'
            self.oversampling_factor = 0

        if (init_str in ['scalable-k-means++', 'k-means||']):
            self.init = init_str

            IF GPUBUILD == 1:
                self._params_init = KMeansPlusPlus

        elif (init_str == 'random'):
            self.init = init

            IF GPUBUILD == 1:
                self._params_init = Random

        else:
            self.init = 'preset'

            IF GPUBUILD == 1:
                self._params_init = Array
            self.cluster_centers_, _n_rows, self.n_cols, self.dtype = \
                input_to_cuml_array(
                    init, order='C',
                    convert_to_dtype=(np.float32 if convert_dtype
                                      else None),
                    check_dtype=[np.float32, np.float64]
                )

    @generate_docstring()
    @enable_device_interop
    def fit(self, X, sample_weight=None, convert_dtype=True) -> "KMeans":
        """
        Compute k-means clustering with X.

        """
        if self.init == 'preset':
            check_cols = self.n_cols
            check_dtype = self.dtype
            target_dtype = self.dtype
        else:
            check_cols = False
            check_dtype = [np.float32, np.float64]
            target_dtype = np.float32

        _X_m, _n_rows, self.n_cols, self.dtype = \
            input_to_cuml_array(X,
                                order='C',
                                check_cols=check_cols,
                                convert_to_dtype=(target_dtype if convert_dtype
                                                  else None),
                                check_dtype=check_dtype)

        IF GPUBUILD == 1:

            cdef uintptr_t input_ptr = _X_m.ptr

            cdef handle_t* handle_ = <handle_t*><size_t>self.handle.getHandle()

            if sample_weight is None:
                sample_weight_m = CumlArray.ones(shape=_n_rows, dtype=self.dtype)
            else:
                sample_weight_m, _, _, _ = \
                    input_to_cuml_array(sample_weight, order='C',
                                        convert_to_dtype=self.dtype,
                                        check_rows=_n_rows)

            cdef uintptr_t sample_weight_ptr = sample_weight_m.ptr

            int_dtype = np.int32 if np.int64(_n_rows) * np.int64(self.n_cols) < 2**31-1 else np.int64

            self.labels_ = CumlArray.zeros(shape=_n_rows, dtype=int_dtype)
            cdef uintptr_t labels_ptr = self.labels_.ptr

            if (self.init in ['scalable-k-means++', 'k-means||', 'random']):
                self.cluster_centers_ = \
                    CumlArray.zeros(shape=(self.n_clusters, self.n_cols),
                                    dtype=self.dtype, order='C')

            cdef uintptr_t cluster_centers_ptr = self.cluster_centers_.ptr

            cdef float inertiaf = 0
            cdef double inertiad = 0

            cdef KMeansParams* params = \
                <KMeansParams*><size_t>self._get_kmeans_params()

            cdef int n_iter_int = 0
            cdef int64_t n_iter_int64 = 0

            if self.dtype == np.float32:
                if int_dtype == np.int32:
                    cpp_fit_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <const float*> input_ptr,
                        <int> _n_rows,
                        <int> self.n_cols,
                        <const float *>sample_weight_ptr,
                        <float*> cluster_centers_ptr,
                        <int*> labels_ptr,
                        inertiaf,
                        n_iter_int)
                    self.n_iter_ = n_iter_int
                else:
                    cpp_fit_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <const float*> input_ptr,
                        <int64_t> _n_rows,
                        <int64_t> self.n_cols,
                        <const float *>sample_weight_ptr,
                        <float*> cluster_centers_ptr,
                        <int64_t*> labels_ptr,
                        inertiaf,
                        n_iter_int64)
                    self.n_iter_ = n_iter_int64
                self.handle.sync()
                self.inertia_ = inertiaf

            elif self.dtype == np.float64:
                if int_dtype == np.int32:
                    cpp_fit_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <const double*> input_ptr,
                        <int> _n_rows,
                        <int> self.n_cols,
                        <const double *>sample_weight_ptr,
                        <double*> cluster_centers_ptr,
                        <int*> labels_ptr,
                        inertiad,
                        n_iter_int)
                    self.n_iter_ = n_iter_int

                else:
                    cpp_fit_predict(
                         handle_[0],
                         <KMeansParams> deref(params),
                         <const double*> input_ptr,
                         <int64_t> _n_rows,
                         <int64_t> self.n_cols,
                         <const double *>sample_weight_ptr,
                         <double*> cluster_centers_ptr,
                         <int64_t*> labels_ptr,
                         inertiad,
                         n_iter_int64)
                    self.n_iter_ = n_iter_int64
                self.handle.sync()
                self.inertia_ = inertiad
            else:
                raise TypeError('KMeans supports only float32 and float64 input,'
                                'but input type ' + str(self.dtype) +
                                ' passed.')

            self.handle.sync()
            del _X_m
            del sample_weight_m
            free(params)
        return self

    @generate_docstring(return_values={'name': 'preds',
                                       'type': 'dense',
                                       'description': 'Cluster indexes',
                                       'shape': '(n_samples, 1)'})
    @enable_device_interop
    def fit_predict(self, X, sample_weight=None) -> CumlArray:
        """
        Compute cluster centers and predict cluster index for each sample.

        """
        return self.fit(X, sample_weight=sample_weight).labels_

    def _predict_labels_inertia(self, X, convert_dtype=True,
                                sample_weight=None,
                                normalize_weights=True
                                ) -> typing.Tuple[CumlArray, float]:
        """
        Predict the closest cluster each sample in X belongs to.

        Parameters
        ----------
        X : array-like (device or host) shape = (n_samples, n_features)
            Dense matrix (floats or doubles) of shape (n_samples, n_features).
            Acceptable formats: cuDF DataFrame, NumPy ndarray, Numba device
            ndarray, cuda array interface compliant array like CuPy

        convert_dtype : bool, optional (default = False)
            When set to True, the predict method will, when necessary, convert
            the input to the data type which was used to train the model. This
            will increase memory used for the method.

        sample_weight : array-like (device or host) shape = (n_samples,), default=None # noqa
            The weights for each observation in X. If None, all observations
            are assigned equal weight.

        Returns
        -------
        labels : array
        Which cluster each datapoint belongs to.

        inertia : float/double
        Sum of squared distances of samples to their closest cluster center.
        """

        _X_m, _n_rows, _n_cols, _ = \
            input_to_cuml_array(X, order='C', check_dtype=self.dtype,
                                convert_to_dtype=(self.dtype if convert_dtype
                                                  else None),
                                check_cols=self.n_cols)

        IF GPUBUILD == 1:
            cdef uintptr_t input_ptr = _X_m.ptr

            if sample_weight is None:
                sample_weight_m = CumlArray.ones(shape=_n_rows, dtype=self.dtype)
            else:
                sample_weight_m, _, _, _ = \
                    input_to_cuml_array(sample_weight, order='C',
                                        convert_to_dtype=self.dtype,
                                        check_rows=_n_rows)

            cdef uintptr_t sample_weight_ptr = sample_weight_m.ptr

            cdef handle_t* handle_ = <handle_t*><size_t>self.handle.getHandle()

            cdef uintptr_t cluster_centers_ptr = self.cluster_centers_.ptr

            int_dtype = np.int32 if np.int64(_n_rows) * np.int64(_n_cols) < 2**31-1 else np.int64

            labels_ = CumlArray.zeros(shape=_n_rows, dtype=int_dtype,
                                      index=_X_m.index)

            cdef uintptr_t labels_ptr = labels_.ptr

            # Sum of squared distances of samples to their closest cluster center.
            cdef float inertiaf = 0
            cdef double inertiad = 0
            cdef KMeansParams* params = \
                <KMeansParams*><size_t>self._get_kmeans_params()

            if self.dtype == np.float32:
                if int_dtype == np.int32:
                    cpp_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <float*> cluster_centers_ptr,
                        <float*> input_ptr,
                        <size_t> _n_rows,
                        <size_t> self.n_cols,
                        <float *>sample_weight_ptr,
                        <bool> normalize_weights,
                        <int*> labels_ptr,
                        inertiaf)
                else:
                    cpp_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <float*> cluster_centers_ptr,
                        <float*> input_ptr,
                        <int64_t> _n_rows,
                        <int64_t> self.n_cols,
                        <float *>sample_weight_ptr,
                        <bool> normalize_weights,
                        <int64_t*> labels_ptr,
                        inertiaf)
                self.handle.sync()
                inertia = inertiaf
            elif self.dtype == np.float64:
                if int_dtype == np.int32:
                    cpp_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <double*> cluster_centers_ptr,
                        <double*> input_ptr,
                        <size_t> _n_rows,
                        <size_t> self.n_cols,
                        <double *>sample_weight_ptr,
                        <bool> normalize_weights,
                        <int*> labels_ptr,
                        inertiad)
                else:
                    cpp_predict(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <double*> cluster_centers_ptr,
                        <double*> input_ptr,
                        <int64_t> _n_rows,
                        <int64_t> self.n_cols,
                        <double *>sample_weight_ptr,
                        <bool> normalize_weights,
                        <int64_t*> labels_ptr,
                        inertiad)

                self.handle.sync()
                inertia = inertiad
            else:
                raise TypeError('KMeans supports only float32 and float64 input,'
                                'but input type ' + str(self.dtype) +
                                ' passed.')

            self.handle.sync()
            del _X_m
            del sample_weight_m
            free(params)
            return labels_, inertia

    @generate_docstring(return_values={'name': 'preds',
                                       'type': 'dense',
                                       'description': 'Cluster indexes',
                                       'shape': '(n_samples, 1)'})
    @enable_device_interop
    def predict(self, X, convert_dtype=True, sample_weight=None,
                normalize_weights=True) -> CumlArray:
        """
        Predict the closest cluster each sample in X belongs to.

        """

        labels, _ = self._predict_labels_inertia(
            X,
            convert_dtype=convert_dtype,
            sample_weight=sample_weight,
            normalize_weights=normalize_weights)
        return labels

    @generate_docstring(return_values={'name': 'X_new',
                                       'type': 'dense',
                                       'description': 'Transformed data',
                                       'shape': '(n_samples, n_clusters)'})
    @enable_device_interop
    def transform(self, X, convert_dtype=True) -> CumlArray:
        """
        Transform X to a cluster-distance space.

        """

        _X_m, _n_rows, _n_cols, _dtype = \
            input_to_cuml_array(X, order='C', check_dtype=self.dtype,
                                convert_to_dtype=(self.dtype if convert_dtype
                                                  else None),
                                check_cols=self.n_cols)
        IF GPUBUILD == 1:
            cdef uintptr_t input_ptr = _X_m.ptr

            cdef handle_t* handle_ = <handle_t*><size_t>self.handle.getHandle()

            cdef uintptr_t cluster_centers_ptr = self.cluster_centers_.ptr

            preds = CumlArray.zeros(shape=(_n_rows, self.n_clusters),
                                    dtype=self.dtype,
                                    order='C')

            cdef uintptr_t preds_ptr = preds.ptr

            # distance metric as L2-norm/euclidean distance: @todo - support other metrics # noqa: E501
            cdef KMeansParams* params = \
                <KMeansParams*><size_t>self._get_kmeans_params()
            params.metric = DistanceType.L2SqrtExpanded

            int_dtype = np.int32 if self.labels_.dtype == np.int32 else np.int64

            if self.dtype == np.float32:
                if int_dtype == np.int32:
                    cpp_transform(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <float*> cluster_centers_ptr,
                        <float*> input_ptr,
                        <int> _n_rows,
                        <int> self.n_cols,
                        <float*> preds_ptr)
                else:
                    cpp_transform(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <float*> cluster_centers_ptr,
                        <float*> input_ptr,
                        <int64_t> _n_rows,
                        <int64_t> self.n_cols,
                        <float*> preds_ptr)

            elif self.dtype == np.float64:
                if int_dtype == np.int32:
                    cpp_transform(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <double*> cluster_centers_ptr,
                        <double*> input_ptr,
                        <int> _n_rows,
                        <int> self.n_cols,
                        <double*> preds_ptr)
                else:
                    cpp_transform(
                        handle_[0],
                        <KMeansParams> deref(params),
                        <double*> cluster_centers_ptr,
                        <double*> input_ptr,
                        <int64_t> _n_rows,
                        <int64_t> self.n_cols,
                        <double*> preds_ptr)

            else:
                raise TypeError('KMeans supports only float32 and float64 input,'
                                'but input type ' + str(self.dtype) +
                                ' passed.')

            self.handle.sync()

            del _X_m
            free(params)
            return preds

    @generate_docstring(return_values={'name': 'score',
                                       'type': 'float',
                                       'description': 'Opposite of the value \
                                                        of X on the K-means \
                                                        objective.'})
    @enable_device_interop
    def score(self, X, y=None, sample_weight=None, convert_dtype=True):
        """
        Opposite of the value of X on the K-means objective.

        """

        return -1 * self._predict_labels_inertia(
            X, convert_dtype=convert_dtype,
            sample_weight=sample_weight)[1]

    @generate_docstring(return_values={'name': 'X_new',
                                       'type': 'dense',
                                       'description': 'Transformed data',
                                       'shape': '(n_samples, n_clusters)'})
    @enable_device_interop
    def fit_transform(self, X, convert_dtype=False,
                      sample_weight=None) -> CumlArray:
        """
        Compute clustering and transform X to cluster-distance space.

        """
        self.fit(X, sample_weight=sample_weight)
        return self.transform(X, convert_dtype=convert_dtype)

    def get_param_names(self):
        return super().get_param_names() + \
            ['n_init', 'oversampling_factor', 'max_samples_per_batch',
                'init', 'max_iter', 'n_clusters', 'random_state',
                'tol', "convert_dtype"]
