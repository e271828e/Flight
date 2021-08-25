module Flight

using Reexport

#(sub) modules
# include("lbv.jl")
# @reexport using .LBV

#math and environment
include("utils.jl")
include("quaternions.jl")
include("rotations.jl")
include("wgs84.jl") #many, many constants here. should keep it a module
include("terrain.jl")
include("atmosphere.jl")

#simulation
include("system.jl")
include("model.jl")

#aircraft kinematics & dynamics
include("kinematics.jl")
include("dynamics.jl")

#airframe components
include("airdata.jl")
include("propulsion.jl")
# include("landinggear.jl")

include("aircraft.jl")

@reexport using .Utils
@reexport using .Quaternions
@reexport using .Rotations
@reexport using .WGS84
@reexport using .Terrain
@reexport using .Atmosphere

@reexport using .System
@reexport using .Model

@reexport using .Kinematics
@reexport using .Dynamics

@reexport using .Airdata
@reexport using .Propulsion
# @reexport using .LandingGear

@reexport using .Aircraft

println("REMINDER: Set normalization = false")

export ftest

ftest() = println("Welcome to Flight")

end
