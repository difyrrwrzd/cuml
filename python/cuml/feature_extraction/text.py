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
import warnings

from cudf import Series
from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS
from string import punctuation
from functools import partial
import nvtext
import cupy as cp
import numbers


def _preprocess(doc, lower=False, remove_punctuation=False, stop_words=None,
                delimiter=' '):
    """Chain together an optional series of text preprocessing steps to
    apply to a document.
    Parameters
    ----------
    doc: nvstrings
        The string to preprocess
    lower: bool
        Whether to use str.lower to lowercase all of the text
    remove_punctuation: bool
        Whether to remove all punctuation from the text before tokenizing.
        Punctuation characters are taken from string.punctuation
    Returns
    -------
    doc: nvstrings
        preprocessed string
    """
    if lower:
        doc = doc.lower()
    if remove_punctuation:
        punctuation_list = Series(list(punctuation))._column.nvstrings
        doc = doc.replace_multi(punctuation_list, delimiter, regex=False)
    if stop_words is not None:
        doc = nvtext.replace_tokens(doc, stop_words, delimiter)
    return doc


class _VectorizerMixin:
    """Provides common code for text vectorizers (tokenization logic)."""

    def _word_ngrams(self, tokens):
        """Turn tokens into a sequence of n-grams"""
        min_n, max_n = self.ngram_range

        ngrams = nvtext.ngrams_tokenize(tokens, N=min_n, sep=' ')
        min_n += 1

        ngrams_list = [nvtext.ngrams_tokenize(tokens, N=n, sep=' ')
                       for n in range(min_n, min(max_n + 1, len(tokens) + 1))]
        ngrams = ngrams.add_strings(ngrams_list)

        return ngrams

    def _char_ngrams(self, text_document):
        """Tokenize text_document into a sequence of character n-grams"""
        # tokens = nvtext.character_tokenize(text_document)
        # return self._word_ngrams(tokens)
        raise NotImplementedError("Character-level ngrams is not yet"
                                  " supported by cuML.")

    def _char_wb_ngrams(self, text_document):
        """Whitespace sensitive char-n-gram tokenization.
        Tokenize text_document into a sequence of character n-grams
        operating only inside word boundaries. n-grams at the edges
        of words are padded with space."""
        text_document = self._surround_with_space(text_document)
        return self._char_ngrams(text_document)

    @staticmethod
    def _surround_with_space(nvstr):
        """Adds spaces before and after each strings of a nvstrings"""
        s = len(nvstr)
        spaces = Series('').repeat(s)._column.nvstrings
        return spaces.cat(nvstr.cat(spaces, sep=' '), sep=' ')

    def build_preprocessor(self):
        """Return a function to preprocess the text before tokenization.
        Returns
        -------
        preprocessor: callable
              A function to preprocess the text before tokenization.
        """
        if self.preprocessor is not None:
            return self.preprocessor

        stop_words = None
        if self.analyzer == 'word' and self.stop_words is not None:
            stop_words = Series(self._get_stop_words())._column.nvstrings

        return partial(_preprocess, lower=self.lowercase,
                       remove_punctuation=self.remove_punctuation,
                       stop_words=stop_words, delimiter=self.delimiter)

    def _get_stop_words(self):
        """Build or fetch the effective stop words list.
        Returns
        -------
        stop_words: list or None
                A list of stop words.
        """
        if self.stop_words == "english":
            return list(ENGLISH_STOP_WORDS)
        elif isinstance(self.stop_words, str):
            raise ValueError("not a built-in stop list: %s" % self.stop_words)
        elif self.stop_words is None:
            return None
        else:  # assume it's a collection
            return list(self.stop_words)

    def _build_ngram_vocab(self, docs):
        """
        Build vocabulary when using ngrams.

        Returns
        -------
        ngrams: nvstrings
            The vocabulary of n-grams.
        """
        if self.analyzer == 'char':
            return self._char_ngrams(docs)
        elif self.analyzer == 'char_wb':
            return self._char_wb_ngrams(docs)
        elif self.analyzer == 'word':
            return self._word_ngrams(docs)
        else:
            raise ValueError('%s is not a valid tokenization scheme/analyzer' %
                             self.analyzer)

    def _build_vocabulary(self, docs):
        """Builds a vocabulary given the preprocessed documents.

        Takes care of tokenization and ngram_generation.
        """
        self._fixed_vocabulary = self.vocabulary is not None

        if self._fixed_vocabulary:
            self.vocabulary_ = self.vocabulary._column.nvstrings
        else:
            if self.ngram_range != (1, 1):
                vocab = self._build_ngram_vocab(docs)
                vocab = Series(vocab).unique()._column.nvstrings
            else:
                if self.analyzer == 'word':
                    vocab = nvtext.unique_tokens(docs)
                    vocab = vocab.sort()
                else:
                    vocab = nvtext.character_tokenize(docs)
                    vocab = Series(vocab).unique()._column.nvstrings

            self.vocabulary_ = vocab

        if len(self.vocabulary_) == 0:
            raise ValueError("Empty vocabulary; perhaps the documents only"
                             " contain stop words")

    def _validate_params(self):
        """Check validity of ngram_range parameter"""
        min_n, max_m = self.ngram_range
        msg = ""
        if min_n < 1:
            msg += "lower boundary must be >= 1. "
        if min_n > max_m:
            msg += "lower boundary larger than the upper boundary."
        if msg != "":
            msg = f"Invalid value for ngram_range={self.ngram_range} {msg}"
            raise ValueError(msg)

    def _warn_for_unused_params(self):
        if self.analyzer != 'word' and self.stop_words is not None:
            warnings.warn("The parameter 'stop_words' will not be used"
                          " since 'analyzer' != 'word'")
        if self.preprocessor is not None and self.stop_words is not None:
            warnings.warn("The parameter 'stop_words' will not be used"
                          " since 'preprocessor' is custom")


class CountVectorizer(_VectorizerMixin):
    """Convert a collection of text documents to a matrix of token counts

    If you do not provide an a-priori dictionary then the number of features
    will be equal to the vocabulary size found by analyzing the data.

    Parameters
    ----------
    lowercase : boolean, True by default
        Convert all characters to lowercase before tokenizing.
    preprocessor : callable or None (default)
        Override the preprocessing (string transformation) stage while
        preserving the tokenizing and n-grams generation steps.
    stop_words : string {'english'}, list, or None (default)
        If 'english', a built-in stop word list for English is used.
        If a list, that list is assumed to contain stop words, all of which
        will be removed from the input documents.
        Only applies if ``analyzer == 'word'`` and preprocessor is not None.
        If None, no stop words will be used. max_df can be set to a value
        to automatically detect and filter stop words based on intra corpus
        document frequency of terms.
    ngram_range : tuple (min_n, max_n), default=(1, 1)
        The lower and upper boundary of the range of n-values for different
        word n-grams or char n-grams to be extracted. All values of n such
        such that min_n <= n <= max_n will be used. For example an
        ``ngram_range`` of ``(1, 1)`` means only unigrams, ``(1, 2)`` means
        unigrams and bigrams, and ``(2, 2)`` means only bigrams.
    analyzer : string, {'word', 'char', 'char_wb'}
        Whether the feature should be made of word n-gram or character
        n-grams.
        Option 'char_wb' creates character n-grams only from text inside
        word boundaries; n-grams at the edges of words are padded with space.
    max_df : float in range [0.0, 1.0] or int, default=1.0
        When building the vocabulary ignore terms that have a document
        frequency strictly higher than the given threshold (corpus-specific
        stop words).
        If float, the parameter represents a proportion of documents, integer
        absolute counts.
        This parameter is ignored if vocabulary is not None.
    min_df : float in range [0.0, 1.0] or int, default=1
        When building the vocabulary ignore terms that have a document
        frequency strictly lower than the given threshold. This value is also
        called cut-off in the literature.
        If float, the parameter represents a proportion of documents, integer
        absolute counts.
        This parameter is ignored if vocabulary is not None.
    max_features : int or None, default=None
        If not None, build a vocabulary that only consider the top
        max_features ordered by term frequency across the corpus.
        This parameter is ignored if vocabulary is not None.
    vocabulary : cudf.Series, optional
        If not given, a vocabulary is determined from the input documents.
    binary : boolean, default=False
        If True, all non zero counts are set to 1. This is useful for discrete
        probabilistic models that model binary events rather than integer
        counts.
    dtype : type, optional
        Type of the matrix returned by fit_transform() or transform().
    remove_punctuation : boolean, True by default
        Remove all characters from string.punctuation before tokenizing.
    delimiter : str, whitespace by default
        String used as a replacement for punctuation if remove_punctuation is
        True and for stop words if stop_words is not None. Typically the
        delimiting character between words is a good choice. Default is space.
    Attributes
    ----------
    vocabulary_ : nvstrings
        Array mapping from feature integer indices to feature name.
    stop_words_ : nvstrings
        Terms that were ignored because they either:
          - occurred in too many documents (`max_df`)
          - occurred in too few documents (`min_df`)
          - were cut off by feature selection (`max_features`).
        This is only available if no vocabulary was given.
    """
    def __init__(self, input=None, encoding=None, decode_error=None,
                 strip_accents=None, lowercase=True, preprocessor=None,
                 tokenizer=None, stop_words=None, token_pattern=None,
                 ngram_range=(1, 1), analyzer='word', max_df=1.0, min_df=1,
                 max_features=None, vocabulary=None, binary=False,
                 dtype=cp.int32, remove_punctuation=True, delimiter=' '):
        self.preprocessor = preprocessor
        self.analyzer = analyzer
        self.lowercase = lowercase
        self.remove_punctuation = remove_punctuation
        self.stop_words = stop_words
        self.max_df = max_df
        self.min_df = min_df
        if max_df < 0 or min_df < 0:
            raise ValueError("negative value for max_df or min_df")
        self.max_features = max_features
        if max_features is not None:
            if not isinstance(max_features, int) or max_features <= 0:
                raise ValueError(
                    "max_features=%r, neither a positive integer nor None"
                    % max_features)
        self.ngram_range = ngram_range
        self.vocabulary = vocabulary
        self.binary = binary
        self.dtype = dtype
        self.delimiter = delimiter

        sklearn_params = {"input": input,
                          "encoding": encoding,
                          "decode_error": decode_error,
                          "strip_accents": strip_accents,
                          "tokenizer": tokenizer,
                          "token_pattern": token_pattern}
        self._check_sklearn_params(analyzer, sklearn_params)

    def _count_vocab(self, docs):
        """Create feature matrix, and vocabulary where fixed_vocab=False"""
        vocabulary = self.vocabulary_
        X = cp.empty((len(docs), len(vocabulary)), dtype=cp.int32)

        if self.ngram_range != (1, 1):
            docs = self._surround_with_space(docs)
            vocabulary = self._surround_with_space(vocabulary)
            nvtext.strings_counts(docs, vocabulary, devptr=X.data.ptr)
        else:
            if self.analyzer == 'word':
                nvtext.tokens_counts(docs, vocabulary, devptr=X.data.ptr)
            else:
                nvtext.strings_counts(docs, vocabulary, devptr=X.data.ptr)

        return X

    def _limit_features(self, X, vocab, high, low, limit):
        """Remove too rare or too common features.

        Prune features that are non zero in more samples than high or less
        documents than low, modifying the vocabulary, and restricting it to
        at most the limit most frequent.
        """
        if high is None and low is None and limit is None:
            self.stop_words_ = None
            return X

        document_frequency = cp.count_nonzero(X, axis=0)
        mask = cp.ones(len(document_frequency), dtype=bool)
        if high is not None:
            mask &= document_frequency <= high
        if low is not None:
            mask &= document_frequency >= low
        if limit is not None and mask.sum() > limit:
            term_frequency = X.sum(axis=0)
            mask_inds = (-term_frequency[mask]).argsort()[:limit]
            new_mask = cp.zeros(len(document_frequency), dtype=bool)
            new_mask[cp.where(mask)[0][mask_inds]] = True
            mask = new_mask

        keep_idx = cp.where(mask)[0].astype(cp.int32)
        keep_num = keep_idx.shape[0]

        self.stop_words_ = vocab.remove_strings(keep_idx.data.ptr, keep_num)
        self.vocabulary_ = vocab.gather(keep_idx.data.ptr, keep_num)

        X = X[:, mask]
        return X

    def _preprocess(self, raw_documents):
        preprocess = self.build_preprocessor()
        docs = raw_documents._column.nvstrings
        return preprocess(docs)

    def fit(self, raw_documents):
        """Build a vocabulary of all tokens in the raw documents.

       Parameters
       ----------
       raw_documents : cudf.Series
           A Series of string documents

       Returns
       -------
       self
       """
        self.fit_transform(raw_documents)
        return self

    def fit_transform(self, raw_documents):
        """Build the vocabulary and return document-term matrix.

        Equivalent to .fit(X).transform(X) but preprocess X only once.

        Parameters
        ----------
        raw_documents : cudf.Series
           A Series of string documents

        Returns
        -------
        X : array of shape (n_samples, n_features)
            Document-term matrix.
        """
        self._warn_for_unused_params()
        self._validate_params()
        docs = self._preprocess(raw_documents)
        self._build_vocabulary(docs)

        X = self._count_vocab(docs)

        if self.binary:
            cp.minimum(X, 1, out=X)

        if not self._fixed_vocabulary:
            n_doc = len(X)
            max_doc_count = (self.max_df
                             if isinstance(self.max_df, numbers.Integral)
                             else self.max_df * n_doc)
            min_doc_count = (self.min_df
                             if isinstance(self.min_df, numbers.Integral)
                             else self.min_df * n_doc)
            if max_doc_count < min_doc_count:
                raise ValueError(
                    "max_df corresponds to < documents than min_df")
            X = self._limit_features(X, self.vocabulary_,
                                     max_doc_count,
                                     min_doc_count,
                                     self.max_features)

        X = X.astype(dtype=self.dtype)
        return X

    def transform(self, raw_documents):
        """Transform documents to document-term matrix.

        Extract token counts out of raw text documents using the vocabulary
        fitted with fit or the one provided to the constructor.

        Parameters
        ----------
        raw_documents : cudf.Series
           A Series of string documents

        Returns
        -------
        X : array of shape (n_samples, n_features)
            Document-term matrix.
        """
        docs = self._preprocess(raw_documents)
        X = self._count_vocab(docs)
        if self.binary:
            cp.minimum(X, 1, out=X)
        X = X.astype(dtype=self.dtype)
        return X

    def inverse_transform(self, X):
        """Return terms per document with nonzero entries in X.

        Parameters
        ----------
        X : array-like of shape (n_samples, n_features)
            Document-term matrix.

        Returns
        -------
        X_inv : list of cudf.Series of shape (n_samples,)
            List of Series of terms.
        """
        vocab = Series(self.vocabulary_)
        return [vocab[X[i, :].nonzero()[0]] for i in range(X.shape[0])]

    def get_feature_names(self):
        """Array mapping from feature integer indices to feature name.
        Returns
        -------
        feature_names : nvstrings
            A list of feature names.
        """
        return self.vocabulary_

    def _check_sklearn_params(self, analyzer, sklearn_params):
        if callable(analyzer):
            raise ValueError("cuML does not support callable analyzer,"
                             " please refer to the cuML documentation for"
                             " more information.")

        for key, vals in sklearn_params.items():
            if vals is not None:
                raise TypeError("The Scikit-learn variable", key,
                                " is not supported in cuML,"
                                " please read the cuML documentation for"
                                " more information.")
