module FSDBenchmark
using Symbolics
using FileIO
using BenchmarkTools
using Statistics
using DataFrames
using CSV
using CurveFit
using Plots
using Memoize
using FastSymbolicDifferentiation
using StaticArrays

include("Chebyshev.jl")
include("SphericalHarmonics.jl")
include("Transformations.jl")
include("LagrangianDynamics.jl")

@variables x, y, z

const SH_NAME = "spherical_harmonics"
const EXE = "exe"
const MAKE_FUNCTION = "make_function"

filename(algorithm_name, function_name, benchmark_name, min_order, max_order, simplify) = "Data/$algorithm_name-$(function_name)-$(benchmark_name)-$min_order-$max_order-simplification-$simplify.csv"
FSD_filename(function_name, benchmark_name, min_order, max_order, simplify) = filename("FSD", function_name, benchmark_name, min_order, max_order, simplify)
Symbolics_filename(function_name, benchmark_name, min_order, max_order, simplify) = filename("Symbolics", function_name, benchmark_name, min_order, max_order, simplify)
export Symbolics_filename

function create_Symbolics_exe(max_l, simplify=true)
    @variables x, y, z

    jac = Symbolics.jacobian(SHFunctions(max_l, x, y, z), [x, y, z]; simplify=simplify)
    fn1, fn2 = eval.(build_function(jac, [x, y, z]))
    return fn1, fn2
end
export create_Symbolics_exe

function make_FSD_exe(max_l; in_place=false)
    graph, x, y, z = to_graph(max_l)
    return jacobian_function!(graph, Node.([x, y, z]); in_place)
end
export make_FSD_exe

preprocess_trial(t::BenchmarkTools.Trial, SHOrder::AbstractString) =
    (SHOrder=SHOrder,
        minimum=minimum(t.times),
        median=median(t.times),
        maximum=maximum(t.times),
        allocations=t.allocs,
        memory_estimate=t.memory)
export preprocess_trial

function Symbolics_spherical_harmonics(min_order, max_order, simplify=true)
    output = DataFrame()

    for n in min_order:1:max_order
        trial = @benchmark Symbolics.jacobian(fn, [$x, $y, $z], simplify=$simplify) setup = fn = SHFunctions($n, $x, $y, $z) evals = 1
        push!(output, preprocess_trial(trial, "$n"))
    end
    CSV.write(Symbolics_filename(SH_NAME, "symbolic", min_order, max_order, simplify), output)
    return output
end
export Symbolics_spherical_harmonics

function FSD_spherical_harmonics(min_order, max_order, simplify=true)
    output = DataFrame()

    for n in min_order:1:max_order
        trial = @benchmark FastSymbolicDifferentiation.symbolic_jacobian!(gr) setup = gr = to_graph($n)[1] evals = 1
        push!(output, preprocess_trial(trial, "$n"))
    end
    CSV.write(FSD_filename(SH_NAME, "symbolic", min_order, max_order, simplify), output)
    return output
end
export FSD_spherical_harmonics

function SH_symbolic_time(min_order, max_order, simplify=true)
    FSD_spherical_harmonics(min_order, max_order)
    Symbolics_spherical_harmonics(min_order, max_order, simplify)
end
export SH_symbolic_time


function SH_make_function_time(min_order, max_order, simplify=true)
    Symbolics_times = DataFrame()
    FSD_times = DataFrame()

    for n in min_order:1:max_order
        graph = to_graph(n)[1]
        tmp = Matrix{Float64}(undef, FastSymbolicDifferentiation.codomain_dimension(graph), FastSymbolicDifferentiation.domain_dimension(graph))

        trial = @benchmark jacobian_function!(gr, variables(gr); in_place=true) setup = gr = to_graph($n)[1] evals = 1
        push!(FSD_times, preprocess_trial(trial, "$n"))


        trial = @benchmark $create_Symbolics_exe($n, $simplify)
        push!(Symbolics_times, preprocess_trial(trial, "$n"))
        @info "Finished order $n"
    end
    CSV.write(Symbolics_filename(SH_NAME, MAKE_FUNCTION, min_order, max_order, simplify), Symbolics_times)
    CSV.write(FSD_filename(SH_NAME, MAKE_FUNCTION, min_order, max_order, simplify), FSD_times)
end
export SH_make_function_time


function SH_exe_time(min_order, max_order, simplify=true)
    Symbolics_times = DataFrame()
    FSD_times = DataFrame()

    for n in min_order:1:max_order
        graph = to_graph(n)[1]
        tmp = Matrix{Float64}(undef, FastSymbolicDifferentiation.codomain_dimension(graph), FastSymbolicDifferentiation.domain_dimension(graph))

        FSD_exe = jacobian_function!(graph, variables(graph); in_place=true)
        trial = @benchmark $FSD_exe(1.1, 2.3, 4.2, $tmp)
        push!(FSD_times, preprocess_trial(trial, "$n"))


        Symbolics_allocating, Symbolics_in_place = create_Symbolics_exe(n, simplify)
        trial = @benchmark $Symbolics_in_place($tmp, [1.1, 2.3, 4.2])
        push!(Symbolics_times, preprocess_trial(trial, "$n"))
        @info "Finished order $n"
    end
    CSV.write(Symbolics_filename(SH_NAME, EXE, min_order, max_order, simplify), Symbolics_times)
    CSV.write(FSD_filename(SH_NAME, EXE, min_order, max_order, simplify), FSD_times)
end
export SH_exe_time

function benchmark_spherical_harmonics(min_order, max_order, simplify=true)
    @info "Starting exe benchmark"
    SH_exe_time(min_order, max_order, simplify)
    @info "Starting make function benchmark"
    SH_make_function_time(min_order, max_order, simplify)
    @info "Starting symbolic benchmark"
    SH_symbolic_time(min_order, max_order, simplify)
end
export benchmark_spherical_harmonics

function plot_data(bench1, bench2, simplify)
    data1 = CSV.read(bench1, DataFrame)
    data2 = CSV.read(bench2, DataFrame)

    graph_title = "Ratio Symbolics/FSD time."
    # plot(data1[:, :SHOrder], data1[:, :minimum] / 1e6, ylabel="ms", xlabel="Spherical Harmonic Order")
    # plot!(data2[:, :SHOrder], data2[:, :minimum] / 1e6, ylabel="ms", xlabel="Spherical Harmonic Order")
    plot(data1[:, :SHOrder], data2[:, :minimum] ./ data1[:, :minimum], xlabel="Spherical Harmonic Order", ylabel="Ratio", title=graph_title, titlefontsizes=8, legend=false)
end
export plot_data



plot_SH_symbolic_time(min_order, max_order, simplify) = plot_data(
    FSD_filename(SH_NAME, "symbolic", min_order, max_order, simplify),
    Symbolics_filename(SH_NAME, "symbolic", min_order, max_order, simplify),
    simplify)
export plot_SH_symbolic_time

plot_SH_exe_time(min_order, max_order, simplify) = plot_data(
    FSD_filename(SH_NAME, EXE, min_order, max_order, simplify),
    Symbolics_filename(SH_NAME, EXE, min_order, max_order, simplify),
    simplify)
export plot_SH_exe_time

plot_SH_make_function_time(min_order, max_order, simplify) = plot_data(
    FSD_filename(SH_NAME, MAKE_FUNCTION, min_order, max_order, simplify),
    Symbolics_filename(SH_NAME, MAKE_FUNCTION, min_order, max_order, simplify),
    simplify)
export plot_SH_make_function_time
end # module Benchmarks