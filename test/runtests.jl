using Flight

include(normpath("physics/test_quaternions.jl")); using .TestQuaternions
include(normpath("physics/test_attitude.jl")); using .TestAttitude
include(normpath("physics/test_geodesy.jl")); using .TestGeodesy
include(normpath("physics/test_kinematics.jl")); using .TestKinematics

include(normpath("components/test_control.jl")); using .TestControl
include(normpath("components/test_propellers.jl")); using .TestPropellers
include(normpath("components/test_landing_gear.jl")); using .TestLandingGear
include(normpath("components/test_piston.jl")); using .TestPiston
include(normpath("components/test_world.jl")); using .TestWorld

include(normpath("aircraft/test_c172r_base.jl")); using .TestC172RBase
include(normpath("aircraft/test_c172r_direct.jl")); using .TestC172RDirect

test_quaternions()
test_attitude()
test_geodesy()
test_kinematics()

test_control()
test_propellers()
test_landing_gear()
test_piston()
test_world()

test_c172r_base()
test_c172r_direct()
# test_c172rv2()