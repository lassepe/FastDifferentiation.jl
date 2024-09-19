# FastDifferentiation

[![Build Status](https://github.com/brianguenter/FastDifferentiation.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/brianguenter/FastDifferentiation.jl/actions/workflows/CI.yml?query=branch%3Amain) [![](https://img.shields.io/badge/docs-stable-blue.svg)](https://brianguenter.github.io/FastDifferentiation.jl/stable) [![](https://img.shields.io/badge/docs-dev-blue.svg)](https://brianguenter.github.io/FastDifferentiation.jl/dev)

***WARNING v0.4.0 has a major bug and should not be used. A patch will be issued soon. Until then revert to 0.3.17 if you upgraded to 0.40**

FastDifferentiation (**FD**) is a package for generating efficient executables to evaluate derivatives of Julia functions. It can also generate efficient true symbolic derivatives for symbolic analysis. 

Unlike forward and reverse mode automatic differentiation **FD** automatically generates efficient derivatives for arbitrary function types: ℝ¹->ℝ¹, ℝ¹->ℝᵐ, ℝⁿ->ℝ¹, and ℝⁿ->ℝᵐ, m≠1,n≠1. **FD** is similar to [D*](https://www.microsoft.com/en-us/research/publication/the-d-symbolic-differentiation-algorithm/) in that it uses the derivative graph[^a] but **FD** is asymptotically faster so it can be applied to much larger expression graphs.

For f:ℝⁿ->ℝᵐ with n,m large FD may have better performance than conventional AD algorithms because the **FD** algorithm finds expressions shared between partials and computes them only once. In some cases **FD** derivatives can be as efficient as manually coded derivatives (see the Lagrangian dynamics example in the [D*](https://www.microsoft.com/en-us/research/publication/the-d-symbolic-differentiation-algorithm/) paper or the Benchmarks section of the documentation for another example).

 **FD** may take much less time to compute symbolic derivatives than Symbolics.jl even in the ℝ¹->ℝ¹ case. The executables generated by **FD** may also be much faster (see the documentation for more details). 

You should consider using FastDifferentiation when you need: 
* a fast executable for evaluating the derivative of a function and the overhead of the preprocessing/compilation time is swamped by evaluation time.
* to do additional symbolic processing on your derivative. **FD** can generate a true symbolic derivative to be processed further in Symbolics.jl or another computer algebra system.

This is the **FD** feature set:

<table>
<tr>
<td> <b></b>
<td> <b>Dense Jacobian</b> <td>  <b>Sparse Jacobian</b> </td> 
<td>  <b>Dense Hessian</b> </td><td>  <b> Sparse Hessian</b> </td> 
<td>  <b>Higher order derivatives</b> </td> 
<td>  <b>Jᵀv</b> </td> 
<td>  <b>Jv</b> </td> 
<td> <b> Hv </b> </td>
</tr>
<tr>
<td> <b> Compiled function </b> </td> 
<td> ✅ </td>
<td> ✅ </td>
<td> ✅ </td>
<td> ✅  </td>
<td> ✅ </td>
<td> ✅ </td>
<td> ✅ </td>
<td> ✅ </td>
</tr>
<tr>
<td> <b> Symbolic expression </b> </td> 
<td> ✅ </td>
<td> ✅ </td>
<td> ✅ </td>
<td> ✅  </td>
<td> ✅ </td>
<td> ✅ </td>
<td> ✅ </td>
<td> ✅ </td>
</tr>

</table>

Jᵀv and Jv compute the Jacobian transpose times a vector and the Jacobian times a vector, without explicitly forming the Jacobian matrix. For applications see this [paper](https://arxiv.org/abs/1812.01892). Hv computes the Hessian times a vector without explicitly forming the Hessian matrix.

See the documentation for more information on the capabilities and limitations of **FD**.

If you use FD in your work please share the functions you differentiate with me. I'll add them to the benchmarks. The more functions available to test the easier it is for others to determine if FD will help with their problem.

## FAQ

**Q**: Does **FD** support complex numbers?  
**A**: Not currently.

**Q**: You say **FD** computes efficient derivatives but the printed version of my symbolic derivatives is very long. How can that be efficient?  
**A**: **FD** stores and evaluates the common subexpressions in your function just once. But, the print function recursively descends through all expressions in the directed acyclic graph representing your function, including nodes that have already been visited. The printout can be exponentially larger than the internal **FD** representation.

**Q**: How about matrix and tensor expressions?  
**A**: If you multiply a matrix of **FD** variables times a vector of **FD** variables the matrix vector multiplication loop is effectively unrolled into scalar expressions. Matrix operations on large matrices will generate large executables and long preprocessing time. **FD** functions with up 10⁵ operations should still have reasonable preprocessing/compilation times (approximately 1 minute on a modern laptop) and good run time performance.

**Q**: Does **FD** support conditionals?  
**A**: As of version 0.4.1 **FD** expressions may contain conditionals which involve variables. However, you cannot yet differentiate an expression containing conditionals. A future PR will allow you to differentiate conditional expressions. 

You can use either the builtin `ifelse` function or a new function `if_else`. `ifelse` will evaluate both the true and false branches. By contrast `if_else` has the semantics of `if...else...end`; only one of the true or false branches will be executed. 

This is useful when your conditional is used to prevent exceptions because of illegal input values:
```julia
julia> f = if_else(x<0,NaN,sqrt(x))
(if_else  (x < 0) NaN sqrt(x))

julia> g = make_function([f],[x])


julia> g([-1])
1-element Vector{Float64}:
 NaN

julia> g([2.0])
1-element Vector{Float64}:
 1.4142135623730951
end
```
In this case you wouldn't want to use `ifelse` because it evaluates both the true and false branches and causes a runtime exception:
```julia
julia> f = ifelse(x<0,NaN,sqrt(x))
(ifelse  (x < 0) NaN sqrt(x))

julia> g = make_function([f],[x])
...

julia> g([-1])
ERROR: DomainError with -1.0:
sqrt was called with a negative real argument but will only return a complex result if called with a complex argument. Try sqrt(Complex(x)).
```

However, you cannot yet compute derivatives of expressions that contain conditionals:
```julia
julia> jacobian([f],[x,y])
ERROR: Your expression contained ifelse. FastDifferentiation does not yet support differentiation through ifelse or any of these conditionals (max, min, copysign, &, |, xor, <, >, <=, >=, !=, ==, signbit, isreal, iszero, isfinite, isnan, isinf, isinteger, !)
```

# Release Notes
<details>
v0.3.2 - make_function now generates functions that have much faster LLVM compile time for all constant input arguments. It now generates code to do this

result = [c1,c2,....]

instead of assigning every element of the array in code:

#old way
result[1] = c1
result[2] = c2
...

This is especially useful for large constant Jacobians. LLVM code generation in the old method could take a very long time (many minutes for constant Jacobians with 100,000+ entries). make_function and LLVM code generation time for constant Jacobians is now much faster, on the order of 20 seconds for a 10000x10000 constant dense Jacobian.

Better algebraic simplification of sums of products. Now this input expression `3x + 5x` will be simplified to `8x`. Before it was left as `3x + 5x`.

v0.3.1 - Code generation is smarter about initializing in place arrays with zeros. Previously it initialized all array elements even if most of them not identically zero and would be set to a properly defined value elsewhere in the code. This especially improves performance for functions where no or few elements are identically zero.

v0.3.0 - BREAKING CHANGE. `make_function` called with `in_place` = true now returns an anonymous function which takes the in place result matrix as the first argument. Prior to this the result matrix was the second argument.

```julia
function main()
     x = FD.make_variables(:x, 5)
     y = FD.make_variables(:y, 5)

     f! = FD.make_function([sum(x), sum(y)], x, y; in_place=true)

     result = zeros(2)
     x = rand(5)
     y = rand(5)

     f!(result, [x; y]) #in place matrix argument now comes first instead of second.
     #f!([x;y], result) #this used to work but now will raise an exception 
     # unless [x;y] and result are the same size in which case the answer will just be wrong.
     return result, (sum(x), sum(y))
end
```

v0.2.9: Added `init_with_zeros` keyword argument to make_function. If this argument is false then the runtime generated function will not zero the in place array, otherwise it will. 

This can significantly improve performance for matrices that are somewhat sparse (say 3/4 of elements identically zero) but not sparse enough that a sparse matrix is efficient. In cases like this setting array elements to zero on every call to the runtime generated function can take more time than evaluating the non-zero array element expressions. 
     
This argument is only active if rhe `in_place` argument is true. 
</details>


[^a]: See the [D* ](https://www.microsoft.com/en-us/research/publication/the-d-symbolic-differentiation-algorithm/) paper for an explanation of derivative graph factorization. 

