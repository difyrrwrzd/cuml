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

import cuml
import numpy as np
import pytest

from cuml.test.utils import get_pattern, clusters_equal, unit_param, \
    quality_param, stress_param

from sklearn import cluster
from sklearn.metrics import adjusted_rand_score
from sklearn.preprocessing import StandardScaler


dataset_names = ['blobs', 'noisy_circles'] + \
                [pytest.param(ds, marks=pytest.mark.xfail)
                 for ds in ['noisy_moons', 'varied', 'aniso']]


@pytest.mark.parametrize('name', dataset_names)
@pytest.mark.parametrize('nrows', [unit_param(20),
                                   quality_param(5000),
                                   stress_param(500000)])
def test_kmeans_sklearn_comparison(name, nrows):

    default_base = {'quantile': .3,
                    'eps': .3,
                    'damping': .9,
                    'preference': -200,
                    'n_neighbors': 10,
                    'n_clusters': 3}

    pat = get_pattern(name, nrows)

    params = default_base.copy()
    params.update(pat[1])

    cuml_kmeans = cuml.KMeans(n_clusters=params['n_clusters'])

    X, y = pat[0]

    X = StandardScaler().fit_transform(X)

    cu_y_pred = cuml_kmeans.fit_predict(X).to_array()

    if nrows < 500000:
        kmeans = cluster.KMeans(n_clusters=params['n_clusters'])
        sk_y_pred = kmeans.fit_predict(X)

        # Noisy circles clusters are rotated in the results,
        # since we are comparing 2 we just need to compare that both clusters
        # have approximately the same number of points.
        calculation = (np.sum(sk_y_pred) - np.sum(cu_y_pred))/len(sk_y_pred)
        print(cuml_kmeans.score(X), kmeans.score(X))
        score_test = (cuml_kmeans.score(X) - kmeans.score(X)) < 2e-3
        if name == 'noisy_circles':
            assert (calculation < 2e-3) and score_test

        else:
            assert (clusters_equal(sk_y_pred, cu_y_pred,
                    params['n_clusters'])) and score_test


@pytest.mark.parametrize('name', dataset_names)
@pytest.mark.parametrize('nrows', [unit_param(20),
                                   quality_param(5000),
                                   stress_param(500000)])
def test_kmeans_sklearn_comparison_default(name, nrows):

    default_base = {'quantile': .3,
                    'eps': .3,
                    'damping': .9,
                    'preference': -200,
                    'n_neighbors': 10,
                    'n_clusters': 3}

    pat = get_pattern(name, nrows)

    params = default_base.copy()
    params.update(pat[1])

    cuml_kmeans = cuml.KMeans()

    X, y = pat[0]

    X = StandardScaler().fit_transform(X)

    cu_y_pred = cuml_kmeans.fit_predict(X)
    cu_score = adjusted_rand_score(cu_y_pred, y)
    kmeans = cluster.KMeans(random_state=12)
    sk_y_pred = kmeans.fit_predict(X)
    sk_score = adjusted_rand_score(sk_y_pred, y)
    assert cu_score > sk_score
