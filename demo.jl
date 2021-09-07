using Flight
using OrdinaryDiffEq
using SciMLBase
using LinearAlgebra
using BenchmarkTools

using StructArrays

using Flight.Plotting

air = AirY()

thr = EThruster();
thr_sys = HybridSystem(thr);
f_cont!(thr_sys, air);
y_thr = thr_sys.y
thr_mdl = HybridModel(thr_sys, (air,))
thr_mdl.u.throttle = 1
step!(thr_mdl, 10, true)

g = ACGroup(left = EThruster(), right = EThruster());
g_sys = HybridSystem(g);
f_cont!(g_sys, air);
y_g = g_sys.y
g_mdl = HybridModel(g_sys, (air,))
g_mdl.u.left.throttle = 1
g_mdl.u.right.throttle = 1
step!(g_mdl)

trn = DummyTerrainModel()
atm = DummyAtmosphericModel()
ac = TestAircraft();

ac_sys = HybridSystem(ac);
f_cont!(ac_sys, trn, atm);
y_ac = ac_sys.y

ac_sys = HybridSystem(ac); #should remake the system, because it sets the Model's initial condition upon creation
ac_mdl = HybridModel(ac_sys, (trn, atm); dt = 0.01, adaptive = false, method = Heun(), y_saveat = 0.1);
ac_mdl.sys.subsystems.pwp.u.left.throttle = 1 #the same
b = @benchmarkable step!($ac_mdl, 1, true) setup=(reinit!($ac_mdl)); run(b)

ac_sys = HybridSystem(ac); #should remake the system, because it sets the Model's initial condition upon creation
ac_mdl = HybridModel(ac_sys, (trn, atm));
ac_mdl.sys.subsystems.pwp.u.left.throttle = 1 #the same
b = @benchmarkable step!($ac_mdl, 1, true) setup=(reinit!($ac_mdl)); run(b)

#kinematics torture test: do not try this without an adaptive integrator! the
#"thing" shoots southward from the North pole. if you're looking exactly south,
#your heading is ill-defined, so it chatters between π and -π at different
#integration step. but the quaternion representation doesn't care. bank angle
#wraps around -π twice longitude is not defined at the North pole, so it jumps
#instantaneously from its random initialization value (0) to around π. it
#doesn't chatter because due to Coriolis acceleration, it does not remain at π.

#reinitialize at the North Pole, set end time and run to completion
x0 = copy(ac_mdl.x)
x0.kin .= get_x0(KinInit(Ob = Geographic(LatLon(ϕ = π/2))))
reinit!(ac_mdl, x0, tf = 3)
solve!(ac_mdl)

#this should be set at startup.jl
plot_settings = (linewidth=2, margin = 10mm,)

plots(ac_mdl; save_path = joinpath("tmp", "plots2"), plot_settings...)