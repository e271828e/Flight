module Systems

using ComponentArrays
using DataStructures
using AbstractTrees

using ..GUI

export Component, System, SystemTrait
export SystemẊ, SystemX, SystemY, SystemU, SystemS
export init_ẋ, init_x, init_y, init_u, init_s
export f_ode!, f_step!, f_disc!, update_y!


################################################################################
############################## Component ################################

abstract type Component end

function DataStructures.OrderedDict(g::Component)
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

system_traits() = (SystemẊ(), SystemX(), SystemY(), SystemU(), SystemS())

################################################################################
################################### System #####################################

const XType = Union{Nothing, AbstractVector{Float64}}

#needs the C type parameter for dispatch, the rest for type stability
#must be mutable to allow y updates
mutable struct System{C <: Component, X <: XType, Y, U, S, P, B}
    ẋ::X #continuous state derivative
    x::X #continuous state
    y::Y #output
    u::U #control input
    s::S #discrete state
    t::Base.RefValue{Float64} #allows implicit propagation of t updates down the subsystem hierarchy
    params::P
    subsystems::B
end

#default trait initializer. if the descriptor has any Component fields of
#its own, these are considered children and traits are (recursively) initialized
#from them
function init(trait::SystemTrait, cmp::Component)
    #get those fields that are themselves Components
    children = filter(p -> isa(p.second, Component), OrderedDict(cmp))
    #build an OrderedDict with the initialized traits for each of those
    trait_dict = OrderedDict(k => init(trait, v) for (k, v) in pairs(children))
    #forward it to the OrderedDict initializers
    init(trait, trait_dict)
end

#fallback method for state vector derivative initialization
function init(::SystemẊ, cmp::Component)
    x = init(SystemX(), cmp)
    return (!isnothing(x) ? (x |> zero) : nothing)
end

#initialize traits from OrderedDict
function init(::SystemTrait, dict::OrderedDict)
    filter!(p -> !isnothing(p.second), dict) #drop Nothing entries
    isempty(dict) && return nothing
    if all(v -> isa(v, AbstractVector), values(dict))
        return ComponentVector(dict)
    else
        return NamedTuple(dict)
    end
end

#y must always be a NamedTuple, even if all subsystem's y are StaticArrays;
#otherwise update_y! will not work
function init(::SystemY, dict::OrderedDict)
    filter!(p -> !isnothing(p.second), dict) #drop Nothing entries
    isempty(dict) && return nothing
    return NamedTuple(dict)
end

#shorthands (do not extend these)
init_ẋ(cmp::Component) = init(SystemẊ(), cmp)
init_x(cmp::Component) = init(SystemX(), cmp)
init_y(cmp::Component) = init(SystemY(), cmp)
init_u(cmp::Component) = init(SystemU(), cmp)
init_s(cmp::Component) = init(SystemS(), cmp)

function System(comp::Component,
                ẋ = init_ẋ(comp), x = init_x(comp), y = init_y(comp),
                u = init_u(comp), s = init_s(comp), t = Ref(0.0))

    #construct subsystems from Component fields
    child_names = filter(p -> (p.second isa Component), OrderedDict(comp)) |> keys |> Tuple

    child_systems = map(child_names) do child_name

        child_component = getproperty(comp, child_name)

        child_properties = map((ẋ, x, y, u, s), system_traits()) do parent, trait
            if !isnothing(parent) && (child_name in propertynames(parent))
                getproperty(parent, child_name)
            else
                init(trait, child_component)
            end
        end

        System(child_component, child_properties..., t)

    end

    subsystems = NamedTuple{child_names}(child_systems)

    #the remaining fields are saved as parameters
    params = NamedTuple(n=>getfield(comp,n) for n in propertynames(comp) if !(n in child_names))
    params = (!isempty(params) ? params : nothing)

    sys = System{map(typeof, (comp, x, y, u, s, params, subsystems))...}(
                    ẋ, x, y, u, s, t, params, subsystems)

    init!(sys)

    return sys

end

init!(::System) = nothing

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
        return :(error("A System's $S cannot be reassigned, only mutated in place"))
    end
end

######################## f_ode! f_step! f_disc! ############################

#f_ode! must update sys.ẋ, compute and reassign sys.y, then return nothing

#f_step! and f_disc! are allowed to modify a System's u, s and x. if they do
#so, they must return true, otherwise false

#caution: if a System subtype defines a f_ode!, f_disc! or f_step! method, but
#its interface is incorrectly specified, dispatch will silently revert to the
#fallback. this has potential to cause subtle bugs. a test should be used to
#confirm that the desired method is indeed being dispatched to!

#fallback method for node Systems. tries calling f_ode! on all subsystems with
#the same arguments provided to the parent System, then assembles a NamedTuple
#from the subsystems' outputs. override as required.
@inline function (f_ode!(sys::System{C, X, Y, U, S, P, B}, args...)
                where {C<:Component, X <: XType, Y, U, S, P, B})

    map(ss-> f_ode!(ss, args...), values(sys.subsystems))
    update_y!(sys)
    return nothing

end

#fallback method for node Systems. tries calling f_step! on all subsystems with
#the same arguments provided to the parent System, then ORs their outputs. does
#NOT update y. override as required
@inline function (f_step!(sys::System{C, X, Y, U, S, P, B}, args...)
                    where {C<:Component, X <: XType, Y, U, S, P, B})

    x_mod = false
    #we need a bitwise OR to avoid calls being skipped after x_mod == true
    for ss in sys.subsystems
        x_mod |= f_step!(ss, args...)
    end
    return x_mod

end

#fallback method for node Systems. tries calling f_disc! on all subsystems
#with the same arguments provided to the parent System, then ORs their outputs.
#updates y, since f_disc! is where discrete Systems should update their
#output. override as required.
@inline function (f_disc!(sys::System{C, X, Y, U, S, P, B}, Δt, args...)
                    where {C<:Component, X <: XType, Y, U, S, P, B})

    x_mod = false
    #we need a bitwise OR to avoid calls being skipped after x_mod == true
    for ss in sys.subsystems
        x_mod |= f_disc!(ss, Δt, args...)
    end
    update_y!(sys)
    return x_mod

end

@inline function (update_y!(sys::System{C, X, Y})
    where {C<:Component, X, Y})
end

#fallback method for updating a System's NamedTuple output. it assembles the
#outputs from its subsystems into a NamedTuple, then assigns it to the System's
#y field
@inline function (update_y!(sys::System{C, X, Y})
    where {C<:Component, X, Y <: NamedTuple{L, M}} where {L, M})

    #the keys of NamedTuple sys.y identify those subsystems with non-null
    #outputs; retrieve their updated ys and assemble them into a NamedTuple of
    #the same type
    ys = map(id -> getproperty(sys.subsystems[id], :y), L)
    sys.y = NamedTuple{L}(ys)
    return nothing

end


################################################################################
############################## Visualization ###################################

Base.@kwdef struct SystemTreeNode
    label::Symbol = :root
    type::DataType #Component type
    function SystemTreeNode(label::Symbol, type::DataType)
        @assert (type <: Component) && (!isabstracttype(type))
        new(label, type)
    end
end

SystemTreeNode(::Type{C}) where {C<:Component} = SystemTreeNode(type = C)

function AbstractTrees.children(node::SystemTreeNode)
    return [SystemTreeNode(name, type) for (name, type) in zip(
            fieldnames(node.type), fieldtypes(node.type))
            if type <: Component]
end

function AbstractTrees.printnode(io::IO, node::SystemTreeNode)
    print(io, ":"*string(node.label)*" ($(node.type))")
end

AbstractTrees.print_tree(cmp::Type{C}; kwargs...) where {C<:Component} =
    print_tree(SystemTreeNode(cmp); kwargs...)

AbstractTrees.print_tree(::C; kwargs...) where {C<:Component} = print_tree(C; kwargs...)
AbstractTrees.print_tree(::System{C}; kwargs...) where {C} = print_tree(C; kwargs...)


################################################################################
#################################### GUI #######################################

#none of these work

#this one doesn't work because the checkbox state is not preserved from one
#execution to the next without the @cstatic macro

# @generated function (GUI.draw!(sys::System{T, X, Y, U, S, P, B}, label::String = "System")
#     where {T<:Component, X, Y, U, S, P, B})

#     ex = Expr(:block)

#     push!(ex.args, :(CImGui.Begin(label)))

#     for ss_key in fieldnames(B)
#         ss_show = gensym(ss_key)
#         ss_label = string(ss_key)
#         Core.print(ss_label)
#         ss_expr = quote
#             $ss_show = Ref(false)
#             println($ss_label)
#             CImGui.Checkbox($ss_label, $ss_show)
#             println($ss_show[])
#         end
#         push!(ex.args, ss_expr)

#     end

#     push!(ex.args, :(CImGui.End()))

#     return ex

# end

# function GUI.draw!(sys::System, gui_input::Bool = true, label::String = "Generic System")

#     isempty(sys.subsystems) && return
#     should_draw = falses(length(sys.subsystems))
#     CImGui.Begin(label)
#     for (i, k) in enumerate(keys(sys.subsystems))
#         should_draw[i] = @cstatic check=false @c CImGui.Checkbox(string(k), &check)
#         # should_draw[2] = @cstatic check=false @c CImGui.Checkbox(string(k), &check)
#     end
#     CImGui.End()
#     println(should_draw)


# end


# function GUI.draw!(sys::System, gui_input::Bool = true, label::String = "Generic System")

#     isempty(sys.subsystems) && return
#     should_draw = falses(3)
#     CImGui.Begin(label)
#         should_draw[1] = @cstatic check=false @c CImGui.Checkbox("One", &check)
#         should_draw[2] = @cstatic check=false @c CImGui.Checkbox("Two", &check)
#         should_draw[3] = @cstatic check=false @c CImGui.Checkbox("Trhee", &check)
#     CImGui.End()
#     println(should_draw)

# end

end #module