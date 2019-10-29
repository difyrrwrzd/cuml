# Copyright (c) 2019, NVIDIA CORPORATION.
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

from cuml.dask.common import extract_ddf_partitions, to_dask_cudf, raise_exception_from_futures
from dask.distributed import default_client
from cuml.dask.common.comms import worker_state, CommsContext
from dask.distributed import wait

from uuid import uuid1

from functools import reduce

from collections import OrderedDict


class PCA(object):
    """
    Multi-Node Multi-GPU implementation of PCA.

    Predictions are done embarrassingly parallel, using cuML's
    single-GPU version.

    For more information on this implementation, refer to the
    documentation for single-GPU PCA.
    """

    def __init__(self, client=None, **kwargs):
        """
        Constructor for distributed PCA model
        """
        self.client = default_client() if client is None else client
        self.kwargs = kwargs

        # define attributes to make sure they
        # are available even on untrained object
        self.local_model = None
        self.components_ = None
        self.explained_variance_ = None
        self.explained_variance_ratio_ = None
        self.singular_values_ = None
        self.noise_variance = None


    @staticmethod
    def _func_create_model(sessionId, dfs, **kwargs):
        try:
            from cuml.decomposition.pca_mg import PCAMG as cumlPCA
        except ImportError:
            raise Exception("cuML has not been built with multiGPU support "
                            "enabled. Build with the --multigpu flag to"
                            " enable multiGPU support.")

        handle = worker_state(sessionId)["handle"]
        return cumlPCA(handle=handle, **kwargs), dfs

    @staticmethod
    def _func_fit(f, M, N, partsToRanks, rank, transform):
        m, dfs = f
        return m.fit(dfs, M, N, partsToRanks, rank, transform)

    @staticmethod
    def _func_transform(f, M, N, partsToRanks, rank):
        m, dfs = f
        return m.transform(dfs, M, N, partsToRanks, rank)

    @staticmethod
    def _func_inverse_transform(f, M, N, partsToRanks, rank):        
        m, dfs = f
        return m.inverse_transform(dfs, M, N, partsToRanks, rank)

    @staticmethod
    def _func_get_first(f):
        return f[0]

    @staticmethod
    def _func_get_idx(f, idx):
        return f[idx]

    @staticmethod
    def _func_xform(model, df):       
        return model.transform(df)

    @staticmethod
    def _func_get_size(df):
        return df.shape[0]

    def fit(self, X, _transform=False):
        gpu_futures = self.client.sync(extract_ddf_partitions, X, agg=False)

        worker_to_parts = OrderedDict()
        for w, p in gpu_futures:
            if w not in worker_to_parts:
                worker_to_parts[w] = []
            worker_to_parts[w].append(p)

        workers = list(map(lambda x: x[0], gpu_futures))

        comms = CommsContext(comms_p2p=False)
        comms.init(workers=workers)

        worker_info = comms.worker_info(comms.worker_addresses)

        key = uuid1()
        partsToRanks = [(worker_info[wf[0]]["r"], self.client.submit(
            PCA._func_get_size,
            wf[1],
            workers=[wf[0]],
            key="%s-%s" % (key, idx)).result())
            for idx, wf in enumerate(gpu_futures)]

        N = X.shape[1]
        M = reduce(lambda a,b: a+b, map(lambda x: x[1], partsToRanks))

        key = uuid1()
        self.pca_models = [(wf[0], self.client.submit(
            PCA._func_create_model,
            comms.sessionId,
            wf[1],
            **self.kwargs,
            workers=[wf[0]],
            key="%s-%s" % (key, idx)))
            for idx, wf in enumerate(worker_to_parts.items())]

        key = uuid1()
        pca_fit = dict([(worker_info[wf[0]]["r"], self.client.submit(
            PCA._func_fit,
            wf[1],
            M, N,
            partsToRanks,
            worker_info[wf[0]]["r"],
            _transform,
            key="%s-%s" % (key, idx),
            workers=[wf[0]]))
            for idx, wf in enumerate(self.pca_models)])

        wait(list(pca_fit.values()))
        raise_exception_from_futures(list(pca_fit.values()))

        comms.destroy()

        self.local_model = self.client.submit(PCA._func_get_first,
                                              self.pca_models[0][1]).result()

        self.components_ = self.local_model.components_
        self.explained_variance_ = self.local_model.explained_variance_
        self.explained_variance_ratio_ = self.local_model.explained_variance_ratio_
        self.singular_values_ = self.local_model.singular_values_
        self.noise_variance = self.local_model.noise_variance_

        out_futures = []
        if _transform:
            completed_part_map = {}
            for rank, size in partsToRanks:
                if rank not in completed_part_map:
                    completed_part_map[rank] = 0
           
                f = pca_fit[rank]
                out_futures.append(self.client.submit(
                    PCA._func_get_idx, f, completed_part_map[rank]))

                completed_part_map[rank] += 1

            return to_dask_cudf(out_futures)

    def _transform(self, X):
        gpu_futures = self.client.sync(extract_ddf_partitions, X, agg=False)

        worker_to_parts = OrderedDict()
        for w, p in gpu_futures:
            if w not in worker_to_parts:
                worker_to_parts[w] = []
            worker_to_parts[w].append(p)

        workers = list(map(lambda x: x[0], gpu_futures))

        comms = CommsContext(comms_p2p=False)
        comms.init(workers=workers)

        worker_info = comms.worker_info(comms.worker_addresses)

        key = uuid1()
        partsToRanks = [(worker_info[wf[0]]["r"], self.client.submit(
            PCA._func_get_size,
            wf[1],
            workers=[wf[0]],
            key="%s-%s" % (key, idx)).result())
            for idx, wf in enumerate(gpu_futures)]

        N = X.shape[1]
        M = reduce(lambda a,b: a+b, map(lambda x: x[1], partsToRanks))

        key = uuid1()
        pca_transform = dict([(worker_info[wf[0]]["r"], self.client.submit(
            PCA._func_transform,
            wf[1],
            M, N,
            partsToRanks,
            worker_info[wf[0]]["r"],
            key="%s-%s" % (key, idx),
            workers=[wf[0]]))
            for idx, wf in enumerate(self.pca_models)])

        wait(list(pca_transform.values()))
        raise_exception_from_futures(list(pca_transform.values()))

        comms.destroy()

        out_futures = []       
        completed_part_map = {}
        for rank, size in partsToRanks:
            if rank not in completed_part_map:
                completed_part_map[rank] = 0
           
            f = pca_transform[rank]
            out_futures.append(self.client.submit(
                PCA._func_get_idx, f, completed_part_map[rank]))

            completed_part_map[rank] += 1

        return to_dask_cudf(out_futures)

    def _inverse_transform(self, X):       
        gpu_futures = self.client.sync(extract_ddf_partitions, X, agg=False)

        worker_to_parts = OrderedDict()
        for w, p in gpu_futures:
            if w not in worker_to_parts:
                worker_to_parts[w] = []
            worker_to_parts[w].append(p)

        workers = list(map(lambda x: x[0], gpu_futures))

        comms = CommsContext(comms_p2p=False)
        comms.init(workers=workers)

        worker_info = comms.worker_info(comms.worker_addresses)

        key = uuid1()
        partsToRanks = [(worker_info[wf[0]]["r"], self.client.submit(
            PCA._func_get_size,
            wf[1],
            workers=[wf[0]],
            key="%s-%s" % (key, idx)).result())
            for idx, wf in enumerate(gpu_futures)]

        N = X.shape[1]
        M = reduce(lambda a,b: a+b, map(lambda x: x[1], partsToRanks))

        key = uuid1()
        pca_inverse_transform = dict([(worker_info[wf[0]]["r"], self.client.submit(
            PCA._func_inverse_transform,
            wf[1],
            M, N,
            partsToRanks,
            worker_info[wf[0]]["r"],
            key="%s-%s" % (key, idx),
            workers=[wf[0]]))
            for idx, wf in enumerate(self.pca_models)])

        wait(list(pca_inverse_transform.values()))
        raise_exception_from_futures(list(pca_inverse_transform.values()))

        comms.destroy()

        out_futures = []       
        completed_part_map = {}
        for rank, size in partsToRanks:
            if rank not in completed_part_map:
                completed_part_map[rank] = 0
           
            f = pca_inverse_transform[rank]
            out_futures.append(self.client.submit(
                PCA._func_get_idx, f, completed_part_map[rank]))

            completed_part_map[rank] += 1

        return to_dask_cudf(out_futures)

    def fit_transform(self, X):     
        return self.fit(X, _transform=True)

    def transform(self, X):
        return self._transform(X)

    def inverse_transform(self, X):
        return self._inverse_transform(X)

    def get_param_names(self):
        return list(self.kwargs.keys())
