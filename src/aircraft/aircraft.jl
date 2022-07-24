module Aircraft

using LinearAlgebra
using StaticArrays, ComponentArrays
using UnPack

using Flight.Systems
using Flight.Attitude
using Flight.Geodesy, Flight.Terrain, Flight.Air
using Flight.Kinematics, Flight.Dynamics
using Flight.Input, Flight.Output

import Flight.Systems: init, f_cont!, f_disc!
import Flight.Dynamics: MassTrait, WrenchTrait, AngularMomentumTrait, get_mp_b
import Flight.Output: update!

export AircraftBase, AbstractVehicle, EmptyVehicle, AbstractAerodynamics,
       AbstractAvionics, NoAvionics


abstract type AbstractAircraftID end

###############################################################################
############################## Vehicle #######################################

abstract type AbstractVehicle <: SystemDescriptor end
MassTrait(::System{<:AbstractVehicle}) = HasMass()
WrenchTrait(::System{<:AbstractVehicle}) = GetsExternalWrench()
AngularMomentumTrait(::System{<:AbstractVehicle}) = HasAngularMomentum()

########################## EmptyVehicle ###########################

Base.@kwdef struct EmptyVehicle <: AbstractVehicle
    mass_distribution::RigidBody = RigidBody(1, SA[1.0 0 0; 0 1.0 0; 0 0 1.0])
end

WrenchTrait(::System{EmptyVehicle}) = GetsNoExternalWrench()
AngularMomentumTrait(::System{EmptyVehicle}) = HasNoAngularMomentum()

get_mp_b(sys::System{EmptyVehicle}) = MassProperties(sys.params.mass_distribution)

@inline f_cont!(::System{EmptyVehicle}, args...) = nothing
@inline (f_disc!(::System{EmptyVehicle}, args...)::Bool) = false

####################### AbstractAerodynamics ##########################

abstract type AbstractAerodynamics <: SystemDescriptor end

MassTrait(::System{<:AbstractAerodynamics}) = HasNoMass()
WrenchTrait(::System{<:AbstractAerodynamics}) = GetsExternalWrench()
AngularMomentumTrait(::System{<:AbstractAerodynamics}) = HasNoAngularMomentum()


###############################################################################
############################## Avionics #######################################

abstract type AbstractAvionics <: SystemDescriptor end

struct NoAvionics <: AbstractAvionics end

@inline f_cont!(::System{NoAvionics}, args...) = nothing
@inline (f_disc!(::System{NoAvionics}, args...)::Bool) = false

###############################################################################
############################## AircraftBase ###################################

struct GenericID <: AbstractAircraftID end

struct AircraftBase{I <: AbstractAircraftID,
                    K <: AbstractKinematics,
                    V <: AbstractVehicle,
                    A <: AbstractAvionics} <: SystemDescriptor

    kinematics::K
    vehicle::V
    avionics::A
end

function AircraftBase(     ::I = GenericID();
                        kinematics::K = KinLTF(),
                        vehicle::V = EmptyVehicle(),
                        avionics::A = NoAvionics()) where {I,K,V,A}
    AircraftBase{I,K,V,A}(kinematics, vehicle, avionics)
end

#override the default SystemDescriptor implementation, because we need to
#add some stuff besides subsystem outputs
init(::SystemY, ac::AircraftBase) = (
    kinematics = init_y(ac.kinematics),
    vehicle = init_y(ac.vehicle),
    avionics = init_y(ac.avionics),
    dynamics = DynData(),
    airflow = AirflowData(),
    )

function init!(ac::System{T}, kin_init::KinInit) where {T<:AircraftBase{I,K}} where {I,K}
    ac.x.kinematics .= init(K(), kin_init)
end

function f_cont!(sys::System{<:AircraftBase}, atm::System{<:Atmosphere}, trn::AbstractTerrain)

    @unpack ẋ, x, subsystems = sys
    @unpack kinematics, vehicle, avionics = subsystems

    #update kinematics
    f_cont!(kinematics)
    kin_data = kinematics.y
    air_data = AirflowData(kin_data, atm)

    #update avionics and vehicle components
    f_cont!(avionics, vehicle, kin_data, air_data, trn)
    f_cont!(vehicle, avionics, kin_data, air_data, trn)

    mp_b = get_mp_b(vehicle)
    wr_b = get_wr_b(vehicle)
    hr_b = get_hr_b(vehicle)

    #update velocity derivatives
    dyn_data = f_dyn!(kinematics.ẋ.vel, kinematics.y, mp_b, wr_b, hr_b)

    sys.y = (kinematics = kinematics.y, vehicle = vehicle.y, avionics = avionics.y,
            dynamics = dyn_data, airflow = air_data,)

    return nothing

end

function f_disc!(sys::System{<:AircraftBase})
    @unpack kinematics, vehicle, avionics = sys

    x_mod = false
    x_mod = x_mod || f_disc!(kinematics, 1e-8)
    x_mod = x_mod || f_disc!(vehicle, avionics, kinematics)
    x_mod = x_mod || f_disc!(avionics, vehicle, kinematics)

    return x_mod
end

function update!(xp::XPInterface, pos::PosData, aircraft::Integer = 0)

    llh = GeographicLocation(pos.ϕ_λ, pos.h_o)
    e_nb = pos.e_nb

    lat = rad2deg(llh.l2d.ϕ)
    lon = rad2deg(llh.l2d.λ)
    alt = llh.alt

    psi = rad2deg(e_nb.ψ)
    theta = rad2deg(e_nb.θ)
    phi = rad2deg(e_nb.φ)

    Output.set_position!(xp; lat, lon, alt, psi, theta, phi, aircraft)

end


end #module