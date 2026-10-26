# Self-contained smoke test using ONLY the explicitly synthetic fixture.
include(joinpath(@__DIR__, "..", "HCVRP.jl"))
using .HCVRP
include(joinpath(@__DIR__, "..", "GA.jl"))
using .GA
using Random

problem = HCVRP.load_problem(joinpath(@__DIR__, "..", "examples", "synthetic_demo.json"))
@assert length(problem.patients) == 5
@assert problem.nbr_nurses == 2
@assert problem.benchmark == 0.0
ok, cost, demand = HCVRP.validate_route(problem, [1, 2])
@assert ok && cost > 0.0 && demand == 2.0
full_cost, full_routes = HCVRP.evaluate_permutation(problem, collect(1:5))
@assert !isnothing(full_routes)
@assert length(full_routes) <= problem.nbr_nurses
@assert sort(reduce(vcat, full_routes)) == collect(1:5)
@assert all(HCVRP.validate_route(problem, r)[1] for r in full_routes)
Random.seed!(42)
best, routes, _ = GA.run_ga(problem; pop_size=15, generations=4,
    log_interval=0, use_two_opt=true, use_inter_route_swap=true,
    use_inter_route_relocate=true)
@assert !isnothing(routes)
@assert isfinite(best)
@assert sort(reduce(vcat, routes)) == collect(1:5)
@assert length(routes) <= problem.nbr_nurses
@assert all(HCVRP.validate_route(problem, r)[1] for r in routes)
println("PASS: Julia loader, route feasibility, DP split, and memetic GA on synthetic fixture.")
