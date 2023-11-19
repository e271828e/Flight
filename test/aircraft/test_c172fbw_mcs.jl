module TestC172FBWMCS

using Test, UnPack, BenchmarkTools, Sockets

using Flight.FlightCore
using Flight.FlightCore.Sim
using Flight.FlightCore.Visualization

using Flight.FlightPhysics
using Flight.FlightComponents

using Flight.FlightAircraft.C172
using Flight.FlightAircraft.C172FBW
using Flight.FlightAircraft.C172FBWMCS

export test_c172fbw_mcs


function test_c172fbw_mcs()
    @testset verbose = true "Cessna172FBW MCS" begin

        test_system_methods()
        test_sim(save = false)

    end
end

function test_system_methods()

        @testset verbose = true "System Methods" begin

            trn = HorizontalTerrain()
            loc = NVector()
            trn_data = TerrainData(trn, loc)
            kin_init_gnd = KinematicInit( h = trn_data.altitude + 1.8);
            kin_init_air = KinematicInit( h = trn_data.altitude + 1000);

            ac = System(Cessna172FBWMCS());

            #to exercise all airframe functionality, including landing gear, we
            #need to be on the ground with the engine running
            init_kinematics!(ac, kin_init_gnd)
            ac.avionics.u.inceptors.eng_start = true #engine start switch on
            f_disc!(ac, 0.02, env) #run avionics for the engine start signal to propagate
            f_ode!(ac, env)
            f_step!(ac)
            f_ode!(ac, env)
            f_step!(ac)
            @test ac.y.physics.airframe.ldg.left.strut.wow == true
            @test ac.y.physics.airframe.pwp.engine.state === Piston.eng_starting

            @test @ballocated(f_ode!($ac)) == 0
            @test @ballocated(f_step!($ac)) == 0
            @test @ballocated(f_disc!($ac, 0.02)) == 0

            #now we put the aircraft in flight
            init_kinematics!(ac, kin_init_air)
            f_ode!(ac, env)
            @test ac.y.physics.airframe.ldg.left.strut.wow == false
            @test @ballocated(f_ode!($ac)) == 0
            @test @ballocated(f_step!($ac)) == 0

            #testing the different avionics modes for allocations is a bit more
            #involved
        end

    return nothing

end

function test_cas(; save::Bool = true)

    @testset verbose = true "Simulation" begin

        world = SimpleWorld(Cessna172FBWMCS()) |> System;

        design_condition = C172.TrimParameters(
            Ob = Geographic(LatLon(), HOrth(1000)),
            EAS = 40.0,
            γ_wOb_n = 0.0,
            x_fuel = 0.5,
            flaps = 0.0,
            payload = C172.PayloadU(m_pilot = 75, m_copilot = 75, m_baggage = 50))

        exit_flag, trim_state = trim!(design_condition, trim_params)
        @test exit_flag === true

        sys_io! = let

            function (world)

                t = world.t[]

            end
        end

        sim = Simulation(world; dt = 0.01, Δt = 0.01, t_end = 60, sys_io!, adaptive = false)
        # sim = Simulation(world; dt = 0.01, Δt = 0.01, t_end = 60, adaptive = false)
        Sim.run!(sim, verbose = true)

        # plots = make_plots(sim; Plotting.defaults...)
        kin_plots = make_plots(TimeHistory(sim).ac.physics.kinematics; Plotting.defaults...)
        air_plots = make_plots(TimeHistory(sim).ac.physics.air; Plotting.defaults...)
        rb_plots = make_plots(TimeHistory(sim).ac.physics.rigidbody; Plotting.defaults...)
        save && save_plots(kin_plots, save_folder = joinpath("tmp", "test_c172fbw_mcs", "cas", "kin"))
        save && save_plots(air_plots, save_folder = joinpath("tmp", "test_c172fbw_mcs", "cas", "air"))
        save && save_plots(rb_plots, save_folder = joinpath("tmp", "test_c172fbw_mcs", "cas", "rigidbody"))

        return nothing

    end
end




end #module