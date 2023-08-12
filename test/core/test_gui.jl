module TestGUI

using Test

using Flight.FlightCore.Systems
using Flight.FlightCore.GUI

using Flight.FlightPhysics.Environment
using Flight.FlightComponents.Control
using Flight.FlightComponents.World
using Flight.FlightAircraft.C172Rv0
using Flight.FlightAircraft.C172Rv2

export test_gui

function test_gui()
    # target = SimpleWorld(Cessna172Rv2(), SimpleEnvironment()) |> System
    # target = PIContinuous{2}() |> System
    target = Cessna172Rv0() |> System
    r = Renderer()
    GUI.init!(r)
    GUI.run(r, GUI.draw!, target)
end

end