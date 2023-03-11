# This script is for setting up the REPL environment for development of the Differentation package. No use in production.

using FastSymbolicFastSymbolicDifferentiation
using FastSymbolicDifferentiation.TestCases
using FastSymbolicDifferentiation.SphericalHarmonics

using Symbolics

@variables x y z
nx = Node(x)
ny = Node(y)
nz = Node(z)