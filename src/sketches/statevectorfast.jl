module StateVectorFast

using StaticArrays

export Node, Leaf


#what i need is to assign to each subsystem's x a view of some part of the
#overall system's state vector. such a view should be held in a Node{S} object.
#in particular, in its data field. for efficiency, one would like the data field
#to be a MVector. but MVectors create copies of their input data upon
#construction, so that will not work. now, the speed of operations on views is
#roughly the same as that of regular Vectors (which is around an order of
#magnitude slower that of StaticArrays, but still very, very fast)

#now, with the template below, what remains is to create the generated function
#which, from the lengths of the types specified in the descriptor, constructs
#the appropriate UnitRanges and then the appropriate views, which are passed to
#the Node{S} constructor for that specific block.

#a System must only have a Node as a state vector. otherwise, when it assigns to
#its state vector, the parents will not be changed. within a Node, there can be
#one or more Leafs, each with its name. but the Leafs don't actually hold data.
#although... i could define a Leaf type whose data is also a SubArray, but for
#which the type parameter fixes its length, and it does not require any further
#indexing to access. yes, definitely a Leaf can also be a valid data holder,
#instead of a simple dispatch tool

#when initializing a system, we only need to recursively assign the state vector
#of each child subsystem to its corresponding Node{S} view generated by the
#getindex methods

struct Leaf{S} end
Base.length(::Type{Leaf{S}}) where {S} = S

struct Node{L} <: AbstractVector{Float64}
    data::SubArray{Float64, 1}
    Node{L}(data::SubArray{Float64, 1}) where {L} = (#=println("Inner const");=# new{L}(data))
end

Node{L}(data::Vector{Float64}) where {L} = Node{L}(view(data, :))

blocklengths(::Type{Node{S}}) where {S} = collect(length.(values(descriptor(Node{S}))))
Base.length(::Type{Node{S}}) where {S} = sum(blocklengths(Node{S}))
Base.length(::Node{S}) where {S} = length(Node{S})

#AbstractArray
Base.size(::Node{S}) where {S} = (length(Node{S}),)
Base.eltype(::Node{S}) where{S} = Float64 #helps with allocation efficiency
Base.getindex(x::Node{S}, i) where {S} = getindex(x.data, i)

#display functions
#change these so the different blocks are displayed
# Base.show(io::IO, ::MIME"text/plain", q::AbstractQuat) = print(io, "$(typeof(q)): $(q[:])")
# Base.show(io::IO, q::AbstractQuat) = print(io, "$(typeof(q)): $(q[:])")


descriptor(::Type{Node{:rbd}}) = (att = Leaf{4}, vel = Leaf{3}, pos = Leaf{3})

#MAKE THIS GENERATED
Base.length(::Type{Node{:rbd}}) = (#=println("Called");=# return 10)

#these are essential for speed
#it is much faster to perform basic operations on the underlying PBV than
#broadcasting them. Broadcasting should be used only as a fallback for generic
#functions
Base.:(+)(x1::Node{S}, x2::Node{S}) where{S} = Node{S}(x1.data + x2.data)
Base.:(+)(a::Real, x::Node{S}) where{S} = Node{S}(a .* x.data)

#add Broadcasting for completeness

#USE PROPAGATE INBOUNDS, ETC

end