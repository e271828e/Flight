module LBV

export LBVLeaf, LBVNode
export @define_node

abstract type AbstractLBV{T, D<:AbstractVector{T}} <: AbstractVector{T} end

########################### LBVLeaf ############################

struct LBVLeaf{L, T, D <: AbstractVector{T}} <: AbstractLBV{T, D}
    data::D
    function LBVLeaf{L,T,D}(data) where {L,T,D} #for some reason, you can't restrict type parameters here!
        if !(L > 0)
            throw(ArgumentError("LBVLeaf length must be positive"))
        end
        if length(data) != length(LBVLeaf{L,T,D})
            throw(ArgumentError("Got input length $(length(data)), expected $(length(LBVLeaf{L,T,D}))"))
        end
        new{L,T,D}(data)
    end
end
LBVLeaf{L,T}(data::D) where {L,T,D} = LBVLeaf{L,T,D}(data) #T/D inconsistencies caught by the inner const
LBVLeaf{L}(data::D) where {L,D} = LBVLeaf{L,eltype(D),D}(data)
LBVLeaf{L,T}() where {L,T} = LBVLeaf{L,T}(Vector{T}(undef, L))
LBVLeaf{L}() where {L} = LBVLeaf{L,Float64}()
LBVLeaf(data::D) where {D} = LBVLeaf{length(data),eltype(data),typeof(data)}(data) #avoid for efficiency

Base.similar(::Type{<:LBVLeaf{L,T}}) where {L,T} = LBVLeaf{L,T}(Vector{T}(undef, L))
Base.similar(::LBVLeaf{L,T}) where {L,T} = similar(LBVLeaf{L,T})
Base.copy(x::LBVLeaf{L}) where {L} = LBVLeaf{L}(copy(getfield(x, :data)))

###### Abstract Array #######

Base.length(::Type{<:LBVLeaf{L}}) where {L} = L
Base.size(::LBVLeaf{L}) where {L} = (L,)
Base.getindex(x::LBVLeaf, i) = getindex(getfield(x,:data), i)
Base.setindex!(x::LBVLeaf, v, i) = setindex!(getfield(x,:data), v, i)

####### Custom Broadcasting #######

struct LBVLeafStyle{L,T} <: Broadcast.AbstractArrayStyle{1} end

LBVLeafStyle{L,T}(::Val{1}) where {L,T} = LBVLeafStyle{L,T}()
Base.BroadcastStyle(::Type{LBVLeaf{L,T,D}}) where {L,T,D} = LBVLeafStyle{L,T}()

function Base.similar(::Broadcast.Broadcasted{LBVLeafStyle{L,T}}, ::Type{ElType}) where {L,T,ElType}
    similar(LBVLeaf{L,T})
end

function Base.BroadcastStyle(::LBVLeafStyle{L,T1}, ::LBVLeafStyle{L,T2}) where {L,T1,T2}
    LBVLeafStyle{L,promote_type(T1, T2)}()
end

########################### LBVNode ############################

struct LBVNode{S, T, D <: AbstractVector{T}} <: AbstractLBV{T, D} #S: identifier
    data::D
    function LBVNode{S,T,D}(data::D) where {S,T,D} #for some reason, you can't restrict type parameters here
        assert_symbol(S)
        if length(data) != length(LBVNode{S,T,D})
            throw(ArgumentError("Got input length $(length(data)), expected $(length(LBVNode{S,T,D}))"))
        end
        new{S,T,D}(data)
    end
end
@generated assert_symbol(x) = x<:Symbol ? nothing : :(throw(TypeError(:LBVNode, "inner constructor", Symbol, $x)))

LBVNode{S,T}(data::D) where {S,T,D} = LBVNode{S,T,D}(data) #T/D inconsistencies caught by the inner const
LBVNode{S}(data::D) where {S,D} = LBVNode{S,eltype(D),D}(data)
LBVNode{S,T}() where {S,T} = LBVNode{S,T}(Vector{T}(undef, length(LBVNode{S,T})))
LBVNode{S}() where {S} = LBVNode{S,Float64}()

# is_registered(::Type{<:LBVNode}) = false
# descriptor(::Type{<:LBVNode}) = error("To be implemented for each type parameter")
# descriptor(::T) where {T<:LBVNode}= descriptor(T)

####### Abstract Array #############

Base.size(x::LBVNode) = size(getfield(x,:data))
Base.getindex(x::LBVNode, i) = getindex(getfield(x,:data), i)
Base.setindex!(x::LBVNode, v, i) = setindex!(getfield(x,:data), v, i)

Base.similar(::Type{<:LBVNode{S,T}}) where {S,T} = LBVNode{S,T}(Vector{T}(undef, length(LBVNode{S,T})))
Base.similar(::LBVNode{S,T}) where {S,T} = similar(LBVNode{S,T})
Base.copy(x::LBVNode{S}) where {S} = LBVNode{S}(copy(getfield(x, :data)))


####### Custom Broadcasting #######

struct LBVNodeStyle{S,T} <: Broadcast.AbstractArrayStyle{1} end

LBVNodeStyle{S,T}(::Val{1}) where {S,T} = LBVNodeStyle{S,T}()
Base.BroadcastStyle(::Type{LBVNode{S,T,D}}) where {S,T,D} = LBVNodeStyle{S,T}()

function Base.similar(::Broadcast.Broadcasted{LBVNodeStyle{S,T}}, ::Type{ElType}) where {S,T,ElType}
    similar(LBVNode{S,T})
end

function Base.BroadcastStyle(::LBVNodeStyle{S,T1}, ::LBVNodeStyle{S,T2}) where {S,T1,T2}
    LBVNodeStyle{S,promote_type(T1, T2)}()
end


######### Code Generation #########

Base.getproperty(x::LBVNode, s::Symbol) = getproperty(x, Val(s))
Base.setproperty!(x::LBVNode, s::Symbol, v) = getproperty!(x, Val(s), v)

#define and register a LBVNode
macro define_node(name, descriptor)

    s_descr = :descriptor

    ex = quote
        # by escaping the LBVNode name, we are defining it as a local variable
        # in the macro caller scope, rather than in the LBV module. this means
        # that, for this name to be used in a macro call in another module:
        # 1) the defining module must export the name in addition to calling
        #    the macro
        # 2) the interested module must import the defining module with "using"

        println("Generating code for $($(QuoteNode(name))) = ",
                "LBVNode{:$($(QuoteNode(name)))}...")

        if isdefined($__module__, $(QuoteNode(name)))
            println("WARNING: Type $($(QuoteNode(name))) already defined in module $($(QuoteNode(__module__)))")
        end

        const $(esc(name)) = LBVNode{$(QuoteNode(name))}

        #because the LBVNode names in the descriptor are defined in their
        #respective modules, not in LBV, we must escape the descriptor to
        #protect them from being qualified with the LBV module path (where they
        #cannot be found)
        child_labels = keys($(esc(descriptor)))
        child_types = values($(esc(descriptor)))
        @assert all([t <: Union{LBVLeaf, LBVNode} for t in child_types]) "Invalid child type"

        # println($(esc(descriptor)))
        # desc = NamedTuple{child_labels}(child_types)
        # node_length = sum(length.(child_types))
        # println(child_labels)
        # println(child_types)
        # println(desc)
        # println(node_length)

        #descriptor is no longer a method defined in and exported from LBV to be
        #extended by modules, it is a local method defined in each module. this
        #avoids potential name clashes between LBVNodes with the same type
        #parameter defined in different modules.
        $(esc(s_descr))(::Type{<:$(esc(name))}) = NamedTuple{child_labels}(child_types)
        $(esc(s_descr))(::($(esc(name)))) = NamedTuple{child_labels}(child_types)

        Base.length(::Type{<:$(esc(name))}) = sum(length.(child_types))

        offset = 0
        for (child_label, child_type) in zip(child_labels, child_types)

            child_length = length(child_type)
            child_range = (1 + offset):(child_length + offset)
            global offset += child_length

            println("Generating helper methods for child $child_label, range $child_range")
            Base.getproperty(x::$(esc(name)), ::Val{child_label}) = (child_type)(view(getfield(x,:data), child_range))
            Base.setproperty!(x::$(esc(name)), ::Val{child_label}, v) = setindex!(getfield(x, :data), v, child_range)

        end

    end
    return Base.remove_linenums!(ex)
    # return ex
end

end