module Aircraft

using LinearAlgebra, UnPack, StaticArrays, ComponentArrays

using Flight.FlightCore.Systems
using Flight.FlightCore.Plotting
using Flight.FlightCore.GUI
using Flight.FlightCore.XPC

using Flight.FlightPhysics.Attitude
using Flight.FlightPhysics.Geodesy
using Flight.FlightPhysics.Kinematics
using Flight.FlightPhysics.RigidBody
using Flight.FlightPhysics.Environment

export AbstractAirframe, EmptyAirframe
export AbstractAvionics, NoAvionics
export AircraftTemplate
export AbstractTrimParameters
export init_kinematics!, trim!, linearize!

################################################################################
########################### AbstractAirframe ###################################

abstract type AbstractAirframe <: SystemDefinition end
RigidBody.MassTrait(::System{<:AbstractAirframe}) = HasMass()
RigidBody.AngMomTrait(::System{<:AbstractAirframe}) = HasAngularMomentum()
RigidBody.WrenchTrait(::System{<:AbstractAirframe}) = GetsExternalWrench()

################################ EmptyAirframe #################################

@kwdef struct EmptyAirframe <: AbstractAirframe
    mass_distribution::RigidBodyDistribution = RigidBodyDistribution(1, SA[1.0 0 0; 0 1.0 0; 0 0 1.0])
end

RigidBody.AngMomTrait(::System{EmptyAirframe}) = HasNoAngularMomentum()
RigidBody.WrenchTrait(::System{EmptyAirframe}) = GetsNoExternalWrench()
RigidBody.get_mp_Ob(sys::System{EmptyAirframe}) = MassProperties(sys.params.mass_distribution)

################################################################################
############################## AircraftPhysics #################################

@kwdef struct AircraftPhysics{K <: AbstractKinematicDescriptor,
                              F <: AbstractAirframe} <: SystemDefinition
    kinematics::K = LTF()
    airframe::F = EmptyAirframe()
end

struct AircraftPhysicsY{K, F}
    kinematics::K
    airframe::F
    rigidbody::RigidBodyData
    air::AirData
end

Systems.init(::SystemY, ac::AircraftPhysics) = AircraftPhysicsY(
    init_y(ac.kinematics),
    init_y(ac.airframe),
    RigidBodyData(),
    AirData())

function init_kinematics!(sys::System{<:AircraftPhysics}, ic::KinematicInit)
    Kinematics.init!(sys.x.kinematics, ic)
end

###############################################################################
############################# AbstractAvionics #################################

abstract type AbstractAvionics <: SystemDefinition end

################################### NoAvionics #################################

struct NoAvionics <: AbstractAvionics end


###############################################################################
#################### AbstractAirframe update methods ###########################

#airframe update methods should only mutate the airframe System

function Systems.f_ode!(airframe::System{<:AbstractAirframe},
                        avionics::System{<:AbstractAvionics},
                        kin::KinematicData,
                        air::AirData,
                        trn::System{<:AbstractTerrain})
    MethodError(f_ode!, (airframe, avionics, kin, air, trn)) |> throw
end

function Systems.f_ode!(::System{EmptyAirframe},
                        ::System{<:AbstractAvionics},
                        ::KinematicData,
                        ::AirData,
                        ::System{<:AbstractTerrain})
    nothing
end

#this method can be extended if required, but in principle Airframe shouldn't
#implement discrete dynamics; discretized algorithms belong in Avionics
function Systems.f_disc!(::System{<:AbstractAirframe},
                        ::Real,
                        ::System{<:AbstractAvionics},
                        ::System{<:AbstractEnvironment})
    return false
end

#f_step! can use the recursive fallback implementation


###############################################################################
#################### AbstractAvionics update methods ###########################

#avionics update methods should only mutate the avionics System

#this method can be extended if required, but in principle avionics shouldn't
#involve continuous dynamics.
function Systems.f_ode!(::System{<:AbstractAvionics},
                        ::System{<:AircraftPhysics},
                        ::System{<:AbstractEnvironment})
    nothing
end

function Systems.f_disc!(avionics::System{<:AbstractAvionics},
                        Δt::Real,
                        physics::System{<:AircraftPhysics},
                        env::System{<:AbstractEnvironment})
    MethodError(f_disc!, (avionics, Δt, physics, env)) |> throw
end

function Systems.f_disc!(::System{NoAvionics},
                        ::Real,
                        ::System{<:AircraftPhysics},
                        ::System{<:AbstractEnvironment})
    return false
end

#f_step! can use the recursive fallback implementation


################################################################################
###################### AircraftPhysics Update methods ##########################

function Systems.f_ode!(physics::System{<:AircraftPhysics},
                        avionics::System{<:AbstractAvionics},
                        env::System{<:AbstractEnvironment})

    @unpack ẋ, x, subsystems = physics
    @unpack kinematics, airframe = subsystems
    @unpack atm, trn = env

    #update kinematics
    f_ode!(kinematics)
    kin_data = KinematicData(kinematics)
    air_data = AirData(kin_data, atm)

    #update airframe
    f_ode!(airframe, avionics, kin_data, air_data, trn)

    #get inputs for rigid body dynamics
    mp_Ob = get_mp_Ob(airframe)
    wr_b = get_wr_b(airframe)
    hr_b = get_hr_b(airframe)

    #update velocity derivatives and rigid body data
    rb_data = f_rigidbody!(kinematics.ẋ.vel, kin_data, mp_Ob, wr_b, hr_b)

    physics.y = AircraftPhysicsY(kinematics.y, airframe.y, rb_data, air_data)

    return nothing

end

#f_step! will use the recursive fallback implementation

#within AircraftPhysics, only the airframe may be modified by f_disc! (and it
#generally shouldn't)
function Systems.f_disc!(physics::System{<:AircraftPhysics},
                        Δt::Real,
                        avionics::System{<:AbstractAvionics},
                        env::System{<:AbstractEnvironment})

    @unpack kinematics, airframe = physics
    @unpack rigidbody, air = physics.y

    x_mod = false
    x_mod |= f_disc!(physics.airframe, Δt, avionics, env)

    #since airframe might have modified its outputs, we need to reassemble
    physics.y = AircraftPhysicsY(kinematics.y, airframe.y, rigidbody, air)

    return x_mod
end


################################################################################
############################## AircraftTemplate ################################

@kwdef struct AircraftTemplate{P <: AircraftPhysics,
                               A <: AbstractAvionics} <: SystemDefinition
    physics::P = AircraftPhysics()
    avionics::A = NoAvionics()
end

struct AircraftTemplateY{P <: AircraftPhysicsY, A}
    physics::P
    avionics::A
end

Systems.init(::SystemY, ac::AircraftTemplate) = AircraftTemplateY(
    init_y(ac.physics), init_y(ac.avionics))

function init_kinematics!(ac::System{<:AircraftTemplate}, ic::KinematicInit)
    Kinematics.init!(ac.physics, ic)
end

function Systems.f_ode!(ac::System{<:AircraftTemplate}, env::System{<:AbstractEnvironment})

    @unpack physics, avionics = ac.subsystems

    f_ode!(avionics, physics, env)
    f_ode!(physics, avionics, env)

    ac.y = AircraftTemplateY(physics.y, avionics.y)

    return nothing

end

function Systems.f_disc!(ac::System{<:AircraftTemplate}, Δt::Real, env::System{<:AbstractEnvironment})

    @unpack physics, avionics = ac.subsystems

    x_mod = false
    x_mod |= f_disc!(avionics, Δt, avionics, env)
    x_mod |= f_disc!(physics, Δt, avionics, env)

    sys.y = AircraftTemplateY(physics.y, avionics.y)

    return x_mod
end

#f_step! can use the recursive fallback implementation


############################# XPlaneConnect ####################################

XPC.set_position!(xp::XPCDevice, y::AircraftTemplateY) = XPC.set_position!(xp, y.physics)

function XPC.set_position!(xp::XPCDevice, y::AircraftPhysicsY)

    aircraft = 0

    @unpack ϕ_λ, e_nb, h_o = y.kinematics

    lat = rad2deg(ϕ_λ.ϕ)
    lon = rad2deg(ϕ_λ.λ)

    psi = rad2deg(e_nb.ψ)
    theta = rad2deg(e_nb.θ)
    phi = rad2deg(e_nb.φ)

    XPC.set_position!(xp; lat, lon, h_o, psi, theta, phi, aircraft)

end


################################# Tools ########################################

abstract type AbstractTrimParameters end

#given the body-axes wind-relative velocity, the wind-relative flight path angle
#and the bank angle, the pitch angle is unambiguously determined
function θ_constraint(; v_wOb_b, γ_wOb_n, φ_nb)
    TAS = norm(v_wOb_b)
    a = v_wOb_b[1] / TAS
    b = (v_wOb_b[2] * sin(φ_nb) + v_wOb_b[3] * cos(φ_nb)) / TAS
    sγ = sin(γ_wOb_n)

    return atan((a*b + sγ*√(a^2 + b^2 - sγ^2))/(a^2 - sγ^2))
    # return asin((a*sγ + b*√(a^2 + b^2 - sγ^2))/(a^2 + b^2)) #equivalent

end

function trim!( ac::System, args...; kwargs...)
    MethodError(trim!, (ac, args...)) |> throw
end

function linearize!(ac::System, args...; kwargs...)
    MethodError(trim!, (ac, args...)) |> throw
end

############################### Plotting #######################################

function Plotting.make_plots(th::TimeHistory{<:AircraftPhysicsY}; kwargs...)

    return OrderedDict(
        :kinematics => make_plots(th.kinematics; kwargs...),
        :airframe => make_plots(th.airframe; kwargs...),
        :rigidbody => make_plots(th.rigidbody; kwargs...),
        :air => make_plots(th.air; kwargs...),
    )

end

function Plotting.make_plots(th::TimeHistory{<:AircraftTemplateY}; kwargs...)

    return OrderedDict(
        :physics => make_plots(th.physics; kwargs...),
        :avionics => make_plots(th.avionics; kwargs...),
    )

end

################################### GUI ########################################


function GUI.draw!(sys::System{<:AircraftTemplate}, label::String = "Aircraft")

    @unpack y = sys

    CImGui.Begin(label)

    show_physics = @cstatic check=false @c CImGui.Checkbox("Airframe", &check)
    show_avionics = @cstatic check=false @c CImGui.Checkbox("Avionics", &check)

    show_physics && GUI.draw!(sys.physics, sys.avionics)
    show_avionics && GUI.draw!(sys.avionics, sys.physics)

    CImGui.End()

end

function GUI.draw!(physics::System{<:AircraftPhysics},
                   avionics::System{<:AbstractAvionics},
                   label::String = "Aircraft Physics")

    @unpack kinematics, rigidbody, air = physics.y

    CImGui.Begin(label)

    show_airframe = @cstatic check=false @c CImGui.Checkbox("Airframe", &check)
    show_dyn = @cstatic check=false @c CImGui.Checkbox("Dynamics", &check)
    show_kin = @cstatic check=false @c CImGui.Checkbox("Kinematics", &check)
    show_air = @cstatic check=false @c CImGui.Checkbox("Air", &check)

    show_airframe && GUI.draw!(sys.airframe, avionics)
    show_dyn && GUI.draw(rigidbody, "Dynamics")
    show_kin && GUI.draw(kinematics, "Kinematics")
    show_air && GUI.draw(air, "Air")

    CImGui.End()

end

end #module