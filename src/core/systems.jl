module Systems

using ComponentArrays

import AbstractTrees: children, printnode, print_tree
import DataStructures: OrderedDict

export f_ode!, f_step!
export SystemDescriptor, SystemGroupDescriptor, System
export SystemẊ, SystemX, SystemY, SystemU, SystemS
export init_ẋ, init_x, init_y, init_u, init_s


################################################################################
############################## SystemDescriptor ################################

abstract type SystemDescriptor end #anything from which we can build a System

function OrderedDict(g::SystemDescriptor)
    fields = propertynames(g)
    values = map(λ -> getproperty(g, λ), fields)
    OrderedDict(k => v for (k, v) in zip(fields, values))
end

################################################################################
############################## SystemTrait #####################################

abstract type SystemTrait end

struct SystemẊ <: SystemTrait end
struct SystemX <: SystemTrait end
struct SystemY <: SystemTrait end
struct SystemU <: SystemTrait end
struct SystemS <: SystemTrait end

#initialize continuous state vector traits from OrderedDict
function init(::Union{SystemẊ, SystemX}, dict::OrderedDict)
    filter!(p -> !isnothing(p.second), dict) #drop Nothing entries
    !isempty(dict) ? ComponentVector(dict) : nothing
end

#initialize all other traits from OrderedDict
function init(::Union{SystemY, SystemU, SystemS}, dict::OrderedDict)
    filter!(p -> !isnothing(p.second), dict) #drop Nothing entries
    !isempty(dict) ? NamedTuple(dict) : nothing
end

init(trait::SystemTrait; kwargs...) = init(trait, OrderedDict(kwargs))

#shorthands (do not extend)
init_ẋ(args...; kwargs...) = init(SystemẊ(), args...; kwargs...)
init_x(args...; kwargs...) = init(SystemX(), args...; kwargs...)
init_y(args...; kwargs...) = init(SystemY(), args...; kwargs...)
init_u(args...; kwargs...) = init(SystemU(), args...; kwargs...)
init_s(args...; kwargs...) = init(SystemS(), args...; kwargs...)


################################################################################
################################### System #####################################

#needs the T type parameter for dispatch, the rest for type stability
#must be mutable to allow y updates
mutable struct System{  T <: SystemDescriptor,
                X <: Union{Nothing, AbstractVector{Float64}}, Y, U, D, P, S}
    ẋ::X #continuous dynamics state vector derivative
    x::X #continuous dynamics state vector
    y::Y #output
    u::U #control input
    s::D #discrete dynamics state
    t::Base.RefValue{Float64} #allows implicit propagation of t updates down the subsystem hierarchy
    params::P
    subsystems::S
end

#default trait initializer. if the descriptor has any SystemDescriptor fields of
#its own, these are considered children and traits are (recursively) initialized
#from them
function init(trait::Union{SystemX, SystemY, SystemU, SystemS}, desc::SystemDescriptor)
    #get those fields that are themselves SystemDescriptors
    children = filter(p -> isa(p.second, SystemDescriptor), OrderedDict(desc))
    #build an OrderedDict with the initialized traits for each of those
    trait_dict = OrderedDict(k => init(trait, v) for (k, v) in pairs(children))
    #forward it to the OrderedDict initializers
    init(trait, trait_dict)
end

#fallback method for state vector derivative initialization
function init(::SystemẊ, desc::SystemDescriptor)
    x = init(SystemX(), desc) #this is a namedtuple
    !isnothing(x) ? x |> zero : nothing
end

#suppose we have a System a with children b and c. if neither b and c have
#inputs, u = init(a, SystemU()) will return nothing. when the System constructor
#for a tries to retrieve a.u.b and a.u.c to use them as inputs for subsystems b
#and c, it will be accessing fields b and c of a nothing variable. we must
#handle this scenario.
function maybe_getproperty(input, label)
    !isnothing(input) && (label in propertynames(input)) ? getproperty(input, label) : nothing
end

function System(desc::SystemDescriptor,
                ẋ = init_ẋ(desc), x = init_x(desc), y = init_y(desc),
                u = init_u(desc), s = init_s(desc), t = Ref(0.0))

    child_names = filter(p -> (p.second isa SystemDescriptor), OrderedDict(desc)) |> keys |> Tuple
    child_systems = (System(map((λ)->maybe_getproperty(λ, name), (desc, ẋ, x, y, u, s))..., t) for name in child_names) |> Tuple
    subsystems = NamedTuple{child_names}(child_systems)

    params = NamedTuple(n=>getfield(desc,n) for n in propertynames(desc) if !(n in child_names))
    params = (!isempty(params) ? params : nothing)

    System{map(typeof, (desc, x, y, u, s, params, subsystems))...}(
                         ẋ, x, y, u, s, t, params, subsystems)

end


Base.getproperty(sys::System, name::Symbol) = getproperty(sys, Val(name))
Base.setproperty!(sys::System, name::Symbol, value) = setproperty!(sys, Val(name), value)

@generated function Base.getproperty(sys::System, ::Val{S}) where {S}
    if S ∈ fieldnames(System)
        return :(getfield(sys, $(QuoteNode(S))))
    else
        return :(getfield(getfield(sys, :subsystems), $(QuoteNode(S))))
    end
end

#disallow setting any System field other than y to avoid breaking the references
#with its subsystems' fields
@generated function Base.setproperty!(sys::System, ::Val{S}, value) where {S}
    if S === :y
        return :(setfield!(sys, $(QuoteNode(S)), value))
    else
        return :(error("A System's $S cannot be reassigned; mutate its fields instead."))
    end
end

#f_step! is free to modify a System's u, s and x. if it modifies x, it must
#return true, otherwise false. no fallbacks are provided for safety reasons: if
#the intended f_ode! or f_step! implementations for the System have the wrong
#interface, the dispatch will silently revert to the fallback, which does
#nothing. this may not be obvious at all and introduce treacherous bugs.

f_ode!(sys::System, args...) = MethodError(f_ode!, (sys, args...)) |> throw
(f_step!(sys::System, args...)::Bool) = MethodError(f_step!, (sys, args...)) |> throw

# #default implementation calls f_step! on all Node subsystems with no
# #arguments, then ORs their outputs. override as required
# @inline @generated function (f_step!(sys::System{T, X, Y, U, D, P, S})
#     where {T<:SystemDescriptor, X <: Union{Nothing, AbstractVector{Float64}}, Y, U, D, P, S})

#     Core.println("Generated function called for $%")
#     Core.println()
#     Core.println()

#     ex = Expr(:block)
#     push!(ex.args, :(x_mod = false))

#     #call f_step! on each subsystem
#     for label in fieldnames(S)
#         #we need all f_step! calls executed, so we can't just chain them with ||
#         push!(ex.args,
#             :(x_mod = x_mod || f_step!(sys.subsystems[$(QuoteNode(label))])))
#     end
#     return ex

# end

@inline function (assemble_y!(sys::System{T, X, Y})
    where {T<:SystemDescriptor, X, Y <: Nothing})
end

@inline @generated function (assemble_y!(sys::System{T, X, Y})
    where {T<:SystemDescriptor, X, Y <: NamedTuple{L, M}} where {L, M})

    #L contains the field names of those subsystems which have outputs. retrieve
    #the y's of those subsystems and assemble them into a NamedTuple, which will
    #have the same type as Y

    #initialize main expression
    ex_main = Expr(:block)

    #build a tuple expression with subsystem outputs
    ex_ss_outputs = Expr(:tuple) #tuple expression for children's outputs
    for label in L
        push!(ex_ss_outputs.args,
            :(sys.subsystems[$(QuoteNode(label))].y))
    end

    #build a NamedTuple from the subsystem's labels and the constructed tuple
    ex_nt = Expr(:call, Expr(:curly, NamedTuple, L), ex_ss_outputs)

    #assign the result to the parent system's y
    ex_assign = Expr(:(=), :(sys.y), ex_nt)

    push!(ex_main.args, ex_assign)
    push!(ex_main.args, :(return nothing))

    return ex_main

end

################################ NullSystem ################################

struct NullSystemDescriptor <: SystemDescriptor end

@inline f_ode!(::System{NullSystemDescriptor}, args...) = nothing
@inline (f_step!(::System{NullSystemDescriptor}, args...)::Bool) = false

######################### SystemGroupDescriptors ############################

#abstract supertype for any SystemDescriptor grouping several children
#SystemDescriptors with common f_ode! and f_step! interfaces. it provides
#automatically generated methods for these functions.

abstract type SystemGroupDescriptor <: SystemDescriptor end

#default implementation calls f_ode! on all Group subsystems with the same
#arguments provided to the parent System, then builds a NamedTuple with the
#subsystem outputs. can be overridden as required.
@inline @generated function (f_ode!(sys::System{T, X, Y, U, D, P, S}, args...)
    where {T<:SystemGroupDescriptor, X <: Union{Nothing, AbstractVector{Float64}}, Y, U, D, P, S})

    # Core.println("Generated function called")
    ex_main = Expr(:block)

    #call f_ode! on each subsystem
    ex_calls = Expr(:block)
    for label in fieldnames(S)
        push!(ex_calls.args,
            :(f_ode!(sys.subsystems[$(QuoteNode(label))], args...)))
    end

    ex_assemble_y = :(assemble_y!(sys))

    push!(ex_main.args, ex_calls)
    push!(ex_main.args, ex_assemble_y)
    push!(ex_main.args, :(return nothing))

    return ex_main

end

#default implementation calls f_step! on all Node subsystems with the same
#arguments provided to the parent Node's System, then ORs their outputs.
#can be overridden as required
# @inline @generated function (f_step!(sys::System{T, X, Y, U, D, P, S}, args...)
#     where {T<:SystemGroupDescriptor, X, Y, U, D, P, S})
@inline @generated function (f_step!(sys::System{T, X, Y, U, D, P, S}, args...)
    where {T<:SystemGroupDescriptor, X <: Union{Nothing, AbstractVector{Float64}}, Y, U, D, P, S})

    # Core.print("Generated function called")
    ex = Expr(:block)
    push!(ex.args, :(x_mod = false))

    #call f_step! on each subsystem
    for label in fieldnames(S)
        #we need all f_step! calls executed, so we can't just chain them with ||
        push!(ex.args,
            :(x_mod = x_mod || f_step!(sys.subsystems[$(QuoteNode(label))], args...)))
    end
    return ex

end

################################################################################
############################## Visualization ###################################

Base.@kwdef struct SystemTreeNode
    label::Symbol = :root
    type::DataType #SystemDescriptor type
    function SystemTreeNode(label::Symbol, type::DataType)
        @assert (type <: SystemDescriptor) && (!isabstracttype(type))
        new(label, type)
    end
end

SystemTreeNode(::Type{T}) where {T<:SystemDescriptor} = SystemTreeNode(type = T)

function children(node::SystemTreeNode)
    return [SystemTreeNode(name, type) for (name, type) in zip(
            fieldnames(node.type), fieldtypes(node.type))
            if type <: SystemDescriptor]
end

function printnode(io::IO, node::SystemTreeNode)
    print(io, ":"*string(node.label)*" ($(node.type))")
end

print_tree(desc::Type{T}; kwargs...) where {T<:SystemDescriptor} =
    print_tree(SystemTreeNode(desc); kwargs...)

print_tree(::T; kwargs...) where {T<:SystemDescriptor} = print_tree(T; kwargs...)
print_tree(::System{D}; kwargs...) where {D} = print_tree(D; kwargs...)

end #module