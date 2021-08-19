module Aircraft

using StaticArrays: SVector, SMatrix
using LinearAlgebra
using ComponentArrays
using RecursiveArrayTools
using UnPack

using Flight.System
using Flight.Kinematics
using Flight.Dynamics
using Flight.Airdata
using Flight.Component
using Flight.Propulsion
using Flight.LandingGear
using Flight.Terrain
using Flight.Atmosphere

import Flight.System: X, Y, U, f_cont!, f_disc!, plotlog

export ParametricAircraft

abstract type AbstractMassModel end

#given some inputs (typically state of the fuel system and external payloads),
#an AbstractMassModel returns a MassData struct (defined in the Dynamics
#module). for now, we can simply define a ConstantMassModel

Base.@kwdef struct ConstantMassModel <: AbstractMassModel
    m::Float64 = 1.0
    J_Ob_b::SMatrix{3, 3, Float64, 9} = SMatrix{3,3,Float64}(I)
    r_ObG_b::SVector{3, Float64} = zeros(SVector{3})
end

get_mass_data(model::ConstantMassModel) = MassData(model.m, model.J_Ob_b, model.r_ObG_b)


struct ParametricAircraft{Mass, Pwp, Ldg} <: AbstractSystem end
ParametricAircraft(mass::AbstractMassModel, pwp::PropulsionGroup, ldg::LandingGearGroup) = ParametricAircraft{mass,pwp,ldg}()

#for some reason, we cannot strip PropulsionGroup{C} to PropulsionGroup in the
#struct declaration, so in order to avoid having to add C as a type parammeter,
#we leave Pwp's supertype unspecified in the struct declaration and enforce it
#in the constructor
function ParametricAircraft()

    mass = ConstantMassModel(m = 1, J_Ob_b = 1*Matrix{Float64}(I,3,3))
    pwp = PropulsionGroup((
        left = EThruster(motor = ElectricMotor(α = CW)),
        right = EThruster(motor = ElectricMotor(α = CCW))))
    ldg = LandingGearGroup((
        lmain = LandingGearLeg(),
        rmain = LandingGearLeg(),
        nlg = LandingGearLeg()))

    ParametricAircraft(mass, pwp, ldg)
end

X(::ParametricAircraft{Mass, Pwp,Ldg}) where {Mass, Pwp,Ldg} = ComponentVector(kin = X(Kin()), pwp = X(Pwp), ldg = X(Ldg))
U(::ParametricAircraft{Mass, Pwp,Ldg}) where {Mass, Pwp,Ldg} = ComponentVector(pwp = U(Pwp), ldg = U(Ldg))
Y(::ParametricAircraft{Mass, Pwp,Ldg}) where {Mass, Pwp,Ldg} = ComponentVector(kin = Y(Kin()), acc = Y(Acc()), air = Y(AirData()), pwp = Y(Pwp), ldg = Y(Ldg))

pwp(::ParametricAircraft{Mass,Pwp,Ldg}) where {Mass,Pwp,Ldg} = Pwp

function f_cont!(y, ẋ, x, u, t, ::ParametricAircraft{Mass,Pwp,Ldg},
    trn::AbstractTerrainModel = DummyTerrainModel(),
    atm::AbstractAtmosphericModel = DummyAtmosphericModel()) where {Mass,Pwp,Ldg}


    #update kinematics
    f_kin!(y.kin, ẋ.kin.pos, x.kin)

    mass_data = get_mass_data(Mass)
    # y.air .= get_air_data(). #call air data system here to update air data, passing also as
    # argument data.atmospheric_model

    #update powerplant
    f_cont!(y.pwp, ẋ.pwp, x.pwp, u.pwp, t, Pwp, y.air)
    #update landing gear
    f_cont!(y.ldg, ẋ.ldg, x.ldg, u.ldg, t, Ldg, trn)

    #get aerodynamics Wrench
    # y_aero = get_wr_Ob_b(Aero, y.air, y.srf, y.ldg, trn)

    #initialize external Wrench and additional angular momentum
    wr_ext_Ob_b = Wrench()
    h_rot_b = SVector(0.,0.,0.)

    #add powerplant contributions
    wr_ext_Ob_b .+= get_wr_Ob_b(y.pwp, Pwp)
    h_rot_b += get_h_Gc_b(y.pwp, Pwp)

    #add landing gear contributions
    wr_ext_Ob_b .+= get_wr_Ob_b(y.ldg, Ldg)
    h_rot_b += get_h_Gc_b(y.ldg, Ldg)

    #update dynamics
    f_dyn!(y.acc, ẋ.kin.vel, wr_ext_Ob_b, h_rot_b, mass_data, y.kin)

    return nothing
end

degraded(nrm) = (abs(nrm - 1.0) > 1e-10)

function f_disc!(x, u, t, aircraft::ParametricAircraft)

    norm_q_lb = norm(x.kin.pos.q_lb)
    norm_q_el = norm(x.kin.pos.q_el)
    if degraded(norm_q_lb) || degraded(norm_q_el)
        # println("Renormalized")
        x.kin.pos.q_lb ./= norm_q_lb
        x.kin.pos.q_el ./= norm_q_el
        return true #x modified
    else
        return false #x not modified
    end

end

function plotlog(log, aircraft::ParametricAircraft)

    y = log.y

    #this could all be delegated to kin, which can return a handle to each plot
    #it produces
    #who saves the plots? how is the folder hierarchy generated?
    kin = y[:kin, :]
    pos = kin[:pos, :]
    Δx = pos[:Δx, :]
    Δy = pos[:Δy, :]
    h = pos[:h, :]

    #the only thing we ask of the log type is that it has fields :t and :saveval
    #now we would construct a NamedTuple to delegate
    return((log.t, h))

end


end