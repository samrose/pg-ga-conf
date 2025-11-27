# Sobol Sensitivity Analysis for PostgreSQL Configuration Tuning
# Uses Saltelli's extension for variance-based global sensitivity analysis

using Sobol
using GlobalSensitivity
using Distributions
using Statistics
using JSON

"""
Generate Sobol samples for sensitivity analysis.

Arguments:
- knobs: Dict mapping knob name to [min, max] bounds
- n_samples: Number of base samples (total will be N * (D + 2))

Returns:
- samples: Array of configuration dictionaries
- matrices: Dict with A, B matrices for later analysis
"""
function generate_sobol_samples(knobs::Dict, n_samples::Int)
    knob_names = collect(keys(knobs))
    n_dims = length(knob_names)

    # Generate Sobol sequence
    seq = SobolSeq(n_dims * 2)  # Need 2*D dimensions for A and B matrices

    # Skip initial points for better uniformity
    skip(seq, n_samples)

    # Generate base samples
    raw_samples = zeros(n_samples, n_dims * 2)
    for i in 1:n_samples
        raw_samples[i, :] = next!(seq)
    end

    # Split into A and B matrices
    A = raw_samples[:, 1:n_dims]
    B = raw_samples[:, (n_dims+1):end]

    # Generate AB matrices (for total-order indices)
    AB_matrices = Dict{String, Matrix{Float64}}()
    for (j, name) in enumerate(knob_names)
        AB = copy(A)
        AB[:, j] = B[:, j]
        AB_matrices[name] = AB
    end

    # Transform samples to actual knob ranges
    function transform_sample(unit_sample::Vector{Float64})
        config = Dict{String, Any}()
        for (j, name) in enumerate(knob_names)
            bounds = knobs[name]
            min_val, max_val = bounds[1], bounds[2]
            # Linear transform from [0,1] to [min, max]
            config[name] = min_val + unit_sample[j] * (max_val - min_val)
        end
        return config
    end

    # Create sample configurations
    samples = Vector{Dict{String, Any}}()

    # A matrix samples
    for i in 1:n_samples
        push!(samples, transform_sample(A[i, :]))
    end

    # B matrix samples
    for i in 1:n_samples
        push!(samples, transform_sample(B[i, :]))
    end

    # AB matrix samples (for each dimension)
    for name in knob_names
        AB = AB_matrices[name]
        for i in 1:n_samples
            push!(samples, transform_sample(AB[i, :]))
        end
    end

    matrices = Dict(
        "A" => A,
        "B" => B,
        "AB" => AB_matrices,
        "n_samples" => n_samples,
        "n_dims" => n_dims,
        "knob_names" => knob_names
    )

    return samples, matrices
end

"""
Compute Sobol sensitivity indices using Saltelli estimators.

Arguments:
- results: Vector of benchmark scores (length = N * (D + 2))
- matrices: Dict from generate_sobol_samples
- knobs: Dict mapping knob name to bounds

Returns:
- Dict with first_order, total_order indices, and ranking
"""
function compute_sensitivity_indices(results::Vector{Float64}, matrices::Dict, knobs::Dict)
    N = matrices["n_samples"]
    D = matrices["n_dims"]
    knob_names = matrices["knob_names"]

    # Expected number of results
    expected = N * (D + 2)
    if length(results) != expected
        error("Expected $expected results, got $(length(results))")
    end

    # Split results into A, B, and AB sections
    Y_A = results[1:N]
    Y_B = results[(N+1):(2*N)]

    # Y_AB for each dimension
    Y_AB = Dict{String, Vector{Float64}}()
    offset = 2 * N
    for (j, name) in enumerate(knob_names)
        Y_AB[name] = results[(offset + (j-1)*N + 1):(offset + j*N)]
    end

    # Compute variance
    f0_sq = mean(Y_A) * mean(Y_B)
    var_Y = var(vcat(Y_A, Y_B))

    if var_Y ≈ 0
        # No variance - all indices are 0
        first_order = Dict(name => 0.0 for name in knob_names)
        total_order = Dict(name => 0.0 for name in knob_names)
    else
        first_order = Dict{String, Float64}()
        total_order = Dict{String, Float64}()

        for name in knob_names
            # First-order index (Saltelli 2010)
            # S_i = (1/N) * sum(Y_B .* (Y_AB_i - Y_A)) / Var(Y)
            V_i = mean(Y_B .* (Y_AB[name] .- Y_A))
            first_order[name] = V_i / var_Y

            # Total-order index (Jansen 1999)
            # S_Ti = (1/2N) * sum((Y_A - Y_AB_i).^2) / Var(Y)
            V_Ti = 0.5 * mean((Y_A .- Y_AB[name]).^2)
            total_order[name] = V_Ti / var_Y
        end
    end

    # Rank by total-order index (most important first)
    ranking = sort(collect(total_order), by=x->x[2], rev=true)
    ranking_list = [Dict("knob" => k, "total_order" => v, "first_order" => first_order[k])
                    for (k, v) in ranking]

    return Dict(
        "first_order" => first_order,
        "total_order" => total_order,
        "ranking" => ranking_list,
        "variance" => var_Y
    )
end

"""
Get the top N most sensitive knobs.
"""
function get_top_knobs(analysis::Dict, n::Int)
    ranking = analysis["ranking"]
    top_n = min(n, length(ranking))
    return [r["knob"] for r in ranking[1:top_n]]
end
