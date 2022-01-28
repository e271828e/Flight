module Beaver

using LinearAlgebra
using StaticArrays
using ComponentArrays
using UnPack
using Unitful

using Flight.Modeling
using Flight.Plotting
using Flight.Misc
using Flight.Attitude
using Flight.Terrain
using Flight.Airdata
using Flight.Kinematics
using Flight.Dynamics
using Flight.Aerodynamics: AbstractAerodynamics
using Flight.Propulsion: EThruster, ElectricMotor, SimpleProp, CW, CCW
using Flight.LandingGear: LandingGearUnit, DirectSteering, DirectBraking, Strut, SimpleDamper
using Flight.Aircraft: AircraftBase, AbstractAircraftID, AbstractAirframe
using Flight.Input: XBoxController, get_axis_value, is_released

import Flight.Modeling: init_x, init_y, init_u, init_d, f_cont!, f_disc!
import Flight.Plotting: plots
import Flight.Dynamics: MassTrait, WrenchTrait, AngularMomentumTrait, get_wr_b, get_mp_b
import Flight.Input: assign!
import Flight.Output: update!

export BeaverDescriptor

struct ID <: AbstractAircraftID end


############################## Powerplant ################################

struct Pwp <: SystemGroupDescriptor
    left::EThruster
    right::EThruster
end

WrenchTrait(::System{<:Pwp}) = HasWrench()
AngularMomentumTrait(::System{<:Pwp}) = HasAngularMomentum()

function Pwp()

    prop = SimpleProp(kF = 1e-2, J = 0.25)

    left = EThruster(propeller = prop, motor = ElectricMotor(α = CW))
    right = EThruster(propeller = prop, motor = ElectricMotor(α = CCW))

    Pwp(left, right)

end

######################### Powerplant Real ####################################

"""
El modelo de motor del report es valido solo dentro de un cierto intervalo de
velocidades. Esto es particularmente evidente viendo que el dpt tiene una V^3 en
el denominador.

Las dos preguntas inmediatas son: cual es este intervalo de validez? que hacemos
fuera de el?

Para responder, echamos mano de Fundamentals of Aircraft and Airship Design,
Vol. 1, Ch 17, Fig 17.20 y Fig 17.19.

Calculamos la potencia en funcion de pz (manifold pressure), rho y n (rpm). a
partir de aqui, el modelo se bifurca en dos. una de baja velocidad, y otra de
alta velocidad. a baja velocidad, solo consideramos el CX dado por las
tablas, las otras 5 contribuciones
"""

############################ LandingGear ############################

# looking at pictures of the aircraft, the coordinates for the bottom of the MLG
# wheels are roughly [0, +/-1.2, 2.3] and the coordinates for the bottom of the
# TLG wheel are roughly [-6.5, 0, 1.8]

struct Ldg{L <: LandingGearUnit, R <: LandingGearUnit,
    T <: LandingGearUnit} <: SystemGroupDescriptor
    left::L
    right::R
    tail::T
end

WrenchTrait(::System{<:Ldg}) = HasWrench()
AngularMomentumTrait(::System{<:Ldg}) = HasNoAngularMomentum()

function Ldg()

    main_damper = SimpleDamper(k_s = 100000, k_d_ext = 2000, k_d_cmp = 2000)
    tail_damper = SimpleDamper(k_s = 100000, k_d_ext = 2000, k_d_cmp = 2000)

    left = LandingGearUnit(
        strut = Strut(
            t_bs = FrameTransform(r = [0, -1.2, 2.5], q = RQuat() ),
            l_0 = 0.0,
            damper = main_damper),
        braking = DirectBraking())

    right = LandingGearUnit(
        strut = Strut(
            t_bs = FrameTransform(r = [0, 1.2, 2.5], q = RQuat() ),
            l_0 = 0.0,
            damper = main_damper),
        braking = DirectBraking())

    tail = LandingGearUnit(
        strut = Strut(
            # t_bs = FrameTransform(r = [-6.5, 0, 1.8] , q = RQuat()),
            t_bs = FrameTransform(r = [-6.5, 0, 1.05] , q = RQuat()), #XPlane cosmetics
            l_0 = 0.0,
            damper = tail_damper),
        steering = DirectSteering())

    Ldg(left, right, tail)

end

###############################  Aerodynamics ###########################

#we need a generic aerodynamics system, which computes all the input values to
#the aerodynamic coefficient tables, including filtered alphadot and betadot,
#and total thrust (which can be retrieved by calling get_wr_b on the pwp model)
#its interface should be f_cont!(aero, air, pwp, ldg, kin, trn). This System's
#descriptor can be parameterized with a type AerodynamicsDataset that allows
#dispatching on a method get_aerodynamic_coefficients(::AeroDataset, alpha,
#alpha_dot, beta, beta_dot, etc), which returns C_X, C_Y, C_Z, C_l, C_m, etc. to
#the main Aerodynamics System. the AerodynamicsDataset and its associated
#get_coefficients method has all the specifics required by each aircraft. the
#AerodynamicsDataset type itself can be empty (a dummy type) or have actual
#fields required for the computation

#should probably define a struct AerodynamicCoefficients with fields Cx, Cy, Cz,
#Cl, Cm, Cn to clearly define the interface for an AeroDataset. since the
#scaling factors for transforming that into component axes are always the same
#(dynamic pressure, etc) maybe we should keep that in the generic root
#Aerodynamics System. If it turns out the non-dimensionalization depends on the
#specific dataset, we should return the dimensional quantities instead.

#if the specific AeroDataset requires an intermediate expression in stability or
#wind axes, these can always be constructed alpha and beta by the standard
#methods

#nope... realistically, all computations should be probably grouped under a
#single Aerodynamics System, because the input arguments to the AeroDataset may
#change greatly from one aircraft to another

Base.@kwdef struct Aero <: AbstractAerodynamics
    S::Float64 = 23.23 #wing area
    b::Float64 = 14.63 #wingspan
    c::Float64 = 1.5875 #mean aerodynamic chord
    τ::Float64 = 0.1 #time constant for airflow angle filtering
    δe_max::Float64 = 30 |> deg2rad #maximum elevator deflection (rad)
    δa_max::Float64 = 40 |> deg2rad #maximum (combined) aileron deflection (rad)
    δr_max::Float64 = 30 |> deg2rad #maximum rudder deflection (rad)
    δf_max::Float64 = 30 |> deg2rad #maximum flap deflection (rad)
end

Base.@kwdef mutable struct AeroU
    e::Bounded{Float64, -1, 1} = 0.0 #elevator control input (+ pitch down)
    a::Bounded{Float64, -1, 1} = 0.0 #aileron control input (+ roll left)
    r::Bounded{Float64, -1, 1} = 0.0 #rudder control input (+ yaw left)
    f::Bounded{Float64, 0, 1} = 0.0 # flap control input (+ flap down)
end

Base.@kwdef struct AeroY
    α::Float64 = 0.0 #preprocessed AoA
    α_filt::Float64 = 0.0 #filtered AoA
    α_filt_dot::Float64 = 0.0 #filtered AoA derivative
    β::Float64 = 0.0 #preprocessed AoS
    β_filt::Float64 = 0.0 #filtered AoS
    β_filt_dot::Float64 = 0.0 #filtered AoS derivative
    e::Float64 = 0.0 #normalized elevator control input
    a::Float64 = 0.0 #normalized aileron control input
    r::Float64 = 0.0 #normalized rudder control input
    f::Float64 = 0.0 #normalized flap control input
    wr_s::Wrench = Wrench() #aerodynamic wrench, stability frame
    wr_b::Wrench = Wrench() #aerodynamic wrench, airframe
end

init_x(::Type{Aero}) = ComponentVector(α_filt = 0.0, β_filt = 0.0) #filtered airflow angles
init_y(::Type{Aero}) = AeroY()
init_u(::Type{Aero}) = AeroU()


############################## Controls #################################

struct Controls <: SystemDescriptor end

Base.@kwdef mutable struct ControlsU
    throttle::Bounded{Float64, 0, 1} = 0.0
    yoke_Δx::Bounded{Float64, -1, 1} = 0.0 #ailerons (+ bank right)
    yoke_x0::Bounded{Float64, -1, 1} = 0.0 #ailerons (+ bank right)
    yoke_Δy::Bounded{Float64, -1, 1} = 0.0 #elevator (+ pitch up)
    yoke_y0::Bounded{Float64, -1, 1} = 0.0 #elevator (+ pitch up)
    pedals::Bounded{Float64, -1, 1} = 0.0 #rudder and nose wheel (+ yaw right)
    brake_left::Bounded{Float64, 0, 1} = 0.0 #[0, 1]
    brake_right::Bounded{Float64, 0, 1} = 0.0 #[0, 1]
    flaps::Bounded{Float64, 0, 1} = 0.0 #[0, 1]
end

#const is essential when declaring type aliases!
Base.@kwdef struct ControlsY
    throttle::Float64
    yoke_Δx::Float64
    yoke_x0::Float64
    yoke_Δy::Float64
    yoke_y0::Float64
    pedals::Float64
    brake_left::Float64
    brake_right::Float64
    flaps::Float64
end

init_u(::Type{Controls}) = ControlsU()
init_y(::Type{Controls}) = ControlsY(zeros(SVector{9})...)


############################## Airframe #################################

Base.@kwdef struct Airframe{ A <: SystemDescriptor, P <: SystemDescriptor,
                        L <: SystemDescriptor} <: AbstractAirframe
    aero::A = Aero()
    pwp::P = Pwp()
    ldg::L = Ldg()
end

MassTrait(::System{<:Airframe}) = HasMass()
WrenchTrait(::System{<:Airframe}) = HasWrench()
AngularMomentumTrait(::System{<:Airframe}) = HasAngularMomentum()


################## Aero Update Functions #######################

function f_cont!(sys::System{Aero}, pwp::System{Pwp},
    air::AirData, kinematics::KinData, terrain::AbstractTerrain)

    #USING BEAVER AERODYNAMICS

    #in this aircraft, the aerodynamics' frame is the airframe itself (b), so
    #we can just use the airflow angles computed by the air data module for the
    #airframe axes. no need to recompute them on a local component frame

    #for near-zero TAS, the airflow angles are likely to chatter between 0, -π
    #and π. this introduces noise in airflow angle derivatives and general
    #unpleasantness. to fix it we fade them in from zero to a safe threshold. as
    #for V, it's only used for non-dimensionalization. we just need to avoid
    #dividing by zero. for TAS < TAS_min, dynamic pressure will be close to zero
    #and therefore forces and moments will vanish anyway.

    @unpack ẋ, x, u, params = sys
    @unpack α_filt, β_filt = x
    @unpack S, b, c, δe_max, δa_max, δr_max, δf_max, τ = params
    @unpack e, a, r, f = u
    @unpack TAS, q, α_b, β_b = air
    ω_lb_b = kinematics.vel.ω_lb_b

    #preprocess airflow angles and airspeed. looking at the lift/drag polar +/-1
    #seem like reasonable airflow angle limits
    TAS_min = 2.0
    χ_TAS = min(TAS/TAS_min, 1.0) #linear fade-in for airflow angles
    α = clamp(α_b * χ_TAS, -1.0, 1.0)
    β = clamp(β_b * χ_TAS, -1.0, 1.0)
    V = max(TAS, TAS_min)

    α_filt_dot = 1/τ * (α - α_filt)
    β_filt_dot = 1/τ * (β - β_filt)

    p_nd = ω_lb_b[1] * b / (2V) #non-dimensional roll rate
    q_nd = ω_lb_b[2] * c / V #non-dimensional pitch rate
    r_nd = ω_lb_b[3] * b / (2V) #non-dimensional yaw rate

    α_dot_nd = α_filt_dot * c / (2V) #not used
    β_dot_nd = β_filt_dot * b / (2V)

    ẋ.α_filt = α_filt_dot
    ẋ.β_filt = β_filt_dot

    # T = get_wr_b(pwp).F[1]
    # C_T = T / (q * S) #thrust coefficient, not used
    δe = Float64(e) * δe_max
    δa = Float64(a) * δa_max
    δr = Float64(r) * δr_max
    δf = Float64(f) * δf_max

    C_X, C_Y, C_Z, C_l, C_m, C_n = get_coefficients(; α, β, p_nd, q_nd, r_nd,
        δa, δr, δe, δf, α_dot_nd, β_dot_nd)

    F_aero_b = q * S * SVector{3,Float64}(C_X, C_Y, C_Z)
    M_aero_b = q * S * SVector{3,Float64}(C_l * b/2, C_m * c, C_n * b/2)

    wr_b = Wrench(F_aero_b, M_aero_b)

    q_bs = get_stability_axes(α)
    t_sb = FrameTransform(q = q_bs')
    wr_s = t_sb(wr_b)

    sys.y = AeroY(; α, α_filt, α_filt_dot, β, β_filt, β_filt_dot,
        e, a, r, f, wr_s, wr_b)

end

function get_coefficients(; α, β, p_nd, q_nd, r_nd, δa, δr, δe, δf, α_dot_nd, β_dot_nd)

    α² = α^2; α³ = α^3; β² = β^2; β³ = β^3

    C_X = -0.03554 + 0.00292α + 5.459α² - 5.162α³  - 0.6748q_nd + 0.03412δr - 0.09447δf + 1.106(δf*α)
    C_Y = -0.002226 - 0.7678β - 0.1240p_nd + 0.3666r_nd -0.02956δa + 0.1158δr + 0.5238(δr*α) - 0.16β_dot_nd
    C_Z = -0.05504 - 5.578α + 3.442α³ - 2.988q_nd - 0.3980δe - 1.377δf - 1.261(δf*α) - 15.93(δe*β²)
    C_l = 5.91e-4 - 0.0618β - 0.5045p_nd + 0.1695r_nd - 0.09917δa + 6.934e-3δr - 0.08269(δa*α)
    C_m = 0.09448 - 0.6028α - 2.14α² -15.56q_nd - 1.921δe + 0.6921β² - 0.3118r_nd + 0.4072δf
    C_n = -3.117e-3 + 6.719e-3β + 0.1373β³ - 0.1585p_nd + 0.1595q_nd - 0.1112r_nd - 3.872e-3δa - 0.08265δr

    return (C_X, C_Y, C_Z, C_l, C_m, C_n)

end

f_disc!(::System{Aero}) = false

get_wr_b(sys::System{Aero}) = sys.y.wr_b


######################## Controls Update Functions ###########################

function f_cont!(ctl::System{Controls}, ::System{Airframe},
                ::KinData, ::AirData, ::AbstractTerrain)

    #here, controls do nothing but update their output state. for a more complex
    #aircraft a continuous state-space autopilot implementation could go here
    @unpack throttle, yoke_Δx, yoke_x0, yoke_Δy, yoke_y0,
            pedals, brake_left, brake_right, flaps = ctl.u

    return ControlsY(; throttle, yoke_Δx, yoke_x0, yoke_Δy, yoke_y0,
                            pedals, brake_left, brake_right, flaps)

end

function f_disc!(::System{<:Controls}, ::System{<:Airframe})
    #this currently does nothing, but it may be used to implement open loop or
    #closed loop control laws, predefined maneuvers, etc. by calling an
    #externally overloadable function
    return false
end


####################### Airframe Update Functions ###########################

#the (left-handed) measurement frame defined in the report has its origin at the
#leading edge of the wing chord, x pointing backwards, z pointint upwards and y
#pointing to the left. here, the reference frame for the airframe is defined
#with the same origin, but with the conventional flight physics axes (x pointing
#forward, z downward and y to the right).

function f_cont!(afm::System{<:Airframe}, ctl::System{<:Controls},
                kin::KinData, air::AirData, trn::AbstractTerrain)

    @unpack aero, pwp, ldg = afm.subsystems

    #could this go in the main aircraft f_cont!?
    assign_component_inputs!(afm, ctl)
    # f_cont!(srf, air) #update surface actuator continuous state & outputs
    f_cont!(ldg, kin, trn) #update landing gear continuous state & outputs
    f_cont!(pwp, kin, air) #update powerplant continuous state & outputs
    f_cont!(aero, pwp, air, kin, trn)
    # f_cont!(aero, air, kin, srf, trn) #requires previous srf update

    afm.y = (aero = aero.y, pwp = pwp.y, ldg = ldg.y)

end

function f_disc!(afm::System{<:Airframe}, ::System{<:Controls})
    #fall back to the default SystemGroup implementation, the f_disc! for the
    # components don't have to deal with the Controls
    return f_disc!(afm)
end

function get_mp_b(::System{<:Airframe})

    #for an aircraft implementing a fuel system the current mass properties are
    #computed here by querying the fuel system for the contributions of the
    #different fuel tanks


    MassProperties(
        #upreferred(2650u"lb") |> ustrip,
        m = 2288, #(OEW = 1526, MTOW = 2324)
        #upreferred.([948, 1346, 1967]u"m") |> ustrip |> diagm |> SMatrix{3,3,Float64},
        J_O = SA[5368.39 0 117.64; 0 6928.93 0; 117.64 0 11158.75],
        r_OG = SVector{3,Float64}(-0.5996, 0, 0.8851))
end

#get_wr_b and get_hr_b use the fallback for SystemGroups, which in turn call
#get_wr_b and get_hr_b on aero, pwp and ldg

function assign_component_inputs!(afm::System{<:Airframe},
    ctl::System{<:Controls})

    @unpack throttle, yoke_Δx, yoke_x0, yoke_Δy, yoke_y0,
            pedals, brake_left, brake_right, flaps = ctl.u
    @unpack aero, pwp, ldg = afm.subsystems

    #yoke_Δx is the offset with respect to the force-free position yoke_x0
    #yoke_Δy is the offset with respect to the force-free position yoke_y0

    pwp.u.left.throttle = throttle
    pwp.u.right.throttle = throttle
    ldg.u.tail.steering[] = -pedals #wheel is behind CG, so we must switch sign
    ldg.u.left.braking[] = brake_left
    ldg.u.right.braking[] = brake_right
    aero.u.e = -(yoke_y0 + yoke_Δy) #+yoke_Δy and +yoke_y0 are back and +δe is pitch down, need to invert it
    aero.u.a = -(yoke_x0 + yoke_Δx) #+yoke_Δx and +yoke_x0 are right and +δa is roll left, need to invert it
    aero.u.r = -pedals # +pedals is right and +δr is yaw left
    aero.u.f = flaps # +flaps is flaps down and +δf is flaps down

    return nothing
end

######################## XBoxController Input Interface ########################

elevator_curve(x) = exp_axis_curve(x, strength = 0.5, deadzone = 0.05)
aileron_curve(x) = exp_axis_curve(x, strength = 0.5, deadzone = 0.05)
pedal_curve(x) = exp_axis_curve(x, strength = 1.5, deadzone = 0.05)
brake_curve(x) = exp_axis_curve(x, strength = 0, deadzone = 0.05)

function exp_axis_curve(x::Bounded{T}, args...; kwargs...) where {T}
    exp_axis_curve(T(x), args...; kwargs...)
end

function exp_axis_curve(x::Real; strength::Real = 0.0, deadzone::Real = 0.0)

    a = strength
    x0 = deadzone

    abs(x) <= 1 || throw(ArgumentError("Input to exponential curve must be within [-1, 1]"))
    (x0 >= 0 && x0 <= 1) || throw(ArgumentError("Exponential curve deadzone must be within [0, 1]"))

    if x > 0
        y = max(0, (x - x0)/(1 - x0)) * exp( a * (abs(x) -1) )
    else
        y = min(0, (x + x0)/(1 - x0)) * exp( a * (abs(x) -1) )
    end
end

function assign!(ac::System{<:AircraftBase{ID}}, joystick::XBoxController)

    u = ac.u.controls

    u.yoke_Δx = get_axis_value(joystick, :right_analog_x) |> aileron_curve
    u.yoke_Δy = get_axis_value(joystick, :right_analog_y) |> elevator_curve
    u.pedals = get_axis_value(joystick, :left_analog_x) |> pedal_curve
    u.brake_left = get_axis_value(joystick, :left_trigger) |> brake_curve
    u.brake_right = get_axis_value(joystick, :right_trigger) |> brake_curve

    u.yoke_x0 -= 0.01 * is_released(joystick, :dpad_left)
    u.yoke_x0 += 0.01 * is_released(joystick, :dpad_right)
    u.yoke_y0 -= 0.01 * is_released(joystick, :dpad_up)
    u.yoke_y0 += 0.01 * is_released(joystick, :dpad_down)

    u.throttle += 0.1 * is_released(joystick, :button_Y)
    u.throttle -= 0.1 * is_released(joystick, :button_A)

    # u.propeller_speed += 0.1 * is_released(joystick, :button_X) #rpms
    # u.propeller_speed -= 0.1 * is_released(joystick, :button_B)

    u.flaps += 0.5 * is_released(joystick, :right_bumper)
    u.flaps -= 0.5 * is_released(joystick, :left_bumper)

    # Y si quisiera landing gear up y down, podria usar option como
    #modifier

end

#Aircraft constructor override keyword inputs to customize

function BeaverDescriptor(; id = ID(), kin = KinLTF(), afm = Airframe(), ctl = Controls())
    AircraftBase( id; kin, afm, ctl)
end



end #module