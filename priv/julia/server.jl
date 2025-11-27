#!/usr/bin/env julia
# Julia JSON Server for Sobol Sensitivity Analysis
# Communicates via stdin/stdout (local mode) or TCP (production mode)

using JSON
using Sockets

include("sensitivity.jl")

# Global state for storing matrices between sample generation and analysis
const MATRICES_CACHE = Dict{Int, Dict}()
const CACHE_LOCK = ReentrantLock()

"""
Process a single request and return response.
"""
function process_request(request)
    request_id = get(request, "id", 0)
    request_type = get(request, "type", "")
    payload = get(request, "payload", Dict())

    try
        result = if request_type == "sobol_sample"
            handle_sobol_sample(request_id, payload)
        elseif request_type == "generate_sobol"
            handle_generate_sobol(request_id, payload)
        elseif request_type == "compute_sensitivity"
            handle_compute_sensitivity(request_id, payload)
        elseif request_type == "analyze"
            handle_analyze(request_id, payload)
        elseif request_type == "ping"
            Dict("status" => "ok")
        else
            Dict("error" => "Unknown request type: $request_type")
        end

        return Dict(
            "id" => request_id,
            "type" => "response",
            "data" => result
        )
    catch e
        return Dict(
            "id" => request_id,
            "type" => "error",
            "message" => sprint(showerror, e)
        )
    end
end

"""
Handle sobol_sample request - generate Sobol samples.
"""
function handle_sobol_sample(request_id::Int, payload)
    knobs = payload["knobs"]
    n_samples = get(payload, "n", 128)

    # Convert knobs to proper format
    knobs_dict = Dict{String, Vector{Float64}}()
    for (name, bounds) in knobs
        knobs_dict[string(name)] = Float64[bounds[1], bounds[2]]
    end

    samples, matrices = generate_sobol_samples(knobs_dict, n_samples)

    # Cache matrices for later analysis
    lock(CACHE_LOCK) do
        MATRICES_CACHE[request_id] = matrices
    end

    return Dict(
        "samples" => samples,
        "total_samples" => length(samples),
        "cache_id" => request_id
    )
end

"""
Handle generate_sobol request - generate Sobol samples with matrices for sensitivity analysis.
"""
function handle_generate_sobol(request_id::Int, payload)
    knobs = payload["knobs"]
    n_samples = get(payload, "n", 128)

    # Convert knobs to proper format
    knobs_dict = Dict{String, Vector{Float64}}()
    for (name, def) in knobs
        # Handle both formats: [min, max] or {"type": ..., "min": ..., "max": ...}
        if isa(def, AbstractVector)
            knobs_dict[string(name)] = Float64[def[1], def[2]]
        elseif isa(def, AbstractDict)
            knobs_dict[string(name)] = Float64[def["min"], def["max"]]
        end
    end

    samples, matrices = generate_sobol_samples(knobs_dict, n_samples)

    # Convert matrices to JSON-serializable format
    matrices_json = Dict{String, Any}(
        "A" => [collect(row) for row in eachrow(matrices["A"])],
        "B" => [collect(row) for row in eachrow(matrices["B"])],
        "AB" => Dict(k => [collect(row) for row in eachrow(v)] for (k, v) in matrices["AB"]),
        "n_samples" => matrices["n_samples"],
        "n_dims" => matrices["n_dims"],
        "knob_names" => matrices["knob_names"]
    )

    # Cache matrices for later analysis
    lock(CACHE_LOCK) do
        MATRICES_CACHE[request_id] = matrices
    end

    return Dict(
        "samples" => samples,
        "matrices" => matrices_json,
        "total_samples" => length(samples),
        "cache_id" => request_id
    )
end

"""
Handle compute_sensitivity request - compute sensitivity indices from results.
"""
function handle_compute_sensitivity(request_id::Int, payload)
    results = Float64.(payload["results"])
    matrices_json = payload["matrices"]
    knobs = payload["knobs"]

    # Reconstruct matrices from JSON
    n_samples = matrices_json["n_samples"]
    n_dims = matrices_json["n_dims"]
    knob_names = matrices_json["knob_names"]

    A = Matrix{Float64}(hcat([Float64.(row) for row in matrices_json["A"]]...)')
    B = Matrix{Float64}(hcat([Float64.(row) for row in matrices_json["B"]]...)')
    AB = Dict{String, Matrix{Float64}}(
        k => Matrix{Float64}(hcat([Float64.(row) for row in v]...)')
        for (k, v) in matrices_json["AB"]
    )

    matrices = Dict(
        "A" => A,
        "B" => B,
        "AB" => AB,
        "n_samples" => n_samples,
        "n_dims" => n_dims,
        "knob_names" => knob_names
    )

    # Convert knobs to proper format
    knobs_dict = Dict{String, Vector{Float64}}()
    for (name, def) in knobs
        if isa(def, AbstractVector)
            knobs_dict[string(name)] = Float64[def[1], def[2]]
        elseif isa(def, AbstractDict)
            knobs_dict[string(name)] = Float64[def["min"], def["max"]]
        end
    end

    analysis = compute_sensitivity_indices(results, matrices, knobs_dict)

    # Format output with S1/ST keys for Elixir
    indices_result = Dict{String, Dict{String, Float64}}()
    for name in knob_names
        indices_result[name] = Dict(
            "S1" => analysis["first_order"][name],
            "ST" => analysis["total_order"][name]
        )
    end

    return indices_result
end

"""
Handle analyze request - compute sensitivity indices.
"""
function handle_analyze(request_id::Int, payload)
    results = Float64.(payload["results"])
    cache_id = get(payload, "cache_id", request_id)

    # Get cached matrices
    matrices = lock(CACHE_LOCK) do
        get(MATRICES_CACHE, cache_id, nothing)
    end

    if matrices === nothing
        # If no cached matrices, need knobs to reconstruct
        if !haskey(payload, "knobs")
            error("No cached matrices and no knobs provided")
        end
        knobs = payload["knobs"]
        n_samples = payload["n_samples"]

        knobs_dict = Dict{String, Vector{Float64}}()
        for (name, bounds) in knobs
            knobs_dict[string(name)] = Float64[bounds[1], bounds[2]]
        end

        _, matrices = generate_sobol_samples(knobs_dict, n_samples)
    end

    knobs_dict = Dict{String, Vector{Float64}}()
    for name in matrices["knob_names"]
        knobs_dict[name] = [0.0, 1.0]  # Bounds not needed for analysis
    end

    analysis = compute_sensitivity_indices(results, matrices, knobs_dict)

    # Get top knobs (default to 12)
    top_n = get(payload, "top_n", 12)
    top_knobs = get_top_knobs(analysis, top_n)

    # Clean up cache
    lock(CACHE_LOCK) do
        delete!(MATRICES_CACHE, cache_id)
    end

    return Dict(
        "first_order" => analysis["first_order"],
        "total_order" => analysis["total_order"],
        "ranking" => analysis["ranking"],
        "top_knobs" => top_knobs,
        "variance" => analysis["variance"]
    )
end

"""
Run server in stdio mode (for local development with erlexec).
"""
function run_stdio_server()
    @info "Julia sensitivity server started (stdio mode)"

    for line in eachline(stdin)
        try
            request = JSON.parse(line)
            response = process_request(request)
            println(stdout, JSON.json(response))
            flush(stdout)
        catch e
            error_response = Dict(
                "id" => 0,
                "type" => "error",
                "message" => sprint(showerror, e)
            )
            println(stdout, JSON.json(error_response))
            flush(stdout)
        end
    end
end

"""
Run server in TCP mode (for production/Kubernetes).
"""
function run_tcp_server(port::Int=9999)
    server = listen(port)
    @info "Julia sensitivity server started (TCP mode) on port $port"

    while true
        sock = accept(server)
        @async begin
            try
                handle_tcp_client(sock)
            catch e
                @warn "Client error" exception=(e, catch_backtrace())
            finally
                close(sock)
            end
        end
    end
end

function handle_tcp_client(sock)
    for line in eachline(sock)
        try
            request = JSON.parse(line)
            response = process_request(request)
            println(sock, JSON.json(response))
            flush(sock)
        catch e
            error_response = Dict(
                "id" => 0,
                "type" => "error",
                "message" => sprint(showerror, e)
            )
            println(sock, JSON.json(error_response))
            flush(sock)
        end
    end
end

# Main entry point
function main()
    mode = get(ENV, "JULIA_SERVER_MODE", "stdio")

    if mode == "tcp"
        port = parse(Int, get(ENV, "JULIA_SERVER_PORT", "9999"))
        run_tcp_server(port)
    else
        run_stdio_server()
    end
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
