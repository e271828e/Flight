module Powerplant

using LinearAlgebra
using StaticArrays
using ComponentArrays
using UnPack

using Flight.Dynamics
using Flight.AirData
using Flight.System
import Flight.System: x_template, u_template, init_data, init_output, f_output!

export SimpleProp, Gearbox, ElectricMotor
export EThruster, EThrusterX, EThrusterU, EThrusterY, EThrusterD, EThrusterSys

export EPowerplant, EPowerplantSys

@enum TurnSense begin
    CW = 1
    CCW = -1
end

Base.@kwdef struct SimpleProp
    kF::Float64 = 0.1
    kM::Float64 = 0.01
    J::Float64 = 1.0
end

Base.@kwdef struct Gearbox
    n::Float64 = 1.0 #gear ratio
    η::Float64 = 1.0 #efficiency
end

Base.@kwdef struct ElectricMotor #defaults from Hacker Motors Q150-4M-V2
    i₀::Float64 = 6.78
    R::Float64 = 0.004
    kV::Float64 = 13.09 #rad/s/V
    Vb::Float64 = 48
    J::Float64 = 0.003 #kg*m^2 #ballpark figure, assuming a cylinder
    s::TurnSense = CW
end

Base.@kwdef struct EThruster <: System.Component
    frame::FrameTransform = FrameTransform()
    motor::ElectricMotor = ElectricMotor()
    gearbox::Gearbox = Gearbox()
    propeller::SimpleProp = SimpleProp()
end

function wrench(prop::SimpleProp, ω::Real, ::AirDataSensed) #air data just for interface demo
    @unpack kF, kM = prop
    F_ext_Os_s = kF * ω^2 * SVector(1,0,0)
    M_ext_Os_s = -sign(ω) * kM * ω^2 * SVector(1,0,0)
    Wrench(F = F_ext_Os_s, M = M_ext_Os_s)
end

function torque(eng::ElectricMotor, throttle::Real, ω::Real)
    @unpack i₀, R, kV, Vb, s = eng
    V = i₀ * R + throttle * Vb
    return Int(s) * ((V - Int(s)*ω/kV) / R - i₀) / kV
end

x_template(::Type{EThruster}) = ComponentVector(ω_shaft = 0.0)
const EThrusterXAxes = typeof(getaxes(x_template(EThruster)))
const EThrusterX{D} = ComponentVector{Float64, D, EThrusterXAxes} where {D<:AbstractVector{Float64}}

u_template(::Type{EThruster}) = ComponentVector(throttle = 0.0)
const EThrusterUAxes = typeof(getaxes(u_template(EThruster)))
const EThrusterU{D} = ComponentVector{Float64, D, EThrusterUAxes} where {D<:AbstractVector{Float64}}

Base.@kwdef mutable struct EThrusterY
    throttle::Float64 = 0.0
    ω_shaft::Float64 = 0.0
    ω_prop::Float64 = 0.0
    wr_Oc_c::Wrench = Wrench()
    wr_Ob_b::Wrench = Wrench()
    h_Gc_b::SVector{3, Float64} = SVector{3}(0,0,0)
end

#external data sources required by the update function
Base.@kwdef mutable struct EThrusterD
    air::AirDataSensed = AirDataSensed()
end
#this is only called by the System constructor when the component is simulated
#as a standalone System. when it is part of a hierarchy, the nodes above will
#hold the required input data and pass it to f_output!
init_data(::EThrusterX, ::EThrusterU, ::Real, ::EThruster) = EThrusterD()

function init_output(x::EThrusterX, u::EThrusterU, t::Real, data::EThrusterD, thr::EThruster)
    ẋ = x_template(thr)
    y = EThrusterY()
    f_output!(y, ẋ, x, u, t, data, thr)
    return y, ẋ
end

function f_output!(y::EThrusterY, ẋ::EThrusterX,
    x::EThrusterX, u::EThrusterU, ::Real,
    data::EThrusterD, thr::EThruster)

    @unpack frame, motor, propeller, gearbox = thr
    @unpack n, η = gearbox

    throttle = u.throttle
    ω_shaft = x.ω_shaft
    ω_prop = ω_shaft / n

    wr_Oc_c = wrench(propeller, ω_prop, data.air)
    wr_Ob_b = frame * wr_Oc_c

    M_eng_shaft = torque(motor, throttle, ω_shaft)
    M_air_prop = wr_Oc_c.M[1]

    ω_shaft_dot = (M_eng_shaft + M_air_prop/(η*n)) / (motor.J + propeller.J/(η*n^2))

    h_Gc_c = SVector(motor.J * ω_shaft + propeller.J * ω_prop, 0, 0)
    h_Gc_b = frame.q_bc * h_Gc_c

    #update out.ẋ (will be assigned to the integrator's ẋ later)
    ẋ.ω_shaft = ω_shaft_dot

    #update out.y
    @pack! y = throttle, ω_shaft, ω_prop, wr_Oc_c, wr_Ob_b, h_Gc_b

    return nothing

end


EThrusterSys(thr::EThruster = EThruster(); kwargs...) =
    System.Continuous(thr; kwargs...)


#################### ElectricPowerplant #######################

#TO DO: consider including the complete named tuple of thruster descriptors in
#the type parameter itself, instead of the size. it may help with type stability
#if and when heterogeneous thrusters are allowed and fields become Unions or
#abstract subtypes (which is not good).

#TO DO: the same goes for EThruster. why not include the descriptors for
#Electric Motor, Gearbox and Propeller in a type parameter?

#TO DO: hell, the complete aircraft hierarchy could be stored in this manner:
#Aircraft{LandingGear, Powerplant, Actuation}

#LandingGear can be composed of a number of LandingGearLeg or LandingGearUnit,
#which could have multiple type parameters: Steerable, Braking, Castoring, etc

struct EPowerplant{T} <: System.Component
    function ElectricPowerplant(nt::NamedTuple) #Dicts are not ordered, so they won't do
        @assert eltype(nt) == EThruster
        new{nt}()
    end
end
EPowerplant() = EPowerplant((left = EThruster(), right = EThruster()))

# init_x(p::ElectricPowerplant) = ComponentVector(NamedTuple{p.labels}(init_x.(p.thrusters)))
# init_u(p::ElectricPowerplant) = ComponentVector(NamedTuple{p.labels}(init_u.(p.thrusters)))
# init_y(p::ElectricPowerplant) = NamedTuple{p.labels}(init_y.(p.thrusters))

# function f_update!(y, ẋ, x, u, t, pwp::ElectricPowerplant)
#     for (name, thruster) in zip(pwp.labels, pwp.thrusters)
#         f_update!(map(input->getproperty(input,name), (y, ẋ, x, u))..., t, thruster)
#     end
# end

# function f_output!(y, x, u, t, pwp::ElectricPowerplant)
#     for (name, thruster) in zip(pwp.labels, pwp.thrusters)
#         f_output!(map(input->getproperty(input,name), (y, x, u))..., t, thruster)
#     end
# end

# ElectricPowerplantSystem(d::ElectricPowerplant = ElectricPowerplant(); kwargs...) =
#     System.Continuous(d; kwargs...)

#this allows us to generalize to the case of an heterogeneous powerplant where
#some elements have a state and others don't

# names = keys(p.thrusters)
# blocks = init_u.(values(p.thrusters))
# with_u = collect(blocks.!=nothing)
# nt = NamedTuple{names[with_u]}(blocks[with_u])
# ComponentVector(nt)

#
end #module