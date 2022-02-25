module Modeling

using Dates
using UnPack
using SciMLBase, OrdinaryDiffEq, DiffEqCallbacks
using ComponentArrays, RecursiveArrayTools
using DataStructures: OrderedDict

import Flight.Plotting: plots

export f_cont!, f_disc!
export SystemDescriptor, SystemGroupDescriptor, NullSystemDescriptor, System, Model


############################# SystemDescriptor ############################

abstract type SystemDescriptor end #anything from which we can build a System

init_x(::Type{T} where {T<:SystemDescriptor}) = nothing
init_y(::Type{T} where {T<:SystemDescriptor}) = nothing
init_u(::Type{T} where {T<:SystemDescriptor}) = nothing
init_d(::Type{T} where {T<:SystemDescriptor}) = nothing
init_ẋ(::Type{T}) where {T<:SystemDescriptor} = init_ẋ(init_x(T))

init_ẋ(x::AbstractVector) = (x |> similar |> zero)
init_ẋ(::Nothing) = nothing

############################# System ############################

#need the T type parameter for dispatch, the rest for type stability. making
#System mutable does not hurt performance, because Systems are only meant to be
#instantiated upon initialization. no runtime heap allocations
mutable struct System{  T <: SystemDescriptor,
                        X <: Union{Nothing, AbstractVector{Float64}},
                        Y, U, D, P, S}
    ẋ::X #continuous state vector derivative
    x::X #continuous state vector
    y::Y #output
    u::U #control input
    d::D #discrete state
    t::Base.RefValue{Float64} #Ref allows automatic propagation of t updates down the subsystem hierarchy
    params::P
    subsystems::S
end

function System(c::T, ẋ = init_ẋ(T), x = init_x(T), y = init_y(T),
                u = init_u(T), d = init_d(T), t = Ref(0.0)) where {T<:SystemDescriptor}

    params = c #by default assign the system descriptor as System parameters
    subsystems = nothing
    System{map(typeof, (c, x, y, u, d, params, subsystems))...}(
                                    ẋ, x, y, u, d, t, params, subsystems)
end

#f_disc! is free to modify a Hybrid system's discrete state, control inputs and
#continuous state. if it modifies the latter, it must return true, false
#otherwise. no fallbacks are provided for safety reasons: if the intended
#f_cont! or f_disc! implementations for the System have the wrong interface, the
#dispatch will silently revert to the fallback, which does nothing and may not
#be obvious at all.

f_cont!(sys::System, args...) = MethodError(f_cont!, (sys, args...)) |> throw
(f_disc!(sys::System, args...)::Bool) = MethodError(f_disc!, (sys, args...)) |> throw

Base.getproperty(sys::System, s::Symbol) = getproperty(sys, Val(s))

@generated function Base.getproperty(sys::System, ::Val{S}) where {S}
    if S ∈ fieldnames(System)
        return :(getfield(sys, $(QuoteNode(S))))
    else
        return :(getfield(getfield(sys, :subsystems), $(QuoteNode(S))))
    end
end


######################### NullSystem ############################

struct NullSystemDescriptor <: SystemDescriptor end

@inline f_cont!(::System{NullSystemDescriptor}, args...) = nothing
@inline (f_disc!(::System{NullSystemDescriptor}, args...)::Bool) = false


######################## SystemGroup #############################

#abstract type providing convenience methods for composite Systems

abstract type SystemGroupDescriptor <: SystemDescriptor end

Base.keys(g::SystemGroupDescriptor) = propertynames(g)
Base.values(g::SystemGroupDescriptor) = map(λ -> getproperty(g, λ), keys(g))

init_x(::Type{T}) where {T<:SystemGroupDescriptor} = maybe_assemble_cv(T, init_x)
init_y(::Type{T}) where {T<:SystemGroupDescriptor} = maybe_assemble_nt(T, init_y)
init_u(::Type{T}) where {T<:SystemGroupDescriptor} = maybe_assemble_nt(T, init_u)
init_d(::Type{T}) where {T<:SystemGroupDescriptor} = maybe_assemble_nt(T, init_d)

function maybe_assemble_cv(::Type{T}, f::Function) where {T<:SystemGroupDescriptor}

    dict = OrderedDict{Symbol, AbstractVector{Float64}}()

    for (ss_label, ss_type) in zip(fieldnames(T), T.types)
        ss_value = f(ss_type)
        !isnothing(ss_value) ? dict[ss_label] = ss_value : nothing
    end

    #if all subsystems returned nothing, return nothing instead of a CV
    return !isempty(dict) ? ComponentVector(dict) : nothing

end

function maybe_assemble_nt(::Type{T}, f::Function) where {T<:SystemGroupDescriptor}
    dict = OrderedDict{Symbol, Any}()

    for (ss_label, ss_type) in zip(fieldnames(T), T.types)
        ss_value = f(ss_type)
        !isnothing(ss_value) ? dict[ss_label] = ss_value : nothing
    end

    #if all subsystems returned nothing, return nothing instead of a NT
    return !isempty(dict) ? NamedTuple{Tuple(keys(dict))}(values(dict)) : nothing

end

#the x of a SystemGroupDescriptor will be either a ComponentVector or nothing. if it's
#nothing it's because init_x returned nothing, and this is only the case if all
#of its subsystems' init_x in turn returned nothing. in this scenario, we can
#assign nothing to its subsystem's x the same goes for y, but with a NamedTuple
#instead of a ComponentVector
function maybe_getproperty(input, label)
    !isnothing(input) && (label in keys(input)) ? getproperty(input, label) : nothing
end

function System(g::T, ẋ = init_ẋ(T), x = init_x(T), y = init_y(T),
                u = init_u(T), d = init_d(T), t = Ref(0.0)) where {T<:SystemGroupDescriptor}

    ss_names = fieldnames(T)
    ss_list = Vector{System}()

    for name in ss_names
        push!(ss_list, System(map((λ)->maybe_getproperty(λ, name), (g, ẋ, x, y, u, d))..., t))
    end

    params = nothing
    subsystems = NamedTuple{ss_names}(ss_list)

    System{map(typeof, (g, x, y, u, d, params, subsystems))...}(
                         ẋ, x, y, u, d, t, params, subsystems)

end


#default implementation calls f_cont! on all Group subsystems with the same
#arguments provided to the parent System, then builds the NamedTuple with the
#subsystem outputs
@inline @generated function (f_cont!(sys::System{T, X, Y}, args...)
    where {T<:SystemGroupDescriptor, X, Y <: Union{Nothing, NamedTuple{L, M}}} where {L, M})

    # Core.println("Generated function called")
    ex_main = Expr(:block)

    #call f_cont! on every subsystem
    ex_calls = Expr(:block)
    for label in fieldnames(T)
        push!(ex_calls.args,
            :(f_cont!(sys.subsystems[$(QuoteNode(label))], args...)))
    end

    ex_update_y = :(update_y!(sys))

    push!(ex_main.args, ex_calls)
    push!(ex_main.args, ex_update_y)
    push!(ex_main.args, :(return nothing))

    return ex_main

end

@inline function (update_y!(sys::System{T, X, Y})
    where {T<:SystemGroupDescriptor, X, Y <: Nothing})
end

@inline @generated function (update_y!(sys::System{T, X, Y})
    where {T<:SystemGroupDescriptor, X, Y <: NamedTuple{L, M}} where {L, M})

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

#default implementation calls f_disc! on all Node subsystems with the same
#arguments provided to the parent Node's System, then ORs their outputs.
#can be overridden for specific SystemGroupDescriptor subtypes if needed
@inline @generated function (f_disc!(sys::System{T}, args...)::Bool
    ) where {T<:SystemGroupDescriptor}

    # Core.print("Generated function called")
    ex = Expr(:block)
    push!(ex.args, :(x_mod = false))
    for label in fieldnames(T)
        #we need all f_disc! calls executed, so | must be used instead of ||
        push!(ex.args,
            :(x_mod = x_mod | f_disc!(sys.subsystems[$(QuoteNode(label))], args...)))
    end
    return ex

end

############################# Model ############################

#in this design, the t and x fields of m.sys behave only as temporary
#storage for f_cont! and f_disc! calls, so we have no guarantees about their
#status after a certain step. the only valid sources for t and x at any
#given moment is the integrator's t and u
struct Model{S <: System,
                   I <: OrdinaryDiffEq.ODEIntegrator,
                   L <: SavedValues}

    sys::S
    integrator::I
    log::L

    function Model(sys, args_c::Tuple = (), args_d::Tuple = ();
        solver = Tsit5(), t_start = 0.0, t_end = 10.0, y_saveat = Float64[],
        save_on = false, int_kwargs...)

        #save_on is set to false because we are not usually interested in saving
        #the naked state vector. the output saved by the SavingCallback is all
        #we need for insight
        saveat_arr = (y_saveat isa Real ? (t_start:y_saveat:t_end) : y_saveat)

        params = (sys = sys, args_c = args_c, args_d = args_d)

        log = SavedValues(Float64, typeof(sys.y))

        dcb = DiscreteCallback((u, t, integrator)->true, f_dcb!)
        scb = SavingCallback(f_scb, log, saveat = saveat_arr)
        cb_set = CallbackSet(dcb, scb)

        # x0 = copy(sys.x) #not needed, the integrator creates its own copy
        x0 = sys.x
        problem = ODEProblem{true}(f_update!, x0, (t_start, t_end), params)
        integrator = init(problem, solver; callback = cb_set, save_on, int_kwargs...)
        new{typeof(sys), typeof(integrator), typeof(log)}(sys, integrator, log)
    end
end

#these functions are better defined outside the constructor; closures seem to
#have some overhead (?)

#function barriers: the System is first extracted from integrator.p,
#then used as an argument in the call to the actual update & callback functions,
#forcing the compiler to specialize for the specific System subtype;
#accesing sys.x and sys.ẋ directly instead causes type instability
f_update!(ẋ, x, p, t) = f_update!(ẋ, x, t, p.sys, p.args_c)
f_scb(x, t, integrator) = f_scb(x, t, integrator.p.sys, integrator.p.args_c)
function f_dcb!(integrator)
    x = integrator.u; t = integrator.t; p = integrator.p
    x_modified = f_dcb!(x, t, p.sys, p.args_c, p.args_d)
    u_modified!(integrator, x_modified)
end

#in-place integrator update function
function f_update!(ẋ::X, x::X, t::Real, sys::System{T,X}, args_c) where {T, X}

    sys.x .= x
    sys.t[] = t
    f_cont!(sys, args_c...) #updates sys.ẋ and sys.y
    ẋ .= sys.ẋ

    return nothing
end

#DiscreteCallback function (called on every integration step). this callback
#brings the System's internal x and y up to date with the last integrator's
#solution step, then executes the System's discrete update function
function f_dcb!(x::X, t::Real, sys::System{T,X}, args_c, args_d) where {T,X}

    sys.x .= x #assign the updated integrator's state to the system's local continuous state
    sys.t[] = t #ditto for time

    #at this point sys.y and sys.ẋ hold the values from the last solver evaluation of
    #f_cont!, not the one corresponding to the updated x. with x up to date, we
    #can now compute the correct sys.y sys.ẋ for this epoch
    f_cont!(sys, args_c...) #updates sys.y, but leaves sys.x unmodified

    #with the system's outputs up to date, call the discrete update function
    x_modified = f_disc!(sys, args_d...) #this may modify sys.x
    x .= sys.x #assign the (potentially modified) sys.x back to the integrator

    #note: as it is, if the System's y depends on x or d, and these are modified
    #by f_disc!, the change will not be reflected on y until the following
    #integration step

    return x_modified
end

#SavingCallback function, this gets called at the end of each step after f_disc!
function f_scb(::X, ::Real, sys::System{T,X}, args_c) where {T,X}
    return deepcopy(sys.y)
end

function Base.getproperty(m::Model, s::Symbol)
    if s === :t
        return m.integrator.t
    elseif s === :x
        return m.integrator.u
    elseif s === :y
        return m.sys.y
    elseif s === :u
        return m.sys.u
    elseif s ∈ (:sys, :integrator, :log)
        return getfield(m, s)
    else
        return getproperty(m.integrator, s)
    end
end

SciMLBase.step!(m::Model, args...) = step!(m.integrator, args...)

SciMLBase.solve!(m::Model) = solve!(m.integrator)

SciMLBase.get_proposed_dt(m::Model) = get_proposed_dt(m.integrator)

function SciMLBase.reinit!(m::Model, args...; kwargs...)

    #for an ODEIntegrator, the optional args... is simply a new initial
    #condition. if not specified, the original initial condition is used
    reinit!(m.integrator, args...; kwargs...)

    #grab the updated t and x from the integrator (in case they were reset by
    #the input arguments). this is not strictly necessary, since they are merely
    #buffers. just for consistency.
    m.sys.t[] = m.integrator.t
    m.sys.x .= m.integrator.u

    resize!(m.log.t, 1)
    resize!(m.log.saveval, 1)
    return nothing
end

function plots(mdl::Model; mode::Symbol = :basic,
    save_path::Union{String,Nothing} = nothing, kwargs...)
    #generate default path tmp/plots/current_date
    save_path = (save_path === nothing ?
        joinpath("tmp", Dates.format(now(), "yyyy_mm_dd_HHMMSS")) : save_path)
    mkpath(save_path)
    plots(mdl.log.t, mdl.log.saveval; mode, save_path, kwargs...)
end

#the following causes type instability and kills performance:
# function f_update!(ẋ, x, p, t)
    # @unpack sys, args_c = p
    # sys.x .= x
    # sys.t[] = t
    # f_cont!(sys, args_c...)
    # ẋ = sys.ẋ
# end

# the reason seems to be that having sys stored in p obfuscates type inference.
# when unpacking sys, the compiler can no longer tell its type, and therefore
# has no knowledge of the types of sys.x, sys.dx, sys.y and sys.t. since these
# are being assigned to and read from, the type instability kills performance.

# this can be fixed by storing the x, dx and y fields of sys directly as entries
# of p. this probably fixes their types during construction, so when they are
# accessed later in the closure, the type instability is no longer an issue.

# however, this is redundant! we already have x, dx, y and t inside of sys. a
# more elegant alternative is simply to use a function barrier, first extract
# sys, then call another function using it as an argument. this forces the
# compiler to infer its type, and therefore it specializes the time-critical
# assignment statements to their actual types.

###########################################################################

#to try:

#in System, define and extend f_branch!

# #individual Component
# f_branch!(y, dx, x, u, t, sys, args...) = f_branch!(Val(has_input(sys)), y, dx, x, u, t, args...)
# f_branch!(::Val{true}, y, dx, x, u, t, sys, args...) = f_cont!(y, dx, x, u, t, sys, args...)
# f_cont!(::HasInput, y, dx, x ,u, t, sys, args...) = f_cont!(y, dx, x, u, t, sys, args...)
# f_cont!(::HasNoInput, y, dx, x, u, t, sys, args...) = f_cont!(y, dx, x, t, sys, args...)

# #for a AirframeGroup
# f_cont!(MaybeInput(S), MaybeOutput(S), y, dx, x, u, t, sys, args...)
# f_cont!(::HasInput, ::HasOutput, y, dx, x ,u, t, sys, args...)
# #now, this method needs to consider the possibility for each component that it
# #may have or not Input or Output. so it must do
# for (label, component) in zip(keys(C), values(C))
#     if MaybeInput(typeof(component)) #need tocheck, because if it has no input, u[label] will not exist!
#         f_cont!(y_cmp, dx_cmp, x_cmp, u_cmp, t, cmp, args...)
#     else
#         f_cont!(y_cmp, dx_cmp, x_cmp, t, cmp, args...)
#     end
# end

end