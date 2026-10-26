include("HCVRP.jl")
include("GA.jl")

import .HCVRP
import .GA
using JSON
using Random
using Printf

"""
    recursive_merge(base, override)
Recursively merges two string-keyed dictionaries.
Values from `override` take precedence over `base`.
"""
function recursive_merge(base::Dict{String,Any}, override::Dict{String,Any})
    merged = copy(base)
    for (k, v) in override
        if haskey(merged, k) && merged[k] isa Dict{String,Any} && v isa Dict{String,Any}
            merged[k] = recursive_merge(merged[k], v)
        else
            merged[k] = v
        end
    end
    return merged
end

"""
    getcfg(cfg, path, default)
Safely reads a nested configuration value from `cfg`.
If any key in `path` is missing, returns `default`.
"""
function getcfg(cfg::Dict{String,Any}, path::Vector{String}, default)
    curr = cfg
    for key in path
        if curr isa Dict{String,Any} && haskey(curr, key)
            curr = curr[key]
        else
            return default
        end
    end
    return curr
end

"""
    to_bool(x, default=false)
Converts common scalar values (Bool, Number, String) to `Bool`.
Returns `default` when conversion is not possible.
"""
function to_bool(x, default::Bool=false)
    if x isa Bool
        return x
    elseif x isa Number
        return x != 0
    elseif x isa AbstractString
        s = lowercase(strip(x))
        return s in ("1", "true", "yes", "y", "on")
    else
        return default
    end
end

"""
    load_project_config(config_path="config.json")
Loads project configuration from JSON and merges it with built-in defaults.
"""
function load_project_config(config_path::String="config.json")
    defaults = Dict{String,Any}(
        "single_run" => Dict{String,Any}(
            "pop_size" => 100,
            "generations" => 500,
            "seed" => 42,
            "plot" => false,
            "plot_format" => "png",
            "output" => "solution.txt"
        ),
        "ga" => Dict{String,Any}(
            "mutation_rate" => 0.2,
            "crossover_rate" => 0.8,
            "elitism_size" => 2,
            "tournament_size" => 2,
            "heuristic_init_fraction" => 0.2,
            "min_heuristic_individuals" => 2,
            "log_interval" => 100,
            "local_search_probability" => 1.0,
            "local_search_top_fraction" => 1.0,
            "local_search_max_evals" => nothing,
            "local_search_max_ms" => nothing,
            "local_search_order" => Any["two_opt", "swap", "relocate"],
            "use_two_opt" => true,
            "two_opt_max_passes" => nothing,
            "two_opt_max_segment_checks" => nothing,
            "two_opt_first_improvement" => true,
            "use_inter_route_swap" => true,
            "inter_route_swap_max_tries" => nothing,
            "use_inter_route_relocate" => true,
            "inter_route_relocate_max_tries" => nothing,
            "mutation_operator_weights" => Dict{String,Any}(
                "swap" => 1.0,
                "reverse" => 1.0,
                "shuffle" => 1.0
            )
        ),
        "penalties" => Dict{String,Any}(
            "time_window_penalty_multiplier" => 100.0,
            "return_time_penalty_multiplier" => 100.0,
            "capacity_penalty_multiplier" => 100.0,
            "extra_route_penalty_multiplier" => 1000.0
        ),
        "batch" => Dict{String,Any}(
            "clean_outputs" => false,
            "train" => Dict{String,Any}(
                "pop_size" => 100,
                "generations" => 500,
                "plot" => true
            ),
            "test" => Dict{String,Any}(
                "pop_size" => 200,
                "generations" => 1000,
                "plot" => true
            )
        )
    )

    if !isfile(config_path)
        return defaults
    end

    user_cfg = JSON.parsefile(config_path)
    if !(user_cfg isa Dict{String,Any})
        return defaults
    end
    return recursive_merge(defaults, user_cfg)
end

"""
    format_solution(prob::HCVRP.Problem, routes::Vector{Vector{Int}})
Formats the final solution into a human-readable string.
Includes one route row for every nurse (unused nurses are shown as empty routes).
Distinguishes route duration (travel + wait + care, for constraints) from travel time
(objective value, excluding care and waiting).
"""
function format_solution(prob::HCVRP.Problem, routes::Vector{Vector{Int}})
    details, _ = HCVRP.get_route_details(prob, routes)
    
    io = IOBuffer()
    println(io, "Instance: $(prob.instance_name)")
    if startswith(lowercase(prob.instance_name), "synthetic_")
        println(io, "DATA: SYNTHETIC DEMONSTRATION (not an academic benchmark)")
    end
    println(io, "Nurse capacity: $(Int(prob.capacity_nurse))")
    println(io, "Depot return time: $(Int(prob.depot_return_time))")
    println(io, "Columns: [Route duration] [Route travel time] [Demand] [Sequence]")
    println(io, "-" ^ 120)
    
    total_travel_time = 0.0
    max_depot_arrival = 0.0
    capacity_violations = 0
    time_window_violations = 0
    seen_patients = Set{Int}()
    duplicate_patients = 0

    for i in 1:prob.nbr_nurses
        if i <= length(details)
            d = details[i]
            r = d.route
            demand = d.demand
            p_details = d.p_details
            route_travel_time = d.travel_time
        else
            r = Int[]
            demand = 0.0
            p_details = Tuple{Float64, Float64, Float64}[]
            route_travel_time = 0.0
        end
        
        # Route duration uses schedule time (travel + wait + care)
        last_node = isempty(r) ? 1 : r[end] + 1
        last_end = isempty(r) ? 0.0 : p_details[end][3]
        arrival_at_depot = last_end + prob.travel_times[last_node, 1]
        max_depot_arrival = max(max_depot_arrival, arrival_at_depot)
        total_travel_time += route_travel_time

        if demand > prob.capacity_nurse
            capacity_violations += 1
        end

        for p_id in r
            if p_id in seen_patients
                duplicate_patients += 1
            else
                push!(seen_patients, p_id)
            end
        end
        
        sequence = ["D (0)"]
        for (idx, p_id) in enumerate(r)
            arrival, start_care, end_care = p_details[idx]
            p_start = prob.start_times[p_id + 1]
            p_end = prob.end_times[p_id + 1]
            if end_care > p_end + 1e-9
                time_window_violations += 1
            end
            # Format: PatientID (StartCare-EndCare) [TimeWindowStart-TimeWindowEnd]
            push!(sequence, @sprintf("%d (%.2f-%.2f) [%d-%d]", p_id, start_care, end_care, Int(p_start), Int(p_end)))
        end
        push!(sequence, @sprintf("D (%.2f)", arrival_at_depot))
        
        @printf(io, "Nurse %-2d    %8.2f    %8.2f    %8.0f    %s\n", i, arrival_at_depot, route_travel_time, demand, join(sequence, " -> "))
    end
    
    println(io, "-" ^ 120)
    @printf(io, "Objective value (total travel time, excl. care/wait): %.2f\n", total_travel_time)
    # Zero means that no external benchmark is supplied (e.g. synthetic demo).
    if prob.benchmark > 0.0
        @printf(io, "Benchmark: %.2f\n", prob.benchmark)
        @printf(io, "Relative error: %.2f%%\n",
            (total_travel_time - prob.benchmark) / prob.benchmark * 100.0)
    else
        println(io, "Benchmark: not provided")
        println(io, "Relative error: not applicable")
    end

    missing_patients = length(prob.patients) - length(seen_patients)
    feasible = (
        max_depot_arrival <= prob.depot_return_time + 1e-9 &&
        capacity_violations == 0 &&
        time_window_violations == 0 &&
        duplicate_patients == 0 &&
        missing_patients == 0 &&
        length(routes) <= prob.nbr_nurses
    )

    println(io, "")
    println(io, "Summary:")
    println(io, "• Feasible: $(feasible)")
    @printf(io, "• Max depot arrival: %.2f / return_time %.2f\n", max_depot_arrival, prob.depot_return_time)
    println(io, "• Capacity violations: $(capacity_violations)")
    println(io, "• Time window violations: $(time_window_violations)")
    
    return String(take!(io))
end

"""
    main()
CLI entry point. Parses arguments, loads the problem instance, runs the GA optimizer, 
and handles output (saving results to file and optional plotting).
"""
function main()
    if length(ARGS) < 1
        println("Usage: julia main.jl <instance_path> [--config file] [--pop-size N] [--generations G] [--seed S] [--mutation-rate R] [--crossover-rate R] [--elitism-size E] [--plot|--no-plot] [--plot-format png|svg] [--output file]")
        return
    end

    config_path = "config.json"
    j = 2
    while j <= length(ARGS)
        if ARGS[j] == "--config" && j + 1 <= length(ARGS)
            config_path = ARGS[j + 1]
            j += 2
        else
            j += 1
        end
    end

    cfg = load_project_config(config_path)
    instance_path = ARGS[1]
    pop_size = Int(getcfg(cfg, ["single_run", "pop_size"], 100))
    generations = Int(getcfg(cfg, ["single_run", "generations"], 500))
    seed = Int(getcfg(cfg, ["single_run", "seed"], 42))
    do_plot = to_bool(getcfg(cfg, ["single_run", "plot"], false), false)
    plot_format = lowercase(String(getcfg(cfg, ["single_run", "plot_format"], "png")))
    output_file = String(getcfg(cfg, ["single_run", "output"], "solution.txt"))
    mutation_rate = Float64(getcfg(cfg, ["ga", "mutation_rate"], 0.2))
    crossover_rate = Float64(getcfg(cfg, ["ga", "crossover_rate"], 0.8))
    elitism_size = Int(getcfg(cfg, ["ga", "elitism_size"], 2))
    heuristic_init_fraction = Float64(getcfg(cfg, ["ga", "heuristic_init_fraction"], 0.2))
    min_heuristic_individuals = Int(getcfg(cfg, ["ga", "min_heuristic_individuals"], 2))
    log_interval = Int(getcfg(cfg, ["ga", "log_interval"], 100))
    use_two_opt = to_bool(getcfg(cfg, ["ga", "use_two_opt"], true), true)
    use_inter_route_swap = to_bool(getcfg(cfg, ["ga", "use_inter_route_swap"], true), true)
    use_inter_route_relocate = to_bool(getcfg(cfg, ["ga", "use_inter_route_relocate"], true), true)
    local_search_probability = Float64(getcfg(cfg, ["ga", "local_search_probability"], 1.0))
    local_search_top_fraction = Float64(getcfg(cfg, ["ga", "local_search_top_fraction"], 1.0))
    local_search_max_evals_cfg = getcfg(cfg, ["ga", "local_search_max_evals"], nothing)
    local_search_max_evals = local_search_max_evals_cfg === nothing ? nothing : Int(local_search_max_evals_cfg)
    local_search_max_ms_cfg = getcfg(cfg, ["ga", "local_search_max_ms"], nothing)
    local_search_max_ms = local_search_max_ms_cfg === nothing ? nothing : Float64(local_search_max_ms_cfg)
    local_search_order_cfg = getcfg(cfg, ["ga", "local_search_order"], Any["two_opt", "swap", "relocate"])
    local_search_order = local_search_order_cfg isa AbstractVector ? [lowercase(String(x)) for x in local_search_order_cfg] : ["two_opt", "swap", "relocate"]
    two_opt_max_passes_cfg = getcfg(cfg, ["ga", "two_opt_max_passes"], nothing)
    two_opt_max_passes = two_opt_max_passes_cfg === nothing ? nothing : Int(two_opt_max_passes_cfg)
    two_opt_max_segment_checks_cfg = getcfg(cfg, ["ga", "two_opt_max_segment_checks"], nothing)
    two_opt_max_segment_checks = two_opt_max_segment_checks_cfg === nothing ? nothing : Int(two_opt_max_segment_checks_cfg)
    two_opt_first_improvement = to_bool(getcfg(cfg, ["ga", "two_opt_first_improvement"], true), true)
    inter_route_swap_max_tries_cfg = getcfg(cfg, ["ga", "inter_route_swap_max_tries"], nothing)
    inter_route_swap_max_tries = inter_route_swap_max_tries_cfg === nothing ? nothing : Int(inter_route_swap_max_tries_cfg)
    inter_route_relocate_max_tries_cfg = getcfg(cfg, ["ga", "inter_route_relocate_max_tries"], nothing)
    inter_route_relocate_max_tries = inter_route_relocate_max_tries_cfg === nothing ? nothing : Int(inter_route_relocate_max_tries_cfg)
    mutation_swap_weight = Float64(getcfg(cfg, ["ga", "mutation_operator_weights", "swap"], 1.0))
    mutation_reverse_weight = Float64(getcfg(cfg, ["ga", "mutation_operator_weights", "reverse"], 1.0))
    mutation_shuffle_weight = Float64(getcfg(cfg, ["ga", "mutation_operator_weights", "shuffle"], 1.0))
    tournament_size = Int(getcfg(cfg, ["ga", "tournament_size"], 2))
    time_window_penalty_multiplier = Float64(getcfg(cfg, ["penalties", "time_window_penalty_multiplier"], 100.0))
    return_time_penalty_multiplier = Float64(getcfg(cfg, ["penalties", "return_time_penalty_multiplier"], 100.0))
    capacity_penalty_multiplier = Float64(getcfg(cfg, ["penalties", "capacity_penalty_multiplier"], 100.0))
    extra_route_penalty_multiplier = Float64(getcfg(cfg, ["penalties", "extra_route_penalty_multiplier"], 1000.0))
    
    # Simple ARGS parsing loop
    i = 2
    while i <= length(ARGS)
        if ARGS[i] == "--config"
            i += 2
        elseif ARGS[i] == "--pop-size"
            pop_size = parse(Int, ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--generations"
            generations = parse(Int, ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--seed"
            seed = parse(Int, ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--mutation-rate"
            mutation_rate = parse(Float64, ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--crossover-rate"
            crossover_rate = parse(Float64, ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--elitism-size"
            elitism_size = parse(Int, ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--plot"
            do_plot = true
            i += 1
        elseif ARGS[i] == "--no-plot"
            do_plot = false
            i += 1
        elseif ARGS[i] == "--plot-format"
            plot_format = lowercase(ARGS[i+1])
            i += 2
        elseif ARGS[i] == "--output"
            output_file = ARGS[i+1]
            i += 2
        else
            i += 1
        end
    end

    if !(plot_format in ("png", "svg"))
        println("Unknown plot format '$plot_format'. Falling back to png.")
        plot_format = "png"
    end
    
    Random.seed!(seed)
    
    println("Loading instance: $instance_path")
    prob = HCVRP.load_problem(instance_path)
    println("Instance: $(prob.instance_name) | Patients: $(length(prob.patients)) | Nurses: $(prob.nbr_nurses)")
    if prob.benchmark > 0.0
        @printf("Benchmark travel time: %.2f\n", prob.benchmark)
    else
        println("Benchmark travel time: not provided")
    end
    
    # Execute the Genetic Algorithm
    best_fitness, best_routes, _ = GA.run_ga(
        prob,
        pop_size=pop_size,
        generations=generations,
        mutation_rate=mutation_rate,
        crossover_rate=crossover_rate,
        elitism_size=elitism_size,
        heuristic_init_fraction=heuristic_init_fraction,
        min_heuristic_individuals=min_heuristic_individuals,
        log_interval=log_interval,
        local_search_probability=local_search_probability,
        local_search_top_fraction=local_search_top_fraction,
        local_search_max_evals=local_search_max_evals,
        local_search_max_ms=local_search_max_ms,
        local_search_order=local_search_order,
        use_two_opt=use_two_opt,
        two_opt_max_passes=two_opt_max_passes,
        two_opt_max_segment_checks=two_opt_max_segment_checks,
        two_opt_first_improvement=two_opt_first_improvement,
        use_inter_route_swap=use_inter_route_swap,
        inter_route_swap_max_tries=inter_route_swap_max_tries,
        use_inter_route_relocate=use_inter_route_relocate,
        inter_route_relocate_max_tries=inter_route_relocate_max_tries,
        mutation_swap_weight=mutation_swap_weight,
        mutation_reverse_weight=mutation_reverse_weight,
        mutation_shuffle_weight=mutation_shuffle_weight,
        tournament_size=tournament_size,
        time_window_penalty_multiplier=time_window_penalty_multiplier,
        return_time_penalty_multiplier=return_time_penalty_multiplier,
        capacity_penalty_multiplier=capacity_penalty_multiplier,
        extra_route_penalty_multiplier=extra_route_penalty_multiplier
    )
    
    if !isnothing(best_routes)
        println("\nOptimization completed.")
        @printf("Best total travel time: %.2f\n", best_fitness)
        if prob.benchmark > 0.0
            @printf("Relative error: %.2f%%\n", (best_fitness - prob.benchmark) / prob.benchmark * 100)
        else
            println("Relative error: not applicable (no benchmark)")
        end
        
        # Save solution to text file
        sol_txt = format_solution(prob, best_routes)
        open(output_file, "w") do f
            write(f, sol_txt)
        end
        println("Solution report saved to $output_file")
        
        # Optional visualization
        if do_plot
            # Route Plot
            plot_path = "$(prob.instance_name)_plot.$plot_format"
            HCVRP.plot_solution(prob, best_routes, plot_path)
            println("Route plot saved to $plot_path")
            
        end
    else
        println("No feasible solution was found for the current configuration.")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
