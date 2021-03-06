# Adapted from scikit-learn
# Copyright (c) 2007–2016 The scikit-learn developers.

using StatsBase: counts

"""Turn seed into a np.random.RandomState instance

If seed is None, return the RandomState singleton used by np.random.
If seed is an int, return a new RandomState instance seeded with seed.
If seed is already a RandomState instance, return it.
Otherwise raise ValueError.
"""
check_random_state(seed::Void) = Base.GLOBAL_RNG
check_random_state(seed::Int) = MersenneTwister(seed)
check_random_state(seed::MersenneTwister) = seed
check_random_state(seed::Any) =
    throw(ArgumentError("$seed cannot be used to seed a MersenneTwister"))


################################################################################
# Defining the cross-validation iterators (eg. KFold)

# Python indices are 0-based, so we need to transform the cross-validation
# iterators by adding 1 to each index.
fix_cv_arr(arr::Vector{Int}) = arr .+ 1
fix_cv_iter_indices(cv::PyObject) =
    [(fix_cv_arr(train), fix_cv_arr(test)) for (train, test) in cv]


cv_iterator_syms = [:KFold, :StratifiedKFold, :LabelKFold, :LeaveOneOut,
                    :LeavePOut, :LeaveOneLabelOut, :LeavePLabelOut,
                    :ShuffleSplit, :LabelShuffleSplit, :StratifiedShuffleSplit]
# Those that are implemented in Julia (so don't need to be imported from
# Python)
julia_iterators = [:KFold, :StratifiedKFold]

# The current procedure collects the value in order to fix them.
# I don't worry about that much (should be marginal in the grand scheme of
# things), but we could do better.
for cv_iter in setdiff(cv_iterator_syms, julia_iterators)
    @eval function $cv_iter(args...; kwargs...)
        sk_cv = importpy("sklearn.cross_validation")
        fix_cv_iter_indices(sk_cv[$(Expr(:quote, cv_iter))](args...; kwargs...))
    end
end

# Note: scikit-learn-python defines a whole class for each cross-validation
# iterator type. That seems like over-engineering to me, but maybe there's
# a deeper reason for it (are the results the same under GridSearchCV, for
# example?) - cstjean May 2016

function folds_from_test_sets(n::Int, test_sets::AbstractVector)
    ind = 1:n
    @assert sum(map(length, test_sets)) == n # sanity check
    return [(setdiff(ind, test_index), convert(Vector{Int}, test_index))
            for test_index in test_sets]
end


"""K-Folds cross validation iterator.

Provides train/test indices to split data in train test sets. Split
dataset into k consecutive folds (without shuffling by default).

Each fold is then used a validation set once while the k - 1 remaining
fold form the training set.

Read more in the :ref:`User Guide <cross_validation>`.

Parameters
----------
n : int
    Total number of elements.

n_folds : int, default=3
    Number of folds. Must be at least 2.

shuffle : boolean, optional
    Whether to shuffle the data before splitting into batches.

random_state : None, int or RandomState
    When shuffle=True, pseudo-random number generator state used for
    shuffling. If None, use default numpy RNG for shuffling.

Examples
--------
>>> using ScikitLearn.CrossValidation: KFold
>>> X = [1 2; 3 4; 1 2; 3 4])
>>> y = [1, 2, 3, 4]
>>> kf = KFold(4, n_folds=2)
>>> length(kf)
2
>>> for (train_index, test_index) in kf
...    println("TRAIN:", train_index, "TEST:", test_index)
...    X_train, X_test = X[train_index], X[test_index]
...    y_train, y_test = y[train_index], y[test_index]
... end
TRAIN: [2 3] TEST: [0 1]
TRAIN: [0 1] TEST: [2 3]

Notes
-----
The first mod(n, n_folds) folds have size div(n, n_folds) + 1, other folds have
size div(n, n_folds)

See also
--------
StratifiedKFold: take label information into account to avoid building
folds with imbalanced class distributions (for binary or multiclass
classification tasks).

LabelKFold: K-fold iterator variant with non-overlapping labels.
"""
function KFold(n; n_folds=3, shuffle=false, random_state=nothing)
    inds = collect(1:n)
    if shuffle
        rng = check_random_state(random_state)
        Base.shuffle!(rng, inds)
    end
    fold_sizes = div(n, n_folds) * ones(Int, n_folds)
    fold_sizes[1:mod(n, n_folds)] += 1
    @assert sum(fold_sizes) == n # sanity check
    current = 1
    test_sets = Any[]
    for fold_size in fold_sizes
        start, stop = current, current + fold_size
        push!(test_sets, inds[start:stop-1])
        current = stop
    end
    return folds_from_test_sets(n, test_sets)
end

function StratifiedKFold(y::AbstractArray; n_folds=3, shuffle=false,
                         random_state=nothing)
    n_samples = size(y, 1)
    unique_labels = unique(y)
    y_inversed = Int[findfirst(unique_labels, a) for a in y] # O(N²)
    label_counts = counts(y_inversed, 1:length(unique_labels))
    min_labels = minimum(label_counts)
    if n_folds > min_labels
        warn("The least populated class in y has only $min_labels" *
             " members, which is too few. The minimum" *
             " number of labels for any class cannot" *
             " be less than n_folds=$n_folds.")
    end

    # don't want to use the same seed in each label's shuffle
    if shuffle
        rng = check_random_state(random_state)
    else
        rng = random_state
    end

    # pre-assign each sample to a test fold index using individual KFold
    # splitting strategies for each label so as to respect the
    # balance of labels
    per_label_cvs = [KFold(max(c, n_folds), n_folds=n_folds, shuffle=shuffle,
                           random_state=rng)
                     for c in label_counts]
    test_folds = zeros(Int, n_samples)
    for (test_fold_idx, per_label_splits) in enumerate(zip(per_label_cvs...))
        for (label, (_, test_split)) in zip(unique_labels, per_label_splits)
            label_test_folds = test_folds[y .== label]
            # the test split can be too big because we used
            # KFold(max(c, self.n_folds), self.n_folds) instead of
            # KFold(c, self.n_folds) to make it possible to not crash even
            # if the data is not 100% stratifiable for all the labels
            # (we use a warning instead of raising an exception)
            # If this is the case, let's trim it:
            test_split = test_split[test_split .<= length(label_test_folds)]
            label_test_folds[test_split] = test_fold_idx
            test_folds[y .== label] = label_test_folds
        end
    end
    return folds_from_test_sets(n_samples,
                                [find(test_folds.==i) for i in 1:n_folds])
end

################################################################################

"""Input checker utility for building a CV in a user friendly way.

Parameters
----------
cv : int, a cv generator instance, or None
    The input specifying which cv generator to use. It can be an
    integer, in which case it is the number of folds in a KFold,
    None, in which case 3 fold is used, or another object, that
    will then be used as a cv generator.

X : array-like
    The data the cross-val object will be applied on.

y : array-like
    The target variable for a supervised learning problem.

classifier : boolean optional
    Whether the task is a classification task, in which case
    stratified KFold will be used.

Returns
-------
checked_cv: a cross-validation generator instance.
    The return value is guaranteed to be a cv generator instance, whatever
    the input type.
"""
function check_cv(cv, X=nothing, y=nothing; classifier=false)
    is_sparse = issparse(X)
    if cv === nothing
        cv = 3
    end
    if isa(cv, Number)
        if classifier
            if type_of_target(y) in ["binary", "multiclass"]
                cv = StratifiedKFold(y; n_folds=cv)
            else
                cv = KFold(size(y, 1); n_folds=cv)
            end
        else
            n_samples = size(X, 1)
            cv = KFold(n_samples; n_folds=cv)
        end
    end
    return cv
end

"""Evaluate a score by cross-validation

Parameters
----------
estimator : estimator object implementing 'fit'
    The object to use to fit the data.

X : array-like
    The data to fit. Can be, for example a list, or an array at least 2d.

y : array-like, optional, default: nothing
    The target variable to try to predict in the case of
    supervised learning.

scoring : string, callable or nothing, optional, default: nothing
    A string (see model evaluation documentation) or
    a scorer callable object / function with signature
    ``scorer(estimator, X, y)``.

cv : cross-validation generator or int, optional, default: nothing
    A cross-validation generator to use. If int, determines
    the number of folds in StratifiedKFold if y is binary
    or multiclass and estimator is a classifier, or the number
    of folds in KFold otherwise. If nothing, it is equivalent to cv=3.

n_jobs : integer, optional
    The number of CPUs to use to do the computation. -1 means
    'all CPUs'.

verbose : integer, optional
    The verbosity level.

fit_params : dict, optional
    Parameters to pass to the fit method of the estimator.

Returns
-------
scores : array of float, shape=(len(list(cv)),)
    Array of scores of the estimator for each run of the cross validation.
"""
function cross_val_score(estimator, X, y=nothing; scoring=nothing, cv=nothing,
                         n_jobs=1, verbose=0, fit_params=nothing)
    # See the original source for inspiration on how to do it.
    @assert n_jobs==1 "Parallel cross-validation not supported yet. TODO"

    check_consistent_length(X, y)

    cv = check_cv(cv, X, y, classifier=is_classifier(estimator))

    scorer = check_scoring(estimator, scoring)

    # We clone the estimator to make sure that all the folds are independent
    scores = Float64[_fit_and_score(clone(estimator), X, y, scorer,
                                    train, test, verbose, nothing,
                                    fit_params)[1]
                     for (train, test) in cv]

    return scores
end


"""Fit estimator and predict values for a given dataset split.

Parameters
----------
estimator : estimator object implementing 'fit' and 'predict'
The object to use to fit the data.

X : array-like of shape at least 2D
The data to fit.

y : array-like, optional, default: None
The target variable to try to predict in the case of
supervised learning.

train : array-like, shape (n_train_samples,)
Indices of training samples.

test : array-like, shape (n_test_samples,)
Indices of test samples.

verbose : integer
The verbosity level.

fit_params : dict or None
Parameters that will be passed to ``estimator.fit``.

Returns
-------
preds : sequence
Result of calling 'estimator.predict'

test : array-like
This is the value of the test parameter
"""
function _fit_and_predict(estimator, X, y, train, test, verbose, fit_params)
    fit_params = fit_params !== nothing ? fit_params : Dict()
    # Adjust length of sample weights
    fit_params = Dict([(k => _index_param_value(X, v, train))
                       for (k, v) in fit_params])

    X_train, y_train = _safe_split(estimator, X, y, train)
    X_test, _ = _safe_split(estimator, X, y, test, train)

    if y_train === nothing
        fit!(estimator, X_train; fit_params...)
    else
        fit!(estimator, X_train, y_train; fit_params...)
    end
    preds = predict(estimator, X_test)
    return preds, test
end


"""Generate cross-validated estimates for each input data point

Parameters
----------
estimator : estimator object implementing 'fit' and 'predict'
    The object to use to fit the data.

X : array-like
    The data to fit. Can be, for example a list, or an array at least 2d.

y : array-like, optional, default: None
    The target variable to try to predict in the case of
    supervised learning.

cv : cross-validation generator or int, optional, default: None
    A cross-validation generator to use. If int, determines
    the number of folds in StratifiedKFold if y is binary
    or multiclass and estimator is a classifier, or the number
    of folds in KFold otherwise. If None, it is equivalent to cv=3.
    This generator must include all elements in the test set exactly once.
    Otherwise, a ValueError is raised.

n_jobs : integer, optional
    The number of CPUs to use to do the computation. -1 means
    'all CPUs'.

verbose : integer, optional
    The verbosity level.

fit_params : dict, optional
    Parameters to pass to the fit method of the estimator.

Returns
-------
preds : ndarray
    This is the result of calling 'predict'
"""
function cross_val_predict(estimator, X, y=nothing; cv=nothing, n_jobs=1,
                           verbose=0, fit_params=nothing)
    @assert n_jobs==1 "Parallel cross-validation not supported yet. TODO"

    check_consistent_length(X, y)

    cv = check_cv(cv, X, y, classifier=is_classifier(estimator))
    # We clone the estimator to make sure that all the folds are
    # independent
    preds_blocks = Any[_fit_and_predict(clone(estimator), X, y,
                                        train, test, verbose,
                                        fit_params)
                       for (train, test) in cv]
    p = vcat([p for (p, _) in preds_blocks]...)
    locs = vcat([loc for (_, loc) in preds_blocks]...)
    ## if !sk_cv._check_is_partition(locs, size(X, 1))
    ##     error("cross_val_predict only works for partitions")
    ## end
    preds = copy(p)  # is the copy necessary?
    preds[locs] = p
    return preds
end




"""Determine scorer from user options.

A TypeError will be thrown if the estimator cannot be scored.

Parameters
----------
estimator : estimator object implementing 'fit'
    The object to use to fit the data.

scoring : string, callable or nothing, optional, default: nothing
    A string (see model evaluation documentation) or
    a scorer callable object / function with signature
    ``scorer(estimator, X, y)``.

allow_none : boolean, optional, default: False
    If no scoring is specified and the estimator has no score function, we
    can either return nothing or raise an exception.

Returns
-------
scoring : callable
    A scorer callable object / function with signature
    ``scorer(estimator, X, y)``.
"""
function check_scoring{T}(estimator::T, scoring=nothing; allow_none=false)
    @assert !allow_none "TODO: allow_none=true"
    # sklearn asserts that estimator has a `fit` method. We should do that too.
    if scoring !== nothing
        return get_scorer(scoring)
    elseif true  # should be: if `score(::T)` is defined. Use `method_exists`
        return score
    elseif allow_none
        nothing
    else
        throw(TypeError("If no scoring is specified, the estimator passed should have a 'score' method. The estimator $estimator does not."))
    end
end


# This is to help deal with the keyword arguments to `fit!` during
# cross-validation . For instance, if `sample_weights` are provided, then
# cross-validation needs to select them according to the train/test split. The
# sklearn-py code has a heuristic "if size(X, 1)==size(keyword_arg, 1) then we
# need to split keyword_arg too". I replicate that logic here, but I would sleep
# better if we could get rid of it. - cstjean
function _index_param_value(X, v::AbstractArray, indices)
    if size(X, 1) == size(v, 1)
        return v[indices]
    else
        # Is this branch ever reached, though? Are there legitimate arguments
        # to `fit` that are not of the same length as the data?
        return v
        ## throw(ArgumentError("fit! was passed a keyword argument that is an ::AbstractArray that does not match with X (not the same number of samples). This is disallowed at the moment"))
    end
end
# Default for every argument that's not an AbstractArray
_index_param_value(X, v, indices) = v

# For reference:
## def _index_param_value(X, v, indices):
##     """Private helper function for parameter value indexing."""
##     if not _is_arraylike(v) or _num_samples(v) != _num_samples(X):
##         # pass through: skip indexing
##         return v
##     if sp.issparse(v):
##         v = v.tocsr()
##     return safe_indexing(v, indices)


"""Fit estimator and compute scores for a given dataset split.

Parameters
----------
estimator : estimator object implementing 'fit'
    The object to use to fit the data.

X : array-like of shape at least 2D
    The data to fit.

y : array-like, optional, default: nothing
    The target variable to try to predict in the case of
    supervised learning.

scorer : callable
    A scorer callable object / function with signature
    ``scorer(estimator, X, y)``.

train : array-like, shape (n_train_samples,)
    Indices of training samples.

test : array-like, shape (n_test_samples,)
    Indices of test samples.

verbose : integer
    The verbosity level.

error_score : 'raise' (default) or numeric
    Value to assign to the score if an error occurs in estimator fitting.
    If set to 'raise', the error is raised. If a numeric value is given,
    FitFailedWarning is raised. This parameter does not affect the refit
    step, which will always raise the error.

parameters : dict or nothing
    Parameters to be set on the estimator.

fit_params : dict or nothing
    Parameters that will be passed to ``estimator.fit``.

return_train_score : boolean, optional, default: False
    Compute and return score on training set.

return_parameters : boolean, optional, default: False
    Return parameters that has been used for the estimator.

Returns
-------
train_score : float, optional
    Score on training set, returned only if `return_train_score` is `True`.

test_score : float
    Score on test set.

n_test_samples : int
    Number of test samples.

scoring_time : float
    Time spent for fitting and scoring in seconds.

parameters : dict or nothing, optional
    The parameters that have been evaluated.
"""
function _fit_and_score(estimator, X, y, scorer,
                        # Vector{Int} is defensive programming. Could be
                        # changed.
                        train::Vector{Int}, test::Vector{Int}, verbose,
                        parameters, fit_params::Union{Void, Dict{Symbol}};
                        return_train_score=false,
                        return_parameters=false, error_score="raise")
    # Julia TODO
    @assert error_score == "raise" "error_score = $error_score not supported"
    if verbose > 1
        if parameters === nothing
            msg = "no parameters to be set"
        else
            msg = string(join(["$k=$v" for (k, v) in parameters], ", "))
        end
        println("[CV] $msg")
    end

    # Adjust length of sample weights
    fit_params = fit_params!==nothing ? fit_params : Dict()
    fit_params = Dict([k => _index_param_value(X, v, train)
                       for (k, v) in fit_params])

    if parameters !== nothing
        set_params!(estimator; parameters...)
    end

    start_time = time()

    X_train, y_train = _safe_split(estimator, X, y, train)
    X_test, y_test = _safe_split(estimator, X, y, test, train)

    # Julia TODO: Python has some meaningful error handling here
    if y_train === nothing
        fit!(estimator, X_train; fit_params...)
    else
        fit!(estimator, X_train, y_train; fit_params...)
    end

    test_score = _score(estimator, X_test, y_test, scorer)
    if return_train_score
        train_score = _score(estimator, X_train, y_train, scorer)
    end

    scoring_time = time() - start_time

    if verbose > 2
        msg *= @sprintf(", score=%.5f", test_score)
    end
    if verbose > 1
        end_msg = msg * @sprintf("  -  %.1fs", scoring_time)
        println("[CV] $end_msg")
    end

    ret = return_train_score ? [train_score] : Any[]
    push!(ret, test_score, size(X_test, 1), scoring_time)
    if return_parameters
        push!(ret, parameters)
    end
    return ret
end


"""Create subset of dataset and properly handle kernels."""
function _safe_split(estimator, X, y, indices, train_indices=nothing)
    # Julia note: I don't get what they mean here. FIXME
    ## if hasattr(estimator, 'kernel') and callable(estimator.kernel)
    ##     # cannot compute the kernel values with custom function
    ##     raise ValueError("Cannot use a custom kernel function. "
    ##                      "Precompute the kernel matrix instead.")

    # Julia note: not sure how to translate this either. It might be how
    # sklearn detects kernels?
    ## if not hasattr(X, "shape"):
    ##     if getattr(estimator, "_pairwise", False):
    ##         raise ValueError("Precomputed kernels or affinity matrices have "
    ##                          "to be passed as arrays or sparse matrices.")
    ##     X_subset = [X[idx] for idx in indices]
    ## else:
    if is_pairwise(estimator)
        # X is a precomputed square kernel matrix
        if size(X, 1) != size(X, 2)
            throw(ArgumentError("X should be a square kernel matrix"))
        end
        # Julia TODO: I want a test case before trying to translate
        # this indexing code
        TODO()
        ## if train_indices === nothing
        ##     X_subset = X[np.ix_(indices, indices)]
    ## else:
        ##     X_subset = X[np.ix_(indices, train_indices)]
    elseif ndims(X) == 1
        X_subset = X[indices]
    else
        # Python seems to support three-dimensionl X (see
        # test_crossvalidation.jl). I don't understand why, and I'd rather
        # disable it until I do - cstjean
        @assert ndims(X) == 2 "X must be 1D or 2D"
        X_subset = X[indices, :]
    end

    if y !== nothing
        y_subset = y[indices]
    else
        y_subset = nothing
    end

    return X_subset, y_subset
end


"""Compute the score of an estimator on a given test set."""
function _score(estimator, X_test, y_test, scorer)
    if y_test === nothing
        score = scorer(estimator, X_test)
    else
        score = scorer(estimator, X_test, y_test)
    end
    if !isa(score, Number)
        throw(ValueError("scoring must return a number, got a $(typeof(score)) instead."))
    end
    return score
end


function train_test_split(args...; kwargs...)
    cv = importpy("sklearn.cross_validation")
    # This is totally cheating - TODO: rewrite in Julia
    # It's used in Classifier_Comparison
    cv[:train_test_split](args...; kwargs...)
end
