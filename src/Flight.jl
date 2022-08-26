module Flight

using Reexport
@reexport using BenchmarkTools

include("core/systems.jl"); @reexport using .Systems
include("core/gui.jl"); @reexport using .GUI
include("core/input.jl"); @reexport using .Input
include("core/output.jl"); @reexport using .Output
include("core/sim.jl"); @reexport using .Sim
include("core/plotting.jl"); @reexport using .Plotting
include("core/utils.jl"); @reexport using .Utils

include("physics/quaternions.jl"); @reexport using .Quaternions
include("physics/attitude.jl"); @reexport using .Attitude
include("physics/geodesy.jl"); @reexport using .Geodesy
include("physics/kinematics.jl"); @reexport using .Kinematics
include("physics/rigidbody.jl"); @reexport using .RigidBody


include("components/common/essentials.jl"); @reexport using .Essentials
# include("components/environment/atmosphere.jl"); @reexport using .Atmosphere
# include("components/environment/terrain.jl"); @reexport using .Terrain
# include("components/environment/environment.jl"); @reexport using .Environment
# include("components/aircraft/landinggear.jl"); @reexport using .LandingGear
# include("components/aircraft/propellers.jl"); @reexport using .Propellers
# include("components/aircraft/piston.jl"); @reexport using .Piston

# include("aircraft/aircraft.jl"); @reexport using .Aircraft
# include("aircraft/c172r/c172r.jl"); @reexport using .C172R

end
