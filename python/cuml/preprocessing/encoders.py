# Copyright (c) 2020, NVIDIA CORPORATION.
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
import numpy as np
import cupy as cp

from cuml.preprocessing import LabelEncoder
from cudf import DataFrame, Series

from cuml.utils import with_cupy_rmm


class OneHotEncoder:
    """
    Encode categorical features as a one-hot numeric array.
    The input to this transformer should be a cuDF.DataFrame of integers or
    strings, denoting the values taken on by categorical (discrete) features.
    The features are encoded using a one-hot (aka 'one-of-K' or 'dummy')
    encoding scheme. This creates a binary column for each category and
    returns a sparse matrix or dense array (depending on the ``sparse``
    parameter).
    By default, the encoder derives the categories based on the unique values
    in each feature. Alternatively, you can also specify the `categories`
    manually.
    Note: a one-hot encoding of y labels should use a LabelBinarizer
    instead.

    Parameters
    ----------
    TODO: Implement categories
    categories : 'auto' or a cuml.DataFrame, default='auto'
        Categories (unique values) per feature:
        - 'auto' : Determine categories automatically from the training data.
        - DataFrame : ``categories[col]`` holds the categories expected in the
          feature col. The passed categories should not mix strings and numeric
          values within a single feature, and should be sorted in case of
          numeric values. TODO: Check sorted for numeric
        The used categories can be found in the ``categories_`` attribute.
    TODO: Implement drop
    drop : 'first' or a cuml.DataFrame, default=None
        Specifies a methodology to use to drop one of the categories per
        feature. This is useful in situations where perfectly collinear
        features cause problems, such as when feeding the resulting data
        into a neural network or an unregularized regression.
        - None : retain all features (the default).
        - 'first' : drop the first category in each feature. If only one
          category is present, the feature will be dropped entirely.
        - DataFrame : ``drop[col]`` is the category in feature col that
          should be dropped.
    # sparse : bool, default=True
    #     Will return sparse matrix if set True else will return an array.
    dtype : number type, default=np.float
        Desired dtype of output.
    handle_unknown : {'error', 'ignore'}, default='error'
        Whether to raise an error or ignore if an unknown categorical feature
        is present during transform (default is to raise). When this parameter
        is set to 'ignore' and an unknown category is encountered during
        transform, the resulting one-hot encoded columns for this feature
        will be all zeros. In the inverse transform, an unknown category
        will be denoted as None.

    Attributes
    ----------
    categories_ : list of arrays
        The categories of each feature determined during fitting
        (in order of the features in X and corresponding with the output
        of ``transform``). This includes the category specified in ``drop``
        (if any).
    drop_idx_ : array of shape (n_features,)
        ``drop_idx_[i]`` is the index in ``categories_[i]`` of the category to
        be dropped for each feature. None if all the transformed features will
        be retained.

    """
    def __init__(self, categories='auto', drop=None, sparse=True,
                 dtype=np.float64, handle_unknown='error'):
        self.categories = categories
        self.sparse = sparse
        self.dtype = dtype
        self.handle_unknown = handle_unknown
        self.drop = drop
        self._fitted = False
        self.categories_ = None
        self.drop_idx_ = None
        self._encoders = None

    def _validate_keywords(self):
        if self.handle_unknown not in ('error', 'ignore'):
            msg = ("handle_unknown should be either 'error' or 'ignore', "
                   "got {0}.".format(self.handle_unknown))
            raise ValueError(msg)
        # If we have both dropped columns and ignored unknown
        # values, there will be ambiguous cells. This creates difficulties
        # in interpreting the model.
        if self.drop is not None and self.handle_unknown != 'error':
            raise ValueError(
                "`handle_unknown` must be 'error' when the drop parameter is "
                "specified, as both would create categories that are all "
                "zero.")

    def fit(self, X):
        """
        Fit OneHotEncoder to X.
        Parameters
        ----------
        X : cuDF.DataFrame
            The data to determine the categories of each feature.
        Returns
        -------
        self
        """
        self._validate_keywords()
        if self.categories == 'auto':
            self._encoders = {feature: LabelEncoder().fit(X[feature])
                              for feature in X.columns}
        else:
            raise NotImplementedError
        #     def filtered_label_encoder(feature):
        #         filtered = X[feature].fil
        #     self._encoders = {feature: filtered_label_encoder(feature)
        #                       for feature in X.columns}
        # self._fit(X, handle_unknown=self.handle_unknown)
        # self.drop_idx_ = self._compute_drop_idx()
        self._fitted = True
        return self

    def fit_transform(self, X):
        """
        Fit OneHotEncoder to X, then transform X.
        Equivalent to fit(X).transform(X).

        Parameters
        ----------
        X : cudf.DataFrame
            The data to encode.
        Returns
        -------
        X_out : sparse matrix if sparse=True else a 2-d array
            Transformed input.
        """
        return self.fit(X).transform(X)

    @staticmethod
    @with_cupy_rmm
    def _one_hot_encoding(encoder, X):
        idx = encoder.transform(X).to_array()
        ohe = cp.zeros((len(X), len(encoder.classes_)))
        ohe[cp.arange(len(ohe)), idx] = 1
        return ohe

    @with_cupy_rmm
    def transform(self, X):
        """
        Transform X using one-hot encoding.
        Parameters
        ----------
        X : cudf.DataFrame
            The data to encode.
        Returns
        -------
        X_out : sparse matrix if sparse=True else a 2-d array
            Transformed input.
        """
        if not self._fitted:
            raise RuntimeError("Model must first be .fit()")
        onehots = [self._one_hot_encoding(self._encoders[feature], X[feature])
                   for feature in X.columns]
        return cp.concatenate(onehots, axis=1)

    @with_cupy_rmm
    def inverse_transform(self, X):
        """
        Convert the data back to the original representation.
        In case unknown categories are encountered (all zeros in the
        one-hot encoding), ``None`` is used to represent this category.
        Parameters
        ----------
        X : array-like or sparse matrix, shape [n_samples, n_encoded_features]
            The transformed data.
        Returns
        -------
        X_tr : cudf.DataFrame
            Inverse transformed array.
        """
        if not self._fitted:
            raise RuntimeError("Model must first be .fit()")
        result = DataFrame(columns=self._encoders.keys())
        j = 0
        for feature in self._encoders.keys():
            enc_size = len(self._encoders[feature].classes_)
            x_feature = cp.argmax(X[:, j:j + enc_size], axis=1)
            inv = self._encoders[feature].inverse_transform(Series(x_feature))
            result[feature] = inv
            j += enc_size
        return result
