module Airframe #this module is really needed, do NOT merge it into aircraft

using LinearAlgebra
using StaticArrays
using ComponentArrays
using UnPack

using Flight.Attitude
using Flight.System
using Flight.Dynamics

import Flight.System: HybridSystem, get_x0, get_y0, get_u0, get_d0, f_cont!, f_disc!
import Flight.Dynamics: get_wr_b, get_hr_b

export ACGroup, ACGroupD, ACGroupU, ACGroupY
export AbstractAirframeComponent


abstract type AbstractAirframeComponent <: AbstractComponent end

######################### AirframeComponentGroup #############################

#we must keep N as a type parameter, because it's left open in the components
#type declaration!
struct ACGroup{T<:AbstractAirframeComponent,N,L} <: AbstractAirframeComponent
    components::NamedTuple{L, M} where {L, M <: NTuple{N, T}}
    function ACGroup(nt::NamedTuple{L, M}) where {L, M<:NTuple{N, T}} where {N, T<:AbstractAirframeComponent}
        new{T,N,L}(nt)
    end
end

ACGroup(;kwargs...) = ACGroup((; kwargs...))

Base.length(::ACGroup{T,N,L}) where {T,N,L} = N
Base.getindex(g::ACGroup, i) = getindex(getfield(g,:components), i)
Base.getproperty(g::ACGroup, i::Symbol) = getproperty(getfield(g,:components), i)
Base.keys(::ACGroup{T,N,L}) where {T,N,L} = L
Base.values(g::ACGroup) = values(getfield(g,:components))


struct ACGroupU{U<:AbstractU,N,L} <: AbstractU{ACGroup}
    nt::NamedTuple{L, NTuple{N,U}}
    function ACGroupU(nt::NamedTuple{L, M}) where {L, M<:NTuple{N, U}} where {N, U}
        new{U,N,L}(nt)
    end
end

struct ACGroupD{D<:AbstractD,N,L} <: AbstractD{ACGroup}
    nt::NamedTuple{L, NTuple{N,D}}
    function ACGroupD(nt::NamedTuple{L, M}) where {L, M<:NTuple{N, D}} where {N, D}
        new{D,N,L}(nt)
    end
end

struct ACGroupY{Y<:AbstractY,N,L} <: AbstractY{ACGroup}
    nt::NamedTuple{L, NTuple{N,Y}}
    function ACGroupY(nt::NamedTuple{L, M}) where {L, M<:NTuple{N, Y}} where {N, Y}
        new{Y,N,L}(nt)
    end
end

get_x0(g::ACGroup{T,N,L}) where {T,N,L} = ComponentVector(NamedTuple{L}(get_x0.(values(g))))
get_u0(g::ACGroup{T,N,L}) where {T,N,L} = ACGroupU(NamedTuple{L}(get_u0.(values(g))))
get_y0(g::ACGroup{T,N,L}) where {T,N,L} = ACGroupY(NamedTuple{L}(get_y0.(values(g))))
get_d0(g::ACGroup{T,N,L}) where {T,N,L} = ACGroupD(NamedTuple{L}(get_d0.(values(g))))

Base.getproperty(y::Union{ACGroupY, ACGroupD, ACGroupU}, s::Symbol) = getproperty(getfield(y,:nt), s)
Base.getindex(y::Union{ACGroupY, ACGroupD, ACGroupU}, s::Symbol) = getindex(getfield(y,:nt), s)

########## ALL OF THESE NEED FIXING!!!!!!

function HybridSystem(g::ACGroup{T,N,L},
                    ẋ = get_x0(g), x = get_x0(g), y = get_y0(g), u = get_u0(g),
                    d = get_d0(g), t = Ref(0.0)) where {T,N,L}

    s_list = Vector{HybridSystem}()
    for label in L
        s_cmp = HybridSystem(map((λ)->getproperty(λ, label), (g, ẋ, x, y, u, d))..., t)
        push!(s_list, s_cmp)
    end

    params = nothing #everything is already stored in the subsystem's parameters
    subsystems = NamedTuple{L}(s_list)

    HybridSystem{map(typeof, (g, x, y, u, d, params, subsystems))...}(ẋ, x, y, u, d, t, params, subsystems)
end

@inline @generated function f_cont!(sys::HybridSystem{C}, args...
    ) where {C<:ACGroup{T,N,L}} where {T <: AbstractAirframeComponent,N,L}

    ex_main = Expr(:block)

    #call f_cont! on each subsystem
    ex_calls = Expr(:block)
    for label in L
        push!(ex_calls.args,
            :(f_cont!(sys.subsystems[$(QuoteNode(label))], args...)))
    end

    #retrieve the y from each subsystem and build a tuple with them
    ex_tuple = Expr(:tuple)
    for label in L
        push!(ex_tuple.args,
            :(sys.subsystems[$(QuoteNode(label))].y))
    end

    #build a NamedTuple from the subsystem's labels and the constructed tuple,
    #and pass it to the ACGroupY's constructor
    ex_y = Expr(:call, ACGroupY, Expr(:call, Expr(:curly, NamedTuple, L), ex_tuple))

    #assign the resulting ACGroupY to the parent system's y
    ex_assign_y = Expr(:(=), :(sys.y), ex_y)

    #pack everything into the main block expression
    push!(ex_main.args, ex_calls)
    push!(ex_main.args, ex_assign_y)
    push!(ex_main.args, :(return nothing))

    return ex_main

end


@inline @generated function (f_disc!(sys::HybridSystem{C}, args...)::Bool
    ) where {C<:ACGroup{T,N,L}} where {T <:AbstractAirframeComponent,N,L}

    ex = Expr(:block)
    push!(ex.args, :(x_mod = false))
    for label in L
        #we need all f_disc! calls executed, so | must be used instead of ||
        push!(ex.args,
            :(x_mod = x_mod | f_disc!(sys.subsystems[$(QuoteNode(label))], args...)))
    end
    return ex

end

@inline @generated function get_wr_b(sys::HybridSystem{C}
    ) where {C<:ACGroup{T,N,L}} where {T <: AbstractAirframeComponent,N,L}

    ex = Expr(:block)
    push!(ex.args, :(wr = Wrench())) #allocate a zero wrench
    for label in L
        push!(ex.args,
            :(wr += get_wr_b(sys.subsystems[$(QuoteNode(label))])))
    end
    return ex

end

@inline @generated function get_hr_b(sys::HybridSystem{C}
    ) where {C<:ACGroup{T,N,L}} where {T <: AbstractAirframeComponent,N,L}

    ex = Expr(:block)
    push!(ex.args, :(h = SVector(0., 0., 0.))) #allocate
    for label in L
        push!(ex.args,
            :(h += get_hr_b(sys.subsystems[$(QuoteNode(label))])))
    end
    return ex

end



end