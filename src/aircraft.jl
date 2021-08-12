module Aircraft

# using StaticArrays: SVector, SMatrix
using LinearAlgebra
using UnPack

using Flight.LBV
# using Flight.WGS84
# using Flight.Attitude
using Flight.Kinematics
using Flight.Airframe


"""
#Defines a local component frame Fc(Oc, Ɛc) related to the airframe reference
frame Fb(Ob, Ɛb) by:
#a) the position vector of the local frame origin Oc relative to the reference
#frame origin Ob, projected in the reference frame axes
# b) the attitude of the local frame axes relative to the reference
#frame axes, given by rotation b_c
"""
Base.@kwdef struct ComponentFrame
    r_ObOc_b::SVector{3,Float64} = zeros(SVector{3})
    q_bc::RQuat = RQuat()
end

function Base.:*(f_bc::ComponentFrame, wr_Oc_c::Wrench)

    #translates a wrench specified on a local frame f2(O2, ε2) to a
    #reference frame f1(O1, ε1) given the frame transform from 1 to 2

    F_Oc_c = wr_Oc_c.F
    M_Oc_c = wr_Oc_c.M

    #project on the reference axes
    F_Oc_b = f_bc.q_bc * F_Oc_c
    M_Oc_b = f_bc.q_bc * M_Oc_c

    #translate them to airframe origin
    F_Ob_b = F_Oc_b
    M_Ob_b = M_Oc_b + f_bc.r_ObOc_b × F_Oc_b

    wr_Ob_b = Wrench(F = F_Ob_b, M = M_Ob_b)

    return wr_Ob_b

end

#1) gathers all wrenches and additional angular momentum from all aircraft
#components, adds them up
#2) from aircrat components, it computes MassData
#3) from XAircraft.kin computes PVData

# and then calls the dynamics method x_vel_dot


#see Python for the contents of an Aircraft. But it does not need to store
#"Airframe". by the very type of the XKin defined by the aircraft, dispatch
#takes care of the appropriate method of x_vel_dot that will be called


abstract type AbstractTerrainModel end
abstract type AbstractAtmosphericModel end

#si necesito simulacion dinamica para atm, por ejemplo, tambien tengo que
#integrar esa ecuacion diferencial. puedo pasar sus outputs como parametros a la
#funcion de aircraft, junto con terrain. o almacenar referencias a atmospheric
#model y terrain model dentro del propio aircraft, evolucionarlos por separado y
#que se vayn actualizando dentro. ojo si lo hago en otros threads!! necesito
#locks alternativa: Channels

#TerrainModel does not belong to the Aircraft itself. it must be defined
#separately, and passed as an external data source. the same goes for Atmosphere
#there must be a level above the Aircraft, which will typically be the
#simulation, that defines the terrain and atmospheric models, and holds all the
#aircraft participating in the simulation. this may be a block based simulation
#or a custom made one. but it must exist in some form

#AtmosphericModel should contain a Channel to the actual AtmosphericModel
#through which the evolving atmospheric model can be queried for the values at
#the current aircraft location. it should behave like a client
#the TerrainModel can be handled similarly, because even if it is not evolving
#in time, it may be an arbitrarily complex terrain database

#initially, these "clients" will be the models themselves, because they will be
#constant, simple and shared with no one else

struct Environment
    trn::AbstractTerrainModel
    atm::AbstractAtmosphericModel
end

#given some inputs (typically state of the fuel system and external payloads),
#an AbstractMassModel returns a MassData struct (defined in the Dynamics
#module). for now, we can simply define a ConstantMassModel

abstract type AbstractMassModel end

struct ConstantMassModel <: AbstractMassModel
    m::Float64 = 1.0
    J_Ob_b::SMatrix{3, 3, Float64, 9} = SMatrix{3,3,Float64}(I)
    r_ObG_b::SVector{3, Float64} = zeros(SVector{3})
end

get_mass_data(model::ConstantMassModel) = MassData(model.m, model.J_Ob_b, model.r_ObG_b)


@define_node XTestAircraft (kin = XKinWGS84, )

struct TestAircraft
    mass_model::ConstantMassModel
    landing_gear::Nothing
    power_plant::Nothing
    control_surfaces::Nothing
    # inner constructor goes here. however, since there is no kinematics
    # subsystem to which the x.kin block belongs, we don't need to call any
    # constructor with that block as input argument. we only need to do that for
    # actual subsystems (LdgGroups, PwpGroup...)
end

function f_output!(ẋ::TestAircraftX, x::TestAircraftX, u::TestAircraftU)
#updates aircraft's x_dot from the current values of x and u
function update_x_dot!(aircraft::TestAircraft, env::Environment, t::Real)

    #atm represents the atmospheric model in its current state (because it may
    #be dynamically evolving, turbulence, etc). like the terrain model, it can
    #be evaluated at the current aircraft location, from which it will return
    #static pressure, temperature, etc.
    @unpack trn, atm = env

    pv = PVDataWGS84(aircraft.x.kin)
    mass = get_mass_data(aircraft.mass_model)
    wr_ext_Ob_b = Wrench()
    h_rot_b = zeros(3)

    x_dot_kin = aircraft.x_dot.kin
    x_dot_kin.vel .= x_vel_dot(wr_ext_Ob_b, h_rot_b, mass, pv)
    x_dot_kin.pos .= x_pos_dot(pv)

    #this may return
end

#function for IIP DiffEqs.jl problem definition
function f!(dx::XAircraft, x::XAircraft, p, t)
    x_backup = copy(p.aircraft.x)
    p.aircraft.x .= x
    update_x_dot!(p.aircraft, p.env, t) #recursively updates the internal dx of the aircraft
    p.aircraft.x .= x_backup
    dx .= aircraft.dx

    #el backup seguramente es innecesario, porque la unica via de acceso a
    #aircraft por parte del integrador es a traves de esta funcion. y siempre
    #que llamo a esta funcion, actualizo el aircraft.x local al input que me
    #pasan. probar primero asi por seguridad, quitarlo y ver si cuesta mucho
    #tiempo de ejecucion. probablemente no

    #if we make update_x_dot also store the computed outputs in a field, we can
    #retrieve them

    #aqui me da igual si aircraft.x es view o es el propio vector

    #generalizar para incluir el input vector!!!!!! esto lo podria hacer
    #definiendo un DEDataVector con un campo u adicional, y definiendo un
    #callback para actualizarlo en cada step (o a intervalos temporales
    #prefijados). cuando corra en tiempo real, que voy a estar dando los steps
    #manualmente, lo suyo es leer en cada step con un callback.

end

function f_saving(x::XAircraft, t, integrator)

    #el problema aqui es que necesito aircraft para evaluar los outputs. y la
    #forma en que los evaluo es escribir en aircraft.x. y como aircraft va en
    #integrator.p, realmente estoy modificando integrator, cosa que no deberia
    #hacer. pero no pasa nada, porque voy a restaurar aircraft.x a su valor anterior
    #basicamente:
    x_backup = copy(p.aircraft.x) #POSSIBLY UNNECESSARY
    integrator.p.aircraft.x .= x
    outputs = update_x_dot!(p.aircraft, p.env, t)
    p.aircraft.x .= x_backup #POSSIBLy UNNECESSARY
    return outputs





end





end