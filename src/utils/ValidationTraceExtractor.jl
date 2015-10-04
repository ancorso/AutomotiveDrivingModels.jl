module ValidationTraceExtractor

using DataFrames
using Discretizers
using JLD

using AutomotiveDrivingModels.CommonTypes
using AutomotiveDrivingModels.Trajdata
using AutomotiveDrivingModels.StreetNetworks
using AutomotiveDrivingModels.Features
using AutomotiveDrivingModels.FeaturesetExtractor
using AutomotiveDrivingModels.Curves # TODO: remove this

import Base: ==, isequal
import Base.Collections: PriorityQueue, dequeue!
import AutomotiveDrivingModels.FeaturesetExtractor: create_dataframe_with_feature_columns

export
        OrigHistobinExtractParameters,
        StartCondition,
        ModelTrainingData,
        FoldAssignment,

        FOLD_TRAIN,
        FOLD_TEST,

        total_framecount,
        # pull_start_conditions,
        calc_traces_to_keep_with_frameskip,

        pull_model_training_data,

        is_strictly_monotonically_increasing,
        merge_region_segments,
        calc_row_count_from_region_segments,

        get_cross_validation_fold_assignment,
        get_train_test_fold_assignment,
        calc_fold_size,
        is_in_fold,


        load_pdsets,
        load_streetnets


########################################
# ORIGINAL HISTOBIN EXTRACT PARAMETERS #
########################################

type OrigHistobinExtractParameters
    behavior        :: String
    subsets         :: Vector{AbstractFeature} # Features that must be true (eg: SUBSET_FREE_FLOW)
    tol_d_cl        :: Float64 # [m]
    tol_yaw         :: Float64 # [rad]
    tol_turnrate    :: Float64 # [rad/s]
    tol_speed       :: Float64 # [m/s]
    tol_accel       :: Float64 # [m/s²]
    tol_d_x_front   :: Float64 # [m]
    tol_d_y_front   :: Float64 # [m]
    tol_d_v_front   :: Float64 # [m/s]

    target_speed    :: Float64 # [m/s]

    pdset_frames_per_sim_frame :: Int # number of pdset frames that occur in the space of one sim frame
    sim_horizon     :: Int # number of sim frames past the initial conditions to run (≥0)
    sim_history     :: Int # number of sim frames up to and including frame 1 (≥1)
    frameskip_between_extracted_scenes :: Int

    function OrigHistobinExtractParameters(
        behavior::String="",
        subsets::Vector{AbstractFeature}=AbstractFeature[],
        tol_d_cl::Float64=NaN,
        tol_yaw::Float64=NaN,
        tol_turnrate::Float64=NaN,
        tol_speed::Float64=NaN,
        tol_accel::Float64=NaN,
        tol_d_x_front::Float64=NaN,
        tol_d_y_front::Float64=NaN,
        tol_d_v_front::Float64=NaN,
        target_speed::Float64=NaN,
        pdset_frames_per_sim_frame::Int=-1,
        sim_horizon::Int=-1,
        sim_history::Int=-1,
        frameskip_between_extracted_scenes::Int=-1,
        )

        retval = new()
        retval.behavior = behavior
        retval.subsets = subsets
        retval.tol_d_cl = tol_d_cl
        retval.tol_yaw = tol_yaw
        retval.tol_turnrate = tol_turnrate
        retval.tol_speed = tol_speed
        retval.tol_accel = tol_accel
        retval.tol_d_x_front = tol_d_x_front
        retval.tol_d_y_front = tol_d_y_front
        retval.tol_d_v_front = tol_d_v_front
        retval.target_speed = target_speed
        retval.pdset_frames_per_sim_frame = pdset_frames_per_sim_frame
        retval.sim_horizon = sim_horizon
        retval.sim_history = sim_history
        retval.frameskip_between_extracted_scenes = frameskip_between_extracted_scenes
        retval
    end
end
total_framecount(stats::OrigHistobinExtractParameters) = stats.sim_history + stats.sim_horizon
function ==(a::OrigHistobinExtractParameters, b::OrigHistobinExtractParameters)
    a.behavior == b.behavior &&
    length(a.subsets) == length(b.subsets) &&
    all([findfirst(item->isa(item, typeof(feature_a)), b.subsets)!=0 for feature_a in a.subsets]) &&
    isapprox(a.tol_d_cl,      b.tol_d_cl)      &&
    isapprox(a.tol_yaw,       b.tol_yaw)       &&
    isapprox(a.tol_turnrate,  b.tol_turnrate)  &&
    isapprox(a.tol_speed,     b.tol_speed)     &&
    isapprox(a.tol_accel,     b.tol_accel)     &&
    isapprox(a.tol_d_x_front, b.tol_d_x_front) &&
    isapprox(a.tol_d_y_front, b.tol_d_y_front) &&
    isapprox(a.tol_d_v_front, b.tol_d_v_front) &&
    isapprox(a.target_speed,  b.target_speed)  &&
    a.pdset_frames_per_sim_frame         == b.pdset_frames_per_sim_frame &&
    a.sim_horizon                        == b.sim_horizon &&
    a.sim_history                        == b.sim_history &&
    a.frameskip_between_extracted_scenes == b.frameskip_between_extracted_scenes
end
!=(a::OrigHistobinExtractParameters, b::OrigHistobinExtractParameters) = !(a==b)
isequal(a::OrigHistobinExtractParameters, b::OrigHistobinExtractParameters) = a == b


########################################
#          START CONDITION             #
########################################

immutable StartCondition
    validfind :: Int # the starting validfind (includes history)
    carids    :: Vector{Int} # vehicles to pull traces for
end

########################################
#         MODEL TRAINING DATA          #
########################################

type ModelTrainingData
    pdset_filepaths::Vector{String}      # list of pdset full filepaths
    streetnet_filepaths::Vector{String}  # list of streetnet full filepaths
    pdset_segments::Vector{PdsetSegment} # set of PdsetSegments, all should be of the same length
    dataframe::DataFrame                 # dataframe of features used in training. A bunch of vcat'ed pdset data
    startframes::Vector{Int}             # dataframe[startframes[i], :] is data row for pdset_segments[i].validfind_start
                                         # seg_to_framestart[i] -> j
                                         # where i is the pdsetsegment index
                                         # and j is the row in dataframe for the start (pdsetsegment.log[pdsetsegment.history,:])
end

########################################
#            Fold Assignment           #
########################################

type FoldAssignment
    # assigns each frame and pdsetseg to
    # an integer fold
    # first fold is fold 1
    frame_assignment::Vector{Int}
    pdsetseg_assignment::Vector{Int}
    nfolds::Int

    function FoldAssignment(frame_assignment::Vector{Int}, pdsetseg_assignment::Vector{Int}, nfolds::Int)

        # some precautions...
        for a in frame_assignment
            @assert(a ≤ nfolds)
        end
        for a in pdsetseg_assignment
            @assert(a ≤ nfolds)
        end

        new(frame_assignment, pdsetseg_assignment, nfolds)
    end
    function FoldAssignment(frame_assignment::Vector{Int}, pdsetseg_assignment::Vector{Int})

        # some precautions...
        nfolds = -1
        for a in frame_assignment
            @assert(a > 0)
            nfolds = max(a, nfolds)
        end
        for a in pdsetseg_assignment
            @assert(a > 0)
            nfolds = max(a, nfolds)
        end

        new(frame_assignment, pdsetseg_assignment, nfolds)
    end
end
const FOLD_TRAIN = 1
const FOLD_TEST = 2

function calc_fold_size{I<:Integer}(fold::Integer, fold_assignment::AbstractArray{I}, match_fold::Bool)
    fold_size = 0
    for a in fold_assignment
        if is_in_fold(fold, a, match_fold)
            fold_size += 1
        end
    end
    fold_size
end
function is_in_fold(fold::Integer, fold_assignment::Integer, match_fold::Bool)
    (fold != 0) && # NOTE(tim): zero never matches
        ((match_fold && fold_assignment == fold) || (!match_fold && fold_assignment != fold))
end

########################################
#              FUNCTIONS               #
########################################

function _get_pdsetfile(csvfile::String, pdset_dir::String=PRIMARYDATA_DIR)
    csvfilebase = basename(csvfile)
    joinpath(pdset_dir, toext("primarydata_" * csvfilebase, "jld"))
end
function _load_pdset(csvfile::String, pdset_dir::String=PRIMARYDATA_DIR)
    pdsetfile = _get_pdsetfile(csvfile, pdset_dir)
    pdset = load(pdsetfile, "pdset")
end

function calc_traces_to_keep_with_frameskip(
    start_conditions :: Vector{StartCondition},
    pdset :: PrimaryDataset,
    frameskip :: Int
    )

    keep = falses(length(start_conditions))
    prev_frameind = -frameskip
    for (i,start_condition) in enumerate(start_conditions)
        frameind = validfind2frameind(pdset, start_condition.validfind)
        keep[i] = (frameind - prev_frameind) ≥ frameskip
        if keep[i]
            prev_frameind = frameind
        end
    end

    keep
end

function _calc_frame_passes_subsets{F<:AbstractFeature}(
    pdset     :: PrimaryDataset,
    sn        :: StreetNetwork,
    carind    :: Int,
    validfind :: Int,
    subsets   :: Vector{F}
    )

    for subset in subsets
        val = get(subset, pdset, sn, carind, validfind)::Float64
        @assert(isapprox(val, 0.0) || isapprox(val, 1.0))
        @assert(isbool(subset))
        if !bool(val)
            return false
        end
    end
    true
end
function _calc_frame_passes_subsets{F<:AbstractFeature}(
    pdset     :: PrimaryDataset,
    sn        :: StreetNetwork,
    carind    :: Int,
    validfind :: Int,
    subsets   :: Vector{F},
    subsets_based_on_csvfileset :: DataFrame
    )

    for subset in subsets


        if isa(subset, typeof(SUBSET_FREE_FLOW))
            passes = subsets_based_on_csvfileset[validfind, symbol(SUBSET_FREE_FLOW)]
        elseif isa(subset, typeof(SUBSET_CAR_FOLLOWING))
            passes = subsets_based_on_csvfileset[validfind, symbol(SUBSET_CAR_FOLLOWING)]
        elseif isa(subset, typeof(SUBSET_LANE_CROSSING))
            passes = subsets_based_on_csvfileset[validfind, symbol(SUBSET_LANE_CROSSING)]
        else
            val = get(subset, pdset, sn, carind, validfind)::Float64
            @assert(isapprox(val, 0.0) || isapprox(val, 1.0))
            @assert(isbool(subset))
            passes = bool(val)
        end

        if !passes
            return false
        end
    end
    true
end
function _calc_frames_pass_subsets{F<:AbstractFeature}(
    pdset           :: PrimaryDataset,
    sn              :: StreetNetwork,
    carind          :: Int,
    validfind_start :: Int,
    validfind_end   :: Int,
    subsets         :: Vector{F}
    )

    for validfind in validfind_start : validfind_end
        if !_calc_frame_passes_subsets(pdset, sn, carind, validfind, subsets)
            return false
        end
    end
    true
end
function _calc_frames_pass_subsets{F<:AbstractFeature}(
    pdset           :: PrimaryDataset,
    sn              :: StreetNetwork,
    carind          :: Int,
    validfind_start :: Int,
    validfind_end   :: Int,
    subsets         :: Vector{F},
    subsets_based_on_csvfileset :: DataFrame
    )

    for validfind in validfind_start : validfind_end
        if !_calc_frame_passes_subsets(pdset, sn, carind, validfind, subsets, subsets_based_on_csvfileset)
            return false
        end
    end
    true
end
function _calc_subset_vector(validfind_regions::AbstractVector{Int}, nframes::Int)

    n = length(validfind_regions)
    @assert(mod(n,2) == 0) # ensure even number of regions

    retval = falses(nframes)
    for i = 1 : 2 : n
        validfind_lo = validfind_regions[i]
        validfind_hi = validfind_regions[i+1]

        @assert(validfind_lo ≤ validfind_hi)
        @assert(validfind_lo ≥ 1)
        @assert(validfind_hi ≤ nframes)

        for j = validfind_lo : validfind_hi
            retval[j] = true
        end
    end

    retval
end
function _calc_subsets_based_on_csvfileset(csvfileset::CSVFileSet, nframes::Int)

    df = DataFrame()
    df[symbol(SUBSET_FREE_FLOW)]     = _calc_subset_vector(csvfileset.freeflow, nframes)
    df[symbol(SUBSET_CAR_FOLLOWING)] = _calc_subset_vector(csvfileset.carfollow, nframes)
    df[symbol(SUBSET_LANE_CROSSING)] = _calc_subset_vector([csvfileset.lanechanges_normal,
                                                        csvfileset.lanechanges_postpass,
                                                        csvfileset.lanechanges_arbitrary], nframes)

    df
end
# function pull_start_conditions(
#     extract_params  :: OrigHistobinExtractParameters,
#     pdset          :: PrimaryDataset,
#     sn             :: StreetNetwork;
#     MAX_DIST       :: Float64 = 5000.0, # max_dist used in frenet_distance_between_points() [m]
#     )

#     #=
#     Identify the set of frameinds that are valid starting locations
#     =#

#     start_conditions = StartCondition[]

#     const PDSET_FRAMES_PER_SIM_FRAME = extract_params.pdset_frames_per_sim_frame
#     const SIM_HORIZON = extract_params.sim_horizon
#     const SIM_HISTORY = extract_params.sim_history

#     @assert(SIM_HISTORY ≥ 1)
#     @assert(SIM_HORIZON ≥ 0)

#     const TOLERANCE_D_CL      = extract_params.tol_d_cl
#     const TOLERANCE_YAW       = extract_params.tol_yaw
#     const TOLERANCE_TURNRATE  = extract_params.tol_turnrate
#     const TOLERANCE_SPEED     = extract_params.tol_speed
#     const TOLERANCE_ACCEL     = extract_params.tol_accel
#     const TOLERANCE_D_X_FRONT = extract_params.tol_d_x_front
#     const TOLERANCE_D_Y_FRONT = extract_params.tol_d_y_front
#     const TOLERANCE_D_V_FRONT = extract_params.tol_d_v_front

#     const TARGET_SPEED        = extract_params.target_speed

#     const N_SIM_FRAMES = total_framecount(extract_params)

#     for validfind = SIM_HISTORY : nvalidfinds(pdset)

#         validfind_start = int(jumpframe(pdset, validfind, -(SIM_HISTORY-1) * PDSET_FRAMES_PER_SIM_FRAME))
#         validfind_end   = int(jumpframe(pdset, validfind,   SIM_HORIZON    * PDSET_FRAMES_PER_SIM_FRAME))

#         if are_validfinds_continuous(pdset, validfind_start, validfind_end) &&
#             _calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets)

#             frameind = validfind2frameind(pdset, validfind)

#             posFy  = gete(pdset, :posFy, frameind)::Float64
#             ϕ      = gete(pdset, :posFyaw, frameind)::Float64
#             d_cl   = gete(pdset, :d_cl, frameind)::Float64
#             v_orig = get(SPEED,    pdset, sn, CARIND_EGO, validfind)::Float64
#             ω      = get(TURNRATE, pdset, sn, CARIND_EGO, validfind)::Float64
#             a      = get(ACC,      pdset, sn, CARIND_EGO, validfind)::Float64
#             has_front = bool(get(HAS_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64)
#             d_x_front = get(D_X_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64
#             d_y_front = get(D_Y_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64
#             v_x_front = get(V_X_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64
#             nll    = int(get(N_LANE_L, pdset, sn, CARIND_EGO, validfind)::Float64)
#             nlr    = int(get(N_LANE_R, pdset, sn, CARIND_EGO, validfind)::Float64)

#             if  abs(d_cl) ≤ TOLERANCE_D_CL      &&
#                 abs(ϕ)    ≤ TOLERANCE_YAW       &&
#                 abs(ω)    ≤ TOLERANCE_TURNRATE  &&
#                 abs(a)    ≤ TOLERANCE_ACCEL     &&
#                 abs(v_orig-TARGET_SPEED) ≤ TOLERANCE_SPEED &&
#                 d_x_front ≤ TOLERANCE_D_X_FRONT &&
#                 abs(d_y_front) ≤ TOLERANCE_D_Y_FRONT &&
#                 v_x_front ≤ TOLERANCE_D_V_FRONT #&&
#                 # (nll + nlr) > 0

#                 find_start = validfind2frameind(pdset, validfind_start)
#                 find_end = validfind2frameind(pdset, validfind_end)

#                 posGxA = gete(pdset, :posGx, find_start)
#                 posGyA = gete(pdset, :posGy, find_start)
#                 posGxB = gete(pdset, :posGx, find_end)
#                 posGyB = gete(pdset, :posGy, find_end)

#                 (Δx, Δy) = frenet_distance_between_points(sn, posGxA, posGyA, posGxB, posGyB, MAX_DIST)

#                 # if Δy < -6
#                 #     println("posFy  =  ", posFy)
#                 #     println("ϕ      =  ", ϕ)
#                 #     println("d_cl   =  ", d_cl)
#                 #     println("v_orig =  ", v_orig)
#                 #     println("ω      =  ", ω)
#                 #     println("a      =  ", a)
#                 #     println("has_front ", has_front)
#                 #     println("d_x_front ", d_x_front)
#                 #     println("d_y_front ", d_y_front)
#                 #     println("v_x_front ", v_x_front)
#                 #     println("nll    =  ", nll)
#                 #     println("nlr    =  ", nlr)
#                 # end

#                 if !isnan(Δx)
#                     error("This code needs to be changed")
#                     if extract_params.behavior == "freeflow"
#                         startcon = StartCondition(validfind_start, Int[CARID_EGO])
#                         push!(start_conditions, startcon)
#                     elseif extract_params.behavior == "carfollow"
#                         # need to pull the leading vehicle

#                         @assert(has_front)
#                         carind_front = int(get(INDFRONT, pdset, sn, CARIND_EGO, validfind))
#                         carid_front = carind2id(pdset, carind_front, validfind)
#                         if frames_contain_carid(pdset, carid_front, validfind_start, validfind_end, frameskip=PDSET_FRAMES_PER_SIM_FRAME)
#                             startcon = StartCondition(validfind_start, Int[CARID_EGO, carid_front])
#                             push!(start_conditions, startcon)
#                         end
#                     end
#                 end
#             end
#         end
#     end

#     start_conditions
# end
# function pull_start_conditions(
#     extract_params :: OrigHistobinExtractParameters,
#     csvfileset     :: CSVFileSet,
#     pdset          :: PrimaryDataset,
#     sn             :: StreetNetwork;
#     MAX_DIST       :: Float64 = 5000.0, # max_dist used in frenet_distance_between_points() [m]
#     )

#     #=
#     Identify the set of frameinds that are valid starting locations
#     =#

#     start_conditions = StartCondition[]

#     const PDSET_FRAMES_PER_SIM_FRAME = extract_params.pdset_frames_per_sim_frame
#     const SIM_HORIZON = extract_params.sim_horizon
#     const SIM_HISTORY = extract_params.sim_history

#     @assert(SIM_HISTORY ≥ 1)
#     @assert(SIM_HORIZON ≥ 0)

#     const TOLERANCE_D_CL      = extract_params.tol_d_cl
#     const TOLERANCE_YAW       = extract_params.tol_yaw
#     const TOLERANCE_TURNRATE  = extract_params.tol_turnrate
#     const TOLERANCE_SPEED     = extract_params.tol_speed
#     const TOLERANCE_ACCEL     = extract_params.tol_accel
#     const TOLERANCE_D_X_FRONT = extract_params.tol_d_x_front
#     const TOLERANCE_D_Y_FRONT = extract_params.tol_d_y_front
#     const TOLERANCE_D_V_FRONT = extract_params.tol_d_v_front

#     const TARGET_SPEED        = extract_params.target_speed

#     const N_SIM_FRAMES = total_framecount(extract_params)

#     num_validfinds = nvalidfinds(pdset)

#     df_subsets = _calc_subsets_based_on_csvfileset(csvfileset, num_validfinds)

#     for validfind = SIM_HISTORY : num_validfinds

#         validfind_start = int(jumpframe(pdset, validfind, -(SIM_HISTORY-1) * PDSET_FRAMES_PER_SIM_FRAME))
#         validfind_end   = int(jumpframe(pdset, validfind,   SIM_HORIZON    * PDSET_FRAMES_PER_SIM_FRAME))

#         # println(validfind, "  ",
#         #        int(are_validfinds_continuous(pdset, validfind_start, validfind_end)), "  ",
#         #         int(_calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets, df_subsets)))

#         if are_validfinds_continuous(pdset, validfind_start, validfind_end) &&
#             _calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets, df_subsets)

#             frameind = validfind2frameind(pdset, validfind)

#             posFy  = gete(pdset, :posFy, frameind)::Float64
#             ϕ      = gete(pdset, :posFyaw, frameind)::Float64
#             d_cl   = gete(pdset, :d_cl, frameind)::Float64
#             v_orig = get(SPEED,    pdset, sn, CARIND_EGO, validfind)::Float64
#             ω      = get(TURNRATE, pdset, sn, CARIND_EGO, validfind)::Float64
#             a      = get(ACC,      pdset, sn, CARIND_EGO, validfind)::Float64
#             has_front = bool(get(HAS_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64)
#             d_x_front = get(D_X_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64
#             d_y_front = get(D_Y_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64
#             v_x_front = get(V_X_FRONT, pdset, sn, CARIND_EGO, validfind)::Float64
#             nll    = int(get(N_LANE_L, pdset, sn, CARIND_EGO, validfind)::Float64)
#             nlr    = int(get(N_LANE_R, pdset, sn, CARIND_EGO, validfind)::Float64)

#             # println(frameind)

#             if  abs(d_cl) ≤ TOLERANCE_D_CL      &&
#                 abs(ϕ)    ≤ TOLERANCE_YAW       &&
#                 abs(ω)    ≤ TOLERANCE_TURNRATE  &&
#                 abs(a)    ≤ TOLERANCE_ACCEL     &&
#                 abs(v_orig-TARGET_SPEED) ≤ TOLERANCE_SPEED &&
#                 d_x_front ≤ TOLERANCE_D_X_FRONT &&
#                 abs(d_y_front) ≤ TOLERANCE_D_Y_FRONT &&
#                 v_x_front ≤ TOLERANCE_D_V_FRONT #&&
#                 #(nll + nlr) > 0

#                 find_start = validfind2frameind(pdset, validfind_start)
#                 find_end = validfind2frameind(pdset, validfind_end)

#                 posGxA = gete(pdset, :posGx, find_start)
#                 posGyA = gete(pdset, :posGy, find_start)
#                 posGxB = gete(pdset, :posGx, find_end)
#                 posGyB = gete(pdset, :posGy, find_end)

#                 (Δx, Δy) = frenet_distance_between_points(sn, posGxA, posGyA, posGxB, posGyB, MAX_DIST)

#                 # if Δy < -6
#                 #     println("posFy  =  ", posFy)
#                 #     println("ϕ      =  ", ϕ)
#                 #     println("d_cl   =  ", d_cl)
#                 #     println("v_orig =  ", v_orig)
#                 #     println("ω      =  ", ω)
#                 #     println("a      =  ", a)
#                 #     println("has_front ", has_front)
#                 #     println("d_x_front ", d_x_front)
#                 #     println("d_y_front ", d_y_front)
#                 #     println("v_x_front ", v_x_front)
#                 #     println("nll    =  ", nll)
#                 #     println("nlr    =  ", nlr)
#                 # end

#                 # println(Δx, "  ", Δy)

#                 if !isnan(Δx)

#                     # create a start condition with all of the vehicles
#                     # println("selected")

#                     startcon = StartCondition(validfind_start, Int[CARID_EGO])
#                     for carid in get_carids(pdset)
#                         if carid != CARID_EGO &&
#                            frames_contain_carid(pdset, carid, validfind_start, validfind_end, frameskip=PDSET_FRAMES_PER_SIM_FRAME)

#                             push!(startcon.carids, carid)
#                         end
#                     end
#                     push!(start_conditions, startcon)


#                     # if extract_params.behavior == "freeflow"
#                     #     startcon = StartCondition(validfind_start, Int[CARID_EGO])
#                     #     push!(start_conditions, startcon)
#                     # elseif extract_params.behavior == "carfollow"
#                     #     # need to pull the leading vehicle

#                     #     @assert(has_front)
#                     #     carind_front = int(get(INDFRONT, pdset, sn, CARIND_EGO, validfind))
#                     #     carid_front = carind2id(pdset, carind_front, validfind)
#                     #     if frames_contain_carid(pdset, carid_front, validfind_start, validfind_end, frameskip=PDSET_FRAMES_PER_SIM_FRAME)
#                     #         startcon = StartCondition(validfind_start, Int[CARID_EGO, carid_front])
#                     #         push!(start_conditions, startcon)
#                     #     end
#                     # end
#                 end
#             end
#         end
#     end

#     start_conditions
# end

function _control_input_exists_at_each_point(
    basics::FeatureExtractBasicsPdSet,
    carid::Integer,
    validfind_start::Integer,
    validfind_end::Integer,
    frames_per_sim::Integer,
    )

    for validfind = validfind_start : frames_per_sim : validfind_end

        carind = carid2ind(basics.pdset, carid, validfind)

        afut = get(FUTUREACCELERATION_250MS, basics, carind, validfind)
        if isnan(afut) || isinf(afut)
            return false
        end
        desang = get(FUTUREDESIREDANGLE_250MS, basics, carind, validfind)
        if isnan(desang) || isinf(desang)
            return false
        end
    end
    true
end

function pull_pdset_segments(
    extract_params::OrigHistobinExtractParameters,
    csvfileset::CSVFileSet,
    pdset::PrimaryDataset,
    sn::StreetNetwork,
    pdset_id::Integer,
    streetnet_id::Integer,
    validfinds::Vector{Int};
    max_dist::Float64 = 5000.0, # max_dist used in frenet_distance_between_points() [m]
    basics::FeatureExtractBasicsPdSet = FeatureExtractBasicsPdSet(pdset, sn),
    )

    #=
    Returns pdset_segments::PdsetSegments[],
        where each segment has length 0 -> SIM_HORIZON,
        they do not overlap over 0 : SIM_HORIZON,
        but the history SIM_HISTORY does exist.
    The control input must exist at every frame.

    Various conditions, as given in extract_params, must be true as well.
    =#

    const PDSET_FRAMES_PER_SIM_FRAME = extract_params.pdset_frames_per_sim_frame
    const SIM_HORIZON         = extract_params.sim_horizon
    const SIM_HISTORY         = extract_params.sim_history

    const TARGET_SPEED        = extract_params.target_speed
    const N_SIM_FRAMES        = total_framecount(extract_params)

    @assert(SIM_HISTORY ≥ 1)
    @assert(SIM_HORIZON ≥ 0)

    carid = csvfileset.carid
    pdset_segments = PdsetSegment[]
    num_validfind_indeces = length(validfinds)
    df_subsets = _calc_subsets_based_on_csvfileset(csvfileset, nvalidfinds(pdset))

    validfind_index = 0
    while validfind_index < num_validfind_indeces

        validfind_index += 1

        validfind = validfinds[validfind_index]
        validfind_start = int(jumpframe(pdset, validfind, -(SIM_HISTORY-1) * PDSET_FRAMES_PER_SIM_FRAME))
        validfind_end   = int(jumpframe(pdset, validfind,   SIM_HORIZON    * PDSET_FRAMES_PER_SIM_FRAME))

        # println(validfind_start, "  ", validfind, "  ", validfind_end)
        # println(validfind_start != 0, "  ", validfind_end != 0)
        # println(are_validfinds_continuous(pdset, validfind_start, validfind_end))
        # println(_calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets, df_subsets))

        if validfind_start == 0 || validfind_end == 0
            # println(validfind_index, " failed start or end")
            continue
        end

        # ensure all points are within validfinds
        all_points_are_in_validfinds = true
        vi = 1
        for v in validfind_start : PDSET_FRAMES_PER_SIM_FRAME : validfind_end
            while vi < num_validfind_indeces && validfinds[vi] < v
                vi += 1
            end
            if validfinds[vi] != v
                all_points_are_in_validfinds = false
                break
            end
        end

        # if !all_points_are_in_validfinds
        #     println(validfind_index, " failed all_points_are_in_validfinds")
        # end
        # if !are_validfinds_continuous(pdset, validfind_start, validfind_end)
        #     println(validfind_index, " failed are_validfinds_continuous")
        # end
        # if !_calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets, df_subsets)
        #     println(validfind_index, " failed _calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets, df_subsets)")
        # end

        if all_points_are_in_validfinds &&
           are_validfinds_continuous(pdset, validfind_start, validfind_end) &&
           _calc_frames_pass_subsets(pdset, sn, CARIND_EGO, validfind, validfind_end, extract_params.subsets, df_subsets)

            carind = carid2ind(pdset, carid, validfind)
            posFy     =      get(pdset, :posFy,   carind, validfind)::Float64
            ϕ         =      get(pdset, :posFyaw, carind, validfind)::Float64
            d_cl      =      get(pdset, :d_cl,    carind, validfind)::Float64
            v_orig    =      get(SPEED,     basics, carind, validfind)::Float64
            ω         =      get(TURNRATE,  basics, carind, validfind)::Float64
            a         =      get(ACC,       basics, carind, validfind)::Float64
            has_front = bool(get(HAS_FRONT, basics, carind, validfind)::Float64)
            d_x_front =      get(D_X_FRONT, basics, carind, validfind)::Float64
            d_y_front =      get(D_Y_FRONT, basics, carind, validfind)::Float64
            v_x_front =      get(V_X_FRONT, basics, carind, validfind)::Float64
            nll       =  int(get(N_LANE_L,  basics, carind, validfind)::Float64)
            nlr       =  int(get(N_LANE_R,  basics, carind, validfind)::Float64)

            if  abs(d_cl)                ≤ extract_params.tol_d_cl &&
                abs(ϕ)                   ≤ extract_params.tol_yaw &&
                abs(ω)                   ≤ extract_params.tol_turnrate &&
                abs(a)                   ≤ extract_params.tol_accel &&
                abs(v_orig-TARGET_SPEED) ≤ extract_params.tol_speed &&
                d_x_front                ≤ extract_params.tol_d_x_front &&
                abs(d_y_front)           ≤ extract_params.tol_d_y_front &&
                v_x_front                ≤ extract_params.tol_d_v_front #&&
                #(nll + nlr) > 0

                carind_start = carid2ind(pdset, carid, validfind_start)
                carind_end = carid2ind(pdset, carid, validfind_end)
                posGxA = get(pdset, :posGx, carind_start, validfind_start)
                posGyA = get(pdset, :posGy, carind_start, validfind_start)
                posGxB = get(pdset, :posGx, carind_end, validfind_end)
                posGyB = get(pdset, :posGy, carind_end, validfind_end)

                # NOTE(tim): may be NAN if we cross from a lane that terminates into a new lane that doesn't
                #            In this case we cannot compute the frenet (Δx, Δy) unless we do something special
                #            like extrapolate the missing lane (which is iffy)
                (Δx, Δy) = frenet_distance_between_points(sn, posGxA, posGyA, posGxB, posGyB, max_dist)

                # if isnan(Δx)
                    # @printf("posA: %15.6f, %15.6f\n", posGxA, posGyA)
                    # @printf("posB: %15.6f, %15.6f\n", posGxB, posGyB)
                    # println("proj: ", project_point_to_streetmap(posGxA, posGyA, sn))
                    # println("proj: ", project_point_to_streetmap(posGxB, posGyB, sn))
                # end

                if !isnan(Δx)
                    push!(pdset_segments, PdsetSegment(pdset_id, streetnet_id, carid, validfind, validfind_end))
                    validfind_next = validfind_end + max(extract_params.frameskip_between_extracted_scenes * PDSET_FRAMES_PER_SIM_FRAME - 1, 0)
                    while validfind_index < num_validfind_indeces && validfinds[validfind_index] < validfind_next
                        validfind_index += 1
                    end
                end
            end
        end
    end

    # println(pdset_segments)

    pdset_segments
end

function is_strictly_monotonically_increasing(vec::AbstractVector{Int})
    if isempty(vec)
        return true
    end

    val = vec[1]
    for i = 2 : length(vec)
        val2 = vec[i]
        if val2 ≤ val
            return false
        end
        val = val2
    end
    true
end
function merge_region_segments(vec::AbstractVector{Int})

    #=
    sorts a set of region segments to be in monotonically increasing order
    will also merge them as necessary if they overlap
    =#

    if isempty(vec)
        return Int[]
    end

    n = length(vec)
    @assert(mod(n,2) == 0)

    validfind_min, validfind_max = extrema(vec)

    validfinds = falses(validfind_max-validfind_min+1)
    for i = 1 : div(n,2)
        validfind_lo = vec[2i-1]-validfind_min+1
        validfind_hi = vec[2i]-validfind_min+1
        for j = validfind_lo : validfind_hi
            validfinds[j] = true
        end
    end

    retval = Int[]
    validfind_lo = findfirst(validfinds)
    while validfind_lo != 0
        validfind_hi = findnext(val->!val, validfinds, validfind_lo+1)
        if validfind_hi == 0
            validfind_hi = length(validfinds)
        end
        push!(retval, validfind_lo+validfind_min-1)
        push!(retval, validfind_hi+validfind_min-1)

        validfind_lo = findnext(validfinds, validfind_hi+1)
    end

    retval
end
function calc_row_count_from_region_segments(validfind_regions::AbstractVector{Int})

    #=
    Computes the number of frames encoded in validfind_regions

    validfind_regions is an array in which subsequent value pairs correspond to continuous frames
    containing a particular behavior.
    validfind_regions should be strictly monotonically increasing

    ex: [1,4,8,10] means 1→4 and 8→10 are continuous frames
    =#

    n = length(validfind_regions)
    if n == 0
        return 0
    end

    if !is_strictly_monotonically_increasing(validfind_regions)
        println("not strincy increasing: ", validfind_regions)
    end

    @assert(mod(n, 2) == 0) # must be an even number
    @assert(is_strictly_monotonically_increasing(validfind_regions))

    estimated_row_count = 0
    index_lo = 1
    while index_lo < length(validfind_regions)
        estimated_row_count += validfind_regions[index_lo+1] - validfind_regions[index_lo] + 1
        index_lo += 2
    end
    estimated_row_count
end

function pull_pdset_segments_and_dataframe(
    extract_params  :: OrigHistobinExtractParameters,
    csvfileset      :: CSVFileSet,
    pdset           :: PrimaryDataset,
    sn              :: StreetNetwork,
    pdset_id        :: Integer,
    streetnet_id    :: Integer,
    features::Vector{AbstractFeature},
    filters::Vector{AbstractFeature};
    pdset_frames_per_sim_frame::Int=N_FRAMES_PER_SIM_FRAME
    )

    basics = FeatureExtractBasicsPdSet(pdset, sn)

    ########################################################################################################
    # pull all of the validfinds that pass the filters
    validfinds = filter(validfind->!does_violate_filter(filters, basics, carid2ind(pdset, csvfileset.carid, validfind), validfind), 1 : nvalidfinds(pdset))

    ########################################################################################################
    # pull all of the pdset_segments that lie within validfinds
    pdset_segments = pull_pdset_segments(extract_params, csvfileset, pdset, sn,
                                         pdset_id, streetnet_id, validfinds,
                                         basics=basics)

    ########################################################################################################
    # now only extract feature frames for each pdset_segment, at intervals of pdset_frames_per_sim_frame
    # and valid frames spaced by pdset_frames_per_sim_frame

    # 0 -> do not use
    # 1 -> is potentially valid
    # 2 -> extracted me
    sample_from_frame = zeros(Int, nvalidfinds(pdset))

    # mark all validfind frames as potentially valid
    for validfind in validfinds
        sample_from_frame[validfind] = 1
    end

    # mark all frames from segments for extraction
    for seg in pdset_segments

        for Δ in seg.validfind_end+1 : seg.validfind_end+pdset_frames_per_sim_frame-1
            sample_from_frame[Δ] = 0 # forward buffer not extracted
        end
        for Δ in seg.validfind_start-1 : -1 : seg.validfind_start-pdset_frames_per_sim_frame+1
            sample_from_frame[Δ] = 0 # backward buffer not extracted
        end

        for validfind in seg.validfind_start : pdset_frames_per_sim_frame : seg.validfind_end
            @assert(sample_from_frame[validfind]==1)
            sample_from_frame[validfind] = 2
            for Δ in 1 : pdset_frames_per_sim_frame-1
                sample_from_frame[validfind+Δ] = 0 # in-between ones should not be used
            end
        end
    end

    # mark all remaining potential frames as extractable with buffer in-between
    for validfind in 1 : length(sample_from_frame)
        if sample_from_frame[validfind] == 1
            sample_from_frame[validfind] = 2 # extract it
            for Δ in 1 : pdset_frames_per_sim_frame-1
                sample_from_frame[validfind+Δ] = 0 # in-between ones should not be used
            end
        end
    end

    validfinds_to_extract = find(sample_from_frame)

    ########################################################################################################
    # extract dataframe on those frames

    dataframe = gen_featureset_from_validfinds(csvfileset.carid, basics, validfinds_to_extract, features, filters)

    ########################################################################################################
    # reconstruct startframes


    startframes = Array(Int, length(pdset_segments))
    startframe = 1
    for (i,seg) in enumerate(pdset_segments)
        while validfinds_to_extract[startframe] != seg.validfind_start
            startframe += 1
        end
        startframes[i] = startframe
    end

    # println("nvalidfinds: ", nvalidfinds(pdset))
    # println("pdset_segments: ", pdset_segments)
    # println("startframes: ", startframes)
    # println("dataframe:", dataframe)

    (pdset_segments, dataframe, startframes)
end
function _pull_model_training_data(
    extract_params::OrigHistobinExtractParameters,
    csvfilesets::Vector{CSVFileSet},
    features::Vector{AbstractFeature},
    filters::Vector{AbstractFeature},
    pdset_dir::String,
    streetmap_base::String,
    )

    streetnet_cache = (String, StreetNetwork)[]

    pdset_filepaths = String[]
    pdset_segments = PdsetSegment[]
    dataframe = create_dataframe_with_feature_columns(features, 0)
    startframes = Int[]

    for csvfileset in csvfilesets

        # tic()

        csvfile = csvfileset.csvfile
        streetmapbasename = csvfileset.streetmapbasename

        if streetmapbasename == "skip"
            continue
        end

        pdset = _load_pdset(csvfile, pdset_dir)
        push!(pdset_filepaths, _get_pdsetfile(csvfile, pdset_dir))
        pdset_id = length(pdset_filepaths)


        streetnet_id = findfirst(tup->tup[1]==streetmapbasename, streetnet_cache)
        if streetnet_id == 0
            streetnet = load(joinpath(streetmap_base, "streetmap_"*streetmapbasename*".jld"))["streetmap"]
            push!(streetnet_cache, (streetmapbasename, streetnet))
            streetnet_id = length(streetnet_cache)
        end
        sn = streetnet_cache[streetnet_id][2]


        # println(csvfile)

        more_pdset_segments, more_dataframe, more_startframes = pull_pdset_segments_and_dataframe(
                                                                    extract_params, csvfileset, pdset, sn,
                                                                    pdset_id, streetnet_id,
                                                                    features, filters)

        more_startframes .+= nrow(dataframe)

        append!(pdset_segments, more_pdset_segments)
        append!(dataframe, more_dataframe)
        append!(startframes, more_startframes)

        # toc()
    end

    streetnet_filepaths = Array(String, length(streetnet_cache))
    for streetnet_id = 1 : length(streetnet_cache)
        streetnet_filepaths[streetnet_id] = streetmap_base*streetnet_cache[streetnet_id][1]*".jld"
    end

     ModelTrainingData(pdset_filepaths, streetnet_filepaths, pdset_segments, dataframe, startframes)
end
function _pull_model_training_data_parallel(
    extract_params::OrigHistobinExtractParameters,
    csvfilesets::Vector{CSVFileSet},
    features::Vector{AbstractFeature},
    filters::Vector{AbstractFeature},
    pdset_dir::String,
    streetmap_base::String,
    )

    num_csvfilesets = length(csvfilesets)
    num_workers = nworkers()
    csvfileset_assignment = Array(Vector{CSVFileSet}, num_workers)
    for i = 1 : num_workers
        csvfileset_assignment[i] = CSVFileSet[]
    end

    worker = 0
    for csvfileset in csvfilesets

        worker += 1
        if worker > num_workers
            worker = 1
        end

        push!(csvfileset_assignment[worker], csvfileset)
    end

    # TODO(tim): fix this
    more_stuff = pmap(assigned_csvfilesets->_pull_pdsets_streetnets_segments_and_dataframe(
                                                extract_params, assigned_csvfilesets,
                                                features, filters, pdset_dir, streetmap_base
                                            ), csvfileset_assignment)

    pdset_filepaths = Array(String, num_csvfilesets)
    streetnet_filepaths = String[]
    pdset_segments = PdsetSegment[]
    dataframe = create_dataframe_with_feature_columns(features, 0)
    startframes = Int[]

    pdset_index = 0
    for (more_pdsets, more_streetnets, more_pdset_segments, more_dataframe, more_startframes) in more_stuff

        more_startframes .+= nrow(dataframe)

        for (i,seg) in enumerate(more_pdset_segments)
            target_streetnet = more_streetnets[seg.streetnet_id]

            streetnet_id = findfirst(streetnet_filepaths, target_streetnet)
            if streetnet_id == 0
                push!(streetnet_filepaths, target_streetnet)
                streetnet_id = length(streetnet_filepaths)
            end

            push!(pdset_segments, PdsetSegment(seg.pdset_id, streetnet_id, seg.carid,
                                  seg.validfind_start, seg.validfind_end))
        end

        for pdset in more_pdsets
            pdset_index += 1
            pdset_filepaths[pdset_index] = pdset
        end

        append!(dataframe, more_dataframe)
        append!(startframes, more_startframes)
    end

    return ModelTrainingData(pdset_filepaths, streetnet_filepaths, pdset_segments, dataframe, startframes)
end
function pull_model_training_data(
    extract_params::OrigHistobinExtractParameters,
    csvfilesets::Vector{CSVFileSet};
    features::Vector{AbstractFeature}=FEATURES,
    filters::Vector{AbstractFeature}=AbstractFeature[],
    pdset_dir::String=PRIMARYDATA_DIR,
    streetmap_base::String="/media/tim/DATAPART1/Data/Bosch/processed/streetmaps/"
    )

    if nworkers() > 1
        _pull_model_training_data_parallel(extract_params, csvfilesets,
                                           features, filters, pdset_dir, streetmap_base)
    else
        _pull_model_training_data(extract_params, csvfilesets,
                                           features, filters, pdset_dir, streetmap_base)
    end
end

function get_cross_validation_fold_assignment(
    nfolds::Int,
    dset::ModelTrainingData,
    )

    #=
    Want: to split the dataframe into k disjoint training sets of nearly the same size
          and simultaneously split the pdset_segments into k disjoint sets of nearly the same size

    Assumptions
    - pdset_segments are all of the same history and horizon
    - pdset_segments do not overlap

    1) randomly divide pdset_segments into k roughly equally-sized groups
    2) for each group, identify the corresponding frames
    3) assign those frames to each training set
    4) divide the remaining training frames among the training sets
    =#

    pdset_segments = dset.pdset_segments
    dataframe = dset.dataframe
    seg_to_framestart = dset.startframes

    nframes = nrow(dataframe)
    npdsetsegments = length(pdset_segments)

    @assert(length(seg_to_framestart) ≥ npdsetsegments)

    npdsetsegments_per_fold = div(npdsetsegments, nfolds)
    nfolds_with_extra_pdsetsegment = mod(npdsetsegments, nfolds)

    # println("nframes: ", nframes)
    # println("npdsetsegments: ", npdsetsegments)
    # println("npdsetsegments_per_fold: ", npdsetsegments_per_fold)
    # println("nfolds_with_extra_pdsetsegment: ", nfolds_with_extra_pdsetsegment)

    frame_fold_assignment = zeros(Int, nframes)
    pdsetsegment_fold_assignment = zeros(Int, npdsetsegments)

    p = randperm(npdsetsegments)
    permind = 0
    for f = 1 : nfolds
        # println(pdsetsegment_fold_assignment)
        npdsetsegments_in_fold = npdsetsegments_per_fold + (f ≤ nfolds_with_extra_pdsetsegment ? 1 : 0)
        for i = 1 : npdsetsegments_in_fold
            permind += 1

            pdsetsegmentind = p[permind]
            pdsetsegment_fold_assignment[pdsetsegmentind] = f

            framestart = seg_to_framestart[pdsetsegmentind]
            frameend = framestart + get_horizon(pdset_segments[pdsetsegmentind])
            # println(framestart,  "  ", frameend)
            frameind = framestart
            for _ in framestart : 5 : frameend
                @assert(frame_fold_assignment[frameind] == 0)
                frame_fold_assignment[frameind] = f
                frameind += 1
            end
        end
    end

    frame_fold_sizes = zeros(Int, nfolds)
    nremaining_frames = 0
    for frameind in 1 : nframes
        if frame_fold_assignment[frameind] == 0
            nremaining_frames += 1
        else
            frame_fold_sizes[frame_fold_assignment[frameind]] += 1
        end
    end

    # println("nremaining_frames: ", nremaining_frames)
    # println("frame_fold_sizes (before): ", frame_fold_sizes)

    fold_priority = PriorityQueue{Int, Int}() # (fold, foldsize), min-ordered
    for (fold,foldsize) in enumerate(frame_fold_sizes)
        fold_priority[fold] = foldsize
    end

    remaining_frames = Array(Int, nremaining_frames)
    rem_frame_count = 0
    for frameind in 1 : nframes
        if frame_fold_assignment[frameind] == 0
            remaining_frames[rem_frame_count+=1] = frameind
        end
    end

    p = randperm(nremaining_frames)
    for rem_frame_ind in 1 : nremaining_frames
        fold = dequeue!(fold_priority)
        frame_fold_assignment[remaining_frames[p[rem_frame_ind]]] = fold
        frame_fold_sizes[fold] += 1
        fold_priority[fold] = frame_fold_sizes[fold]
    end

    # println("frame_fold_sizes (after): ", frame_fold_sizes)

    FoldAssignment(frame_fold_assignment, pdsetsegment_fold_assignment, nfolds)
end
function get_cross_validation_fold_assignment(
    nfolds::Int,
    dset::ModelTrainingData,
    train_test_split::FoldAssignment,
    )

    #=
    Want: to split the dataframe into k disjoint training sets of nearly the same size
          and simultaneously split the pdset_segments into k disjoint sets of nearly the same size

    Assumptions
    - pdset_segments are all of the same history and horizon
    - pdset_segments do not overlap

    1) randomly divide pdset_segments into k roughly equally-sized groups
    2) for each group, identify the corresponding frames
    3) assign those frames to each training set
    4) divide the remaining training frames among the training sets
    =#

    pdset_segments = dset.pdset_segments
    dataframe = dset.dataframe
    seg_to_framestart = dset.startframes

    frame_tv_assignment = train_test_split.frame_assignment
    pdsetseg_tv_assignment = train_test_split.pdsetseg_assignment

    nframes = nrow(dataframe)
    npdsetsegments = length(pdset_segments)

    nframes_assigned_to_training = 0
    for v in frame_tv_assignment
        if v == FOLD_TRAIN
            nframes_assigned_to_training += 1
        end
    end

    npdsetsegments_assigned_to_training = 0
    for v in pdsetseg_tv_assignment
        if v == FOLD_TRAIN
            npdsetsegments_assigned_to_training += 1
        end
    end

    indeces_of_train_frames = Array(Int, nframes_assigned_to_training)
    ind = 1
    for (i,v) in enumerate(frame_tv_assignment)
        if v == FOLD_TRAIN
            indeces_of_train_frames[ind] = i
            ind += 1
        end
    end

    indeces_of_train_pdsetsegs = Array(Int, npdsetsegments_assigned_to_training)
    ind = 1
    for (i,v) in enumerate(pdsetseg_tv_assignment)
        if v == FOLD_TRAIN
            indeces_of_train_pdsetsegs[ind] = i
            ind += 1
        end
    end

    @assert(length(seg_to_framestart) ≥ npdsetsegments)

    npdsetsegments_per_fold = div(npdsetsegments_assigned_to_training, nfolds)
    nfolds_with_extra_pdsetsegment = mod(npdsetsegments_assigned_to_training, nfolds)

    # println("nframes: ", nframes)
    # println("npdsetsegments: ", npdsetsegments)
    # println("npdsetsegments_per_fold: ", npdsetsegments_per_fold)
    # println("nfolds_with_extra_pdsetsegment: ", nfolds_with_extra_pdsetsegment)

    # NOTE(tim): will only set frames and segs that are marked TRAIN
    frame_fold_assignment = zeros(Int, nframes)
    pdsetsegment_fold_assignment = zeros(Int, npdsetsegments)

    p = randperm(npdsetsegments_assigned_to_training)
    permind = 0
    for f = 1 : nfolds
        # println(pdsetsegment_fold_assignment)
        npdsetsegments_in_fold = npdsetsegments_per_fold + (f ≤ nfolds_with_extra_pdsetsegment ? 1 : 0)
        for i = 1 : npdsetsegments_in_fold
            permind += 1

            pdsetsegmentind = indeces_of_train_pdsetsegs[p[permind]]
            pdsetsegment_fold_assignment[pdsetsegmentind] = f

            framestart = seg_to_framestart[pdsetsegmentind]
            frameend = framestart + get_horizon(pdset_segments[pdsetsegmentind])
            frameind = framestart

            for _ in framestart : 5 : frameend
                @assert(frame_fold_assignment[frameind] == 0)
                frame_fold_assignment[frameind] = f
                frameind += 1
            end
        end
    end

    frame_fold_sizes = zeros(Int, nfolds)
    nremaining_frames = 0
    for frameind in 1 : nframes_assigned_to_training
        if frame_fold_assignment[indeces_of_train_frames[frameind]] == 0
            nremaining_frames += 1
        else
            frame_fold_sizes[frame_fold_assignment[indeces_of_train_frames[frameind]]] += 1
        end
    end

    # println("nremaining_frames: ", nremaining_frames)
    # println("frame_fold_sizes (before): ", frame_fold_sizes)

    fold_priority = PriorityQueue{Int, Int}() # (fold, foldsize), min-ordered
    for (fold,foldsize) in enumerate(frame_fold_sizes)
        fold_priority[fold] = foldsize
    end

    remaining_frames = Array(Int, nremaining_frames)
    rem_frame_count = 0
    for frameind in 1 : nframes_assigned_to_training
        if frame_fold_assignment[indeces_of_train_frames[frameind]] == 0
            remaining_frames[rem_frame_count+=1] = indeces_of_train_frames[frameind]
        end
    end

    p = randperm(nremaining_frames)
    for rem_frame_ind in 1 : nremaining_frames
        fold = dequeue!(fold_priority)
        frame_fold_assignment[remaining_frames[p[rem_frame_ind]]] = fold
        frame_fold_sizes[fold] += 1
        fold_priority[fold] = frame_fold_sizes[fold]
    end

    # println("frame_fold_sizes (after): ", frame_fold_sizes)

    FoldAssignment(frame_fold_assignment, pdsetsegment_fold_assignment, nfolds)
end
function get_train_test_fold_assignment(
    fraction_validation::Float64,
    dset::ModelTrainingData,
    )

    #=
    returns a FoldAssignment with two folds: 1 for train, 2 for test
    =#

    pdset_segments = dset.pdset_segments
    dataframe = dset.dataframe
    seg_to_framestart = dset.startframes

    @assert(fraction_validation ≥ 0.0)
    frac_train = 1.0 - fraction_validation

    nframes = nrow(dataframe)
    npdsetsegments = length(pdset_segments)
    @assert(length(seg_to_framestart) ≥ npdsetsegments)

    frame_tv_assignment = zeros(Int, nframes) # train = 1, validation = 2
    pdsetseg_tv_assignment = zeros(Int, npdsetsegments) # train = 1, validation = 2

    nframes_to_assign_to_training = ifloor(nframes * frac_train)
    npdsetsegments_to_assign_to_training = ifloor(npdsetsegments * frac_train)

    p = randperm(npdsetsegments)
    for i = 1 : npdsetsegments_to_assign_to_training
        pdsetsegmentind = p[i]
        pdsetseg_tv_assignment[pdsetsegmentind] = FOLD_TRAIN

        framestart = seg_to_framestart[pdsetsegmentind]
        frameend = framestart + get_horizon(pdset_segments[pdsetsegmentind])
        frameind = framestart
        for _ in framestart : 5 : frameend
            @assert(frame_tv_assignment[frameind] == 0)
            frame_tv_assignment[frameind] = FOLD_TRAIN
            frameind += 1
        end
    end

     # = sum(frame_tv_assignment)
    nremaining_frames_unassigned = 0
    for frameind in 1 : nframes
        if frame_tv_assignment[frameind] == 0
            nremaining_frames_unassigned += 1
        end
    end

    nframes_assigned_to_training = nframes - nremaining_frames_unassigned
    nremaining_frames_to_assign = nframes_to_assign_to_training - nframes_assigned_to_training

    # println("nframes:                      ", nframes)
    # println("nframes_assigned_to_training: ", nframes_assigned_to_training)
    # println("nremaining_frames_to_assign:  ", nremaining_frames_to_assign)
    # println("nremaining_frames_unassigned: ", nremaining_frames_unassigned)

    remaining_frames = Array(Int, nremaining_frames_unassigned)
    rem_frame_count = 0
    for frameind in 1 : nframes
        if frame_tv_assignment[frameind] == 0
            remaining_frames[rem_frame_count+=1] = frameind
        end
    end
    @assert(rem_frame_count == nremaining_frames_unassigned)

    p = randperm(nremaining_frames_unassigned)
    for rem_frame_ind in 1 : nremaining_frames_to_assign
        i = p[rem_frame_ind]
        j = remaining_frames[i]
        k = frame_tv_assignment[remaining_frames[p[rem_frame_ind]]]
        frame_tv_assignment[remaining_frames[p[rem_frame_ind]]] = FOLD_TRAIN
    end

    for (i,v) in enumerate(frame_tv_assignment)
        if v != FOLD_TRAIN
          frame_tv_assignment[i] = FOLD_TEST
        end
    end
    for (i,v) in enumerate(pdsetseg_tv_assignment)
        if v != FOLD_TRAIN
          pdsetseg_tv_assignment[i] = FOLD_TEST
        end
    end

    FoldAssignment(frame_tv_assignment, pdsetseg_tv_assignment, 2)
end

function load_pdsets(dset::ModelTrainingData)
    pdsets = Array(PrimaryDataset, length(dset.pdset_filepaths))
    for (i,pdset_filepath) in enumerate(dset.pdset_filepaths)
        pdsets[i] = load(pdset_filepath, "pdset")
    end
    pdsets
end
function load_streetnets(dset::ModelTrainingData)
    streetnets = Array(StreetNetwork, length(dset.streetnet_filepaths))
    for (i,streetnet_filepath) in enumerate(dset.streetnet_filepaths)
        streetnets[i] = load(streetnet_filepath, "streetmap")
    end
    streetnets
end



end # end module