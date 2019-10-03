import numpy as np
import cudf
from cuml.solvers import SGD as cumlSGD
import pytest
from sklearn.datasets.samples_generator import make_blobs
from sklearn.model_selection import train_test_split
from sklearn import datasets
import pandas as pd


def unit_param(*args, **kwargs):
    return pytest.param(*args, **kwargs, marks=pytest.mark.unit)


def quality_param(*args, **kwargs):
    return pytest.param(*args, **kwargs, marks=pytest.mark.quality)


def stress_param(*args, **kwargs):
    return pytest.param(*args, **kwargs, marks=pytest.mark.stress)


@pytest.mark.parametrize('lrate', ['constant', 'invscaling', 'adaptive'])
@pytest.mark.parametrize('datatype', [np.float32, np.float64])
@pytest.mark.parametrize('input_type', ['ndarray'])
@pytest.mark.parametrize('penalty', ['none', 'l1', 'l2', 'elasticnet'])
@pytest.mark.parametrize('loss', ['hinge', 'log', 'squared_loss'])
@pytest.mark.parametrize('name', [unit_param(None), quality_param('iris'),
                         stress_param('blobs')])
def test_svd(datatype, lrate, input_type, penalty,
             loss, name):

    if name == 'blobs':
        X, y = make_blobs(n_samples=500000,
                          n_features=1000, random_state=0)
        X = X.astype(datatype)
        y = y.astype(datatype)
        X_train, X_test, y_train, y_test = train_test_split(X, y,
                                                            train_size=0.8)

    elif name == 'iris':
        iris = datasets.load_iris()
        X = (iris.data).astype(datatype)
        y = (iris.target).astype(datatype)
        X_train, X_test, y_train, y_test = train_test_split(X, y,
                                                            train_size=0.8)

    else:
        X_train = np.array([[-1, -1], [-2, -1], [1, 1], [2, 1]],
                           dtype=datatype)
        y_train = np.array([1, 1, 2, 2], dtype=datatype)
        X_test = np.array([[3.0, 5.0], [2.0, 5.0]]).astype(datatype)

    cu_sgd = cumlSGD(learning_rate=lrate, eta0=0.005, epochs=2000,
                     fit_intercept=True, batch_size=4096,
                     tol=0.0, penalty=penalty, loss=loss)

    if input_type == 'dataframe':
        y_train_pd = pd.DataFrame({'fea0': y_train[0:, ]})
        X_train_pd = pd.DataFrame(
                     {'fea%d' % i: X_train[0:, i] for i in range(
                             X_train.shape[1])})
        X_test_pd = pd.DataFrame(
                     {'fea%d' % i: X_test[0:, i] for i in range(
                             X_test.shape[1])})
        X_train = cudf.DataFrame.from_pandas(X_train_pd)
        X_test = cudf.DataFrame.from_pandas(X_test_pd)
        y_train = y_train_pd.values
        y_train = y_train[:, 0]
        y_train = cudf.Series(y_train)

    cu_sgd.fit(X_train, y_train)
    cu_pred = cu_sgd.predict(X_test).to_array()
    print("cuML predictions : ", cu_pred)


@pytest.mark.parametrize('datatype', [np.float32, np.float64])
@pytest.mark.parametrize('input_type', ['ndarray'])
def test_svd_default(datatype, input_type):

    X_train = np.array([[-1, -1], [-2, -1], [1, 1], [2, 1]],
                       dtype=datatype)
    y_train = np.array([1, 1, 2, 2], dtype=datatype)
    X_test = np.array([[3.0, 5.0], [2.0, 5.0]]).astype(datatype)

    cu_sgd = cumlSGD()

    cu_sgd.fit(X_train, y_train)
    cu_pred = cu_sgd.predict(X_test).to_array()
    print("cuML predictions : ", cu_pred)
