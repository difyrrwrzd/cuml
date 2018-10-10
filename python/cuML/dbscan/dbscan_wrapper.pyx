#
 # Copyright (c) 2018, NVIDIA CORPORATION.
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

cimport c_dbscan
import numpy as np
from numba import cuda
import pygdf
from libcpp cimport bool
import ctypes
from libc.stdint cimport uintptr_t
from c_dbscan cimport *


class DBSCAN:

    def __init__(self, eps=1.0, min_samples=1):
        self.eps = eps
        self.min_samples = min_samples
        self.labels_ = None
        
    def _get_ctype_ptr(self, obj):
        # The manner to access the pointers in the gdf's might change, so
        # encapsulating access in the following 3 methods. They might also be
        # part of future gdf versions.
        return obj.device_ctypes_pointer.value

    def _get_column_ptr(self, obj):
        return self._get_ctype_ptr(obj._column._data.to_gpu_array())

    def _get_gdf_as_matrix_ptr(self, gdf):
        return self._get_ctype_ptr(gdf.as_gpu_matrix(order='C'))

    def fit(self, input_gdf):
        x = []
        for col in input_gdf.columns:
            x.append(input_gdf[col]._column.dtype)
            break

        self.gdf_datatype = np.dtype(x[0])
        self.n_rows = len(input_gdf)
        self.n_cols = len(input_gdf._cols)
        
        cdef uintptr_t input_ptr = self._get_gdf_as_matrix_ptr(input_gdf)
        self.labels_ = pygdf.Series(np.zeros(self.n_rows, dtype=np.int32))
        cdef uintptr_t labels_ptr = self._get_column_ptr(self.labels_)

        if self.gdf_datatype.type == np.float32:
            c_dbscan.dbscanFit(<float*>input_ptr, 
                               <int> self.n_rows, 
                               <int> self.n_cols, 
                               <float> self.eps, 
                               <int> self.min_samples,
		               <int*> labels_ptr)
        else:
            c_dbscan.dbscanFit(<double*>input_ptr, 
                               <int> self.n_rows, 
                               <int> self.n_cols, 
                               <double> self.eps, 
                               <int> self.min_samples,
		               <int*> labels_ptr)

    
    def fit_predict(self, input_gdf):
        self.fit(input_gdf)
        return self.labels_
