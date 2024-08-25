module TestC172FBWv1

using Test, UnPack, BenchmarkTools, Sockets

using Flight.FlightCore
using Flight.FlightCore.Sim
using Flight.FlightCore.Networking

using Flight.FlightPhysics
using Flight.FlightComponents
using Flight.FlightComponents.Control.Discrete: load_pid_lookup, load_lqr_tracker_lookup

using Flight.FlightAircraft.AircraftBase
using Flight.FlightAircraft.C172
using Flight.FlightAircraft.C172FBWv1
using Flight.FlightAircraft.C172FBW.FlightControl: lon_direct, lon_thr_ele, lon_thr_q, lon_thr_θ, lon_thr_EAS, lon_EAS_q, lon_EAS_θ, lon_EAS_clm
using Flight.FlightAircraft.C172FBW.FlightControl: lat_direct, lat_p_β, lat_φ_β, lat_χ_β
using Flight.FlightAircraft.C172FBW.FlightControl: vrt_gdc_off, vrt_gdc_alt
using Flight.FlightAircraft.C172FBW.FlightControl: hor_gdc_off, hor_gdc_line
using Flight.FlightAircraft.C172FBW.FlightControl: phase_gnd, phase_air

export test_c172fbw_v1


function test_c172fbw_v1()
    @testset verbose = true "Cessna172 FBWv1" begin

        test_control_modes()
        test_guidance_modes()

    end
end

y_kin(ac::System{<:Cessna172FBWv1}) = ac.y.vehicle.kinematics
y_air(ac::System{<:Cessna172FBWv1}) = ac.y.vehicle.air

function test_control_modes()

    data_folder = joinpath(dirname(dirname(@__DIR__)),
        normpath("src/aircraft/c172/c172fbw/control/data"))

    @testset verbose = true "Control Modes" begin

    h_trn = HOrth(0)
    trn = HorizontalTerrain(altitude = h_trn)
    ac = Cessna172FBWv1(LTF(), trn) |> System;
    fcl = ac.avionics.fcl

    kin_init_gnd = KinematicInit( h = TerrainData(trn).altitude + 1.9);
    design_point = C172.TrimParameters()
    f_init_gnd! = (ac) -> Systems.init!(ac, kin_init_gnd)
    f_init_air! = (ac) -> Systems.init!(ac, design_point)

    #we don't really need to provide a specific sys_init! function, because
    #sys_init! defaults to Systems.init!, which for Aircraft has methods
    #accepting both a Kinematics.Initializer and an AbstractTrimParameters
    dt = Δt = 0.01
    sim = Simulation(ac; dt, Δt, t_end = 600)

    ############################################################################
    ############################## Ground ######################################

    @testset verbose = true "Ground" begin

    kin_init_gnd = KinematicInit( h = TerrainData(trn).altitude + 1.9);
    reinit!(sim, f_init_gnd!)

    @test ac.y.avionics.fcl.flight_phase === phase_gnd

    #set arbitrary control and guidance modes
    fcl.u.vrt_gdc_mode_req = vrt_gdc_alt
    fcl.u.hor_gdc_mode_req = hor_gdc_line
    fcl.u.lon_ctl_mode_req = lon_EAS_clm
    fcl.u.lat_ctl_mode_req = lat_p_β
    fcl.u.throttle_sp_input = 0.1
    fcl.u.aileron_sp_input = 0.2
    fcl.u.elevator_sp_input = 0.3
    fcl.u.rudder_sp_input = 0.4

    step!(sim, Δt, true)

    @test fcl.y.flight_phase === phase_gnd

    #the mode requests are overridden due to phase_gnd
    @test fcl.y.vrt_gdc_mode === vrt_gdc_off
    @test fcl.y.hor_gdc_mode === hor_gdc_off
    @test fcl.y.lon_ctl_mode === lon_direct
    @test fcl.y.lat_ctl_mode === lat_direct

    #control laws outputs must have propagated to actuator inputs (not yet to
    #their outputs, that requires a subsequent call to f_ode!)
    @test ac.vehicle.components.act.throttle.u[] == 0.1
    @test ac.vehicle.components.act.aileron.u[] == 0.2
    @test ac.vehicle.components.act.elevator.u[] == 0.3
    @test ac.vehicle.components.act.rudder.u[] == 0.4

    # @test @ballocated(f_ode!($ac)) == 0
    # @test @ballocated(f_step!($ac)) == 0
    # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end #testset

    ############################################################################
    ################################# Air ######################################

    @testset verbose = true "Air" begin

    #put the aircraft in its nominal design point
    reinit!(sim, f_init_air!)
    y_kin_trim = y_kin(ac)

    ############################### direct control #############################

    @testset verbose = true "lon_direct + lat_direct" begin

        reinit!(sim, f_init_air!)
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_direct
        @test fcl.y.lat_ctl_mode === lat_direct

        #with direct surface control, trim state must be initially preserved
        step!(sim, 10, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b, y_kin_trim.ω_lb_b; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b, y_kin_trim.v_eOb_b; atol = 1e-2))

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end #testset

    ############################ thr+ele SAS mode ##############################

    @testset verbose = true "lon_thr_ele" begin

        #we test the longitudinal SAS first, because we want to test the lateral
        #modes with it enabled
        reinit!(sim, f_init_air!)
        fcl.u.lon_ctl_mode_req = lon_thr_ele
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_thr_ele

        #check the correct parameters are loaded and assigned to the controller
        te2te_lookup = load_lqr_tracker_lookup(joinpath(data_folder, "te2te_lookup.h5"))
        C_fwd = te2te_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).C_fwd
        @test all(isapprox.(fcl.y.lon_ctl.te2te_lqr.C_fwd, C_fwd; atol = 1e-6))

        #with thr+ele SAS active, trim state must be preserved for longer
        step!(sim, 30, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end #testset

    ################################ φ + β #####################################

    @testset verbose = true "lat_φ_β" begin

        reinit!(sim, f_init_air!)
        fcl.u.lon_ctl_mode_req = lon_thr_ele
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lat_ctl_mode === lat_φ_β

        #check the correct parameters are loaded and assigned to the controller
        φβ2ar_lookup = load_lqr_tracker_lookup(joinpath(data_folder, "φβ2ar_lookup.h5"))
        C_fwd = φβ2ar_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).C_fwd
        @test all(isapprox.(fcl.y.lat_ctl.φβ2ar_lqr.C_fwd, C_fwd; atol = 1e-6))

        #with setpoints matching their trim values, the control mode must activate
        #without transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking while turning
        fcl.u.φ_sp = π/12
        fcl.u.β_sp = deg2rad(3)
        step!(sim, 10, true)
        @test isapprox(fcl.u.φ_sp, y_kin(ac).e_nb.φ; atol = 1e-3)
        @test isapprox(Float64(fcl.u.β_sp), y_air(ac).β_b; atol = 1e-3)

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end

    ################################ p + β #####################################

    @testset verbose = true "lat_p_β" begin

        reinit!(sim, f_init_air!)
        fcl.u.lon_ctl_mode_req = lon_thr_ele
        fcl.u.lat_ctl_mode_req = lat_p_β
        step!(sim, Δt, true)
        @test fcl.y.lat_ctl_mode === lat_p_β

        #check the correct parameters are loaded and assigned to the controllers
        φβ2ar_lookup = load_lqr_tracker_lookup(joinpath(data_folder, "φβ2ar_lookup.h5"))
        C_fwd = φβ2ar_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).C_fwd
        @test all(isapprox.(fcl.y.lat_ctl.φβ2ar_lqr.C_fwd, C_fwd; atol = 1e-6))

        #the control mode must activate without transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #the controller must keep trim values in steady state
        step!(sim, 10, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        fcl.u.p_sp = 0.02
        fcl.u.β_sp = deg2rad(3)
        step!(sim, 10, true)
        @test isapprox(Float64(fcl.u.p_sp), y_kin(ac).ω_lb_b[1]; atol = 1e-3)
        @test isapprox(fcl.u.β_sp, y_air(ac).β_b; atol = 1e-3)

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end

    ################################ χ + β #####################################

    @testset verbose = true "lat_χ_β" begin

        reinit!(sim, f_init_air!)
        fcl.u.lon_ctl_mode_req = lon_thr_ele
        fcl.u.lat_ctl_mode_req = lat_χ_β
        step!(sim, Δt, true)
        @test fcl.y.lat_ctl_mode === lat_χ_β

        #check the correct parameters are loaded and assigned to the controller
        χ2φ_lookup = load_pid_lookup(joinpath(data_folder, "χ2φ_lookup.h5"))
        k_p = χ2φ_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).k_p
        @test all(isapprox.(fcl.y.lat_ctl.χ2φ_pid.k_p, k_p; atol = 1e-6))

        #with setpoints matching their trim values, the control mode must activate
        #without transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking
        fcl.u.χ_sp = π/2
        step!(sim, 29, true)
        @test fcl.lat_ctl.u.χ_sp != 0
        @test isapprox(fcl.u.χ_sp, y_kin(ac).χ_gnd; atol = 1e-2)
        # @test isapprox(Float64(fcl.u.yaw_input), y_air(ac).β_b; atol = 1e-3)

        #correct tracking with 10m/s of crosswind
        ac.vehicle.atmosphere.u.v_ew_n[1] = 10
        step!(sim, 10, true)
        @test isapprox(fcl.u.χ_sp, y_kin(ac).χ_gnd; atol = 1e-2)
        ac.vehicle.atmosphere.u.v_ew_n[1] = 0

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end

    ############################################################################

    #now we proceed to test the remaining longitudinal modes we test with
    #lateral p + β mode enabled

    ############################### lon_thr_q ##################################

    @testset verbose = true "lon_thr_q" begin

        reinit!(sim, f_init_air!)

        fcl.u.lon_ctl_mode_req = lon_thr_q
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_thr_q

        #check the correct parameters are loaded and assigned to the controller
        q2e_lookup = load_pid_lookup(joinpath(data_folder, "q2e_lookup.h5"))
        k_p = q2e_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).k_p
        @test all(isapprox.(fcl.y.lon_ctl.q2e_pid.k_p, k_p; atol = 1e-6))

        #when trim setpoints are kept, the control mode must activate without
        #transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking while turning
        fcl.u.φ_sp = π/12
        fcl.u.q_sp = 0.01
        step!(sim, 10, true)

        @test fcl.lon_ctl.u.q_sp != 0
        @test isapprox(fcl.lon_ctl.u.q_sp, y_kin(ac).ω_lb_b[2]; atol = 1e-3)
        @test isapprox(Float64(ac.y.vehicle.components.act.throttle.cmd),
                        Float64(fcl.u.throttle_sp_input + fcl.u.throttle_sp_offset); atol = 1e-3)

        # @test @ballocated(f_disc!($ac, $Δt)) == 0


    end


    ############################## lon_thr_θ ###################################

    @testset verbose = true "lon_thr_θ" begin

        reinit!(sim, f_init_air!)

        fcl.u.lon_ctl_mode_req = lon_thr_θ
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_thr_θ

        #when trim setpoints are kept, the control mode must activate without
        #transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking while turning
        fcl.u.φ_sp = π/6
        fcl.u.θ_sp = deg2rad(5)
        step!(sim, 10, true)
        @test isapprox(y_kin(ac).e_nb.θ, fcl.u.θ_sp; atol = 1e-4)

        # @test @ballocated(f_disc!($ac, $Δt)) == 0


    end


    ################################ lon_thr_EAS ###############################

    @testset verbose = true "lon_thr_EAS" begin

        reinit!(sim, f_init_air!)

        fcl.u.lon_ctl_mode_req = lon_thr_EAS
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_thr_EAS

        #check the correct parameters are loaded and assigned to the controller
        v2θ_lookup = load_pid_lookup(joinpath(data_folder, "v2θ_lookup.h5"))
        k_p = v2θ_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).k_p
        @test all(isapprox.(fcl.y.lon_ctl.v2θ_pid.k_p, k_p; atol = 1e-6))

        #when trim setpoints are kept, the control mode must activate without
        #transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking while turning
        fcl.u.φ_sp = π/6
        fcl.u.EAS_sp = 45
        step!(sim, 30, true)
        @test all(isapprox.(y_air(ac).EAS, fcl.u.EAS_sp; atol = 1e-1))

        # @test @ballocated(f_disc!($ac, $Δt)) == 0


    end

    ################################ lon_EAS_q #################################

    @testset verbose = true "lon_EAS_q" begin

        reinit!(sim, f_init_air!)

        fcl.u.lon_ctl_mode_req = lon_EAS_q
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_EAS_q

        #check the correct parameters are loaded and assigned to v2t, the q
        #tracker is shared with other modes
        v2t_lookup = load_pid_lookup(joinpath(data_folder, "v2t_lookup.h5"))
        k_p = v2t_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).k_p
        @test all(isapprox.(fcl.y.lon_ctl.v2t_pid.k_p, k_p; atol = 1e-6))

        #when trim setpoints are kept, the control mode must activate without
        #transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking
        fcl.u.q_sp = -0.01
        step!(sim, 10, true)
        fcl.u.q_sp = 0.005
        step!(sim, 10, true)
        fcl.u.q_sp = 0.0
        step!(sim, 20, true)

        @test isapprox(fcl.lon_ctl.u.q_sp, y_kin(ac).ω_lb_b[2]; atol = 1e-3)
        @test all(isapprox.(y_air(ac).EAS, fcl.u.EAS_sp; atol = 1e-1))

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end


    ################################ lon_EAS_q #################################

    @testset verbose = true "lon_EAS_θ" begin

        reinit!(sim, f_init_air!)

        fcl.u.lon_ctl_mode_req = lon_EAS_θ
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_EAS_θ

        #when trim setpoints are kept, the control mode must activate without
        #transients
        step!(sim, 0.1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking while turning
        fcl.u.φ_sp = π/6
        fcl.u.θ_sp = deg2rad(3)
        step!(sim, 10, true)
        fcl.u.θ_sp = -deg2rad(3)
        step!(sim, 60, true)

        @test isapprox(fcl.lon_ctl.u.θ_sp, y_kin(ac).e_nb.θ; atol = 1e-3)
        @test all(isapprox.(y_air(ac).EAS, fcl.u.EAS_sp; atol = 1e-1))

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

    end

    ############################## lon_EAS_clm #################################

    @testset verbose = true "lon_EAS_clm" begin

        reinit!(sim, f_init_air!)

        fcl.u.lon_ctl_mode_req = lon_EAS_clm
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.lon_ctl_mode === lon_EAS_clm

        #check the correct parameters are loaded and assigned to the controller
        vc2te_lookup = load_lqr_tracker_lookup(joinpath(data_folder, "vc2te_lookup.h5"))
        C_fwd = vc2te_lookup(y_air(ac).EAS, Float64(y_kin(ac).h_e)).C_fwd
        @test all(isapprox.(fcl.y.lon_ctl.vc2te_lqr.C_fwd, C_fwd; atol = 1e-6))

        #when trim setpoints are kept, the control mode must activate without
        #transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #correct tracking while turning
        fcl.u.φ_sp = π/6
        fcl.u.EAS_sp = 45
        fcl.u.clm_sp = 2
        step!(sim, 30, true)
        @test all(isapprox.(y_kin(ac).v_eOb_n[3], -fcl.u.clm_sp; atol = 1e-1))
        @test all(isapprox.(y_air(ac).EAS, fcl.u.EAS_sp; atol = 1e-1))

        # @test @ballocated(f_disc!($ac, $Δt)) == 0

        # kin_plots = make_plots(TimeSeries(sim).vehicle.kinematics; Plotting.defaults...)
        # air_plots = make_plots(TimeSeries(sim).vehicle.air; Plotting.defaults...)
        # save_plots(kin_plots, save_folder = joinpath("tmp", "test_c172_fbw_v1", "avionics", "kin"))
        # save_plots(air_plots, save_folder = joinpath("tmp", "test_c172_fbw_v1", "avionics", "air"))
        # return TimeSeries(sim)


    end #testset

    end #testset

    end #testset

end #function


function test_guidance_modes()

    @testset verbose = true "Guidance Modes" begin

    h_trn = HOrth(0)
    trn = HorizontalTerrain(altitude = h_trn)
    ac = Cessna172FBWv1(LTF(), trn) |> System;
    fcl = ac.avionics.fcl
    design_point = C172.TrimParameters()
    f_init_air! = (ac) -> Systems.init!(ac, design_point)

    dt = Δt = 0.01
    sim = Simulation(ac; dt, Δt, t_end = 600)

    @testset verbose = true "Altitude Guidance" begin

        reinit!(sim, f_init_air!)
        y_kin_trim = y_kin(ac)

        fcl.u.vrt_gdc_mode_req = vrt_gdc_alt
        fcl.u.lat_ctl_mode_req = lat_φ_β
        step!(sim, Δt, true)
        @test fcl.y.vrt_gdc_mode === vrt_gdc_alt
        @test fcl.y.lon_ctl_mode === lon_EAS_clm

        #when trim setpoints are kept, the guidance mode must activate without
        #transients
        step!(sim, 1, true)
        @test all(isapprox.(y_kin(ac).ω_lb_b[2], y_kin_trim.ω_lb_b[2]; atol = 1e-5))
        @test all(isapprox.(y_kin(ac).v_eOb_b[1], y_kin_trim.v_eOb_b[1]; atol = 1e-2))

        #all tests while turning
        fcl.u.φ_sp = π/12

        fcl.u.h_sp = y_kin_trim.h_e + 100
        step!(sim, 1, true)
        @test fcl.y.lon_ctl_mode === lon_thr_EAS
        step!(sim, 60, true) #altitude is captured
        @test fcl.y.lon_ctl_mode === lon_EAS_clm
        @test isapprox.(y_kin(ac).h_e - fcl.u.h_sp, 0.0; atol = 1e-1)

        #setpoint changes within the current threshold do not prompt a mode change
        fcl.u.h_sp = y_kin(ac).h_e - fcl.alt_gdc.s.h_thr / 2
        step!(sim, 1, true)
        @test fcl.y.lon_ctl_mode === lon_EAS_clm
        step!(sim, 30, true) #altitude is captured
        @test isapprox.(y_kin(ac).h_e - fcl.u.h_sp, 0.0; atol = 1e-1)

        fcl.u.h_sp = y_kin_trim.h_e - 100
        step!(sim, 1, true)
        @test fcl.y.lon_ctl_mode === lon_thr_EAS
        step!(sim, 80, true) #altitude is captured
        @test fcl.y.lon_ctl_mode === lon_EAS_clm
        @test isapprox.(y_kin(ac).h_e - fcl.u.h_sp, 0.0; atol = 1e-1)

        @test fcl.y.lon_ctl_mode === lon_EAS_clm
        # @test @ballocated(f_disc!($ac, $Δt)) == 0
        fcl.u.h_sp = y_kin_trim.h_e + 100
        step!(sim, 1, true)
        @test fcl.y.lon_ctl_mode === lon_thr_EAS
        # @test @ballocated(f_disc!($ac, $Δt)) == 0

        # kin_plots = make_plots(TimeSeries(sim).vehicle.kinematics; Plotting.defaults...)
        # air_plots = make_plots(TimeSeries(sim).vehicle.air; Plotting.defaults...)
        # save_plots(kin_plots, save_folder = joinpath("tmp", "test_c172_fbw_v1", "avionics", "kin"))
        # save_plots(air_plots, save_folder = joinpath("tmp", "test_c172_fbw_v1", "avionics", "air"))
        # return TimeSeries(sim)

    end

    end #testset

end

function test_sim_interactive(; save::Bool = true)

    h_trn = HOrth(601.55);

    trn = HorizontalTerrain(altitude = h_trn)
    ac = Cessna172FBWv1(LTF(), trn) |> System;
    sim = Simulation(ac; dt = 1/60, Δt = 1/60, t_end = 600)

    # #on ground
    # initializer = KinematicInit(
    #     loc = LatLon(ϕ = deg2rad(40.503205), λ = deg2rad(-3.574673)),
    #     h = h_trn + 1.81);

    #on air, automatically trimmed by reinit!
    initializer = C172.TrimParameters(
        Ob = Geographic(LatLon(ϕ = deg2rad(40.503205), λ = deg2rad(-3.574673)), HEllip(1050)))

    f_init! = (ac)->Systems.init!(ac, initializer)

    reinit!(sim, f_init!)

    for joystick in get_connected_joysticks()
        Sim.attach!(sim, joystick)
    end

    xpc = XPCClient()
    # xpc = XPCClient(address = IPv4("192.168.1.2"))
    Sim.attach!(sim, xpc)

    Sim.run_interactive!(sim)

    kin_plots = make_plots(TimeSeries(sim).vehicle.kinematics; Plotting.defaults...)
    air_plots = make_plots(TimeSeries(sim).vehicle.air; Plotting.defaults...)
    save && save_plots(kin_plots, save_folder = joinpath("tmp", "test_c172fbw_v1", "sim_interactive", "kin"))
    save && save_plots(air_plots, save_folder = joinpath("tmp", "test_c172fbw_v1", "sim_interactive", "air"))

    return nothing

end


end #module