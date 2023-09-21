module TestC172RCAS

using Test, UnPack, BenchmarkTools, Sockets

using Flight.FlightCore.Systems
using Flight.FlightCore.Sim
using Flight.FlightCore.Plotting
using Flight.FlightCore.IODevices
using Flight.FlightCore.Joysticks
using Flight.FlightCore.XPC

using Flight.FlightPhysics.Attitude
using Flight.FlightPhysics.Geodesy
using Flight.FlightPhysics.Kinematics
using Flight.FlightPhysics.Environment

using Flight.FlightComponents.Aircraft
using Flight.FlightComponents.World

using Flight.FlightAircraft.C172R
using Flight.FlightAircraft.C172RCAS

export test_c172r_cas


function test_c172r_cas()
    @testset verbose = true "Cessna172RCAS" begin

        test_system_methods()
        test_sim(save = false)

    end
end

function test_system_methods()

        @testset verbose = true "System Methods" begin

            env = SimpleEnvironment() |> System

            loc = NVector()
            trn_data = TerrainData(env.trn, loc)
            kin_init_gnd = KinematicInit( h = trn_data.altitude + 1.8);
            kin_init_air = KinematicInit( h = trn_data.altitude + 1000);

            ac = System(Cessna172RCAS());

            #to exercise all landing gear functionality we need to be on ground
            init_kinematics!(ac, kin_init_gnd)
            f_ode!(ac, env) #make sure we're on the ground
            @test ac.y.airframe.ldg.left.strut.wow == true

            @test @ballocated(f_ode!($ac, $env)) == 0
            @test @ballocated(f_step!($ac)) == 0
            @test @ballocated(f_disc!($ac, 0.02, $env)) == 0

            #to exercise all CAS functionality we need to be airborne and select
            #the outer control loops for all axes
            init_kinematics!(ac, kin_init_air)
            f_ode!(ac, env)
            @test ac.y.airframe.ldg.left.strut.wow == false

            ac.avionics.u.pitch_mode_select = C172RCAS.pitch_angle_mode
            ac.avionics.u.roll_mode_select = C172RCAS.roll_angle_mode
            ac.avionics.u.yaw_mode_select = C172RCAS.sideslip_mode
            f_disc!(ac, 0.02, env)
            @test ac.avionics.y.logic.flight_phase == C172RCAS.phase_air

            @test @ballocated(f_ode!($ac, $env)) == 0
            @test @ballocated(f_step!($ac)) == 0
            @test @ballocated(f_disc!($ac, 0.02, $env)) == 0

        end

    return nothing

end

function test_sim(; save::Bool = true)

    @testset verbose = true "CAS" begin

        h_trn = HOrth(608.55);

        ac = Cessna172RCAS();
        env = SimpleEnvironment(trn = HorizontalTerrain(altitude = h_trn))
        world = SimpleWorld(ac, env) |> System;

        kin_init = KinematicInit(
            v_eOb_n = [30, 0, 0],
            ω_lb_b = [0, 0, 0],
            q_nb = REuler(ψ = 0, θ = 0.0, φ = 0.),
            loc = LatLon(ϕ = deg2rad(40.503205), λ = deg2rad(-3.574673)),
            h = h_trn + 1.9 + 2200.5);

        init_kinematics!(world, kin_init)

        world.ac.avionics.u.eng_start = true #engine start switch on
        world.ac.avionics.u.CAS_enable = true #enable CAS
        world.ac.avionics.u.roll_mode_select = C172RCAS.roll_angle_mode
        world.ac.avionics.u.pitch_mode_select = C172RCAS.pitch_angle_mode
        world.ac.avionics.u.yaw_mode_select = C172RCAS.sideslip_mode
        world.ac.avionics.u.throttle = 1
        world.env.atm.wind.u.v_ew_n .= [0, 0, 0]

        sys_io! = let

            function (world)

                u_avionics = world.ac.avionics.u
                t = world.t[]

                if 0 < t < 10
                    u_avionics.roll_input = 0
                    u_avionics.pitch_input = 0
                    u_avionics.yaw_input = 0
                elseif 10 < t < 15
                    u_avionics.roll_input = 1
                    u_avionics.pitch_input = 0.0
                    u_avionics.yaw_input = 0.1
                else #t>15
                    u_avionics.roll_input = 1
                    u_avionics.pitch_input = 0.0
                    u_avionics.yaw_input = 0.0
                end
            end
        end

        sim = Simulation(world; Δt = 0.02, t_end = 18, sys_io!, adaptive = false)
        Sim.run!(sim, verbose = true)

        # plots = make_plots(sim; Plotting.defaults...)
        plots = make_plots(TimeHistory(sim).ac.kinematics; Plotting.defaults...)
        save && save_plots(plots, save_folder = joinpath("tmp", "test_c172r_cas", "cas"))

        return nothing

    end
end


function test_sim_paced(; save::Bool = true)

    h_trn = HOrth(601.55);

    ac = Cessna172RCAS();
    env = SimpleEnvironment(trn = HorizontalTerrain(altitude = h_trn))
    world = SimpleWorld(ac, env) |> System;

    kin_init = KinematicInit(
        v_eOb_n = [0, 0, 0],
        ω_lb_b = [0, 0, 0],
        q_nb = REuler(ψ = 0, θ = 0.0, φ = 0.3),
        loc = LatLon(ϕ = deg2rad(40.503205), λ = deg2rad(-3.574673)),
        h = h_trn + 1.9 + 0);

    init_kinematics!(world, kin_init)

    sim = Simulation(world; dt = 0.01, Δt = 0.02, t_end = 300)

    interfaces = Vector{IODevices.Interface}()
    for joystick in get_connected_joysticks()
        push!(interfaces, attach_io!(sim, joystick))
    end

    xp = XPCDevice()
    # xp = XPCDevice(host = IPv4("192.168.1.2"))
    push!(interfaces, attach_io!(sim, xp))

    @sync begin
        for interface in interfaces
            Threads.@spawn IODevices.start!(interface)
        end
        Threads.@spawn Sim.run_paced!(sim; pace = 1, verbose = true)
    end

    plots = make_plots(TimeHistory(sim).ac.kinematics; Plotting.defaults...)
    # plots = make_plots(TimeHistory(sim); Plotting.defaults...)
    save && save_plots(plots, save_folder = joinpath("tmp", "test_c172r_cas", "sim_paced"))

    return nothing

end


end #module