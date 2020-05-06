#
# Copyright (c) 2019-2020, NVIDIA CORPORATION.
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

import random

from cuml.dask.common import raise_exception_from_futures
from cuml.ensemble import RandomForestClassifier as cuRFC
from cuml.dask.common.input_utils import DistributedDataHandler
from dask.distributed import default_client, wait
from cuml.dask.common.base import DelayedPredictionMixin, \
    DelayedPredictionProbaMixin
from cuml.dask.ensemble.base import \
    BaseRandomForestModel


class RandomForestClassifier(BaseRandomForestModel, DelayedPredictionMixin,
                             DelayedPredictionProbaMixin):

    """
    Experimental API implementing a multi-GPU Random Forest classifier
    model which fits multiple decision tree classifiers in an
    ensemble. This uses Dask to partition data over multiple GPUs
    (possibly on different nodes).

    Currently, this API makes the following assumptions:
    * The set of Dask workers used between instantiation, fit,
    and predict are all consistent
    * Training data comes in the form of cuDF dataframes,
    distributed so that each worker has at least one partition.

    Future versions of the API will support more flexible data
    distribution and additional input types.

    The distributed algorithm uses an embarrassingly-parallel
    approach. For a forest with N trees being built on w workers, each
    worker simply builds N/w trees on the data it has available
    locally. In many cases, partitioning the data so that each worker
    builds trees on a subset of the total dataset works well, but
    it generally requires the data to be well-shuffled in advance.
    Alternatively, callers can replicate all of the data across
    workers so that rf.fit receives w partitions, each containing the
    same data. This would produce results approximately identical to
    single-GPU fitting.

    Please check the single-GPU implementation of Random Forest
    classifier for more information about the underlying algorithm.

    Parameters
    -----------
    n_estimators : int (default = 10)
                   total number of trees in the forest (not per-worker)
    handle : cuml.Handle
        If it is None, a new one is created just for this class.
    split_criterion : The criterion used to split nodes.
        0 for GINI, 1 for ENTROPY, 4 for CRITERION_END.
        2 and 3 not valid for classification
        (default = 0)
    split_algo : 0 for HIST and 1 for GLOBAL_QUANTILE
        (default = 1)
        the algorithm to determine how nodes are split in the tree.
    split_criterion : The criterion used to split nodes.
        0 for GINI, 1 for ENTROPY, 4 for CRITERION_END.
        2 and 3 not valid for classification
        (default = 0)
    bootstrap : boolean (default = True)
        Control bootstrapping.
        If set, each tree in the forest is built
        on a bootstrapped sample with replacement.
        If false, sampling without replacement is done.
    bootstrap_features : boolean (default = False)
        Control bootstrapping for features.
        If features are drawn with or without replacement
    rows_sample : float (default = 1.0)
        Ratio of dataset rows used while fitting each tree.
    max_depth : int (default = -1)
        Maximum tree depth. Unlimited (i.e, until leaves are pure), if -1.
    max_leaves : int (default = -1)
        Maximum leaf nodes per tree. Soft constraint. Unlimited, if -1.
    max_features : float (default = 'auto')
        Ratio of number of features (columns) to consider
        per node split.
    n_bins : int (default = 8)
        Number of bins used by the split algorithm.
    min_rows_per_node : int (default = 2)
        The minimum number of samples (rows) needed to split a node.
    quantile_per_tree : boolean (default = False)
        Whether quantile is computed for individual RF trees.
        Only relevant for GLOBAL_QUANTILE split_algo.
    n_streams : int (default = 4 )
        Number of parallel streams used for forest building
    workers : optional, list of strings
        Dask addresses of workers to use for computation.
        If None, all available Dask workers will be used.

    Examples
    ---------
    For usage examples, please see the RAPIDS notebooks repository:
    https://github.com/rapidsai/notebooks/blob/branch-0.12/cuml/random_forest_mnmg_demo.ipynb
    """

    def __init__(
        self,
        n_estimators=10,
        max_depth=-1,
        max_features="auto",
        n_bins=8,
        split_algo=1,
        split_criterion=0,
        min_rows_per_node=2,
        bootstrap=True,
        bootstrap_features=False,
        type_model="classifier",
        verbose=False,
        rows_sample=1.0,
        max_leaves=-1,
        n_streams=4,
        quantile_per_tree=False,
        dtype=None,
        criterion=None,
        min_samples_leaf=None,
        min_weight_fraction_leaf=None,
        max_leaf_nodes=None,
        min_impurity_decrease=None,
        min_impurity_split=None,
        oob_score=None,
        n_jobs=None,
        random_state=None,
        warm_start=None,
        class_weight=None,
        workers=None,
        client=None
    ):

        unsupported_sklearn_params = {
            "criterion": criterion,
            "min_samples_leaf": min_samples_leaf,
            "min_weight_fraction_leaf": min_weight_fraction_leaf,
            "max_leaf_nodes": max_leaf_nodes,
            "min_impurity_decrease": min_impurity_decrease,
            "min_impurity_split": min_impurity_split,
            "oob_score": oob_score,
            "n_jobs": n_jobs,
            "random_state": random_state,
            "warm_start": warm_start,
            "class_weight": class_weight,
        }

        for key, vals in unsupported_sklearn_params.items():
            if vals is not None:
                raise TypeError(
                    "The Scikit-learn variable",
                    key,
                    " is not supported in cuML,"
                    " please read the cuML documentation for"
                    " more information",
                )

        self.n_estimators = n_estimators
        self.n_estimators_per_worker = list()
        self.num_classes = 2

        self.client = default_client() if client is None else client
        if workers is None:
            workers = self.client.has_what().keys()  # Default to all workers
        self.workers = workers
        self._create_the_model(
            model_func=RandomForestClassifier._func_build_rf,
            max_depth=max_depth,
            n_streams=n_streams,
            max_features=max_features,
            n_bins=n_bins,
            split_algo=split_algo,
            split_criterion=split_criterion,
            min_rows_per_node=min_rows_per_node,
            bootstrap=bootstrap,
            bootstrap_features=bootstrap_features,
            type_model=type_model,
            verbose=verbose,
            rows_sample=rows_sample,
            max_leaves=max_leaves,
            quantile_per_tree=quantile_per_tree,
            dtype=dtype)

    @staticmethod
    def _func_build_rf(
        n_estimators,
        seed,
        **kwargs
    ):
        return cuRFC(
            n_estimators=n_estimators,
            seed=seed,
            **kwargs
        )

    @staticmethod
    def _predict_model_on_cpu(model, X, convert_dtype, r):
        return model._predict_get_all(X, convert_dtype)

    def print_summary(self):
        """
        Print the summary of the forest used to train and test the model.
        """
        return self._print_summary()

    def fit(self, X, y, convert_dtype=False):
        """
        Fit the input data with a Random Forest classifier

        IMPORTANT: X is expected to be partitioned with at least one partition
        on each Dask worker being used by the forest (self.workers).

        If a worker has multiple data partitions, they will be concatenated
        before fitting, which will lead to additional memory usage. To minimize
        memory consumption, ensure that each worker has exactly one partition.

        When persisting data, you can use
        cuml.dask.common.utils.persist_across_workers to simplify this::

            X_dask_cudf = dask_cudf.from_cudf(X_cudf, npartitions=n_workers)
            y_dask_cudf = dask_cudf.from_cudf(y_cudf, npartitions=n_workers)
            X_dask_cudf, y_dask_cudf = persist_across_workers(dask_client,
                                                              [X_dask_cudf,
                                                               y_dask_cudf])

        (this is equivalent to calling `persist` with the data and workers)::
            X_dask_cudf, y_dask_cudf = dask_client.persist([X_dask_cudf,
                                                            y_dask_cudf],
                                                           workers={
                                                           X_dask_cudf=workers,
                                                           y_dask_cudf=workers
                                                           })

        Parameters
        ----------
        X : Dask cuDF dataframe  or CuPy backed Dask Array (n_rows, n_features)
            Distributed dense matrix (floats or doubles) of shape
            (n_samples, n_features).
        y : Dask cuDF dataframe  or CuPy backed Dask Array (n_rows, 1)
            Labels of training examples.
            **y must be partitioned the same way as X**
        convert_dtype : bool, optional (default = False)
            When set to True, the fit method will, when necessary, convert
            y to be the same data type as X if they differ. This
            will increase memory used for the method.

        """
        self.num_classes = len(y.unique())
        self._fit(model=self.rfs,
                  dataset=(X, y),
                  convert_dtype=convert_dtype)
        return self

    def predict(self, X, output_class=True, algo='auto', threshold=0.5,
                convert_dtype=True, predict_model="GPU",
                fil_sparse_format='auto', delayed=True):
        """
        Predicts the labels for X.

        Parameters
        ----------
        X : Dask cuDF dataframe  or CuPy backed Dask Array (n_rows, n_features)
            Distributed dense matrix (floats or doubles) of shape
            (n_samples, n_features).
        output_class : boolean (default = True)
            This is optional and required only while performing the
            predict operation on the GPU.
            If true, return a 1 or 0 depending on whether the raw
            prediction exceeds the threshold. If False, just return
            the raw prediction.
        algo : string (default = 'auto')
            This is optional and required only while performing the
            predict operation on the GPU.
            'naive' - simple inference using shared memory
            'tree_reorg' - similar to naive but trees rearranged to be more
            coalescing-friendly
            'batch_tree_reorg' - similar to tree_reorg but predicting
            multiple rows per thread block
            `algo` - choose the algorithm automatically. Currently
            'batch_tree_reorg' is used for dense storage
            and 'naive' for sparse storage
        threshold : float (default = 0.5)
            Threshold used for classification. Optional and required only
            while performing the predict operation on the GPU, that is for,
            predict_model='GPU'.
            It is applied if output_class == True, else it is ignored
        convert_dtype : bool, optional (default = True)
            When set to True, the predict method will, when necessary, convert
            the input to the data type which was used to train the model. This
            will increase memory used for the method.
        predict_model : String (default = 'GPU')
            'GPU' to predict using the GPU, 'CPU' otherwise. The GPU can only
            be used if the model was trained on float32 data and `X` is float32
            or convert_dtype is set to True.
        fil_sparse_format : boolean or string (default = auto)
            This variable is used to choose the type of forest that will be
            created in the Forest Inference Library. It is not required
            while using predict_model='CPU'.
            'auto' - choose the storage type automatically
            (currently True is chosen by auto)
            False - create a dense forest
            True - create a sparse forest, requires algo='naive'
            or algo='auto'
        delayed : bool (default = True)
            Whether to do a lazy prediction (and return Delayed objects) or an
            eagerly executed one.  It is not required  while using
            predict_model='CPU'.

        Returns
        ----------
        y : Dask cuDF dataframe or CuPy backed Dask Array (n_rows, 1)
        """
        if self.num_classes > 2 or predict_model == "CPU":
            preds = self.predict_model_on_cpu(X,
                                              convert_dtype=convert_dtype)

        else:
            preds = \
                self.predict_using_fil(X, output_class=output_class,
                                       algo=algo,
                                       threshold=threshold,
                                       num_classes=self.num_classes,
                                       convert_dtype=convert_dtype,
                                       predict_model="GPU",
                                       fil_sparse_format=fil_sparse_format,
                                       delayed=delayed)

        return preds

    def predict_using_fil(self, X, delayed, **kwargs):
        self.local_model = self._concat_treelite_models()
        return self._predict_using_fil(X=X,
                                       delayed=delayed,
                                       **kwargs)
    """
    TODO : Update function names used for CPU predict.
        Cuml issue #1854 has been created to track this.
    """
    def predict_model_on_cpu(self, X, convert_dtype=True):
        """
        Predicts the labels for X.

        Parameters
        ----------
        X : Dask cuDF dataframe  or CuPy backed Dask Array (n_rows, n_features)
            Distributed dense matrix (floats or doubles) of shape
            (n_samples, n_features).
        convert_dtype : bool, optional (default = True)
            When set to True, the predict method will, when necessary, convert
            the input to the data type which was used to train the model. This
            will increase memory used for the method.
        Returns
        ----------
        y : Dask cuDF dataframe or CuPy backed Dask Array (n_rows, 1)
        """
        c = default_client()
        workers = self.workers

        X_Scattered = c.scatter(X)
        futures = list()
        for n, w in enumerate(workers):
            futures.append(
                c.submit(
                    RandomForestClassifier._predict_model_on_cpu,
                    self.rfs[w],
                    X_Scattered,
                    convert_dtype,
                    random.random(),
                    workers=[w],
                )
            )

        wait(futures)
        raise_exception_from_futures(futures)

        indexes = list()
        rslts = list()
        for d in range(len(futures)):
            rslts.append(futures[d].result())
            indexes.append(0)

        pred = list()

        for i in range(len(X)):
            classes = dict()
            max_class = -1
            max_val = 0

            for d in range(len(rslts)):
                for j in range(self.n_estimators_per_worker[d]):
                    sub_ind = indexes[d] + j
                    cls = rslts[d][sub_ind]
                    if cls not in classes.keys():
                        classes[cls] = 1
                    else:
                        classes[cls] = classes[cls] + 1

                    if classes[cls] > max_val:
                        max_val = classes[cls]
                        max_class = cls

                indexes[d] = indexes[d] + self.n_estimators_per_worker[d]

            pred.append(max_class)
        return pred

    def predict_proba(self, X,
                      delayed=True, **kwargs):
        """
        Predicts the probability of each class for X.

        Parameters
        ----------
        X : Dask cuDF dataframe  or CuPy backed Dask Array (n_rows, n_features)
            Distributed dense matrix (floats or doubles) of shape
            (n_samples, n_features).
        predict_model : String (default = 'GPU')
            'GPU' to predict using the GPU, 'CPU' otherwise. The 'GPU' can only
            be used if the model was trained on float32 data and `X` is float32
            or convert_dtype is set to True. Also the 'GPU' should only be
            used for binary classification problems.
        output_class : boolean (default = True)
            This is optional and required only while performing the
            predict operation on the GPU.
            If true, return a 1 or 0 depending on whether the raw
            prediction exceeds the threshold. If False, just return
            the raw prediction.
        algo : string (default = 'auto')
            This is optional and required only while performing the
            predict operation on the GPU.
            'naive' - simple inference using shared memory
            'tree_reorg' - similar to naive but trees rearranged to be more
            coalescing-friendly
            'batch_tree_reorg' - similar to tree_reorg but predicting
            multiple rows per thread block
            `auto` - choose the algorithm automatically. Currently
            'batch_tree_reorg' is used for dense storage
            and 'naive' for sparse storage
        threshold : float (default = 0.5)
            Threshold used for classification. Optional and required only
            while performing the predict operation on the GPU.
            It is applied if output_class == True, else it is ignored
        num_classes : int (default = 2)
            number of different classes present in the dataset
        convert_dtype : bool, optional (default = True)
            When set to True, the predict method will, when necessary, convert
            the input to the data type which was used to train the model. This
            will increase memory used for the method.
        fil_sparse_format : boolean or string (default = auto)
            This variable is used to choose the type of forest that will be
            created in the Forest Inference Library. It is not required
            while using predict_model='CPU'.
            'auto' - choose the storage type automatically
            (currently True is chosen by auto)
            False - create a dense forest
            True - create a sparse forest, requires algo='naive'
            or algo='auto'

        Returns
        ----------
        y : NumPy
           Dask cuDF dataframe or CuPy backed Dask Array (n_rows, n_classes)
        """
        self.local_model = self._concat_treelite_models()
        data = DistributedDataHandler.create(X, client=self.client)
        self.datatype = data.datatype
        return self._predict_proba(X, delayed, **kwargs)

    def get_params(self, deep=True):
        """
        Returns the value of all parameters
        required to configure this estimator as a dictionary.

        Parameters
        -----------
        deep : boolean (default = True)
        """
        return self._get_params(deep)

    def set_params(self, worker_numb=None, **params):
        """
        Sets the value of parameters required to
        configure this estimator, it functions similar to
        the sklearn set_params.

        Parameters
        -----------
        params : dict of new params.
        worker_numb : list (default = None)
            If worker_numb is `None`, then the parameters will be set for all
            the workers. If it is not `None` then a list of worker numbers
            for whom the model parameter values have to be set should be
            passed.
            ex. worker_numb = [0], will only update the parameters for
            the model present in the first worker.
            The values passed into the list should not be greater than the
            number of workers in the cluster. The values passed in the list
            should range from : 0 to len(workers present in the client) - 1.
        """
        return self._set_params(**params,
                                worker_numb=worker_numb)
