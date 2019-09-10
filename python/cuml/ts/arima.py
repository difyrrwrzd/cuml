#
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

from typing import List, Tuple
import numpy as np
from IPython.core.debugger import set_trace
import pandas as pd

from cuml.ts.batched_kalman import batched_kfilter
from cuml.ts.batched_kalman import pynvtx_range_push, pynvtx_range_pop
from cuml.ts.batched_kalman import batched_transform as batched_trans_cuda
from cuml.ts.batched_kalman import pack, unpack
from cuml.ts.batched_lbfgs import batched_fmin_lbfgs_b
from cuml.ts.batched_arima import batched_loglike_cuda

class ARIMAModel:
    r"""
    The Batched ARIMA model fits the following to each given input:
    if d=1:
      \delta \tilde{y}_{t} = \mu + \sum_{i=1}^{p} \phi_i \delta y_{t-i}
                                    + \sum_{i=1}^{q} \theta_i (y_{t-i} -
                                                                 \tilde{y}_{t-i})

    Note all fitted parameters, \mu, \phi_i, \theta_i.
    """

    def __init__(self, order: List[Tuple[int, int, int]],
                 mu: np.ndarray,
                 ar_params: List[np.ndarray],
                 ma_params: List[np.ndarray],
                 y: pd.DataFrame):
        self.order = order
        self.mu = mu
        self.ar_params = ar_params
        self.ma_params = ma_params
        self.y = y
        self.num_samples = y.shape[0]  # pandas Dataframe shape is (num_batches, num_samples)
        self.num_batches = y.shape[1]
        self.yp = None
        self.niter = None # number of iterations used during fit

    def __repr__(self):
        return "Batched ARIMA Model {}, mu:{}, ar:{}, ma:{}".format(self.order, self.mu,
                                                                    self.ar_params, self.ma_params)

    def __str__(self):
        return self.__repr__()

    @property
    def bic(self):
        (p, d, q) = self.order[0]
        x = pack(p, d, q, self.num_batches, self.mu, self.ar_params, self.ma_params)
        llb = ll_f(self.num_batches, self.order[0], self.y, x)
        return [-2 * lli + np.log(len(self.y)) * (_model_complexity(self.order[i]))
                for (i, lli) in enumerate(llb)]

    @property
    def aic(self):
        (p, d, q) = self.order[0]
        x = pack(p, d, q, self.num_batches, self.mu, self.ar_params, self.ma_params)
        llb = ll_f(self.num_batches, self.order[0], self.y, x)
        return [-2 * lli + 2 * (_model_complexity(self.order[i]))
                for (i, lli) in enumerate(llb)]


def _model_complexity(order):
    (p, d, q) = order
    # complexity is number of parameters: mu + ar + ma
    return d + p + q


def ll_f(num_batches, order, y, x, trans=True):
    """Computes batched loglikelihood given parameters stored in `x`."""
    pynvtx_range_push("ll_f")

    p, d, q = order
    nobs = len(y)
    llb = batched_loglike_cuda(y, num_batches, nobs, p, d, q, x, trans)
    
    pynvtx_range_pop()
    return llb

def ll_gf(num_batches, num_parameters, order, y, x, h=1e-8, trans=True):
    """Computes fd-gradient of batched loglikelihood given parameters stored in
    `x`. Because batches are independent, it only compute the function for the
    single-batch number of parameters."""
    pynvtx_range_push("ll_gf")
    
    fd = np.zeros(num_parameters)

    grad = np.zeros(len(x))

    # 1st order FD saves 20% runtime.
    # ll_b0 = ll_f(num_batches, num_parameters, order, y, x, trans=trans)
    assert (len(x) / num_parameters) == float(num_batches)
    for i in range(num_parameters):
        fd[i] = h

        # duplicate the perturbation across batches (they are independent)
        fdph = np.tile(fd, num_batches)

        # reset perturbation
        fd[i] = 0.0

        ll_b_ph = ll_f(num_batches, order, y, x+fdph, trans=trans)
        ll_b_mh = ll_f(num_batches, order, y, x-fdph, trans=trans)
        
        np.seterr(all='raise')
        grad_i_b = (ll_b_ph - ll_b_mh)/(2*h)
        # grad_i_b = (ll_b_ph - ll_b0)/(h)

        if num_batches == 1:
            grad[i] = grad_i_b
        else:
            assert len(grad[i::num_parameters]) == len(grad_i_b)
            # Distribute the result to all batches
            grad[i::num_parameters] = grad_i_b

    pynvtx_range_pop()
    return grad


def fit(y: np.ndarray,
        order: Tuple[int, int, int],
        mu0: np.ndarray,
        ar_params0: List[np.ndarray],
        ma_params0: List[np.ndarray],
        opt_disp=-1, h=1e-9, gpu=True, alpha_max=1000):
    """
    Fits the ARIMA model to each time-series (batched together in a dense numpy matrix)
    with the given initial parameters. `y` is (num_samples, num_batches)

    """

    # turn on floating point exceptions!
    np.seterr(all='raise')

    p, d, q = order
    num_parameters = d + p + q

    num_samples = y.shape[0]  # pandas Dataframe shape is (num_batches, num_samples)
    num_batches = y.shape[1]

    def f(x: np.ndarray) -> np.ndarray:
        """The (batched) energy functional returning the negative loglikelihood (for each series)."""

        # Recall: Maximimize LL means minimize negative
        n_llf = -(ll_f(num_batches, order, y, x, trans=True))
        return n_llf/(num_samples-1)


    # optimized finite differencing gradient for batches
    def gf(x):
        """The gradient of the (batched) energy functional."""
        # Recall: We maximize LL by minimizing -LL
        n_gllf = -ll_gf(num_batches, num_parameters, order, y, x, h, trans=True)
        return n_gllf/(num_samples-1)

    x0 = pack(p, d, q, num_batches, mu0, ar_params0, ma_params0)
    x0 = batch_invtrans(p, d, q, num_batches, x0)
        
    # check initial parameter sanity
    if ((np.isnan(x0).any()) or (np.isinf(x0).any())):
            raise FloatingPointError("Initial condition 'x0' has NaN or Inf.")


    # Optimize parameters by minimizing log likelihood.
    x, niter, flags = batched_fmin_lbfgs_b(f, x0, num_batches, gf,
                                           iprint=opt_disp, factr=1000)

    # TODO: Better Handle non-zero `flag` array values: 0 -> ok, 1,2 -> optimizer had trouble
    if (flags != 0).any():
        print("WARNING(`fit()`): Some batch members had optimizer problems.")

    Tx = batch_trans(p, d, q, num_batches, x)
    mu, ar, ma = unpack(p, d, q, num_batches, Tx)

    fit_model = ARIMAModel(num_batches*[order], mu, ar, ma, y)
    fit_model.niter = niter
    return fit_model


def diffAndCenter(y: np.ndarray,
                  p, q,
                  mu_ar_ma_params_x: np.ndarray):
    """Diff and center batched series `y`"""
    pynvtx_range_push("diffAndCenter")
    y_diff = np.diff(y, axis=0)

    pynvtx_range_pop()
    return np.asfortranarray(y_diff-mu_ar_ma_params_x[::(1+p+q)])


def run_kalman(y, order: Tuple[int, int, int],
               num_batches, mu_ar_ma_params_x,
               initP_kalman_iterations=False) -> Tuple[np.ndarray, np.ndarray]:
    """Run the (batched) kalman filter for the given model (and contained batched
    series). `initP_kalman_iterations, if true uses kalman iterations, and if false
    uses an analytical approximation (Durbin Koopman pg 138).`"""
    pynvtx_range_push("run_kalman")
    p, d, q = order

    if d == 0:

        ll_b, vs = batched_kfilter(np.asfortranarray(y), # numpy
                                   mu_ar_ma_params_x,
                                   p, d, q,
                                   initP_kalman_iterations)
    elif d == 1:

        y_diff_centered = diffAndCenter(y, p, q, mu_ar_ma_params_x)
        # print("ydiff:", y_diff_centered)
        ll_b, vs = batched_kfilter(y_diff_centered, # numpy
                                   mu_ar_ma_params_x,
                                   p, d, q,
                                   initP_kalman_iterations)
    else:
        raise NotImplementedError("ARIMA only support d==0,1")

    pynvtx_range_pop()
    return ll_b, vs


def predict_in_sample(model):
    """Return in-sample prediction on batched series given batched model"""

    p, d, q = model.order[0]
    x = pack(p, d, q, model.num_batches, model.mu, model.ar_params, model.ma_params)
    _, vs = run_kalman(model.y, (p, d, q), model.num_batches, x)

    assert_same_d(model.order) # We currently assume the same d for all series
    _, d, _ = model.order[0]

    if d == 0:
        y_p = model.y - vs
    elif d == 1:
        y_diff = np.diff(model.y, axis=0)
        # Following statsmodel `predict(typ='levels')`, by adding original
        # signal back to differenced prediction, we retrive a prediction of
        # the original signal.
        predict = (y_diff - vs)
        y_p = model.y[0:-1, :] + predict
    else:
        # d>1
        raise NotImplementedError("Only support d==0,1")

    # Extend prediction by 1 when d==1
    if d == 1:
        # forecast a single value to make prediction length of original signal
        fc1 = np.zeros(model.num_batches)
        for i in range(model.num_batches):
            fc1[i] = fc_single(1, model.order[i], y_diff[:,i],
                               vs[:,i], model.mu[i],
                               model.ma_params[i],
                               model.ar_params[i])

        final_term = model.y[-1, :] + fc1

        # append final term to prediction
        temp = np.zeros((y_p.shape[0]+1, y_p.shape[1]))
        temp[:-1, :] = y_p
        temp[-1, :] = final_term
        y_p = temp

    model.yp = y_p
    return y_p

def fc_single(num_steps, order, y_diff, vs, mu, ma_params, ar_params):

    p, _, q = order

    y_ = np.zeros(p+num_steps)
    vs_ = np.zeros(q+num_steps)
    if p>0:
        y_[:p] = y_diff[-p:]
    if q>0:
        vs_[:q] = vs[-q:]

    fcast = np.zeros(num_steps)

    for i in range(num_steps):
        mu_star = mu * (1-ar_params.sum())
        fcast[i] = mu_star
        if p > 0:
            fcast[i] += np.dot(ar_params, y_[i:i+p])
        if q > 0 and i < q:
            fcast[i] += np.dot(ma_params, vs_[i:i+q])
        if p > 0:
            y_[i+p] = fcast[i]

    return fcast


def forecast(model, nsteps: int) -> np.ndarray:
    """Forecast the given model `nsteps` into the future."""
    y_fc_b = np.zeros((nsteps, model.num_batches))

    p, d, q = model.order[0]
    x = pack(p, d, q, model.num_batches, model.mu, model.ar_params, model.ma_params)

    _, vs = run_kalman(model.y, model.order[0], model.num_batches, x)

    for i in range(model.num_batches):
        p, d, q = model.order[i]
        vsi = vs[:,i]
        ydiff_i = np.diff(model.y[:, i],axis=0)
        fc = fc_single(nsteps, (p,d,q), ydiff_i, vsi,
                       model.mu[i], model.ma_params[i],
                       model.ar_params[i])

        if model.order[i][1] > 0: # d > 0
            fc = undifference(fc, model.y[-1,i])[1:]

        y_fc_b[:, i] = fc[:]

    return y_fc_b


def batch_trans(p, d, q, nb, x):
    """Apply the stationarity/invertibility guaranteeing transform to batched-parameter vector x."""
    pynvtx_range_push("jones trans")

    Tx = batched_trans_cuda(p, d, q, nb, x, False)
    
    pynvtx_range_pop()
    return Tx


def batch_invtrans(p, d, q, nb, x):
    """Apply the *inverse* stationarity/invertibility guaranteeing transform to
       batched-parameter vector x.
    """
    pynvtx_range_push("jones inv-trans")

    Tx = batched_trans_cuda(p, d, q, nb, x, True)

    pynvtx_range_pop()
    return Tx


def undifference(x, x0):
    # set_trace()
    xi = np.append(x0, x)
    return np.cumsum(xi)


def assert_same_d(b_order):
    """Checks that all values of d in batched order are same"""
    b_d = [d for _, d, _ in b_order]
    assert (np.array(b_d) == b_d[0]).all()


def start_params(order, y_diff):
    """A quick approach to determine reasonable starting mu (trend), AR, and MA parameters"""

    # y is mutated so we need a copy
    y = np.copy(y_diff)
    nobs = len(y)

    p, q, d = order
    params_init = np.zeros(p+q+d)
    if d > 0:
        # center y (in `statsmodels`, this is result when exog = [1, 1, 1...])
        mean_y = np.mean(y)
        params_init[0] = mean_y
        y -= mean_y

    if p == 0 and q == 0:
        return params_init

    if p != 0:

        # TODO: `statsmodels` uses BIC to pick the "best" `p` for this initial
        # fit. The "best" model is probably a p=1, so we will assume that for now.
        p_best = 1
        x = np.zeros((len(y) - p_best, p_best))
        # create lagged series set
        for lag in range(1, p_best+1):
            # create lag and trim appropriately from front so they are all the same size
            x[:, lag-1] = y[p_best-lag:-lag].T

        # LS fit a*X - Y
        y_ar = y[p_best:]
        
        (ar_fit, _, _, _) = np.linalg.lstsq(x, y_ar.T, rcond=None)
        # print("initial_ar_fit:", ar_fit)
        # set_trace()
        if q == 0:
            params_init[d:] = ar_fit
        else:
            residual = y[p_best:] - np.dot(x, ar_fit)

            assert p >= p_best
            p_diff = p - p_best

            x_resid = np.zeros((len(residual) - q - p_diff, q))
            x_ar2 = np.zeros((len(residual) - q - p_diff, p))
 
            # create lagged residual and ar term
            for lag in range(1, q+1):
                x_resid[:, lag-1] = (residual[q-lag:-lag].T)[p_diff:]
            for lag in range(1, p+1):
                x_ar2[:, lag-1] = (y[p-lag:-lag].T)[q:]

            X = np.column_stack((x_ar2, x_resid))
            (arma_fit, _, _, _) = np.linalg.lstsq(X, y_ar[(q+p_diff):].T, rcond=None)

            params_init[d:] = arma_fit

    else:
        # case when p == 0 and q>0

        # when p==0, MA params are often -1
        # TODO: See how `statsmodels` handles this case
        params_init[d:] = -1*np.ones(q)

    return params_init

def init_x0(order, y):
    pynvtx_range_push("init x0")
    (p, d, q) = order
    if d == 1:
        yd = np.diff(y)
    else:
        yd = np.copy(y)
    
    x0 = start_params((p, q, d), yd)

    mu, ar, ma = unpack(p, d, q, 1, x0)
    
    # The inverse jones transform has domain [-1, 1]. Apply Tanh to ensure this range.
    if p > 0:
        ar = [np.tanh(ar[0])]
    else:
        ar = []
    if q > 0:
        ma = [np.tanh(ma[0])]
    else:
        ma = []

    x0 = pack(p, d, q, 1, mu, ar, ma)

    pynvtx_range_pop()
    return x0

def grid_search(y_b: np.ndarray, d=1, max_p=3, max_q=3, method="bic"):
    """Grid search to find optimal (lowest `ic`) (p,_,q) values for each
    time-series in y_b, which is a dense `ndarray` with columns as time.
    Optimality is based on minimizing BIC or AIC, which both sum negative
    log-likelihood against model complexity; Higher model complexity might
    yield a lower negative LL, but at higher `bic` due to complexity term.
    """

    num_batches = y_b.shape[1]
    best_ic = np.full(num_batches, np.finfo(np.float64).max/2)
    best_model = ARIMAModel([[]]*num_batches, np.zeros(num_batches), [[]]*num_batches, [[]]*num_batches, y_b)
    # best_model =

    for p in range(0, max_p):
        arparams = np.zeros(p)
        for q in range(0, max_q):
            maparams = np.zeros(q)

            # skip 0,0 case
            if p == 0 and q == 0:
                continue

            x0 = np.array([])
            for i in range(num_batches):
                x0i = init_x0((p, d, q), y_b[:, i])
                x0 = np.r_[x0, x0i]

            mu0, ar0, ma0 = unpack(p, d, q, num_batches, x0)

            b_model = fit(y_b, (p, d, q), mu0, ar0, ma0)

            if method == "aic":
                ic = b_model.aic
            elif method == "bic":
                ic = b_model.bic
            else:
                raise NotImplementedError("Method '{}' not supported".format(method))

            for (i, ic_i) in enumerate(ic):
                if ic_i < best_ic[i]:
                    best_model.order[i] = (p, d, q)
                    best_model.mu[i] = b_model.mu[i]

                    if p > 0:
                        best_model.ar_params[i] = b_model.ar_params[i]
                    else:
                        best_model.ar_params[i] = []
                    if q > 0:
                        best_model.ma_params[i] = b_model.ma_params[i]
                    else:
                        best_model.ma_params[i] = []

                    best_ic[i] = ic_i

    return (best_model, best_ic)
