module FastDifferentiation

# using TermInterface
using StaticArrays
using SpecialFunctions
using NaNMath
# using Statistics
using RuntimeGeneratedFunctions
import Base: iterate
using UUIDs
using SparseArrays
using DataStructures


module AutomaticDifferentiation
struct NoDeriv
end
export NoDeriv
end #module

const INVARIANTS = true

"""
    @invariant ex msgs...

This macro is used to create invariant test code that is dependent on the global constant `INVARIANTS`. If `INVARIANTS` is false then the test code will not be inserted into the program and there will be no run time overhead. If `INVARIANTS` is true then the code will be inserted. Code that tests invariants tends to increase run time substantially so only set `INVARIANTS` true when you are debugging or testing."""
macro invariant(ex, msgs...)
    if INVARIANTS
        return :(@assert $(esc(ex)) $(esc(msgs)))
    end
end



RuntimeGeneratedFunctions.init(@__MODULE__)

const DefaultNodeIndexType = Int64

include("Methods.jl")
include("Utilities.jl")
include("BitVectorFunctions.jl")
include("ExpressionGraph.jl")
include("PathEdge.jl")
include("DerivativeGraph.jl")
include("Reverse.jl")
include("GraphProcessing.jl")
include("FactorableSubgraph.jl")
include("Factoring.jl")
include("Jacobian.jl")
include("CodeGeneration.jl")
# include("NonUnique.jl")

# FastDifferentiationVisualizationExt overloads them
function make_dot_file end
function draw_dot end
function write_dot end



function test()
    @variables x y z w u

    e1 = PathEdge(1, 2, x, BitVector([1, 0, 1]), BitVector([0, 0, 1]))
    e2 = PathEdge(3, 2, y, BitVector([1, 0, 0]), BitVector([0, 0, 1]))
    e3 = PathEdge(3, 2, z, BitVector([1, 1, 0]), BitVector([0, 0, 1]))
    e4 = PathEdge(3, 2, w, BitVector([1, 1, 0]), BitVector([1, 0, 1]))
    e5 = PathEdge(3, 2, u, BitVector([1, 1, 0]), BitVector([0, 1, 1]))


    path = [e1, e3, e2]   #2,2,1 times used
    println(multiply_sequence(path))
    @test (x * z) * y === multiply_sequence(path)
end
export test


end # module
