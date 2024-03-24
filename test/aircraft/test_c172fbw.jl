module TestC172FBW

using Test
using UnPack
using BenchmarkTools
using Sockets

using Flight.FlightCore
using Flight.FlightCore.Sim
using Flight.FlightCore.Networking

using Flight.FlightPhysics
using Flight.FlightComponents

using Flight.FlightAircraft.AircraftBase
using Flight.FlightAircraft.C172
using Flight.FlightAircraft.C172FBW

export test_c172fbw

function test_c172fbw()
    @testset verbose = true "Cessna172FBW" begin

        test_trimming()
        test_system_methods()
        test_sim(save = false)

    end
end

function test_trimming()

    @testset verbose = true "Trimming" begin

        vehicle = System(C172FBW.Vehicle())
        trim_params = C172.TrimParameters()
        state = C172.TrimState()

        f_target = C172.get_f_target(vehicle, trim_params)

        @test @ballocated($f_target($state)) === 0

        success, _ = trim!(vehicle, trim_params)

        @test success

    end #testset

end #function

function test_linearization()

    @testset verbose = true "Linearization" begin

    end #testset

end #function

function test_system_methods()

        @testset verbose = true "System Methods" begin

            trn = HorizontalTerrain()
            loc = NVector()
            trn_data = TerrainData(trn, loc)
            kin_init = KinematicInit( h = trn_data.altitude + 1.8);

            ac_LTF = Cessna172FBW(LTF(), trn) |> System;
            ac_ECEF = Cessna172FBW(ECEF(), trn) |> System;
            ac_NED = Cessna172FBW(NED(), trn) |> System;

            Systems.init!(ac_LTF, kin_init)
            Systems.init!(ac_ECEF, kin_init)
            Systems.init!(ac_NED, kin_init)

            f_ode!(ac_LTF)
            #make sure we are on the ground to ensure landing gear code coverage
            @test ac_LTF.y.vehicle.components.ldg.left.strut.wow == true

            #all three kinematics implementations must be supported, no allocations
            @test @ballocated(f_ode!($ac_LTF)) == 0
            @test @ballocated(f_step!($ac_LTF)) == 0
            @test @ballocated(f_disc!($ac_LTF, 1)) == 0

            @test @ballocated(f_ode!($ac_ECEF)) == 0
            @test @ballocated(f_step!($ac_ECEF)) == 0
            @test @ballocated(f_disc!($ac_ECEF, 1)) == 0

            @test @ballocated(f_ode!($ac_NED)) == 0
            @test @ballocated(f_step!($ac_NED)) == 0
            @test @ballocated(f_disc!($ac_NED, 1)) == 0

        end

    return nothing

end

function test_sim(; save::Bool = true)

    @testset verbose = true "Simulation" begin

        ac = Cessna172FBW() |> System;

        mid_cg_pld = C172.PayloadU(m_pilot = 75, m_copilot = 75, m_baggage = 50)

        ac.vehicle.atmosphere.u.v_ew_n .= [0, 0, 0]

        trim_params = C172.TrimParameters(
        Ob = Geographic(LatLon(), HOrth(1000)),
        EAS = 25.0,
        γ_wOb_n = 0.0,
        x_fuel = 0.5,
        flaps = 1.0,
        payload = mid_cg_pld)

        exit_flag, trim_state = trim!(ac, trim_params)
        @test exit_flag === true

        sys_io! = let

            function (ac)

                u_act = ac.vehicle.components.act.u
                t = ac.t[]

                # u_act.throttle_cmd = 0.2
                # u_act.aileron_cmd = (t < 5 ? 0.25 : 0.0)
                # u_act.elevator_cmd = 0.0
                # u_act.rudder_cmd = 0.1
                # u_act.aileron_cmd = 0.1
                # u_act.brake_left = 1
                # u_act.brake_right = 1

            end
        end

        sim = Simulation(ac; t_end = 30, sys_io!, adaptive = true)
        Sim.run!(sim)

        # plots = make_plots(sim; Plotting.defaults...)
        kin_plots = make_plots(TimeSeries(sim).vehicle.kinematics; Plotting.defaults...)
        air_plots = make_plots(TimeSeries(sim).vehicle.air; Plotting.defaults...)
        rb_plots = make_plots(TimeSeries(sim).vehicle.dynamics; Plotting.defaults...)
        save && save_plots(kin_plots, save_folder = joinpath("tmp", "test_c172fbw", "sim", "kin"))
        save && save_plots(air_plots, save_folder = joinpath("tmp", "test_c172fbw", "sim", "air"))
        save && save_plots(rb_plots, save_folder = joinpath("tmp", "test_c172fbw", "sim", "dynamics"))

    end

end


function test_sim_paced(; save::Bool = true)

    h_trn = HOrth(601.55);

    trn = HorizontalTerrain(altitude = h_trn)
    ac = Cessna172FBW(LTF(), trn) |> System

    kin_init = KinematicInit(
        v_eOb_n = [0, 0, 0],
        ω_lb_b = [0, 0, 0],
        q_nb = REuler(ψ = 0, θ = 0.0, φ = 0.0),
        loc = LatLon(ϕ = deg2rad(40.503205), λ = deg2rad(-3.574673)),
        h = h_trn + 1.9 + 0);

    Systems.init!(ac, kin_init)

    sim = Simulation(ac; dt = 0.02, Δt = 0.02, t_end = 300)

    for joystick in get_connected_joysticks()
        Sim.attach!(sim, joystick)
    end

    xpc = XPCDevice()
    # xpc = XPCDevice(host = IPv4("192.168.1.2"))
    Sim.attach!(sim, xpc)

    Sim.run_paced!(sim)

    plots = make_plots(TimeSeries(sim).vehicle.kinematics; Plotting.defaults...)
    # plots = make_plots(TimeSeries(sim); Plotting.defaults...)
    save && save_plots(plots, save_folder = joinpath("tmp", "test_c172fbw", "sim_paced"))

    return nothing

end




end #module