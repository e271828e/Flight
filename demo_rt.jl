using Flight
using OrdinaryDiffEq
using SciMLBase
using LinearAlgebra
using BenchmarkTools
using Base.Iterators


################################## AC2 ######################################

function demo_rt()

    h_trn = AltOrth(609.5);

    trn = HorizontalTerrain(altitude = h_trn);
    atm = System(AtmosphereDescriptor());
    ac = System(C172Aircraft());
    ac_mdl = Model(ac, (trn, atm); dt = 0.02, t_end = 20, adaptive = false, solver = RK4(), y_saveat = 0.02);

    kin_init = KinInit(v_eOb_b = [30, 0, 0],
                        ω_lb_b = [0, 0, 0],
                        q_nb = REuler(ψ = π, θ = 0.1, φ = 0.05),
                        Ob = Geographic(LatLon(ϕ = deg2rad(40.531818), λ = deg2rad(-3.574862)),
                                        h_trn + 0.85 + 0.4));
    ac.u.throttle = 0
    ac.u.pedals = 0.1
    ac.u.brake_left = 1
    ac.u.brake_right = 1
    atm.u.wind.v_ew_n[1] = 0

    # kin_init = KinInit(v_eOb_b = [0, 0, 0],
    #                     ω_lb_b = [0, 0, 0],
    #                     q_nb = REuler(ψ = π, θ = 0, φ = 0),
    #                     Ob = Geographic(LatLon(ϕ = deg2rad(40.531818), λ = deg2rad(-3.574862)),
    #                                     h_trn + 0.85));

    # ac.u.throttle = 1
    # ac.u.brake_left = 1
    # ac.u.brake_right = 1

    init!(ac, kin_init)
    #if the model was instantiated in advance, we need this to change its internal state vector!
    reinit!(ac_mdl, ac.x)

    xp = XPInterface()
    disable_physics(xp)
    set_position(xp, kin_init)

    output_div = 1

    t_wall = time()
    t_wall_0 = t_wall

    println("Generalize this for non-rt")

    # for i in take(ac_mdl.integrator, 5)
    for i in ac_mdl.integrator

        #when using the integrator as an iterator, we don't need to step, it is done
        #automatically at the beginning of each iteration. therefore, the dt we need
        #for pacing the simulation is not the proposed dt for the next step, but the
        #one in the step the integrator has already taken.

        #retrieve the dt just taken by the integrator
        dt = ac_mdl.dt

        #compute the wall time corresponding to the newly updated simulation
        t_wall_next = t_wall + dt

        #busy wait until the wall time catches up
        while (time() < t_wall_next) end
        # println(time()-t_wall_next)

        t_wall = t_wall_next
        # println(t_wall - t_wall_0)

        if ac_mdl.success_iter % output_div == 0
            set_position(xp, ac_mdl.sys.y.kin.pos)
        end

        #when GLFW is implemented, build the model with t_end = Inf and use this to break
        # if !GLFW.WindowShouldClose(window)
        #     break
        # end

    end

    plot_settings = (linewidth=2, margin = 10mm, guidefontsize = 12)
    plots(ac_mdl; save_path = joinpath("tmp", "plots_demo_rt"), plot_settings...)


end



# plots(ac_mdl; save_path = joinpath("tmp", "plots_ac_rt"), plot_settings...)