include("main.jl")
using Printf

"""
    move_artifacts(instance_stem, target_dir, plot_format)
Moves generated plot files into the target output directory.
"""
function move_artifacts(instance_stem::String, target_dir::String, plot_format::String)
    ext = lowercase(plot_format)
    plot_name = "$(instance_stem)_plot.$ext"

    if isfile(plot_name)
        mv(plot_name, joinpath(target_dir, plot_name); force=true)
    end
end

"""
    run_comprehensive_evaluation()
Runs all train and test instances with centralized configuration and stores
all generated artifacts in `train_results/` and `test_results/`.
"""
function run_comprehensive_evaluation()
    project_root = @__DIR__
    config_path = if isempty(ARGS)
        joinpath(project_root, "config.json")
    else
        isabspath(ARGS[1]) ? ARGS[1] : joinpath(project_root, ARGS[1])
    end
    cfg = load_project_config(config_path)

    train_pop = Int(getcfg(cfg, ["batch", "train", "pop_size"], 100))
    train_gen = Int(getcfg(cfg, ["batch", "train", "generations"], 500))
    train_plot = to_bool(getcfg(cfg, ["batch", "train", "plot"], true), true)
    train_plot_format = lowercase(String(getcfg(cfg, ["batch", "train", "plot_format"], getcfg(cfg, ["single_run", "plot_format"], "png"))))
    clean_outputs = to_bool(getcfg(cfg, ["batch", "clean_outputs"], false), false)

    test_pop = Int(getcfg(cfg, ["batch", "test", "pop_size"], 200))
    test_gen = Int(getcfg(cfg, ["batch", "test", "generations"], 1000))
    test_plot = to_bool(getcfg(cfg, ["batch", "test", "plot"], true), true)
    test_plot_format = lowercase(String(getcfg(cfg, ["batch", "test", "plot_format"], getcfg(cfg, ["single_run", "plot_format"], "png"))))

    batch_seed = Int(getcfg(cfg, ["single_run", "seed"], 42))

    cd(project_root) do
        train_files = [joinpath("train", "train_$i.json") for i in 0:9]
        test_files = [joinpath("test", "test_instance_$i.json") for i in 1:3]

        mkpath("train_results")
        mkpath("test_results")

        if clean_outputs
            for output_dir in ("train_results", "test_results")
                for f in readdir(output_dir)
                    file_path = joinpath(output_dir, f)
                    if isfile(file_path)
                        rm(file_path; force=true)
                    end
                end
            end
            println("Previous outputs removed from train_results/ and test_results/ (batch.clean_outputs=true).")
        end
        
        println("="^80)
        println("Starting comprehensive evaluation (13 instances)")
        println("Project root: $(project_root)")
        println("="^80)
        
        # 1. Run Train Instances
        for (i, file) in enumerate(train_files)
            name = basename(file)
            instance_stem = replace(name, ".json" => "")
            println("\n[Train $(i)/10] Processing $name")
            
            empty!(ARGS)
            push!(ARGS, file)
            push!(ARGS, "--config")
            push!(ARGS, config_path)
            push!(ARGS, "--pop-size")
            push!(ARGS, string(train_pop))
            push!(ARGS, "--generations")
            push!(ARGS, string(train_gen))
            push!(ARGS, "--seed")
            push!(ARGS, string(batch_seed))
            push!(ARGS, train_plot ? "--plot" : "--no-plot")
            push!(ARGS, "--plot-format")
            push!(ARGS, train_plot_format)
            
            out_name = joinpath("train_results", "$(instance_stem)_solution.txt")
            push!(ARGS, "--output")
            push!(ARGS, out_name)
            
            try
                main()
                move_artifacts(instance_stem, "train_results", train_plot_format)
            catch e
                println("Execution failed for $name: $e")
            end
        end

        # 2. Run Test Instances (Maximum effort)
        for (i, file) in enumerate(test_files)
            name = basename(file)
            instance_stem = replace(name, ".json" => "")
            println("\n[Test $(i)/3] Processing $name")
            
            empty!(ARGS)
            push!(ARGS, file)
            push!(ARGS, "--config")
            push!(ARGS, config_path)
            push!(ARGS, "--pop-size")
            push!(ARGS, string(test_pop))
            push!(ARGS, "--generations")
            push!(ARGS, string(test_gen))
            push!(ARGS, "--seed")
            push!(ARGS, string(batch_seed))
            push!(ARGS, test_plot ? "--plot" : "--no-plot")
            push!(ARGS, "--plot-format")
            push!(ARGS, test_plot_format)
            
            out_name = joinpath("test_results", "$(instance_stem)_solution.txt")
            push!(ARGS, "--output")
            push!(ARGS, out_name)
            
            try
                main()
                move_artifacts(instance_stem, "test_results", test_plot_format)
            catch e
                println("Execution failed for $name: $e")
            end
        end
        
        println("\n" * "="^80)
        println("Evaluation completed.")
        println("All outputs are saved in train_results/ and test_results/:")
        println("- *_solution.txt")
        println("- *_plot.<png|svg>")
        println("="^80)
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__) && basename(PROGRAM_FILE) == basename(@__FILE__)
    run_comprehensive_evaluation()
elseif isinteractive()
    println("run_all_tests.jl loaded in interactive mode.")
    println("To start the full evaluation, run: run_comprehensive_evaluation()")
end
