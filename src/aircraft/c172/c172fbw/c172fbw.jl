module C172FBW

using LinearAlgebra, StaticArrays, ComponentArrays, UnPack, Reexport
using ControlSystems, RobustAndOptimalControl

using Flight.FlightCore
using Flight.FlightCore.Utils

using Flight.FlightPhysics
using Flight.FlightComponents

using ..C172

################################################################################
################################ Powerplant ####################################

function PowerPlant()

    #cache propeller lookup data to speed up aircraft instantiation. WARNING: if
    #the propeller definition or the lookup data generation methods in the
    #Propellers module are modified, the cache file must be regenerated
    # cache_file = joinpath(@__DIR__, "prop.h5")
    # if !isfile(cache_file)
    #     prop_data = Propellers.Lookup(Propellers.Blade(), 2)
    #     Propellers.save_lookup(prop_data, cache_file)
    # end
    # prop_data = Propellers.load_lookup(cache_file)

    #always generate the lookup data from scratch
    prop_data = Propellers.Lookup(Propellers.Blade(), 2)

    propeller = Propeller(prop_data;
        sense = Propellers.CW, d = 2.0, J_xx = 0.3,
        t_bp = FrameTransform(r = [2.055, 0, 0.833]))

    Piston.Thruster(; propeller)

end

################################################################################
################################## Actuator ####################################

@kwdef struct Actuator <: SystemDefinition #second order linear actuator model
    ω_n::Float64 = 5*2π #natural frequency (default: 10 Hz)
    ζ::Float64 = 0.6 #damping ratio (default: underdamped with minimal resonance)
    range::Tuple{Float64, Float64} = (-1.0, 1.0)
end

@kwdef struct ActuatorY
    cmd::Float64 = 0.0
    pos_free::Float64 = 0.0
    pos::Float64 = 0.0
    vel::Float64 = 0.0
    sat::Int64 = 0 #output saturation status
end

#with an underdamped actuator, the position state can still transiently exceed
#the intended range due to overshoot. the true actuator position should
#therefore be clamped. in the real world, this behaviour could correspond to a
#clutched output actuator, where the output position saturates beyond a given
#opposing torque (for example, if the surface's mechanical limits are hit)
Systems.init(::SystemU, act::Actuator) = Ref(Ranged(0.0, act.range[1], act.range[2]))
Systems.init(::SystemX, ::Actuator) = ComponentVector(v = 0.0, p = 0.0)
Systems.init(::SystemY, ::Actuator) = ActuatorY()

function Systems.f_ode!(sys::System{Actuator})

    @unpack ẋ, x, u, constants = sys
    @unpack ω_n, ζ, range = constants

    cmd = Float64(u[])
    pos_free = x.p
    pos = clamp(pos_free, range[1], range[2]) #clamped output
    vel = x.v
    sat_hi = pos_free >= range[1]
    sat_lo = pos_free <= range[2]
    sat = sat_hi - sat_lo

    ẋ.v = ω_n^2 * (cmd - x.p) - 2ζ*ω_n*x.v
    ẋ.p = x.v

    sys.y = ActuatorY(; cmd, pos_free, pos, vel, sat)

end

################################################################################
#################################### Actuation #################################

#Fly-by-wire actuation system. Throttle, steering and aerodynamic surfaces are
#controlled via actuators, the rest of are direct feedthrough

@kwdef struct Actuation <: C172.Actuation
    throttle_act::Actuator = Actuator(range = (0.0, 1.0))
    aileron_act::Actuator = Actuator(range = (-1.0, 1.0))
    elevator_act::Actuator = Actuator(range = (-1.0, 1.0))
    rudder_act::Actuator = Actuator(range = (-1.0, 1.0))
end

@kwdef mutable struct ActuationU
    eng_start::Bool = false
    eng_stop::Bool = false
    throttle_cmd::Ranged{Float64, 0., 1.} = 0.0
    mixture::Ranged{Float64, 0., 1.} = 0.5
    aileron_cmd::Ranged{Float64, -1., 1.} = 0.0
    elevator_cmd::Ranged{Float64, -1., 1.} = 0.0
    rudder_cmd::Ranged{Float64, -1., 1.} = 0.0
    flaps::Ranged{Float64, 0., 1.} = 0.0
    brake_left::Ranged{Float64, 0., 1.} = 0.0
    brake_right::Ranged{Float64, 0., 1.} = 0.0
end

@kwdef struct ActuationY
    eng_start::Bool = false
    eng_stop::Bool = false
    throttle_cmd::Float64 = 0.0
    mixture::Float64 = 0.5
    aileron_cmd::Float64 = 0.0
    elevator_cmd::Float64 = 0.0
    rudder_cmd::Float64 = 0.0
    flaps::Float64 = 0.0
    brake_left::Float64 = 0.0
    brake_right::Float64 = 0.0
    throttle_act::ActuatorY = ActuatorY()
    aileron_act::ActuatorY = ActuatorY()
    elevator_act::ActuatorY = ActuatorY()
    rudder_act::ActuatorY = ActuatorY()
end

Systems.init(::SystemU, ::Actuation) = ActuationU()
Systems.init(::SystemY, ::Actuation) = ActuationY()

function Systems.f_ode!(sys::System{Actuation})

    @unpack throttle_act, aileron_act, elevator_act, rudder_act = sys

    @unpack eng_start, eng_stop, throttle_cmd, mixture,
            aileron_cmd, elevator_cmd, rudder_cmd,
            flaps, brake_left, brake_right = sys.u

    #assign inputs to actuator subsystems
    throttle_act.u[] = Float64(throttle_cmd)
    aileron_act.u[] = Float64(aileron_cmd)
    elevator_act.u[] = Float64(elevator_cmd)
    rudder_act.u[] = Float64(rudder_cmd)

    #update actuator subsystems
    f_ode!(throttle_act)
    f_ode!(aileron_act)
    f_ode!(elevator_act)
    f_ode!(rudder_act)

    sys.y = ActuationY(;
            eng_start, eng_stop, throttle_cmd, mixture,
            aileron_cmd, elevator_cmd, rudder_cmd,
            flaps, brake_left, brake_right,
            throttle_act = throttle_act.y, aileron_act = aileron_act.y,
            elevator_act = elevator_act.y, rudder_act = rudder_act.y)

end

function C172.assign!(aero::System{<:C172.Aero},
                ldg::System{<:C172.Ldg},
                pwp::System{<:Piston.Thruster},
                act::System{<:Actuation})

    @unpack eng_start, eng_stop, mixture, flaps, brake_left, brake_right,
            throttle_act, aileron_act, elevator_act, rudder_act = act.y

    pwp.engine.u.start = eng_start
    pwp.engine.u.stop = eng_stop
    pwp.engine.u.throttle = throttle_act.pos
    pwp.engine.u.mixture = mixture
    ldg.nose.steering.u[] = rudder_act.pos
    ldg.left.braking.u[] = brake_left
    ldg.right.braking.u[] = brake_right
    aero.u.e = -elevator_act.pos
    aero.u.a = aileron_act.pos
    aero.u.r = -rudder_act.pos
    aero.u.f = flaps

    return nothing
end


function GUI.draw(sys::System{Actuation}, label::String = "Cessna 172 Fly-By-Wire Actuation")

    @unpack eng_start, eng_stop, throttle_cmd, mixture,
            aileron_cmd, elevator_cmd, rudder_cmd,
            flaps, brake_left, brake_right,
            throttle_act, aileron_act, elevator_act, rudder_act = sys.y

    CImGui.Begin(label)

    CImGui.PushItemWidth(-60)

    CImGui.Dummy(10.0, 10.0)
    CImGui.Text("Engine Start: $(eng_start)")
    CImGui.Text("Engine Stop: $(eng_stop)")
    CImGui.Dummy(10.0, 10.0);

    CImGui.Separator()

     if CImGui.CollapsingHeader("Throttle")
        CImGui.Text("Throttle Actuator Command"); CImGui.SameLine(300); display_bar("", throttle_act.cmd, 0, 1)
        CImGui.Text("Throttle Actuator Position"); CImGui.SameLine(300); display_bar("", throttle_act.pos, 0, 1)
        @running_plot("Throttle Actuator Position", throttle_act.pos, 0, 1, 0.0, 120)
        CImGui.Dummy(10.0, 10.0);
    end

    if CImGui.CollapsingHeader("Aileron")
        CImGui.Text("Aileron Command"); CImGui.SameLine(300); display_bar("", aileron_cmd, -1, 1)
        CImGui.Text("Aileron Actuator Command"); CImGui.SameLine(300); display_bar("", aileron_act.cmd, -1, 1)
        CImGui.Text("Aileron Actuator Position"); CImGui.SameLine(300); display_bar("", aileron_act.pos, -1, 1)
        @running_plot("Aileron Actuator Position", aileron_act.pos, -1, 1, 0.0, 120)
        CImGui.Dummy(10.0, 10.0);
    end

    if CImGui.CollapsingHeader("Elevator")
        CImGui.Text("Elevator Command"); CImGui.SameLine(300); display_bar("", elevator_cmd, -1, 1)
        CImGui.Text("Elevator Actuator Command"); CImGui.SameLine(300); display_bar("", elevator_act.cmd, -1, 1)
        CImGui.Text("Elevator Actuator Position"); CImGui.SameLine(300); display_bar("", elevator_act.pos, -1, 1)
        @running_plot("Elevator Actuator Position", elevator_act.pos, -1, 1, 0.0, 120)
        CImGui.Dummy(10.0, 10.0)
    end

    if CImGui.CollapsingHeader("Rudder")
        CImGui.Text("Rudder Command"); CImGui.SameLine(300); display_bar("", rudder_cmd, -1, 1)
        CImGui.Text("Rudder Actuator Command"); CImGui.SameLine(300); display_bar("", rudder_act.cmd, -1, 1)
        CImGui.Text("Rudder Actuator Position"); CImGui.SameLine(300); display_bar("", rudder_act.pos, -1, 1)
        @running_plot("Rudder Position", rudder_act.pos, -1, 1, 0.0, 120)
        CImGui.Dummy(10.0, 10.0)
    end

    CImGui.Separator()

    CImGui.Dummy(10.0, 10.0)
    display_bar("Flaps", flaps, 0, 1)
    display_bar("Mixture", mixture, 0, 1)
    display_bar("Left Brake", brake_left, 0, 1)
    display_bar("Right Brake", brake_right, 0, 1)

    CImGui.PopItemWidth()

    CImGui.End()

end

function GUI.draw!(sys::System{Actuation}, label::String = "Cessna 172 Fly-By-Wire Actuation")

    @unpack u, y = sys

    CImGui.Begin(label)

    CImGui.PushItemWidth(-60)

    CImGui.Dummy(10.0, 10.0)
    dynamic_button("Engine Start", 0.4); CImGui.SameLine()
    u.eng_start = CImGui.IsItemActive()
    dynamic_button("Engine Stop", 0.0)
    u.eng_stop = CImGui.IsItemActive()
    CImGui.Dummy(10.0, 10.0);

    CImGui.Separator()
    u.throttle_cmd = safe_slider("Throttle Command", u.throttle_cmd, "%.6f")
    CImGui.Text("Throttle Actuator Command"); CImGui.SameLine(300); display_bar("", y.throttle_act.cmd, 0, 1)
    CImGui.Text("Throttle Actuator Position"); CImGui.SameLine(300); display_bar("", y.throttle_act.pos, 0, 1)
    @running_plot("Throttle Actuator Position", y.throttle_act.pos, 0, 1, 0.0, 120)
    CImGui.Dummy(10.0, 10.0)

    u.aileron_cmd = safe_slider("Aileron Command", u.aileron_cmd, "%.6f")
    CImGui.Text("Aileron Actuator Command"); CImGui.SameLine(300); display_bar("", y.aileron_act.cmd, -1, 1)
    CImGui.Text("Aileron Actuator Position"); CImGui.SameLine(300); display_bar("", y.aileron_act.pos, -1, 1)
    @running_plot("Aileron Actuator Position", y.aileron_act.pos, -1, 1, 0.0, 120)
    CImGui.Dummy(10.0, 10.0)

    u.elevator_cmd = safe_slider("Elevator Command", u.elevator_cmd, "%.6f")
    CImGui.Text("Elevator Actuator Command"); CImGui.SameLine(300); display_bar("", y.elevator_act.cmd, -1, 1)
    CImGui.Text("Elevator Actuator Position"); CImGui.SameLine(300); display_bar("", y.elevator_act.pos, -1, 1)
    @running_plot("Elevator Position", y.elevator_act.pos, -1, 1, 0.0, 120)
    CImGui.Dummy(10.0, 10.0)

    u.rudder_cmd = safe_slider("Rudder Command", u.rudder_cmd, "%.6f")
    CImGui.Text("Rudder Actuator Command"); CImGui.SameLine(300); display_bar("", y.rudder_act.cmd, -1, 1)
    CImGui.Text("Rudder Actuator Position"); CImGui.SameLine(300); display_bar("", y.rudder_act.pos, -1, 1)
    @running_plot("Rudder Position", y.rudder_act.pos, -1, 1, 0.0, 120)
    CImGui.Separator()

    CImGui.Dummy(10.0, 10.0)
    u.flaps = safe_slider("Flaps", u.flaps, "%.6f")
    u.mixture = safe_slider("Mixture", u.mixture, "%.6f")
    u.brake_left = safe_slider("Left Brake", u.brake_left, "%.6f")
    u.brake_right = safe_slider("Right Brake", u.brake_right, "%.6f")

    CImGui.PopItemWidth()

    CImGui.End()

end

# ################################## IODevices ###################################

elevator_curve(x) = exp_axis_curve(x, strength = 1, deadzone = 0.05)
aileron_curve(x) = exp_axis_curve(x, strength = 1, deadzone = 0.05)
rudder_curve(x) = exp_axis_curve(x, strength = 1.5, deadzone = 0.05)
brake_curve(x) = exp_axis_curve(x, strength = 1, deadzone = 0.05)

function IODevices.assign!(sys::System{<:Actuation},
                           joystick::XBoxController,
                           ::DefaultMapping)

    u = sys.u

    u.aileron_cmd = get_axis_value(joystick, :right_analog_x) |> aileron_curve
    u.elevator_cmd = get_axis_value(joystick, :right_analog_y) |> elevator_curve
    u.rudder_cmd = get_axis_value(joystick, :left_analog_x) |> rudder_curve
    u.brake_left = get_axis_value(joystick, :left_trigger) |> brake_curve
    u.brake_right = get_axis_value(joystick, :right_trigger) |> brake_curve

    u.flaps += 0.3333 * was_released(joystick, :right_bumper)
    u.flaps -= 0.3333 * was_released(joystick, :left_bumper)

    u.throttle_cmd += 0.1 * was_released(joystick, :button_Y)
    u.throttle_cmd -= 0.1 * was_released(joystick, :button_A)
end

function IODevices.assign!(sys::System{<:Actuation},
                           joystick::T16000M,
                           ::DefaultMapping)

    u = sys.u

    u.throttle_cmd = get_axis_value(joystick, :throttle)
    u.aileron_cmd = get_axis_value(joystick, :stick_x) |> aileron_curve
    u.elevator_cmd = get_axis_value(joystick, :stick_y) |> elevator_curve
    u.rudder_cmd = get_axis_value(joystick, :stick_z) |> rudder_curve

    u.brake_left = is_pressed(joystick, :button_1)
    u.brake_right = is_pressed(joystick, :button_1)

    u.flaps += 0.3333 * was_released(joystick, :button_3)
    u.flaps -= 0.3333 * was_released(joystick, :button_2)

end


################################################################################
################################# Templates ####################################

const Airframe = C172.Airframe{typeof(PowerPlant()), C172FBW.Actuation}
const Physics{K, T} = Aircraft.Physics{C172FBW.Airframe, K, T} where {K <: AbstractKinematicDescriptor, T <: AbstractTerrain}
const Template{K, T, A} = Aircraft.Template{C172FBW.Physics{K, T}, A} where {K <: AbstractKinematicDescriptor, T <: AbstractTerrain, A <: AbstractAvionics}

function Physics(kinematics = LTF(), terrain = HorizontalTerrain())
    Aircraft.Physics(C172.Airframe(PowerPlant(), Actuation()), kinematics, terrain, LocalAtmosphere())
end

function Template(kinematics = LTF(), terrain = HorizontalTerrain(), avionics = NoAvionics())
    Aircraft.Template(Physics(kinematics, terrain), avionics)
end

############################### Trimming #######################################
################################################################################

#assigns trim state and parameters to aircraft physics, then updates aircraft physics
function Aircraft.assign!(physics::System{<:C172FBW.Physics},
                        trim_params::C172.TrimParameters,
                        trim_state::C172.TrimState)

    @unpack EAS, β_a, x_fuel, flaps, mixture, payload = trim_params
    @unpack n_eng, α_a, throttle, aileron, elevator, rudder = trim_state
    @unpack act, pwp, aero, fuel, ldg, pld = physics.airframe

    atm_data = LocalAtmosphericData(physics.atmosphere)
    Systems.init!(physics.kinematics, Kinematics.Initializer(trim_state, trim_params, atm_data))

    #for trimming, control surface inputs are set to zero, and we work only with
    #their offsets
    act.u.throttle_cmd = throttle
    act.u.aileron_cmd = aileron
    act.u.elevator_cmd = elevator
    act.u.rudder_cmd = rudder
    act.u.flaps = flaps
    act.u.mixture = mixture

    #assign payload
    @unpack m_pilot, m_copilot, m_lpass, m_rpass, m_baggage = payload
    @pack! pld.u = m_pilot, m_copilot, m_lpass, m_rpass, m_baggage

    #engine must be running
    pwp.engine.s.state = Piston.eng_running

    #set engine speed state
    ω_eng = n_eng * pwp.engine.constants.ω_rated
    pwp.x.engine.ω = ω_eng

    #engine idle compensator: as long as the engine remains at normal
    #operational speeds, well above its nominal idle speed, the idle controller
    #compensator's output will be saturated at its lower bound by proportional
    #error. its integrator will be disabled, its state will not change nor have
    #any effect on the engine. we can simply set it to zero
    pwp.x.engine.idle .= 0.0

    #engine friction compensator: with the engine running at normal operational
    #speeds, the engine's friction constraint compensator will be saturated, so
    #its integrator will be disabled and its state will not change. furthermore,
    #with the engine running friction is ignored. we can simply set it to zero.
    pwp.x.engine.frc .= 0.0

    #actuator states: in steady state every actuator's velocity state must be
    #zero, and its position state must be equal to the actuator command.
    act.x.throttle_act.v = 0.0
    act.x.throttle_act.p = throttle
    act.x.aileron_act.v = 0.0
    act.x.aileron_act.p = aileron
    act.x.elevator_act.v = 0.0
    act.x.elevator_act.p = elevator
    act.x.rudder_act.v = 0.0
    act.x.rudder_act.p = rudder

    aero.x.α_filt = α_a #ensures zero state derivative
    aero.x.β_filt = β_a #ensures zero state derivative
    fuel.x .= Float64(x_fuel)

    f_ode!(physics)

    #check essential assumptions about airframe systems states & derivatives
    @assert !any(SVector{3}(leg.strut.wow for leg in ldg.y))
    @assert pwp.x.engine.ω > pwp.engine.constants.ω_idle
    @assert pwp.x.engine.idle[1] .== 0
    @assert pwp.x.engine.frc[1] .== 0
    @assert abs(aero.ẋ.α_filt) < 1e-10
    @assert abs(aero.ẋ.β_filt) < 1e-10

    @assert all(SVector{8,Float64}(act.ẋ) .== 0)

end



################################################################################
############################### Linearization ##################################

@kwdef struct XLinear <: FieldVector{24, Float64}
    p::Float64 = 0.0; q::Float64 = 0.0; r::Float64 = 0.0; #angular rates (ω_eb_b)
    ψ::Float64 = 0.0; θ::Float64 = 0.0; φ::Float64 = 0.0; #heading, inclination, bank (body/NED)
    v_x::Float64 = 0.0; v_y::Float64 = 0.0; v_z::Float64 = 0.0; #aerodynamic velocity, body axes
    ϕ::Float64 = 0.0; λ::Float64 = 0.0; h::Float64 = 0.0; #latitude, longitude, ellipsoidal altitude
    α_filt::Float64 = 0.0; β_filt::Float64 = 0.0; #filtered airflow angles
    ω_eng::Float64 = 0.0; fuel::Float64 = 0.0; #engine speed, fuel fraction
    thr_v::Float64 = 0.0; thr_p::Float64 = 0.0; #throttle actuator states
    ail_v::Float64 = 0.0; ail_p::Float64 = 0.0; #aileron actuator states
    ele_v::Float64 = 0.0; ele_p::Float64 = 0.0; #elevator actuator states
    rud_v::Float64 = 0.0; rud_p::Float64 = 0.0 #rudder actuator states
end

#flaps and mixture are trim parameters and thus omitted from the control vector
@kwdef struct ULinear <: FieldVector{4, Float64}
    throttle_cmd::Float64 = 0.0
    aileron_cmd::Float64 = 0.0
    elevator_cmd::Float64 = 0.0
    rudder_cmd::Float64 = 0.0
end

#all states (for full-state feedback), plus other useful stuff, plus control inputs
@kwdef struct YLinear <: FieldVector{41, Float64}
    p::Float64 = 0.0; q::Float64 = 0.0; r::Float64 = 0.0; #angular rates (ω_eb_b)
    ψ::Float64 = 0.0; θ::Float64 = 0.0; φ::Float64 = 0.0; #heading, inclination, bank (body/NED)
    v_x::Float64 = 0.0; v_y::Float64 = 0.0; v_z::Float64 = 0.0; #aerodynamic velocity, body axes
    ϕ::Float64 = 0.0; λ::Float64 = 0.0; h::Float64 = 0.0; #latitude, longitude, ellipsoidal altitude
    α_filt::Float64 = 0.0; β_filt::Float64 = 0.0; #filtered airflow angles
    ω_eng::Float64 = 0.0; fuel::Float64 = 0.0; #engine speed, available fuel fraction
    thr_v::Float64 = 0.0; thr_p::Float64 = 0.0; #throttle actuator states
    ail_v::Float64 = 0.0; ail_p::Float64 = 0.0; #aileron actuator states
    ele_v::Float64 = 0.0; ele_p::Float64 = 0.0; #elevator actuator states
    rud_v::Float64 = 0.0; rud_p::Float64 = 0.0; #rudder actuator states
    f_x::Float64 = 0.0; f_y::Float64 = 0.0; f_z::Float64 = 0.0; #specific force at G (f_iG_b)
    α::Float64 = 0.0; β::Float64 = 0.0; #unfiltered airflow angles
    EAS::Float64 = 0.0; TAS::Float64 = 0.0; #airspeed
    v_N::Float64 = 0.0; v_E::Float64 = 0.0; v_D::Float64 = 0.0; #Ob/ECEF velocity, NED axes
    χ::Float64 = 0.0; γ::Float64 = 0.0; climb_rate::Float64 = 0.0; #track and flight path angles, climb rate
    throttle_cmd::Float64 = 0.0; aileron_cmd::Float64 = 0.0; #actuator commands
    elevator_cmd::Float64 = 0.0; rudder_cmd::Float64 = 0.0; #actuator commands
end


function XLinear(x_physics::ComponentVector)

    x_kinematics = x_physics.kinematics
    x_airframe = x_physics.airframe

    @unpack ψ_nb, θ_nb, φ_nb, ϕ, λ, h_e = x_kinematics.pos
    p, q, r = x_kinematics.vel.ω_eb_b
    v_x, v_y, v_z = x_kinematics.vel.v_eOb_b
    α_filt, β_filt = x_airframe.aero
    ω_eng = x_airframe.pwp.engine.ω
    fuel = x_airframe.fuel[1]
    thr_v = x_airframe.act.throttle_act.v
    thr_p = x_airframe.act.throttle_act.p
    ail_v = x_airframe.act.aileron_act.v
    ail_p = x_airframe.act.aileron_act.p
    ele_v = x_airframe.act.elevator_act.v
    ele_p = x_airframe.act.elevator_act.p
    rud_v = x_airframe.act.rudder_act.v
    rud_p = x_airframe.act.rudder_act.p

    ψ, θ, φ, h = ψ_nb, θ_nb, φ_nb, h_e

    XLinear(;  p, q, r, ψ, θ, φ, v_x, v_y, v_z, ϕ, λ, h, α_filt, β_filt,
        ω_eng, fuel, thr_v, thr_p, ail_v, ail_p, ele_v, ele_p, rud_v, rud_p)

end

function ULinear(physics::System{<:C172FBW.Physics{NED}})

    @unpack throttle_cmd, aileron_cmd, elevator_cmd, rudder_cmd = physics.airframe.act.u
    ULinear(; throttle_cmd, aileron_cmd, elevator_cmd, rudder_cmd)

end

function YLinear(physics::System{<:C172FBW.Physics{NED}})

    @unpack throttle_cmd, aileron_cmd, elevator_cmd, rudder_cmd = physics.airframe.act.u
    @unpack airframe, air, rigidbody, kinematics = physics.y
    @unpack pwp, fuel, aero,act = airframe

    @unpack e_nb, ϕ_λ, h_e, ω_eb_b, v_eOb_b, v_eOb_n, χ_gnd, γ_gnd = kinematics
    @unpack ψ, θ, φ = e_nb
    @unpack ϕ, λ = ϕ_λ

    h = h_e
    p, q, r = ω_eb_b
    v_x, v_y, v_z = v_eOb_b
    v_N, v_E, v_D = v_eOb_n
    ω_eng = pwp.engine.ω
    fuel = fuel.x_avail
    α_filt = aero.α_filt
    β_filt = aero.β_filt

    thr_v = act.throttle_act.vel
    thr_p = act.throttle_act.pos
    ail_v = act.aileron_act.vel
    ail_p = act.aileron_act.pos
    ele_v = act.elevator_act.vel
    ele_p = act.elevator_act.pos
    rud_v = act.rudder_act.vel
    rud_p = act.rudder_act.pos

    f_x, f_y, f_z = physics.y.rigidbody.f_G_b
    EAS = physics.y.air.EAS
    TAS = physics.y.air.TAS
    α = physics.y.air.α_b
    β = physics.y.air.β_b
    χ = χ_gnd
    γ = γ_gnd
    climb_rate = -v_D

    YLinear(; p, q, r, ψ, θ, φ, v_x, v_y, v_z, ϕ, λ, h, α_filt, β_filt,
            ω_eng, fuel, thr_v, thr_p, ail_v, ail_p, ele_v, ele_p, rud_v, rud_p,
            f_x, f_y, f_z, EAS, TAS, α, β, v_N, v_E, v_D, χ, γ, climb_rate,
            throttle_cmd, aileron_cmd, elevator_cmd, rudder_cmd)

end

Aircraft.ẋ_linear(physics::System{<:C172FBW.Physics{NED}}) = XLinear(physics.ẋ)
Aircraft.x_linear(physics::System{<:C172FBW.Physics{NED}}) = XLinear(physics.x)
Aircraft.u_linear(physics::System{<:C172FBW.Physics{NED}}) = ULinear(physics)
Aircraft.y_linear(physics::System{<:C172FBW.Physics{NED}}) = YLinear(physics)

function Aircraft.assign_u!(physics::System{<:C172FBW.Physics{NED}}, u::AbstractVector{Float64})

    #The velocity states in the linearized model are meant to be aerodynamic so
    #they can be readily used for flight control design. Since the velocity
    #states in the nonlinear model are Earth-relative, we need to ensure wind
    #velocity is set to zero for linearization.
    physics.atmosphere.u.v_ew_n .= 0
    @unpack throttle_cmd, aileron_cmd, elevator_cmd, rudder_cmd = ULinear(u)
    @pack! physics.airframe.act.u = throttle_cmd, aileron_cmd, elevator_cmd, rudder_cmd

end

function Aircraft.assign_x!(physics::System{<:C172FBW.Physics{NED}}, x::AbstractVector{Float64})

    @unpack p, q, r, ψ, θ, φ, v_x, v_y, v_z, ϕ, λ, h, α_filt, β_filt, ω_eng,
            fuel, thr_v, thr_p, ail_v, ail_p, ele_v, ele_p, rud_v, rud_p = XLinear(x)

    x_kinematics = physics.x.kinematics
    x_airframe = physics.x.airframe

    ψ_nb, θ_nb, φ_nb, h_e = ψ, θ, φ, h

    @pack! x_kinematics.pos = ψ_nb, θ_nb, φ_nb, ϕ, λ, h_e
    x_kinematics.vel.ω_eb_b .= p, q, r
    x_kinematics.vel.v_eOb_b .= v_x, v_y, v_z
    x_airframe.aero .= α_filt, β_filt
    x_airframe.pwp.engine.ω = ω_eng
    x_airframe.fuel .= fuel
    x_airframe.act.throttle_act.v = thr_v
    x_airframe.act.throttle_act.p = thr_p
    x_airframe.act.aileron_act.v = ail_v
    x_airframe.act.aileron_act.p = ail_p
    x_airframe.act.elevator_act.v = ele_v
    x_airframe.act.elevator_act.p = ele_p
    x_airframe.act.rudder_act.v = rud_v
    x_airframe.act.rudder_act.p = rud_p

end

function Control.Continuous.LinearizedSS(
            physics::System{<:C172FBW.Physics{NED}},
            trim_params::C172.TrimParameters = C172.TrimParameters();
            model::Symbol = :full)

    lm = linearize!(physics, trim_params)

    if model === :full
        return lm

    #preserve the ordering of the complete linearized state and output vectors
    elseif model === :lon
        x_labels = [:q, :θ, :v_x, :v_z, :h, :α_filt, :ω_eng, :thr_v, :thr_p, :ele_v, :ele_p]
        u_labels = [:throttle_cmd, :elevator_cmd]
        y_labels = vcat(x_labels, [:f_x, :f_z, :α, :EAS, :TAS, :γ, :climb_rate, :throttle_cmd, :elevator_cmd])
        return Control.Continuous.submodel(lm; x = x_labels, u = u_labels, y = y_labels)

    elseif model === :lat
        x_labels = [:p, :r, :ψ, :φ, :v_x, :v_y, :β_filt, :ail_v, :ail_p, :rud_v, :rud_p]
        u_labels = [:aileron_cmd, :rudder_cmd]
        y_labels = vcat(x_labels, [:f_y, :β, :χ, :aileron_cmd, :rudder_cmd])
        return Control.Continuous.submodel(lm; x = x_labels, u = u_labels, y = y_labels)

    else
        error("Valid model keyword values: :full, :lon, :lat")

    end

end


################################################################################
################################## Variants ####################################

include(normpath("variants/base.jl")); @reexport using .C172FBWBase
include(normpath("variants/cas/cas.jl")); @reexport using .C172CAS
include(normpath("variants/mcs/mcs.jl")); @reexport using .C172MCS

end