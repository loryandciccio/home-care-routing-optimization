module GA

using ..HCVRP
using Random

export run_ga

"""
Module GA

This module implements a Memetic Algorithm (a Genetic Algorithm enhanced with Local Search) 
to solve the Home-Care Vehicle Routing Problem (HCVRP) with strict time windows and capacity constraints.

Key Features:
- Initialization: Combines random patient permutations with a Nearest Neighbor constructive heuristic to establish a high-quality initial population.
- Decoding: Uses a dynamic programming Split algorithm (via `evaluate_permutation`) to optimally partition flat sequences into valid nurse routes.
- Local Search: Applies intra-route (2-opt) and inter-route (swap, relocate) optimizations to feasible solutions, aggressively minimizing total travel time.
- Evolution: Employs Order Crossover (OX), mixed mutation strategies (swap, reverse, shuffle), tournament selection, and elitism to drive continuous improvement across generations.
"""



"""
    two_opt(prob, route; max_passes=nothing, max_segment_checks=nothing, first_improvement=true)
Standard intra-route 2-opt local search.

Tunable controls:
- `max_passes`: maximum number of outer improvement passes (`nothing` means no cap).
- `max_segment_checks`: maximum number of `(i, j)` segment checks (`nothing` means no cap).
- `first_improvement`: when `true`, applies the first improving move found (default, preserves prior behavior);
  when `false`, uses best-improvement per pass.
"""
function two_opt(
    prob::Problem,
    route::Vector{Int};
    max_passes=nothing,
    max_segment_checks=nothing,
    first_improvement=true
)
    best_route = copy(route)
    improved = true
    pass_count = 0
    segment_checks = 0
    
    # Get initial travel time (must be valid to start)
    valid, best_time, _ = validate_route(prob, best_route)
    if !valid return route end
    
    while improved
        if !isnothing(max_passes) && pass_count >= max_passes
            break
        end
        pass_count += 1
        improved = false
        n = length(best_route)
        best_candidate = copy(best_route)
        candidate_found = false
        candidate_best_time = best_time

        for i in 1:n-1
            for j in i+1:n
                if !isnothing(max_segment_checks) && segment_checks >= max_segment_checks
                    return best_route
                end
                segment_checks += 1

                # Reverse the segment [i:j] and check for improvements
                new_route = copy(best_route)
                new_route[i:j] = reverse(new_route[i:j])
                v, t, _ = validate_route(prob, new_route)
                if v && t < best_time
                    if first_improvement
                        best_time = t
                        best_route = new_route
                        improved = true
                        break
                    else
                        if !candidate_found || t < candidate_best_time
                            candidate_best_time = t
                            best_candidate = new_route
                            candidate_found = true
                        end
                    end
                end
            end
            if first_improvement && improved
                break
            end
        end

        if !first_improvement && candidate_found
            best_route = best_candidate
            best_time = candidate_best_time
            improved = true
        end
    end
    return best_route
end

"""
    inter_route_swap(prob, routes; max_tries=nothing)
Inter-route local search: swaps one patient from route A with one from route B
to reduce the total travel time of both routes.

`max_tries` limits how many swap attempts are evaluated (`nothing` means no cap).
"""
function inter_route_swap(prob::Problem, routes::Vector{Vector{Int}}; max_tries=nothing)
    improved = true
    tries = 0
    while improved
        improved = false
        for r1_idx in 1:length(routes)
            for r2_idx in r1_idx+1:length(routes)
                r1 = routes[r1_idx]
                r2 = routes[r2_idx]
                if isempty(r1) || isempty(r2) continue end
                
                for i in 1:length(r1), j in 1:length(r2)
                    if !isnothing(max_tries) && tries >= max_tries
                        return
                    end
                    tries += 1

                    new_r1 = copy(r1)
                    new_r2 = copy(r2)
                    new_r1[i], new_r2[j] = new_r2[j], new_r1[i]
                    
                    v1, t1, _ = validate_route(prob, new_r1)
                    v2, t2, _ = validate_route(prob, new_r2)
                    
                    _, old_t1, _ = validate_route(prob, r1)
                    _, old_t2, _ = validate_route(prob, r2)
                    
                    # Accept the swap if both routes remain valid and total cost decreases
                    if v1 && v2 && (t1 + t2 < old_t1 + old_t2)
                        routes[r1_idx] = new_r1
                        routes[r2_idx] = new_r2
                        improved = true
                        break
                    end
                end
                if improved break end
            end
            if improved break end
        end
    end
end

"""
    inter_route_relocate(prob, routes; max_tries=nothing)
Inter-route local search: moves a patient from route A to any valid position
in route B.

`max_tries` limits how many relocate attempts are evaluated (`nothing` means no cap).
"""
function inter_route_relocate(prob::Problem, routes::Vector{Vector{Int}}; max_tries=nothing)
    improved = true
    tries = 0
    while improved
        improved = false
        for r1_idx in 1:length(routes)
            for r2_idx in 1:length(routes)
                if r1_idx == r2_idx continue end
                r1 = routes[r1_idx]
                r2 = routes[r2_idx]
                if isempty(r1) continue end
                
                for i in 1:length(r1)
                    for j in 1:length(r2)+1
                        if !isnothing(max_tries) && tries >= max_tries
                            return
                        end
                        tries += 1

                        new_r1 = copy(r1)
                        deleteat!(new_r1, i)
                        new_r2 = copy(r2)
                        insert!(new_r2, j, r1[i])
                        
                        v1, t1, _ = validate_route(prob, new_r1)
                        v2, t2, _ = validate_route(prob, new_r2)
                        
                        _, old_t1, _ = validate_route(prob, r1)
                        _, old_t2, _ = validate_route(prob, r2)
                        
                        # Accept the move if both routes remain valid and total cost decreases
                        if v1 && v2 && (t1 + t2 < old_t1 + old_t2)
                            routes[r1_idx] = new_r1
                            routes[r2_idx] = new_r2
                            improved = true
                            break
                        end
                    end
                    if improved break end
                end
                if improved break end
            end
            if improved break end
        end
    end
end

"""
    crossover_ox(p1, p2)
Order Crossover (OX) for permutations. Preserves the relative order of items 
from parents to generate children.
"""
function crossover_ox(p1::Vector{Int}, p2::Vector{Int})
    size = length(p1)
    start_idx, end_idx = sort(rand(1:size, 2))
    
    child = fill(-1, size)
    child[start_idx:end_idx] = p1[start_idx:end_idx]
    
    child_set = Set(child[start_idx:end_idx])
    remaining = [x for x in p2 if !(x in child_set)]
    
    curr = (end_idx % size) + 1
    for item in remaining
        child[curr] = item
        curr = (curr % size) + 1
    end
    return child
end

"""
    mutate!(ind)
Applies a random mutation operator: Swap, Reverse (2-opt like), or Shuffle.
"""
function mutate!(
    ind::Vector{Int};
    swap_weight=1.0,
    reverse_weight=1.0,
    shuffle_weight=1.0
)
    size = length(ind)
    total_weight = max(1e-9, swap_weight + reverse_weight + shuffle_weight)
    swap_threshold = swap_weight / total_weight
    reverse_threshold = (swap_weight + reverse_weight) / total_weight
    op = rand()
    if op < swap_threshold
        idx1, idx2 = rand(1:size, 2)
        ind[idx1], ind[idx2] = ind[idx2], ind[idx1]
    elseif op < reverse_threshold
        idx1, idx2 = sort(rand(1:size, 2))
        ind[idx1:idx2] = reverse(ind[idx1:idx2])
    else
        idx1, idx2 = sort(rand(1:size, 2))
        if idx1 < idx2
            shuffle!(@view ind[idx1:idx2])
        end
    end
end

"""
    constructive_heuristic(prob)
Nearest Neighbor constructive heuristic to generate a reasonable starting permutation.
Attempts to build valid routes by always picking the closest available patient.
"""
function constructive_heuristic(prob::Problem)
    unvisited = Set(1:length(prob.patients))
    all_perm = Int[]
    
    while !isempty(unvisited)
        curr_route = Int[]
        curr_node = 1
        
        while !isempty(unvisited)
            best_p = -1
            min_dist = Inf
            
            for p_id in unvisited
                temp_route = [curr_route; p_id]
                valid, _, _ = validate_route(prob, temp_route)
                if valid
                    dist = prob.travel_times[curr_node, p_id + 1]
                    if dist < min_dist
                        min_dist = dist
                        best_p = p_id
                    end
                end
            end
            
            if best_p != -1
                push!(curr_route, best_p)
                delete!(unvisited, best_p)
                curr_node = best_p + 1
            else
                break
            end
        end
        append!(all_perm, curr_route)
        
        # If no valid neighbor found but patients remain, shuffle and append them
        if isempty(curr_route) && !isempty(unvisited)
            rem = collect(unvisited)
            shuffle!(rem)
            append!(all_perm, rem)
            break
        end
    end
    return all_perm
end

"""
    run_ga(prob; kwargs...)
Main Evolutionary Loop. Employs a Memetic approach:
1. Decode permutations into routes using the Split algorithm.
2. Apply local search heuristics to valid solutions for refinement.
3. Perform selection, crossover, and mutation to evolve the population.
"""
function run_ga(
    prob::Problem;
    pop_size=100,
    generations=500,
    mutation_rate=0.2,
    crossover_rate=0.8,
    elitism_size=2,
    tournament_size=2,
    heuristic_init_fraction=0.2,
    min_heuristic_individuals=2,
    log_interval=100,
    local_search_probability=1.0,
    local_search_top_fraction=1.0,
    local_search_max_evals=nothing,
    local_search_max_ms=nothing,
    local_search_order=["two_opt", "swap", "relocate"],
    use_two_opt=true,
    two_opt_max_passes=nothing,
    two_opt_max_segment_checks=nothing,
    two_opt_first_improvement=true,
    use_inter_route_swap=true,
    inter_route_swap_max_tries=nothing,
    use_inter_route_relocate=true,
    inter_route_relocate_max_tries=nothing,
    mutation_swap_weight=1.0,
    mutation_reverse_weight=1.0,
    mutation_shuffle_weight=1.0,
    time_window_penalty_multiplier=100.0,
    return_time_penalty_multiplier=100.0,
    capacity_penalty_multiplier=100.0,
    extra_route_penalty_multiplier=1000.0
)
    # Initialize population with a mix of heuristic and random permutations
    population = Vector{Int}[]
    heuristic_n = max(min_heuristic_individuals, Int(floor(pop_size * heuristic_init_fraction)))
    heuristic_n = min(heuristic_n, pop_size)
    for _ in 1:heuristic_n
        push!(population, constructive_heuristic(prob))
    end
    while length(population) < pop_size
        p = collect(1:length(prob.patients))
        shuffle!(p)
        push!(population, p)
    end
    
    best_valid_fitness = Inf
    best_overall_fitness = Inf
    best_routes = nothing
    
    # History for plotting
    history_valid = Float64[]
    history_overall = Float64[]
    history_avg = Float64[]
    history_min = Float64[]

    # Global Local Search budget counters (shared across generations)
    ls_evals_used = 0
    ls_start_ns = time_ns()

    # Normalize and validate local-search execution order once
    allowed_ops = Set(["two_opt", "swap", "relocate"])
    ls_order = String[]
    for op in local_search_order
        op_s = lowercase(String(op))
        if op_s in allowed_ops
            push!(ls_order, op_s)
        end
    end
    if isempty(ls_order)
        ls_order = ["two_opt", "swap", "relocate"]
    end
    
    for gen in 1:generations
        fitnesses = Float64[]
        
        decoded_routes = Vector{Union{Nothing, Vector{Vector{Int}}}}(undef, length(population))
        is_feasible = falses(length(population))

        for (i, ind) in enumerate(population)
            # 1. Decode and evaluate
            fit, routes = evaluate_permutation(
                prob,
                ind,
                time_window_penalty_multiplier=time_window_penalty_multiplier,
                return_time_penalty_multiplier=return_time_penalty_multiplier,
                capacity_penalty_multiplier=capacity_penalty_multiplier,
                extra_route_penalty_multiplier=extra_route_penalty_multiplier
            )

            decoded_routes[i] = routes
            is_feasible[i] = !isnothing(routes)
            push!(fitnesses, fit)
        end

        # Select feasible individuals eligible by rank (top fraction)
        feasible_idxs = [i for i in eachindex(population) if is_feasible[i]]
        ls_top_fraction = clamp(local_search_top_fraction, 0.0, 1.0)
        top_count = Int(ceil(ls_top_fraction * length(feasible_idxs)))
        top_count = max(0, min(top_count, length(feasible_idxs)))
        top_set = Set{Int}()
        if top_count > 0
            sorted_feasible = sort(feasible_idxs, by=i -> fitnesses[i])
            for idx in sorted_feasible[1:top_count]
                push!(top_set, idx)
            end
        end

        # 2. Local Search (Memetic Step), with configurable application policy and budgets
        for i in feasible_idxs
            routes = decoded_routes[i]
            if isnothing(routes)
                continue
            end

            can_by_rank = i in top_set
            can_by_probability = rand() < clamp(local_search_probability, 0.0, 1.0)
            can_by_eval_budget = isnothing(local_search_max_evals) || ls_evals_used < local_search_max_evals
            elapsed_ms = (time_ns() - ls_start_ns) / 1e6
            can_by_time_budget = isnothing(local_search_max_ms) || elapsed_ms < local_search_max_ms

            apply_ls = can_by_rank && can_by_probability && can_by_eval_budget && can_by_time_budget

            improved_routes = copy(routes)
            if apply_ls
                for op in ls_order
                    if op == "two_opt" && use_two_opt
                        improved_routes = [two_opt(
                            prob,
                            r,
                            max_passes=two_opt_max_passes,
                            max_segment_checks=two_opt_max_segment_checks,
                            first_improvement=two_opt_first_improvement
                        ) for r in improved_routes]
                    elseif op == "swap" && use_inter_route_swap
                        inter_route_swap(prob, improved_routes, max_tries=inter_route_swap_max_tries)
                    elseif op == "relocate" && use_inter_route_relocate
                        inter_route_relocate(prob, improved_routes, max_tries=inter_route_relocate_max_tries)
                    end
                end
                ls_evals_used += 1
            end

            # Keep the same representation update strategy as before (flatten decoded/improved routes)
            new_ind = isempty(improved_routes) ? Int[] : reduce(vcat, improved_routes)
            new_fit = sum(r -> validate_route(prob, r)[2], improved_routes)

            population[i] = new_ind
            fitnesses[i] = new_fit

            if new_fit < best_valid_fitness
                best_valid_fitness = new_fit
                best_routes = improved_routes
            end
        end

        # Update global best considering both feasible and infeasible final generation fitnesses
        gen_best = minimum(fitnesses)
        if gen_best < best_overall_fitness
            best_overall_fitness = gen_best
        end
        
        push!(history_valid, isinf(best_valid_fitness) ? NaN : best_valid_fitness)
        push!(history_overall, best_overall_fitness)
        push!(history_avg, sum(fitnesses) / length(fitnesses))
        push!(history_min, minimum(fitnesses))
        
        if gen == 1 || (log_interval > 0 && gen % log_interval == 0)
            status = isinf(best_valid_fitness) ? "No feasible solution yet (best penalized fitness: $(round(best_overall_fitness, digits=2)))" : "$(round(best_valid_fitness, digits=2))"
            println("Generation $gen | Best feasible travel time: $status | Benchmark: $(prob.benchmark > 0 ? string(prob.benchmark) : "not provided")")
        end
        
        # 3. Selection & New Generation
        # Helper: tournament selection returns index of best among k random competitors
        tournament_select = function(fitnesses::Vector{Float64}, k::Int)
            k = max(1, min(k, length(fitnesses)))
            idxs = rand(1:length(fitnesses), k)
            best_idx = idxs[1]
            best_val = fitnesses[best_idx]
            for ii in idxs
                if fitnesses[ii] < best_val
                    best_val = fitnesses[ii]
                    best_idx = ii
                end
            end
            return best_idx
        end

        new_population = Vector{Int}[]
        perm = sortperm(fitnesses)
        # Elitism: preserve the best individuals
        for i in 1:min(elitism_size, pop_size)
            push!(new_population, copy(population[perm[i]]))
        end
        
        # Tournament Selection and Reproduction (parameterized tournament size)
        while length(new_population) < pop_size
            p1_idx = tournament_select(fitnesses, tournament_size)
            p2_idx = tournament_select(fitnesses, tournament_size)

            p1 = population[p1_idx]
            p2 = population[p2_idx]
            
            child = rand() < crossover_rate ? crossover_ox(p1, p2) : copy(p1)
            if rand() < mutation_rate
                mutate!(
                    child,
                    swap_weight=mutation_swap_weight,
                    reverse_weight=mutation_reverse_weight,
                    shuffle_weight=mutation_shuffle_weight
                )
            end
            push!(new_population, child)
        end
        population = new_population
    end
    
    return best_valid_fitness, best_routes, (history_valid, history_overall, history_avg, history_min)
end

end # module
