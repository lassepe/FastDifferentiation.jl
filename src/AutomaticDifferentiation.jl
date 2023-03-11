module AutomaticDifferentiation
struct NoDeriv
end
export NoDeriv
end #module
export AutomaticDifferentiation

#until I can think of a better way of structing the caching operation it will be a single global expression cache. This precludes multithreading, unfortunately.
EXPRESSION_CACHE = IdDict()

function check_cache(a::Tuple{Vararg}, cache)
    cache_val = get(cache, a, nothing)
    if cache_val === nothing
        cache[a] = Node(a[1], a[2:end]...) #this should wrap everything, including basic numbers, in a Node object
    end

    return cache[a]
end

"""Clears the global expression cache. To maximize efficiency of expressions the differentation system automatically eliminates common subexpressions by checking for there existence in the global expression cache. Over time this cache can become arbitrarily large. Best practice is to clear the cache before you start defining expressions, define your expressions and then clear the cache."""
clear_cache() = empty!(EXPRESSION_CACHE)
export clear_cache


# #if I want to eventually define my own @variables macro 
# #Add the code in this block
#
# macro nvariables(args)
#     tmp = Expr(:block)
#     for x in args.args
#         println(x)
#         println(typeof(x))
#         push!(tmp.args, :($(esc(x)) = Node($(Meta.quot(x)))))
#     end
#     tmp
# end
# export @nvariables

# #also add this inner constructor
# Node(a::S) where {S<:Symbol} = new{S,0}(a)
#
# #end of code block to add

struct Node{T,N}
    node_value::T
    children::Union{MVector{N,Node},Nothing} #initially used SVector but this was incredibly inefficient. Possibly because the compiler was inlining the entire graph into a single static structure, which could lead to very long == and hashing times.

    Node(f::S, a) where {S} = new{S,1}(f, MVector{1}(Node(a)))
    Node(f::S, a, b) where {S} = new{S,2}(f, MVector{2}(Node(a), Node(b))) #if a,b not a Node convert them.

    Node(a::T) where {T<:Real} = new{T,0}(a, nothing) #convert numbers to Node
    Node(a::T) where {T<:Node} = a #if a is already a special node leave it alone

    Node(a::AutomaticDifferentiation.NoDeriv) = new{AutomaticDifferentiation.NoDeriv,0}(a, nothing) #TODO: this doesn't seem like it should ever be called.

    function Node(operation, args::MVector{N,T}) where {T<:Node,N} #use MVector rather than Vector. 40x faster.
        ntype = typeof(operation)
        return new{ntype,N}(operation, args)
    end

    Node(a::SymbolicUtils.BasicSymbolic{Real}) = new{typeof(a),0}(a, nothing)


end
export Node

"""ensure that no Node has a node_value of Num type. Extract either the number or BasicSymbolic type and use that instead"""
Node(a::Num) = Node(a.val)


#convenience function to extract the fields from Node object to check cache
function check_cache(a::Node{T,N}, cache) where {T,N}
    if node_children(a) !== nothing
        check_cache((node_value(a), node_children(a)...), cache)
    else
        check_cache((a,), cache)
    end
end


SymbolicUtils.islike(::Node{T}, ::Type{Number}) where {T} = true
Base.zero(::Type{Node}) = Node(0)
Base.zero(::Node) = Node(0)
Base.one(::Type{Node}) = Node(1)
Base.one(::Node) = Node(1)

node_value(a::Node) = a.node_value
export node_value
arity(::Node{T,N}) where {T,N} = N
export arity

is_leaf(::Node{T,0}) where {T} = true
is_leaf(::Node{T,N}) where {T,N} = false
export is_leaf
is_tree(::Node{T,N}) where {T,N} = N >= 1
export is_tree


is_variable(a::Node) = SymbolicUtils.issym(node_value(a))
export is_variable

is_constant(a::Node) = !is_variable(a) && !is_tree(a) #pretty confident this is correct but there may be edges cases in Symbolics I am not aware of.
export is_constant

function is_zero(a::Node)
    if is_tree(a) || is_variable(a)
        return false
    elseif node_value(a) == 0 #may think could just do this test but in Symbolics x==0 x*x == 0 is a non-boolean expression.
        return true
    else
        return false
    end
end
export is_zero

function is_one(a::Node)
    if is_tree(a) || is_variable(a)
        return false
    elseif node_value(a) == 1 #may think could just do this test but in Symbolics x==1 or x*x == 1 is a non-boolean expression.
        return true
    else
        return false
    end
end
export is_one

#Simple algebraic simplification rules for *,+,-,/. These are mostly safe, i.e., they will return exactly the same results as IEEE arithmetic. However multiplication by 0 always simplifies to 0, which is not true for IEEE arithmetic: 0*NaN=NaN, 0*Inf = NaN, for example. This should be a good tradeoff, since zeros are common in derivative expressions and can result in considerable expression simplification. Maybe later make this opt-out.

simplify_check_cache(a, b, c, cache) = check_cache((a, b, c), cache)

is_nary(a::Node{T,N}) where {T,N} = N > 2
is_times(a::Node) = node_value(a) == *
export is_times

is_nary_times(a::Node) = is_nary(a) && node_value(a) == typeof(*)
export is_nary_times

function simplify_check_cache(::typeof(*), na, nb, cache)
    a = Node(na)
    b = Node(nb)

    #TODO sort variables so if y < x then x*y => y*x. The will automatically get commutativity.
    #TODO add another check that moves all constants to the left and then does constant propagation
    #c1*c2 = c3, (c1*x)*(c2*x) = c3*x
    if is_zero(a) && is_zero(b)
        return Node(zero(promote(node_value(a), node_value(b)))) #user may have mixed types for numbers so use the widest type.
    elseif is_zero(a) #b is not zero
        return a #use this node rather than creating a zero since a has the type encoded in it
    elseif is_zero(b) #a is not zero
        return b #use this node rather than creating a zero since b has the type encoded in it
    elseif is_one(a)
        return b #At this point in processing the type of b may be impossible to determine, for example if b = sin(x) and the value of x won't be known till the expression is evaluated. No easy way to promote the type of b here if a has a wider type than b will eventually be determined to have. Example: a = BigFloat(1.0), b = sin(x). If the value of x is Float32 when the function is evaluated then would expect the type of the result to be BigFloat. But it will be Float32. Need to figure out a type of Node that will eventually generate code something like this: b = promote_type(a,b)(b) where the types of a,b will be known because this will be called in the generated Julia function for the derivative.
    elseif is_one(b)
        return a
    elseif is_constant(a) && is_constant(b)
        return Node(node_value(a) * node_value(b)) #this relies on the fact that objectid(Node(c)) == objectid(Node(c)) where c is a constant so don't have to check cache.
    else
        return check_cache((*, a, b), cache)
    end
end
export simplify_check_cache

function simplify_check_cache(::typeof(+), na, nb, cache)
    a = Node(na)
    b = Node(nb)

    #TODO sort variables so if y < x then x*y => y*x. The will automatically get commutativity.
    #TODO add another check that moves all contants to the left and then does constant propagation
    #c1 + c2 = c3, (c1 + x)+(c2 + x) = c3+x

    if is_zero(a)
        return b
    elseif is_zero(b)
        return a
    elseif is_constant(a) && is_constant(b)
        return Node(node_value(a) + node_value(b))
    else
        return check_cache((+, a, b), cache)
    end
end

function simplify_check_cache(::typeof(/), na, nb, cache)
    a = Node(na)
    b = Node(nb)
    a, b = promote(a, b)

    if is_one(b)
        return one(a) #returns the promoted type of a,b. Believe this is the desirable action.
    elseif is_constant(a) && is_constant(b)
        return Node(node_value(a) / node_value(b))
    else
        return check_cache((/, a, b), cache)
    end
end

function simplify_check_cache(::typeof(-), na, nb, cache)
    a = Node(na)
    b = Node(nb)
    if is_zero(b)
        return a
    elseif is_zero(a)
        return -b
    elseif is_constant(a) && is_constant(b)
        return Node(node_value(a) - node_value(b))
    else
        return check_cache((-, a, b), cache)
    end
end

SymbolicUtils.@number_methods(Node, check_cache((f, a), EXPRESSION_CACHE), simplify_check_cache(f, a, b, EXPRESSION_CACHE)) #create methods for standard functions that take Node instead of Number arguments. Check cache to see if these arguments have been seen before.

#TODO: probably want to add boolean operations so can sort Nodes.
# binary ops that return Bool
# for (f, Domain) in [(==) => Number, (!=) => Number,
#     (<=) => Real,   (>=) => Real,
#     (isless) => Real,
#     (<) => Real,   (> ) => Real,
#     (& ) => Bool,   (| ) => Bool,
#     xor => Bool]
# @eval begin
# promote_symtype(::$(typeof(f)), ::Type{<:$Domain}, ::Type{<:$Domain}) = Bool
# (::$(typeof(f)))(a::Symbolic{<:$Domain}, b::$Domain) = term($f, a, b, type=Bool)
# (::$(typeof(f)))(a::Symbolic{<:$Domain}, b::Symbolic{<:$Domain}) = term($f, a, b, type=Bool)
# (::$(typeof(f)))(a::$Domain, b::Symbolic{<:$Domain}) = term($f, a, b, type=Bool)
# end
# end

# struct Differential
#     expression::Differentiation.Node #expression to take derivative of
#     with_respect_to::Differentiation.Node #variable or internal node to take derivative wrt
# end

# derivative(f, args, v) = NoDeriv()

rules = Any[]

Base.push!(a::Vector{T}, b::Number) where {T<:Node} = push!(a, Node(b)) #there should be a better way to do this.

Base.convert(::Type{Node}, a::T) where {T<:Real} = Node(a)
Base.promote_rule(::Type{<:Real}, ::Type{<:Node}) = Node


# Pre-defined derivatives
import DiffRules
for (modu, fun, arity) ∈ DiffRules.diffrules(; filter_modules=(:Base, :SpecialFunctions, :NaNMath))
    fun in [:*, :+, :abs, :mod, :rem, :max, :min] && continue # special
    for i ∈ 1:arity

        expr = if arity == 1
            DiffRules.diffrule(modu, fun, :(args[1]))
        else
            DiffRules.diffrule(modu, fun, ntuple(k -> :(args[$k]), arity)...)[i]
        end
        push!(rules, expr)
        # @eval derivative(::typeof($modu.$fun), args::NTuple{$arity,Any}, ::Val{$i}) = $expr 
        @eval derivative(::typeof($modu.$fun), args::NTuple{$arity,Any}, ::Val{$i}) = check_cache($expr, EXPRESSION_CACHE)
    end
end

#need to define because derivative functions can return inv
Base.inv(a::Node{typeof(/),2}) = node_children(a)[2] / node_children(a)[1]

#efficient explicit methods for most common cases
derivative(a::Node{T,1}, index::Val{1}) where {T} = derivative(node_value(a), (node_children(a)[1],), index)
derivative(a::Node{T,2}, index::Val{1}) where {T} = derivative(node_value(a), (node_children(a)[1], node_children(a)[2]), index)
derivative(a::Node{T,2}, index::Val{2}) where {T} = derivative(node_value(a), (node_children(a)[1], node_children(a)[2]), index)
derivative(a::Node, index::Val{i}) where {i} = derivative(node_value(a), (node_children(a)...,), index)
export derivative

function derivative(::typeof(*), args::NTuple{N,Any}, ::Val{I}) where {N,I}
    if N == 2
        return I == 1 ? args[2] : args[1]
    else
        return Node(*, deleteat!(collect(args), I)...)
    end
end

derivative(::typeof(+), args::NTuple{N,Any}, ::Val{I}) where {I,N} = Node(1)

# Special cases for leaf nodes with no children. Handles the case when the node value is a Symbolics Num value, which can be either a symbol or a number.
function derivative(a::Node{T,0}) where {T}
    if SymbolicUtils.issym(node_value(a))
        return Node(1)
    else
        return Node(0)
    end
end



"""returns the leaf variables in a DAG. If a leaf is a Sym the assumption is that it is a variable. Leaves can also be numbers, which are not variables. Not certain how robust this is."""
variables(node::Node) = filter((x) -> is_variable(x), graph_leaves(node)) #SymbolicUtils changed, used to use SymbolicUtils.Sym for this test.
export variables

# isvariable(a::Node) = SymbolicUtils.issym(node_value(a))
# # isvariable(::Node{T,0}) where {T<:SymbolicUtils.Sym} = true
# export isvariable
# # isvariable(::Node) = false

node_children(a::Node) = a.children
export node_children

function Base.show(io::IO, a::Node)
    print(io, to_string(a))
end

function to_string(a::Node)
    function node_id(b::Node)
        # return "Node:$(b.node_value) id:$(objectid(b))"
        return "$(b.node_value)"
    end

    if arity(a) == 0
        return "$(node_id(a))"
    else
        if arity(a) == 1
            return "$(node_id(a))($(to_string(a.children[1])))"
        else
            if arity(a) == 2
                return "($(to_string(a.children[1])) $(node_id(a)) $(to_string(a.children[2])))"
            else #Symbolics has expressions like +,* that can have any number of arguments, which translates to any number of Node children.
                return "($(a.node_value) $(foldl((x,y) -> x * " " * y,to_string.(a.children), init = "")))" #this is probably incredibly inefficient since it's O(n^2) in the length of the expression. Presumably there won't be many expresssions x+y+z+....., that are incredibly long. Best bet don't print out giant expressions.
            end
        end
    end
end
export to_string

expr_to_dag(x::NoDeriv, cache, substitions) = Node(NaN) #when taking the derivative with respect to the first element of 1.0*x Symbolics.derivative will return Symbolics.NoDeriv. These derivative values will never be used (or should never be used) in my derivative computation so set to NaN so error will show up if this ever happens.

function expr_to_dag(x::Real, cache::IdDict=IdDict(), substitutions::Union{IdDict,Nothing}=nothing)
    return _expr_to_dag(x, cache, substitutions)
end
export expr_to_dag


#WARNING!!!!!!! TODO. *,+ simplification code relies on Node(0) have node_value 0 as Int64, not wrapped in a Num. Need to make sure that expr_to_dag unwraps numbers or the simplification code won't work.
function _expr_to_dag(symx, cache::IdDict, substitutions::Union{IdDict,Nothing}) #cache is an IdDict, to make clear that hashing into the cache Dict is  based on objectid, i.e., using === rather than ==.
    # Substitutions are done on a Node graph, not a SymbolicsUtils.Sym graph. As a consequence the values
    # in substitutions Dict are Node not Sym type. cache has keys (op,args...) where op is generally a function type but sometimes a Sym, 
    # and args are all Node types.

    #need to extract the SymbolicUtils tree from symx

    if isa(symx, Num) #substitutions are stored as SymbolicUtils.Symx so extract the underlying Symx value
        symx = symx.val
    end


    if substitutions !== nothing

        tmpsub = get(substitutions, symx, nothing)
        if tmpsub !== nothing
            return substitutions[symx] #substitute Node object for symbolic object created in differentiation
        end
    end

    tmp = get(cache, symx, nothing)

    if tmp !== nothing
        return tmp
    elseif !SymbolicUtils.istree(symx)

        tmpnode = Node(symx)
        cache[symx] = tmpnode

        return tmpnode
    else
        numargs = length(SymbolicUtils.arguments(symx))
        symargs = MVector{numargs}(SymbolicUtils.arguments(symx))


        #Taking Ref(nothing) causes the broadcasting to screw up for some reason. need two cases on for subsitutions === nothing and one for it being an IdDict.
        if substitutions === nothing
            args = _expr_to_dag.(symargs, Ref(cache), substitutions)
        else
            args = _expr_to_dag.(symargs, Ref(cache), Ref(substitutions))
        end

        key = (SymbolicUtils.operation(symx), args...)
        tmp = get(cache, key, nothing)

        if tmp !== nothing
            return tmp
        else
            tmpnode = Node(SymbolicUtils.operation(symx), args)
            cache[key] = tmpnode

            return tmpnode
        end
    end
end

function node_symbol(a::Node)
    if is_tree(a)
        result = gensym() #create a symbol to represent the node
    elseif is_variable(a)
        result = nameof(node_value(a))  #use the name of the Symbolics symbol which represents the variable
    else
        result = node_value(a) #not a tree not a variable so is some kind of constant. Symbolics represents constants as Num so extract value so returned function will return a conventional number, not a Num.
    end
    return result
end


"""Create body of Expr that will evaluate the function"""
function function_body(dag::Node, node_to_var::Union{Nothing,Dict{Node,Union{Symbol,Real}}}=nothing)
    if node_to_var === nothing
        node_to_var = Dict{Node,Union{Symbol,Real}}()
    end

    body = Expr(:block)

    function _dag_to_function(node)

        tmp = get(node_to_var, node, nothing)

        if tmp === nothing
            node_to_var[node] = node_symbol(node)

            if is_tree(node)
                args = _dag_to_function.(node_children(node))
                statement = :($(node_to_var[node]) = $(Symbol(node_value(node)))($(args...)))
                push!(body.args, statement)
            end
        end

        return node_to_var[node]
    end

    return body, _dag_to_function(dag)
end

# # NOTE: if the dag is Node(x) or Node(1) then this will return a function that returns nothing. TODO: think about whether this is correct or whether want to make dag_to_function(Node(x)) return a function with one argument that returns that argument and dag_to_function(Node(1)) return a function with no arguments that returns 1. Not sure if this is necessary.
dag_to_function(dag::Node, variable_order::Union{T,Nothing}=nothing, node_to_var::Union{Nothing,Dict{Node,Union{Symbol,Real}}}=nothing) where {T<:AbstractVector{Num}} = @RuntimeGeneratedFunction(dag_to_Expr(dag, variable_order, node_to_var))
export dag_to_function
dag_to_function(a::Num, variable_order::Union{T,Nothing}=nothing) where {T<:AbstractVector{Num}} = dag_to_function(expr_to_dag(a), variable_order)

"""`variable_order` contains `Symbolics` variables in the order you want them to appear in the generated function. You can have more variables in `variable_order` than are present in the dag. Those input variables to the generated function will have no effect on the output."""
function dag_to_Expr(dag::Node, variable_order::Union{T,Nothing}=nothing, node_to_var::Union{Nothing,Dict{Node,Union{Symbol,Real}}}=nothing) where {T<:AbstractVector{Num}}
    if node_to_var === nothing
        node_to_var = Dict{Node,Union{Symbol,Real}}()
    end

    all_vars = variables(dag)
    if variable_order === nothing
        ordering = all_vars
    else
        ordering = Node.(variable_order)
    end

    @assert Set(all_vars) ⊆ Set(ordering) "Not every variable in the graph had a corresponding ordering variable."

    body, variable = function_body(dag, node_to_var)
    push!(body.args, :(return $variable))

    return Expr(:->, Expr(:tuple, map(x -> node_symbol(x), ordering)...), body)
end
export dag_to_function

"""converts from dag to Symbolics expression"""
function dag_to_Symbolics_expression(a::Node)
    if arity(a) === 0
        return Num(node_value(a)) #convert everything to Num type. This will wrap types like Int64,Float64, etc., but will not double wrap nodes that are Num types already.
    else
        if arity(a) === 1
            return a.node_value(dag_to_Symbolics_expression(a.children[1]))
        else
            return foldl(a.node_value, dag_to_Symbolics_expression.(a.children))
        end
    end
end
export dag_to_Symbolics_expression

"""Used to postorder function with multiple outputs"""
function postorder(roots::AbstractVector{T}) where {T<:Node}
    node_to_index = IdDict{Node,Int64}()
    nodes = Vector{Node}(undef, 0)
    variables = Vector{Node}(undef, 0)

    for root in roots
        _postorder_nodes!(root, nodes, variables, node_to_index)
    end
    return node_to_index, nodes, variables
end
export postorder


"""returns vector of `Node` entries in the tree in postorder, i.e., if `result[i] == a::Node` then the postorder number of `a` is`i`. Not Multithread safe."""
function _postorder_nodes!(a::Node{T,N}, nodes::AbstractVector{S}, variables::AbstractVector{S}, visited::IdDict{Node,Int64}) where {T,N,S<:Node}
    if get(visited, a, nothing) === nothing
        if a.children !== nothing
            for child in a.children
                _postorder_nodes!(child, nodes, variables, visited)
            end
        elseif is_variable(a)
            push!(variables, a)
        end
        push!(nodes, a)
        visited[a] = length(keys(visited)) + 1 #node has not been added to visited yet so the count will be one less than needed.
    end
    return nothing
end

"""finds all the nodes in the graph and the number of times each node is visited in DFS."""
function all_nodes(a::Node, index_type=DefaultNodeIndexType)
    visited = Dict{Node,index_type}()
    nodes = Vector{Node}(undef, 0)

    _all_nodes!(a, visited, nodes)
    return nodes
end
export all_nodes

function _all_nodes!(node::Node, visited::Dict{Node,T}, nodes::Vector{Node}) where {T<:Integer}
    tmp = get(visited, node, nothing)
    if tmp === nothing
        push!(nodes, node) #only add node to nodes once.
        if node.children !== nothing
            _all_nodes!.(node.children, Ref(visited), Ref(nodes))
        end
        visited[node] = 1
    else #already visited this node so don't have to recurse to children
        visited[node] += 1
    end

    return nothing
end

function new_variables(node::Node, visited)
    nodes = Vector{Node}(undef, 0)

    _new_variables!(node, visited, nodes)
    return nodes
end
export all_nodes

function _new_variables!(node::Node, visited::Dict{Node,T}, nodes::Vector{Node}) where {T<:Integer}
    tmp = get(visited, node, nothing)
    if tmp === nothing
        if node.children !== nothing
            _new_variables!.(node.children, Ref(visited), Ref(nodes))
        elseif is_variable(node)
            push!(nodes, node)
        end
        visited[node] = true
    end

    return nothing
end

"""computes leaves of the graph `node`. This is inefficient since it allocates space to store all nodes and then searches through that vector to find the leaves."""
function graph_leaves(node::Node)
    result = Vector{Node}(undef, 0)
    nodes = all_nodes(node)

    for n in nodes
        if arity(n) === 0 #all nodes with no children are leaves.
            push!(result, n)
        end
    end

    return result
end
export graph_leaves


# """inefficient exponential time algorithm to compute derivative. Only used for testing small examples"""
# function all_paths_derivative(graph::DerivativeGraph)
#     graph_root = root_index(graph)

#     return sum(_all_paths_derivative.(Ref(graph), child_edges(graph, graph_root), Ref(Node(1))))
# end
# export all_paths_derivative

# function _all_paths_derivative(graph::DerivativeGraph, edge::Edge{Int64}, prod)
#     curr_node = edge.bott_vertex
#     if isleaf(graph, curr_node)
#         if function_variable_index(graph) == curr_node
#             @assert typeof(node_value(edge_value(edge))) != AutomaticDifferentiation.NoDeriv
#             prod *= edge_value(edge) #this may seem redundant have two `prod *= edge_value(edge)` statements. But the edge value of an edge to a constant has value NoDeriv. Only want to do the multiplication when certain the edge value won't be NoDeriv.
#             return prod
#         else
#             return 0.0 #if leaf node is not the function variable then this path adds nothing to derivative sum
#         end
#     else
#         @assert typeof(node_value(edge_value(edge))) != AutomaticDifferentiation.NoDeriv
#         prod *= edge_value(edge) #this may seem redundant have two `prod *= edge_value(edge)` statements. But the edge value of an edge to a constant has value NoDeriv. Only want to do the multiplication when certain the edge value won't be NoDeriv.
#         return sum(_all_paths_derivative.(Ref(graph), child_edges(graph, curr_node), Ref(prod)))
#     end
# end