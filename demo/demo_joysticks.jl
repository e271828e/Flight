module DemoJoysticks

using UnPack
using CImGui
using CImGui.CSyntax

using Flight
using Flight.FlightAircraft.Control: PIContinuous, PIContinuousU, PIContinuousY

export demo_joysticks

struct TestMapping <: InputMapping end

function IODevices.assign!(sys::System{<:PIContinuous{N}},
                            joystick::T16000M,
                            ::TestMapping) where {N}

    sys.u.feedback .= get_axis_value(joystick, :stick_y)
end

function demo_joysticks()

    sys = PIContinuous{2}(k_p = 0, k_i = 0.2) |> System
    sim = Simulation(sys; t_end = 30, dt = 0.02)

    joy_interfaces = Vector{IODevices.Interface}()
    for joystick in get_connected_joysticks()
        push!(joy_interfaces, attach_io!(sim, joystick; mapping = TestMapping()))
    end

    @sync begin
        for interface in joy_interfaces
            Threads.@spawn IODevices.start!(interface)
        end

        # disable_gui!(sim)
        Threads.@spawn Sim.run_paced!(sim; rate = 1, verbose = true)
    end

end

end #module