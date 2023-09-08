
"""
    sparsity(sym_func::AbstractArray{<:Node})


Computes a number representing the sparsity of the array of expressions. If `nelts` is the number of elements in the array and `nzeros` is the number of zero elements in the array
then `sparsity = (nelts-nzeros)/nelts`. 

Frequently used in combination with a call to `make_function` to determine whether to set keyword argument `init_with_zeros` to false."""
function sparsity(sym_func::AbstractArray{<:Node})
    zeros = mapreduce(x -> is_zero(x) ? 1 : 0, +, sym_func)
    tot = prod(size(sym_func))
    return zeros == 0 ? 1.0 : (tot - zeros) / tot
end
export sparsity

"""
    function_body!(
        dag::Node,
        variable_to_index::IdDict{Node,Int64},
        node_to_var::Union{Nothing,IdDict{Node,Union{Symbol,Real,Expr}}}=nothing
    )

Create body of Expr that will evaluate the function. The function body will be a sequence of assignment statements to automatically generated variable names. This is an example for a simple function:
```julia
quote
    var"##343" = 2x
    var"##342" = var"##343" + y
    var"##341" = var"##342" + 1
end
```
The last automatically generated name (in this example var"##341") is the second return value of `function_body`. This variable will hold the value of evaluating the dag at runtime.
If the dag is a constant then the function body will be empty:
```julia
quote
end
```
and the second return value will be the constant value.
"""
function function_body!(dag::Node, variable_to_index::IdDict{Node,Int64}, node_to_var::Union{Nothing,IdDict{Node,Union{Symbol,Real,Expr}}}=nothing)
    if node_to_var === nothing
        node_to_var = IdDict{Node,Union{Symbol,Real,Expr}}()
    end

    body = Expr(:block)

    function _dag_to_function(node)

        tmp = get(node_to_var, node, nothing)

        if tmp === nothing #if node not in node_to_var then it hasn't been visited. Otherwise it has so don't recurse.
            node_to_var[node] = node_symbol(node, variable_to_index)

            if is_tree(node)
                args = _dag_to_function.(children(node))
                statement = :($(node_to_var[node]) = $(Symbol(value(node)))($(args...)))
                push!(body.args, statement)
            end
        end

        return node_to_var[node]
    end

    return body, _dag_to_function(dag)
end

undef_array_declaration(::StaticArray{S,<:Any,N}) where {S,N} = :(result = MArray{$(S),promote_type(result_element_type, eltype(input_variables)),$N}(undef))
undef_array_declaration(func_array::Array{T,N}) where {T,N} = :(result = Array{result_element_type}(undef, $(size(func_array))))

return_expression(::SArray) = :(return SArray(result))
return_expression(::Array) = :(return result)

function _infer_numeric_eltype(array::AbstractArray{<:Node})
    eltype = Union{}
    for elt in array
        eltype = promote_type(eltype, typeof(numeric_value(elt)))
    end
    eltype
end


numeric_value(a::Node) = is_constant(a) ? a.node_value : NaN

"""Should only be called if `all_constants(func_array) == true`. Unpredictable results otherwise."""
function to_number(func_array::AbstractArray{T}) where {T<:Node}
    #find type
    element_type = _infer_numeric_eltype(func_array)
    tmp = similar(func_array, element_type)
    @. tmp = numeric_value(func_array)
    return tmp
end

function to_number(func_array::SparseMatrixCSC{T}) where {T<:Node}
    nz = nonzeros(func_array)
    element_type = _infer_numeric_eltype(nz)
    tmp = similar(nz, element_type)
    @. tmp = numeric_value(nz)
    return tmp
end


"""
    make_Expr(
        func_array::AbstractArray{<:Node},
        input_variables::AbstractVector{<:Node},
        in_place::Bool,
        init_with_zeros::Bool
    )
"""
function make_Expr(func_array::AbstractArray{T}, input_variables::AbstractVector{S}, in_place::Bool, init_with_zeros::Bool) where {T<:Node,S<:Node}
    zero_threshold = 0.8
    zero_mask = is_zero.(func_array)
    nonzero_const_mask = is_constant.(func_array) .& .!zero_mask

    zero_keys = findall(zero_mask)
    nonzero_const_keys = findall(nonzero_const_mask)
    nonzero_const_values = to_number(func_array)

    node_to_var = IdDict{Node,Union{Symbol,Real,Expr}}()
    node_to_index = IdDict{Node,Int64}()
    for (i, node) in pairs(input_variables)
        node_to_index[node] = i
    end

    body = Expr(:block)

    # declare result element type, and result variable if not provided by the user
    if in_place && init_with_zeros && !isempty(zero_keys)
        push!(body.args, :(result_element_type = eltype(input_variables)))
    elseif !in_place
        push!(body.args, :(result_element_type = promote_type($(_infer_numeric_eltype(func_array)), eltype(input_variables))))
        push!(body.args, undef_array_declaration(func_array))
    end

    # set all zeros in one shot
    if !in_place || init_with_zeros
        mostly_zeros = length(zero_keys) > zero_threshold * length(func_array)
        if mostly_zeros
            # the result is clearly dominated by zeros so we don't bother to mask out the exact places
            push!(body.args, :(result .= zero(result_element_type)))
        elseif !isempty(zero_keys)
            push!(body.args, :(result[$zero_keys] .= zero(result_element_type)))
        end
    end

    # set all nonzero constants in one shot
    is_all_nonzero_constants = length(nonzero_const_keys) == length(func_array)
    if is_all_nonzero_constants
        push!(body.args, :(result .= $nonzero_const_values))
    elseif !isempty(nonzero_const_keys)
        push!(body.args, :(result[$nonzero_const_keys] .= $(nonzero_const_values[nonzero_const_keys])))
    end


    for (i, node) in pairs(func_array)
        # skip all terms that we have computed above during construction
        if zero_mask[i] || nonzero_const_mask[i]
            continue
        end
        node_body, variable = function_body!(node, node_to_index, node_to_var)
        for arg in node_body.args
            push!(body.args, arg)
        end
        push!(body.args, :(result[$i] = $variable))
    end

    # return result or nothing if in_place
    if in_place
        push!(body.args, :(return nothing))
    else
        push!(body.args, return_expression(func_array))
    end

    # wrap in function body
    if in_place
        return :((result, input_variables) -> @inbounds begin
            $body
        end)
    else
        return :((input_variables) -> @inbounds begin
            $body
        end)
    end
end
export make_Expr

"""
    make_Expr(
        A::SparseMatrixCSC{<:Node,<:Integer},
        input_variables::AbstractVector{<:Node},
        in_place::Bool, init_with_zeros::Bool
    )

`init_with_zeros` argument is not used for sparse matrices."""
function make_Expr(A::SparseMatrixCSC{T,Ti}, input_variables::AbstractVector{S}, in_place::Bool, init_with_zeros::Bool) where {T<:Node,S<:Node,Ti}
    rows = rowvals(A)
    vals = nonzeros(A)
    _, n = size(A)
    body = Expr(:block)
    node_to_var = IdDict{Node,Union{Symbol,Real,Expr}}()

    if !in_place #have to store the sparse vector indices in the generated code to know how to create sparsity pattern
        push!(body.args, :(element_type = promote_type(Float64, eltype(input_variables))))
        push!(body.args, :(result = SparseMatrixCSC($(A.m), $(A.n), $(A.colptr), $(A.rowval), zeros(element_type, $(length(A.nzval))))))
    end

    push!(body.args, :(vals = nonzeros(result)))

    num_consts = count(x -> is_constant(x), vals)
    if num_consts == nnz(A) #all elements are constant
        push!(body.args, :(vals .= $(to_number(A))))
        if in_place
            return :((result, input_variables) -> $body)
        else
            return :((input_variables) -> $body)
        end
    else
        node_to_index = IdDict{Node,Int64}()
        for (i, node) in pairs(input_variables)
            node_to_index[node] = i
        end

        for j = 1:n
            for i in nzrange(A, j)
                node_body, variable = function_body!(vals[i], node_to_index, node_to_var)
                for arg in node_body.args
                    push!(body.args, arg)
                end
                push!(node_body.args,)

                push!(body.args, :(vals[$i] = $variable))
            end
        end

        push!(body.args, :(return result))

        if in_place
            return :((result, input_variables) -> $body)
        else
            return :((input_variables) -> $body)
        end
    end
end
export make_Expr

"""
    make_function(
        func_array::AbstractArray{<:Node},
        input_variables::AbstractVector{<:Node}...;
        in_place::Bool=false, init_with_zeros::Bool=true
    )

Makes a function to evaluate the symbolic expressions in `func_array`. Every variable that is used in `func_array` must also be in `input_variables`. However, it will not cause an error if variables in `input_variables` are not variables used by `func_array`.

```julia
julia> @variables x
x

julia> f = x+1
(x + 1)


julia> jac = jacobian([f],[x]) #the Jacobian has a single constant element, 1, and is no longer a function of x
1×1 Matrix{FastDifferentiation.Node}:
 1

 julia> fjac = make_function(jac,[x])
 ...
 
 julia> fjac(2.0) #the value 2.0 is passed in for the variable x but has no effect on the output. Does not cause a runtime exception.
 1×1 Matrix{Float64}:
  1.0
```

If `in_place=false` then a new array will be created to hold the result each time the function is called. If `in_place=true` the function expects a user supplied array to hold the result. The user supplied array must be the first argument to the function.

```julia
julia> @variables x
x

julia> f! = make_function([x,x^2],[x],in_place=true)
...

julia> result = zeros(2)
2-element Vector{Float64}:
 0.0
 0.0

julia> f!(result,[2.0])
4.0

julia> result
2-element Vector{Float64}:
 2.0
 4.0
```

If the array is sparse then the keyword argument `init_with_zeros` has no effect. If the array is dense and `in_place=true` then the keyword argument `init_with_zeros` affects how the in place array is initialized. If `init_with_zeros = true` then the in place array is initialized with zeros. If `init_with_zeros=false` it is the user's responsibility to initialize the array with zeros before passing it to the runtime generated function.

This can be useful for modestly sparse dense matrices with say at least 1/4 of the array entries non-zero. In this case a sparse matrix may not be as efficient as a dense matrix. But a large fraction of time could be spent unnecessarily setting elements to zero. In this case you can initialize the in place Jacobian array once with zeros before calling the run time generated function.
"""
function make_function(func_array::AbstractArray{T}, input_variables::AbstractVector{<:Node}...; in_place::Bool=false, init_with_zeros::Bool=true) where {T<:Node}
    vars = variables(func_array) #all unique variables in func_array
    all_input_vars = vcat(input_variables...)

    @assert vars ⊆ all_input_vars "Some of the variables in your function (the func_array argument) were not in the input_variables argument. Every variable that is used in your function must have a corresponding entry in the input_variables argument."

    @RuntimeGeneratedFunction(make_Expr(func_array, all_input_vars, in_place, init_with_zeros))
end
export make_function

