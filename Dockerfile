# From: https://github.com/rapidsai/cudf/blob/master/Dockerfile
FROM cudf

ADD ml-prims /cuML/ml-prims
ADD cuML /cuML/cuML
ADD python /cuML/python
ADD setup.py /cuML/setup.py

WORKDIR /cuML
RUN source activate cudf && conda install -c pytorch cython faiss-gpu
RUN source activate cudf && python setup.py install
