# Home-Care Routing Optimization (Julia)

A **memetic evolutionary solver** for a simplified Home-Care Vehicle Routing Problem (HCVRP), implemented for **IT3708 — Bio-Inspired Artificial Intelligence** at the Norwegian University of Science and Technology (NTNU), Spring 2026.

Developed by Lorenzo Cozzolino.

> **Educational prototype, not a production healthcare system.** The runnable example in this repository is **synthetic** and is **not** an original course instance.

## Optimization problem

Plan patient visits using a limited fleet of identical nurses, starting and finishing at one depot. The model enforces:

- Every patient is visited **exactly once**, by one nurse.
- Each route starts at time 0 and ends at the depot by `return_time`.
- Total patient demand on each route is at most `capacity_nurse`.
- A patient cannot start care before `start_time`; waiting is allowed. Care must finish by `end_time`.
- Number of routes cannot exceed `nbr_nurses`.

The objective is the **total travel time**, including trips to/from the depot. Waiting and service times count toward schedules and feasibility, **not** the travel-time objective.

This is a simplified academic model: it does not incorporate nurse qualifications, real road networks, traffic, working shifts, or clinical priorities.

## Algorithm and architecture

| File | Implemented responsibility |
| --- | --- |
| `HCVRP.jl` | JSON loader, problem model, route validator, penalty calculation, dynamic-programming **Split** decoder, route details, plotting |
| `GA.jl` | Population initialization, memetic genetic algorithm, local search |
| `main.jl` | Command-line options, seed, config, execution, human-readable output and route plots |
| `config.json` | Algorithm, penalties, local-search budgets and batch settings |
| `run_all_tests.jl` | Original batch evaluator; **requires independently obtained academic inputs** |
| `test/smoke.jl` | Short smoke test on synthetic data |

A chromosome is a permutation of patient IDs. A Split dynamic program partitions it into nurse routes, using travel times and penalties for constraint violations, followed by explicit route validation. The GA mixes constructive and random initial permutations, uses tournament selection, **Order Crossover (OX)**, swap/reverse/shuffle mutations and elitism. A configurable memetic step adds intra-route **2-opt**, inter-route swap and relocation. The methods are established evolutionary and combinatorial-optimization techniques; their integration for this assignment is the implementation contribution. No global optimum is guaranteed.

## Setup

The original academic implementation targeted **Julia 1.12.x** and requires **JSON.jl** and **Plots.jl** (also listed in `REQUIREMENTS.txt`). Install Julia from the [official Julia website](https://julialang.org/downloads/) and the dependencies with:

```bash
julia --startup-file=no -e 'using Pkg; Pkg.add(["JSON", "Plots"])'
```

Package installation may use the network; the solver itself does not require credentials or an external API. The repository intentionally retains the original dependency model (no lockfile), so report package versions for reproducible comparisons.

## Run the synthetic demonstration

`examples/synthetic_demo.json` is a **fabricated five-patient, two-nurse example** with Euclidean travel times and deliberately simple time windows. It contains no real patient records. `benchmark` is set to `0`, a sentinel for **no external benchmark**; relative-error reporting is disabled in that case.

From the project root:

```bash
julia --startup-file=no main.jl examples/synthetic_demo.json \
  --pop-size 20 --generations 20 --seed 42 \
  --no-plot --output synthetic_demo_solution.txt
```

The output contains route schedules, objective travel time and a feasibility summary. Replace `--no-plot` with `--plot` and optionally add `--plot-format svg` to generate a route plot in the working directory.

Run the separate small smoke test:

```bash
julia --startup-file=no test/smoke.jl
```

It checks instance loading, capacity/time-window feasibility, Split decoding and a short GA run. This **does not** measure benchmark accuracy or validate deployment suitability.

## Input schema

JSON instances require `instance_name`, `nbr_nurses`, `capacity_nurse`, `benchmark`, `depot`, `patients` and `travel_times`.

- `depot`: `x_coord`, `y_coord`, `return_time`.
- `patients`: object keys `"1"` … `"N"`, with `x_coord`, `y_coord`, `demand`, `start_time`, `end_time`, `care_time` for each visit.
- `travel_times`: numeric square **(N+1) × (N+1)** matrix, with the depot at index 0 and patients 1…N in ID order.
- `benchmark`: a justified external travel-time reference, or `0` when none is available.

Coordinates support plotting; actual travel costs come from the **travel-time matrix**, not inferred Euclidean distances. Time units and demand units must be consistent. The loader assumes consecutive patient IDs and a correctly shaped matrix; input schema validation is limited. See `examples/synthetic_demo.json` for a complete example.

## Course inputs and original experiments

The academic project used **10 training instances and 3 test instances**, supplied through the NTNU course's Blackboard platform alongside benchmark values. The original project also generated text solutions and route plots.

**Original JSON inputs, benchmark-derived results, plots, the assignment PDF and lecture slides have been excluded** because no applicable redistribution permission was verified. Numeric identifiers and coordinate fields do not prove an original dataset is free of personal or licensing restrictions.

Students with legitimate access can retrieve course material through NTNU's authorized platform, subject to its access and sharing terms. The original batch runner expects these paths:

- `train/train_0.json` … `train/train_9.json`
- `test/test_instance_1.json` … `test/test_instance_3.json`

Only after supplying the original inputs legally may the corresponding batch evaluation be run:

```bash
julia --startup-file=no run_all_tests.jl
```

Without these files, **the original course benchmarks are not reproducible from this public-copy package**. The repository does not include or claim independently validated original benchmark numbers.

### Evaluation protocol

Report **feasibility**, **travel-time objective** and **execution time** separately. For controlled comparisons, record the input's provenance, run seed(s), population size, generations, operators and local-search budgets, penalty settings, exact `config.json`, hardware, Julia/dependency versions and runtime. Use multiple independent seeds for stochastic comparisons and calculate relative error only when an authorized, like-for-like external benchmark exists. The synthetic demo provides no evidence of original benchmark performance.

## Configuration and limitations

`config.json` provides `single_run` defaults, GA options (`ga`), constraint penalty multipliers (`penalties`) and course batch settings (`batch`). Command-line overrides in `main.jl` include `--config`, `--pop-size`, `--generations`, `--seed`, `--mutation-rate`, `--crossover-rate`, `--elitism-size`, `--plot`, `--no-plot`, `--plot-format` and `--output`.

The search is stochastic and may return no feasible solution. It assumes identical nurse capacities, one depot, and consistent input IDs/matrices. This is **not** a production tool, a privacy-preserving healthcare data pipeline, or proof of optimality.

## Attribution, data and licensing

The work was developed in NTNU's [IT3708 course](https://www.ntnu.edu/studies/courses/IT3708). The course handout describes home-care optimization and credits **Visma Resolve** as background inspiration; this is not an endorsement. **JSON.jl** and **Plots.jl** are independent third-party packages. The underlying GA, Split, and local-search concepts are established methods rather than novel algorithms claimed here.

The project source was authored solely by **Lorenzo Cozzolino**. No project-wide open-source license is asserted, so publication does not itself grant general permission to reuse or modify the source. This repository does **not** grant rights over NTNU materials, course datasets, or third-party dependencies.
