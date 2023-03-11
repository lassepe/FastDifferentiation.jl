function _reverse_mapping(a, ::Type{N}, ::Type{T}) where {T,N}
    result = Dict{N,T}()

    for mapping in pairs(a)
        result[mapping[2]] = mapping[1]
    end

    return result
end

reverse_mapping(a::AbstractVector{T}, index_type=DefaultNodeIndexType) where {T} = _reverse_mapping(a, T, index_type)
export reverse_mapping

"""Each `Edge` instance has a unique id so need special equality test if only want to test value equals. Could overload Base.== but that is risky since so many other function, hash, etc., depend on the definition of ==."""
function value_equal(item1::T, item2::S, fields_to_ignore::Union{Nothing,Vector{Symbol}}=Symbol[]) where {T,S}
    fields = fieldnames(T)
    fields2 = fieldnames(S)
    @assert fields2 == fields #closest I can come to a type check. If have parameterized type Blob{X,Y,Z} then if item1 is a Blob{Int,Float64,Int} and item2 is a Blob{Int,Int,Float64} then they won't have the same type so can't have a function declaration like value_equal(item1::T,item2::T). Want to somehow extract the type name of the Parameterized type, Blob, automatically and use that as a type parameter, But can't do that. So trust to luck that item1 and item2 are the same parameterized type.
    for field in fields
        if !in(field, fields_to_ignore)
            if getfield(item1, field) != getfield(item2, field)
                return false
            end
        end
    end
    return true
    # edge1.top_vertex == edge2.top_vertex && 
    # edge1.bott_vertex == edge2.bott_vertex && 
    # node_value(edge_value(edge1)) == node_value(edge_value(edge2))
end
export value_equal

show_all(a::AbstractArray) = show(stdout, "text/plain", a)
export show_all