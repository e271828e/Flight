module Airframe

using StaticArrays
using LinearAlgebra
using UnPack
using ComponentArrays

using Flight.WGS84
using Flight.Attitude
using Flight.Kinematics
using Flight.Airdata
using Flight.System
import Flight.System: X, Y, U, D, f_cont!

export Acc, AccY
export Wrench, MassData, AbstractComponent, ComponentFrame, ComponentGroup, Wrench
export get_wr_Ob_b, get_h_Gc_b, inertia_wrench, gravity_wrench, f_vel!

struct Acc end

const AccYTemplate = ComponentVector(
    α_eb_b = zeros(3), α_ib_b = zeros(3), a_eOb_b = zeros(3), a_iOb_b = zeros(3))

const AccY{D} = ComponentVector{Float64, D, typeof(getaxes(AccYTemplate))} where {D<:AbstractVector{Float64}}
Y(::Acc) = similar(AccYTemplate)

Base.@kwdef struct MassData
    m::Float64 = 1.0
    J_Ob_b::SMatrix{3, 3, Float64, 9} = SMatrix{3,3,Float64}(I)
    r_ObG_b::SVector{3, Float64} = zeros(SVector{3})
end

################ AbstractComponent Interface ################

abstract type AbstractComponent <: AbstractSystem end

get_wr_Ob_b(::Any, comp::AbstractComponent) = error("Method not implemented for subtype $comp or incorrect call signature")
get_h_Gc_b(::Any, comp::AbstractComponent) = error("Method not implemented for subtype $comp or incorrect call signature")

################# Wrench ########################

const WrenchAxes = getaxes(ComponentVector(F = zeros(3), M = zeros(3)))
# const WrenchAxes = WrenchAxes
const WrenchCV{D} = ComponentVector{Float64, D, typeof(WrenchAxes)} where {D <: AbstractVector{Float64}}
const Wrench(v::AbstractVector{Float64}) = (@assert length(v) == 6; ComponentVector(v, WrenchAxes))
function Wrench(; F = SVector(0.0,0,0), M = SVector(0.0,0,0))
    wr = ComponentVector{Float64}(undef, WrenchAxes)
    wr.F = F; wr.M = M
    return wr
end

####################### ComponentFrame ###############

"""
#Specifies a local ComponentFrame fc(Oc, Ɛc) relative to the airframe reference
frame fb(Ob, Ɛb) by:
#a) the position vector of the local frame origin Oc relative to the reference
#frame origin Ob, projected in the reference frame axes
# b) the attitude of the local frame axes relative to the reference
#frame axes, given by rotation quaternion q_bc
"""
Base.@kwdef struct ComponentFrame
    r_ObOc_b::SVector{3,Float64} = zeros(SVector{3})
    q_bc::RQuat = RQuat()
end

"""
Translate a Wrench specified on a local ComponentFrame fc(Oc, εc) to the
airframe reference frame fb(Ob, εb) given the relative ComponentFrame
specification f_bc
"""

function Base.:*(f_bc::ComponentFrame, wr_Oc_c::WrenchCV)

    F_Oc_c = wr_Oc_c.F
    M_Oc_c = wr_Oc_c.M

    #project on the reference axes
    F_Oc_b = f_bc.q_bc * F_Oc_c
    M_Oc_b = f_bc.q_bc * M_Oc_c

    #translate them to airframe origin
    F_Ob_b = F_Oc_b
    M_Ob_b = M_Oc_b + f_bc.r_ObOc_b × F_Oc_b
    Wrench(F = F_Ob_b, M = M_Ob_b) #wr_Ob_b

end

################# ComponentGroup ###############

struct ComponentGroup{T <: AbstractComponent, C} <: AbstractComponent
    function ComponentGroup(nt::NamedTuple{L, NTuple{N, T}}) where {L, N, T <: AbstractComponent} #Dicts are not ordered, so they won't do
        new{T,nt}()
    end
end
ComponentGroup(;kwargs...) = ComponentGroup((;kwargs...))
Base.getindex(::ComponentGroup{T, C}, i::Integer) where {T, C} = getindex(C, i)
Base.getproperty(::ComponentGroup{T, C}, i::Symbol) where {T, C} = getproperty(C, i)
labels(::ComponentGroup{T, C}) where {T, C} = keys(C)
components(::ComponentGroup{T, C}) where {T, C} = values(C)

X(::ComponentGroup{T, C}) where {T, C} = ComponentVector(NamedTuple{keys(C)}(X.(values(C))))
U(::ComponentGroup{T, C}) where {T, C} = ComponentVector(NamedTuple{keys(C)}(U.(values(C))))
Y(::ComponentGroup{T, C}) where {T, C} = ComponentVector(NamedTuple{keys(C)}(Y.(values(C))))
D(::ComponentGroup{T, C}) where {T, C} = D(C[1]) #assume all components use the same external data sources
# D(::ComponentGroup{T, C}) where {T, C} = NamedTuple{L}(D.(C))

@inline @generated function f_cont!(y::Any, ẋ::Any, x::Any, u::Any, t::Real,
                                      data::Any, ::ComponentGroup{T,C}) where {T,C}
    ex = Expr(:block)
    for label in keys(C)
        label = QuoteNode(label)
        ex_comp = quote
            y_cmp = @view y[$label]; ẋ_cmp = @view ẋ[$label]
            x_cmp = @view x[$label]; u_cmp = @view u[$label]
            f_cont!(y_cmp, ẋ_cmp, x_cmp, u_cmp, t, data, C[$label])
        end
        push!(ex.args, ex_comp)
    end
    return ex
end

@inline @generated function get_wr_Ob_b(y::Any, ::ComponentGroup{T,C}) where {T,C}

    ex = Expr(:block)
    push!(ex.args, :(wr = Wrench())) #allocate a zero wrench

    for label in keys(C)
        label = QuoteNode(label)
        ex_comp = quote
            #extract and perform in-place broadcasted addition of each
            #component's wrench
            wr .+= get_wr_Ob_b(view(y,$label), C[$label])
        end
        push!(ex.args, ex_comp)
    end
    return ex
end

@inline @generated function get_h_Gc_b(y::Any, ::ComponentGroup{T,C}) where {T,C}

    ex = Expr(:block)
    push!(ex.args, :(h = SVector(0., 0., 0.))) #allocate

    for label in keys(C)
        label = QuoteNode(label)
        ex_comp = quote
            h += get_h_Gc_b(view(y,$label), C[$label])
        end
        push!(ex.args, ex_comp)
    end
    return ex
end

################## f_vel! and helper functions ####################

function inertia_wrench(mass::MassData, y_vel::VelY, h_rot_b::AbstractVector{<:Real})

    @unpack m, J_Ob_b, r_ObG_b = mass

    ω_ie_b = SVector{3,Float64}(y_vel.ω_ie_b)
    ω_eb_b = SVector{3,Float64}(y_vel.ω_eb_b)
    ω_ib_b = SVector{3,Float64}(y_vel.ω_ib_b)
    v_eOb_b = SVector{3,Float64}(y_vel.v_eOb_b)

    #additional angular momentum due to the angular velocity of the rotating
    #elements with respect to the airframe
    h_rot_b = SVector{3,Float64}(h_rot_b)

    #angular momentum of the overall airframe as a rigid body
    h_rbd_b = J_Ob_b * ω_ib_b

    #total angular momentum
    h_all_b = h_rbd_b + h_rot_b

    #exact
    a_1_b = (ω_eb_b + 2 * ω_ie_b) × v_eOb_b
    F_in_Ob_b = -m * (a_1_b + ω_ib_b × (ω_ib_b × r_ObG_b) + r_ObG_b × (ω_eb_b × ω_ie_b ))
    M_in_Ob_b = - ( J_Ob_b * (ω_ie_b × ω_eb_b) + ω_ib_b × h_all_b + m * r_ObG_b × a_1_b)

    Wrench(F = F_in_Ob_b, M = M_in_Ob_b)

end

function gravity_wrench(mass::MassData, y_pos::PosY)

    #strictly, the gravity vector should be evaluated at G, with its direction
    #given by the z-axis of LTF(G). however, since g(G) ≈ g(Ob) and LTF(G) ≈
    #LTF(Ob), we can instead evaluate g at Ob, assuming its direction given by
    #LTF(Ob), and then apply it at G.
    q_el = RQuat(y_pos.q_el, normalization = false)
    q_lb = RQuat(y_pos.q_lb, normalization = false)
    Ob = WGS84Pos(NVector(q_el), y_pos.h)

    g_G_l = gravity(Ob)

    #the resultant consists of the force of gravity acting on G along the local
    #vertical and a null torque
    F_G_l = mass.m * g_G_l
    M_G_l = zeros(SVector{3})
    wr_G_l = Wrench(F = F_G_l, M = M_G_l)

    #with the previous assumption, the transformation from body frame to local
    #gravity frame is given by the translation r_ObG_b and the (passive)
    #rotation from b to LTF(Ob) (instead of LTF(G)), which is given by pos.l_b'
    wr_Oc_c = wr_G_l
    f_bc = ComponentFrame(r_ObOc_b = mass.r_ObG_b, q_bc = q_lb')
    return f_bc * wr_Oc_c #wr_Ob_b

end

function f_vel!(y_acc::AccY, ẋ_vel::VelX, wr_ext_Ob_b::WrenchCV,
    h_rot_b::AbstractVector{<:Real}, mass::MassData, y_kin::KinY)

    #wr_ext_Ob_b: External Wrench on the airframe due to aircraft components

    #h_rot_b: Additional angular momentum due to the angular velocity of the
    #rotating aircraft components with respect to the airframe. these are
    #computed individually by each component relative to its center of mass and
    #then summed

    #wr_ext_Ob_b and h_rot_b, as well as mass data, are produced by aircraft
    #components, so they must be computed by the aircraft's x_dot method. and,
    #since y_kin is needed by those components, it must be called from the
    #aircraft's kinematic state vector

    #clearly, r_ObG_b cannot be arbitrarily large, because J_Ob_b is larger than
    #J_G_b (Steiner). therefore, at some point J_G_b would become zero (or at
    #least singular)!

    @unpack m, J_Ob_b, r_ObG_b = mass

    ω_eb_b = SVector{3,Float64}(y_kin.vel.ω_eb_b)
    ω_ie_b = SVector{3,Float64}(y_kin.vel.ω_ie_b)
    v_eOb_b = SVector{3,Float64}(y_kin.vel.v_eOb_b)
    q_el = RQuat(y_kin.pos.q_el, normalization = false)
    q_eb = RQuat(y_kin.pos.q_eb, normalization = false)
    Ob = WGS84Pos(NVector(q_el), y_kin.pos.h)

    #preallocating is faster than directly concatenating the blocks
    A = Array{Float64}(undef, (6,6))

    r_ObG_b_sk = Attitude.skew(r_ObG_b)
    A[1:3, 1:3] .= J_Ob_b
    A[1:3, 4:6] .= m * r_ObG_b_sk
    A[4:6, 1:3] .= -m * r_ObG_b_sk
    A[4:6, 4:6] .= m * SMatrix{3,3,Float64}(I)

    A = SMatrix{6,6}(A)

    wr_g_Ob_b = gravity_wrench(mass, y_kin.pos)
    wr_in_Ob_b = inertia_wrench(mass, y_kin.vel, h_rot_b)
    wr_Ob_b = wr_ext_Ob_b + wr_g_Ob_b + wr_in_Ob_b
    b = SVector{6}([wr_Ob_b.M ; wr_Ob_b.F])

    ẋ_vel .= A\b

    #update y_acc
    v̇_eOb_b = SVector{3}(ẋ_vel.v_eOb_b)
    r_eO_e = rECEF(Ob)
    r_eO_b = q_eb' * r_eO_e

    α_eb_b = SVector{3}(ẋ_vel.ω_eb_b) #α_eb_b == ω_eb_b_dot
    α_ib_b = α_eb_b - ω_eb_b × ω_ie_b
    a_eOb_b = v̇_eOb_b + ω_eb_b × v_eOb_b
    a_iOb_b = v̇_eOb_b + (ω_eb_b + 2ω_ie_b) × v_eOb_b + ω_ie_b × (ω_ie_b × r_eO_b)

    y_acc.α_eb_b .= α_eb_b #α_eb_b == ω_eb_b_dot
    y_acc.α_ib_b .= α_ib_b
    y_acc.a_eOb_b .= a_eOb_b
    y_acc.a_iOb_b .= a_iOb_b

    return nothing

end

end #module