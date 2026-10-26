module HCVRP

using JSON
using Plots

export Problem, load_problem, validate_route, evaluate_permutation, get_route_details, plot_solution

"""
    Patient
Represents a patient with their location, demand, time windows, and service duration.
"""
struct Patient
    id::Int
    x::Float64
    y::Float64
    demand::Float64
    start_time::Float64
    end_time::Float64
    care_time::Float64
end

"""
    Problem
Main data structure for the HCVRP instance. Stores problem constraints and 
pre-processed arrays for high-performance access during optimization.
"""
struct Problem
    instance_name::String
    nbr_nurses::Int
    capacity_nurse::Float64
    benchmark::Float64
    depot_return_time::Float64
    depot_x::Float64
    depot_y::Float64
    patients::Vector{Patient}
    travel_times::Matrix{Float64}
    
    # Pre-fetched arrays for speed (index 1 is the depot)
    demands::Vector{Float64}
    start_times::Vector{Float64}
    end_times::Vector{Float64}
    care_times::Vector{Float64}
    x_coords::Vector{Float64}
    y_coords::Vector{Float64}
end

"""
    load_problem(file_path::String)
Parses a JSON instance file and initializes the Problem structure.
"""
function load_problem(file_path::String)
    data = JSON.parsefile(file_path)
    
    instance_name = data["instance_name"]
    nbr_nurses = data["nbr_nurses"]
    capacity_nurse = Float64(data["capacity_nurse"])
    benchmark = Float64(data["benchmark"])
    
    depot = data["depot"]
    depot_return_time = Float64(depot["return_time"])
    depot_x = Float64(depot["x_coord"])
    depot_y = Float64(depot["y_coord"])
    
    # Sort patients by ID for consistency
    p_keys = sort(collect(keys(data["patients"])), by=x->parse(Int, x))
    patients = Patient[]
    for k in p_keys
        p_data = data["patients"][k]
        push!(patients, Patient(
            parse(Int, k),
            Float64(p_data["x_coord"]),
            Float64(p_data["y_coord"]),
            Float64(p_data["demand"]),
            Float64(p_data["start_time"]),
            Float64(p_data["end_time"]),
            Float64(p_data["care_time"])
        ))
    end
    
    travel_times = Float64.(reduce(hcat, data["travel_times"]))' |> collect


    # =========================================================================
    # PERFORMANCE OPTIMIZATION: ARRAY PRE-ALLOCATION
    # Creates flat 1D arrays to allow O(1) constant-time data access during 
    # the Genetic Algorithm. Since Julia is 1-indexed, index 1 is strictly 
    # reserved for the Depot. 
    # The loop then maps each patient's data to the index (ID + 1).
    # =========================================================================
    
    # Initialize pre-calculated vectors (Julia is 1-indexed)
    num_p = length(patients)
    demands = zeros(num_p + 1)
    start_times = zeros(num_p + 1)
    end_times = zeros(num_p + 1)
    care_times = zeros(num_p + 1)
    x_coords = zeros(num_p + 1)
    y_coords = zeros(num_p + 1)
    
    x_coords[1] = depot_x
    y_coords[1] = depot_y
    end_times[1] = depot_return_time
    
    for p in patients
        idx = p.id + 1
        demands[idx] = p.demand
        start_times[idx] = p.start_time
        end_times[idx] = p.end_time
        care_times[idx] = p.care_time
        x_coords[idx] = p.x
        y_coords[idx] = p.y
    end
    
    return Problem(
        instance_name, nbr_nurses, capacity_nurse, benchmark,
        depot_return_time, depot_x, depot_y, patients, travel_times,
        demands, start_times, end_times, care_times, x_coords, y_coords
    )
end

"""
    validate_route(prob::Problem, route::Vector{Int}; return_penalty=false)
Validates a single route by checking capacity, time windows, and depot return time.
Returns (is_valid, travel_time, total_demand) and optionally a penalty score.
"""
function validate_route(
    prob::Problem,
    route::Vector{Int};
    return_penalty=false,
    time_window_penalty_multiplier=100.0,
    return_time_penalty_multiplier=100.0,
    capacity_penalty_multiplier=100.0
)
    if isempty(route)
        return return_penalty ? (true, 0.0, 0.0, 0.0) : (true, 0.0, 0.0)
    end

    total_demand = 0.0
    current_time = 0.0
    total_travel_time = 0.0
    penalty = 0.0
    has_violation = false
    prev_node = 1 # Start at depot
    
    for p_id in route
        p_idx = p_id + 1
        total_demand += prob.demands[p_idx]
        travel = prob.travel_times[prev_node, p_idx]
        total_travel_time += travel
        current_time += travel
        
        # Wait if arriving before the start of the time window
        if current_time < prob.start_times[p_idx]
            current_time = prob.start_times[p_idx]
        end
        
        # Check if service completion exceeds the end of the time window
        end_care = current_time + prob.care_times[p_idx]
        if end_care > prob.end_times[p_idx]
            has_violation = true
            penalty += (end_care - prob.end_times[p_idx]) * time_window_penalty_multiplier
        end
        
        current_time = end_care
        prev_node = p_idx
    end
    
    # Return to depot
    travel_to_depot = prob.travel_times[prev_node, 1]
    total_travel_time += travel_to_depot
    current_time += travel_to_depot
    
    # Verify depot return time constraint
    if current_time > prob.depot_return_time
        has_violation = true
        penalty += (current_time - prob.depot_return_time) * return_time_penalty_multiplier
    end
    
    # Verify nurse capacity constraint
    if total_demand > prob.capacity_nurse
        has_violation = true
        penalty += (total_demand - prob.capacity_nurse) * capacity_penalty_multiplier
    end
    
    is_valid = !has_violation
    if return_penalty
        return is_valid, total_travel_time, total_demand, penalty
    else
        return is_valid, total_travel_time, total_demand
    end
end

"""
    evaluate_permutation(prob::Problem, permutation::Vector{Int})
Implements the Split Algorithm (Dynamic Programming) to optimally partition a 
sequence of patients into valid routes. Returns the total cost and the list of routes.
"""
function evaluate_permutation(
    prob::Problem,
    permutation::Vector{Int};
    time_window_penalty_multiplier=100.0,
    return_time_penalty_multiplier=100.0,
    capacity_penalty_multiplier=100.0,
    extra_route_penalty_multiplier=1000.0
)
    # =========================================================================
    # Dynamic Programming Split Algorithm: Finds the optimal way to 
    # slice a continuous sequence of patients into individual nurse routes. 
    # The outer loop i sets the route's end, while the inner 
    # loop j searches backward for the best start. It dynamically 
    # memorizes the cheapest cumulative cost and uses 
    # pruning (break when capacity is exceeded) to improve
    # computation time
    # =========================================================================
    
    
    n = length(permutation)
    # V_cost[i] stores the minimum cost to cover the first i patients in the sequence.
    V_cost = fill(Inf, n + 1)
    V_prev = fill(-1, n + 1) # To reconstruct the split points
    V_num = fill(0, n + 1)   # To track number of routes used
    
    V_cost[1] = 0.0
    
    for i in 1:n
        for j in i:-1:1
            # Evaluate a candidate route covering patients from index j to i
            route = permutation[j:i]
            valid, t_time, demand, penalty = validate_route(
                prob,
                route,
                return_penalty=true,
                time_window_penalty_multiplier=time_window_penalty_multiplier,
                return_time_penalty_multiplier=return_time_penalty_multiplier,
                capacity_penalty_multiplier=capacity_penalty_multiplier
            )
            cost = valid ? t_time : t_time + penalty
            
            # Update DP state if this split yields a lower cumulative cost
            if V_cost[j] + cost < V_cost[i+1]
                V_cost[i+1] = V_cost[j] + cost
                V_prev[i+1] = j
                V_num[i+1] = V_num[j] + 1
            end
            
            # Pruning: if demand exceeds capacity, longer routes starting at j won't work
            if demand > prob.capacity_nurse
                break
            end
        end
    end
    
    total_cost = V_cost[n+1]
    num_routes = V_num[n+1]
    
    # Apply high penalty if the solution requires more nurses than available
    if num_routes > prob.nbr_nurses
        total_cost += (num_routes - prob.nbr_nurses) * extra_route_penalty_multiplier
    end
    
    # Reconstruct the set of routes from the DP pointers
    routes = Vector{Int}[]
    curr = n + 1
    while curr > 1
        prev = V_prev[curr]
        push!(routes, permutation[prev:curr-1])
        curr = prev
    end
    reverse!(routes)
    
    # Final validity check for the reconstructed solution
    is_valid = (total_cost < Inf && num_routes <= prob.nbr_nurses)
    if is_valid
        for r in routes
            v, _, _ = validate_route(
                prob,
                r,
                time_window_penalty_multiplier=time_window_penalty_multiplier,
                return_time_penalty_multiplier=return_time_penalty_multiplier,
                capacity_penalty_multiplier=capacity_penalty_multiplier
            )
            if !v
                is_valid = false
                break
            end
        end
    end
    
    return total_cost, (is_valid ? routes : nothing)
end

"""
    get_route_details(prob::Problem, routes::Vector{Vector{Int}})
Extracts detailed temporal metrics (arrival, service start/end) for each patient.
"""
function get_route_details(prob::Problem, routes::Vector{Vector{Int}})
    all_details = []
    total_time = 0.0
    for r in routes
        total_demand = 0.0
        current_time = 0.0
        total_travel_time = 0.0
        details = []
        prev_node = 1
        
        for p_id in r
            p_idx = p_id + 1
            total_demand += prob.demands[p_idx]
            travel = prob.travel_times[prev_node, p_idx]
            total_travel_time += travel
            current_time += travel
            
            arrival_time = current_time
            start_care = max(arrival_time, prob.start_times[p_idx])
            end_care = start_care + prob.care_times[p_idx]
            
            push!(details, (arrival_time, start_care, end_care))
            current_time = end_care
            prev_node = p_idx
        end
        travel_to_depot = prob.travel_times[prev_node, 1]
        total_travel_time += travel_to_depot
        
        push!(all_details, (route=r, travel_time=total_travel_time, demand=total_demand, p_details=details))
        total_time += total_travel_time
    end
    return all_details, total_time
end

"""
    plot_solution(prob::Problem, routes::Vector{Vector{Int}}, output_path::String)
Visualizes the routes and patient locations, saving the result to a PNG file.
"""
function plot_solution(prob::Problem, routes::Vector{Vector{Int}}, output_path::String)
    # Create base scatter with legend outside the plot so it does not cover routes
    p = scatter([prob.depot_x], [prob.depot_y], color=:red, shape=:square, markersize=8, label="Depot", legend=:outerright)

    px = [pat.x for pat in prob.patients]
    py = [pat.y for pat in prob.patients]
    scatter!(p, px, py, color=:black, alpha=0.6, markersize=2.2, label="Patients")
    
    # Prepare a color palette for routes so lines and arrows share the same color
    n_routes = max(1, length(routes))
    if n_routes <= 10
        cols = palette(:tab10, n_routes)
    elseif n_routes <= 20
        cols = palette(:tab20, n_routes)
    else
        # Fallback to HSV spectrum for many routes
        cols = palette(:hsv, n_routes)
    end
    # Arrow scale: fraction of each segment length (kept minimal for readability)
    arrow_scale = 0.02

    for (i, r) in enumerate(routes)
        if isempty(r) continue end
        rx = [prob.depot_x]
        ry = [prob.depot_y]
        for p_id in r
            p_idx = p_id + 1
            push!(rx, prob.x_coords[p_idx])
            push!(ry, prob.y_coords[p_idx])
        end
        push!(rx, prob.depot_x)
        push!(ry, prob.depot_y)
        # Draw polyline for the route and add a legend entry
        c = cols[mod1(i, length(cols))]
        plot!(p, rx, ry, alpha=0.95, lw=2.0, label=string("Route ", i), color=c)

        # Draw arrows along each segment to show direction using quiver
        # origins: all points except the last; deltas: next - current
        nseg = length(rx) - 1
        if nseg >= 1
            # Put arrow origins at segment midpoints and shrink vector length
            xs = [(rx[j] + rx[j+1]) / 2 for j in 1:nseg]
            ys = [(ry[j] + ry[j+1]) / 2 for j in 1:nseg]
            dxs = [arrow_scale * (rx[j+1] - rx[j]) for j in 1:nseg]
            dys = [arrow_scale * (ry[j+1] - ry[j]) for j in 1:nseg]
            # Draw arrows centered on each segment using same color as route
            quiver!(p, xs, ys, quiver=(dxs, dys), color=c, lw=0.6, alpha=0.85, label=false)
        end
    end

    # Keep legend compact and readable when many routes are shown
    plot!(p, legendfontsize=6)
    
    savefig(p, output_path)
end

end # module
