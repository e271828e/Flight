module Sim

using UnPack, Reexport, StructArrays
using OrdinaryDiffEq: OrdinaryDiffEq, OrdinaryDiffEqAlgorithm, ODEProblem,
                      ODEIntegrator, Heun, RK4, u_modified!, init as init_integrator
using DiffEqCallbacks: SavingCallback, DiscreteCallback, PeriodicCallback,
                       CallbackSet, SavedValues
using RecursiveArrayTools
using Logging

using ..Systems
using ..IODevices
using ..GUI

@reexport using OrdinaryDiffEq: step!, reinit!, add_tstop!, get_proposed_dt
export Simulation, enable_gui!, disable_gui!, attach!
export TimeSeries, get_time, get_data, get_components, get_child_names


################################################################################
################################# SimInfo ########################################

mutable struct SimInfo
    @atomic algorithm::String
    @atomic t_start::Float64
    @atomic t_end::Float64
    @atomic dt::Float64 #last time step
    @atomic iter::Int64 #total iterations
    @atomic t::Float64 #simulation time
    @atomic τ::Float64 #wall-clock time
end

SimInfo() = SimInfo("", 0.0, 0.0, 0.0, 0, 0.0, 0.0)

function GUI.draw(info::SimInfo)

    # algorithm = @atomic info.algorithm
    # t_start = @atomic info.t_start
    # t_end = @atomic info.t_end
    # dt = @atomic info.dt
    # iter = @atomic info.iter
    # t = @atomic info.t
    # τ = @atomic info.τ

    # CImGui.Begin("Sim Info")
    #     CImGui.Text("Algorithm: " * algorithm)
    #     CImGui.Text("Step size: $dt")
    #     CImGui.Text("Iterations: $iter")
    #     CImGui.Text(@sprintf("Simulation time: %.3f s", t) * " [$t_start, $t_end]")
    #     CImGui.Text(@sprintf("Wall-clock time: %.3f s", τ))
    #     CImGui.Text(@sprintf("GUI framerate: %.3f ms/frame (%.1f FPS)",
    #                         1000 / unsafe_load(CImGui.GetIO().Framerate),
    #                         unsafe_load(CImGui.GetIO().Framerate)))
    # CImGui.End()

end

################################################################################
############################ SimControl ########################################

#the @atomic fields are declared as such because they are accessed concurrently
#both from the GUI thread (within the call to GUI.update!) and the simulation
#thread (within the main loop)
mutable struct SimControl
    @atomic running::Bool #to be checked on each loop iteration for termination
    @atomic paused::Bool #to pause or unpause the simulation
    @atomic pace::Float64 #to be set by the SimControl GUI
end

#no-argument constructor because @kwdef doesn't work with @atomic fields
SimControl() = SimControl(false, false, 1.0)

function GUI.draw!(control::SimControl)

    CImGui.Begin("Sim Control")

        mode_button("Pause", true, false, (@atomic control.paused); HSV_active = HSV_amber)
        CImGui.IsItemClicked() && (@atomic control.paused = true); CImGui.SameLine()
        mode_button("Resume", true, false, !(@atomic control.paused); HSV_active = HSV_green)
        CImGui.IsItemClicked() && (@atomic control.paused = false); CImGui.SameLine()
        dynamic_button("Abort", HSV_red)
        if CImGui.IsItemClicked()
            @atomic control.paused = false
            @atomic control.running = false
        end
        CImGui.SameLine()

        pace = @atomic control.pace
        @atomic control.pace = safe_input("Pace", pace, 0.1, 1.0, "%.3f")
        # control.pace = safe_slider("Pace", control.pace, 1e-2, 1e3, "%.3f", ImGuiSliderFlags_Logarithmic)
    CImGui.End()

end

################################################################################
################################ SimInput ######################################

struct SimInput{D <: InputDevice,  M <: InputMapping, S}
    device::D
    mapping::M #selected device-to-target mapping, used for dispatch on assign_input!
    system::S #target System for input assignment
    control::SimControl
    io_start::Base.Event
    sys_lock::ReentrantLock
end


################################################################################
############################### SimOutput ######################################

struct SimOutput{D <: OutputDevice, C <: Channel}
    device::D
    channel::C #channel to which Simulation's output will be put!
    control::SimControl
    io_start::Base.Event
end

#for buffered channels, isready returns 1 if there is at least one value in the
#channel. our channel is of length 1. if it contains 1 value and we try to put!
#another, the simulation loop will block. to avoid this, we should only put! if
#the channel !isready
@inline function put_no_wait!(channel::Channel{T}, data::T) where {T}
    (isopen(channel) && !isready(channel)) && put!(channel, data)
end

@inline function put_no_wait!(output::SimOutput, data)
    put_no_wait!(output.channel, data)
end


################################################################################
################################# SimGUI #######################################

struct SimGUI
    renderer::Renderer
    control::SimControl
    io_start::Base.Event
    sys_lock::ReentrantLock
end


################################################################################
############################### SimData #########################################

@kwdef struct SimData{Y}
    t::Float64
    y::Y #System's y
end

################################################################################
############################# Simulation #######################################

struct Simulation{S <: System, I <: ODEIntegrator, L <: SavedValues, Y}
    sys::S
    integrator::I
    log::L
    gui::SimGUI
    info::SimInfo
    control::SimControl
    io_start::Base.Event #to be waited on by IO devices and GUI before entering their update loops
    sys_lock::ReentrantLock #to be acquired before modifying the simulated System
    inputs::Vector{SimInput}
    outputs::Vector{SimOutput}

    function Simulation(
        sys::System;
        args_ode::Tuple = (), #externally supplied arguments to System's f_ode!
        args_step::Tuple = (), #externally supplied arguments to System's f_step!
        args_disc::Tuple = (), #externally supplied arguments to System's f_disc!
        sys_init!::Function = Systems.init!, #default System initialization function
        user_callback!::Function = user_callback!, #user-specified callback
        algorithm::OrdinaryDiffEqAlgorithm = RK4(),
        adaptive::Bool = false,
        dt::Real = 0.02, #continuous dynamics integration step
        Δt::Real = 0.02, #discrete dynamics execution period (do not set to Inf!)
        t_start::Real = 0.0,
        t_end::Real = 10.0,
        save_on::Bool = true,
        saveat::Union{Real, AbstractVector{<:Real}} = Float64[], #defers to save_everystep
        save_everystep::Bool = isempty(saveat),
        save_start::Bool = false, #initial System's outputs might not be up to date
        save_end::Bool = false,
        )

        @assert (t_end - t_start >= Δt) "Simulation timespan cannot be shorter "* "
                                        than the discrete dynamics update period"

        params = (sys = sys, sys_init! = sys_init!, user_callback! = user_callback!, Δt = Δt,
                  args_ode = args_ode, args_step = args_step, args_disc = args_disc)

        cb_cont = DiscreteCallback((u, t, integrator)->true, f_cb_cont!)
        cb_step = DiscreteCallback((u, t, integrator)->true, f_cb_step!)
        cb_disc = PeriodicCallback(f_cb_disc!, Δt)
        cb_user = DiscreteCallback((u, t, integrator)->true, f_cb_user!)

        log = SavedValues(Float64, typeof(sys.y))
        saveat = (saveat isa Real ? (t_start:saveat:t_end) : saveat)
        cb_save = SavingCallback(f_cb_save, log; saveat, save_everystep, save_start, save_end)

        if save_on
            cb_set = CallbackSet(cb_cont, cb_step, cb_disc, cb_user, cb_save)
        else
            cb_set = CallbackSet(cb_cont, cb_step, cb_disc, cb_user)
        end

        #the current System's x value is used as initial condition. a copy is
        #needed, otherwise it's just a reference and will get overwritten during
        #simulation. if the System has no continuous state, provide a dummy one
        x0 = (has_x(sys) ? copy(sys.x) : [0.0])
        problem = ODEProblem{true}(f_ode_wrapper!, x0, (t_start, t_end), params)
        integrator = init_integrator(problem, algorithm; save_on = false,
                                     callback = cb_set, adaptive, dt)

        #save_on = false because we are not interested in logging the plain
        #System's state vector; everything we need to know about the System
        #should be made available in its (immutable) output y, logged via
        #SavingCallback
        info = SimInfo()
        control = SimControl()
        io_start = Base.Event()
        sys_lock = ReentrantLock()

        f_draw = let info = info, control = control, sys = sys
            () -> GUI.draw!(info, control, sys)
        end

        #the GUI Renderer's refresh rate must be uncapped (no VSync), so that
        #calls to GUI.update!() return immediately without blocking and
        #therefore do not interfere with simulation stepping
        gui = SimGUI(Renderer(; label = "Simulation", sync = UInt8(0), f_draw),
                    control, io_start, sys_lock)

        new{typeof(sys), typeof(integrator), typeof(log), typeof(sys.y)}(
            sys, integrator, log, gui, info, control, io_start, sys_lock,
            SimInput[], SimOutput[])
    end

end

Base.getproperty(sim::Simulation, s::Symbol) = getproperty(sim, Val(s))

@generated function Base.getproperty(sim::Simulation, ::Val{S}) where {S}
    if S === :t
        return :(getproperty(getfield(sim, :sys), $(QuoteNode(S)))[])
    elseif S ∈ fieldnames(System)
        return :(getproperty(getfield(sim, :sys), $(QuoteNode(S))))
    else
        return :(getfield(sim, $(QuoteNode(S))))
    end
end

#function signature for a user callback function, called after every integration
#step. this function MUST NOT modify the System's ẋ, x or t
user_callback!(::System) = nothing


################################ I/O ###########################################

#attaches an input device to the Simulation, enabling it to safely modify the
#System's input
function attach!(sim::Simulation, device::InputDevice;
                    mapping::InputMapping = DefaultMapping())

    input = SimInput(device, mapping, sim.sys, sim.control, sim.io_start, sim.sys_lock)
    push!(sim.inputs, input)

end

#attaches an output device to the Simulation, linking it to a dedicated channel
#for simulation output data. on each step, the simulation loop will try to write
#the updated output data on each output channel. if any of the output devices
#still has not consumed the item from the previous step, the simulation will
#block. to avoid this, the simulation should only write to the channel when it
#has no data pending, that is, when !isready(channel). for this to work, the
#channel must be buffered. if the channel were unbuffered, !isready(channel)
#would be true whenever the output thread is NOT blocked waiting for new data.
#this may cause the sim thread to block when it shouldn't
function attach!(sim::Simulation, device::OutputDevice)
    channel = Channel{SimData{typeof(sim.sys.y)}}(1)
    output = SimOutput(device, channel, sim.control, sim.io_start)
    push!(sim.outputs, output)
end

function write_data!(sim::Simulation)
    data = SimData(sim.t[], sim.y)
    for output in sim.outputs
        put_no_wait!(output, data)
    end
end


############################ Stepping functions ################################

@inline has_x(sys::System) = !isnothing(sys.x)

#wrapper around the System's continuous dynamics function f_ode! it modifies the
#System's ẋ and y as a side effect
function f_ode_wrapper!(u̇, u, p, t)

    @unpack sys, args_ode = p

    #assign current integrator solution to System's continuous state
    has_x(sys) && (sys.x .= u)

    #same with time
    sys.t[] = t

    f_ode!(sys, args_ode...) #call continuous dynamics, updates sys.ẋ and sys.y

    has_x(sys) && (u̇ .= sys.ẋ) #update the integrator's derivative

end

#System update function, called on every integration step. brings the
#System's internal x and y up to date with the last integrator's solution step
function f_cb_cont!(integrator)

    @unpack t, u, p = integrator
    @unpack sys, args_ode = p

    #assign final integrator solution for this epoch to System's continuous state
    has_x(sys) && (sys.x .= u)

    #same with time
    sys.t[] = t

    #at this point sys.y and sys.ẋ hold the values from the last algorithm
    #evaluation of f_ode!, not the one corresponding to the updated x. with x
    #up to date, we can now compute the final sys.y and sys.ẋ for this epoch
    f_ode!(sys, args_ode...)

    u_modified!(integrator, false)

end

#DiscreteCallback function, called on every integration step. calls the System's
#own f_step!. modifications to x or s will not propagate to y until the next
#integration step
function f_cb_step!(integrator)

    @unpack u, p = integrator
    @unpack sys, args_step = p

    f_step!(sys, args_step...)

    #assign the (potentially) modified sys.x back to the integrator
    has_x(sys) && (u .= sys.x)

end

#PeriodicCallback function, calls the System's discrete dynamics update with the
#period Δt given to the Simulation constructor. modifications to x or s will not
#propagate to y until the next integration step
function f_cb_disc!(integrator)

    @unpack u, p = integrator
    @unpack sys, Δt, args_disc = p

    f_disc!(sys, Δt, args_disc...)

    #assign the (potentially) modified sys.x back to the integrator
    has_x(sys) && (u .= sys.x)

end

#DiscreteCallback function, calls the user-specified System I/O function after
#every integration step
function f_cb_user!(integrator)

    @unpack u, p = integrator
    @unpack sys, user_callback! = p

    user_callback!(sys)

    #assign the (potentially) modified sys.x back to the integrator
    has_x(sys) && (u .= sys.x)

end

#SavingCallback function, gets called at the end of each step after f_disc!
#and/or f_step!
f_cb_save(x, t, integrator) = deepcopy(integrator.p.sys.y)


####################### OrdinaryDiffEq extensions ##############################

OrdinaryDiffEq.step!(sim::Simulation, args...) = step!(sim.integrator, args...)

OrdinaryDiffEq.get_proposed_dt(sim::Simulation) = get_proposed_dt(sim.integrator)

OrdinaryDiffEq.add_tstop!(sim::Simulation, t) = add_tstop!(sim.integrator, t)

function OrdinaryDiffEq.reinit!(sim::Simulation, sys_init_args...; sys_init_kwargs...)

    @unpack integrator, log = sim
    @unpack p = integrator

    #initialize the System's x, u and s
    p.sys_init!(p.sys, sys_init_args...; sys_init_kwargs...)

    #initialize the ODEIntegrator with the System's initial x. ODEIntegrator's
    #reinit! calls f_ode_wrapper!, so the System's ẋ and y are updated in the
    #process, no need to do it explicitly
    if has_x(p.sys)
        OrdinaryDiffEq.reinit!(integrator, p.sys.x)
    else
        OrdinaryDiffEq.reinit!(integrator)
    end

    resize!(log.t, 1)
    resize!(log.saveval, 1)
    return nothing
end


################################# GUI ##########################################

function GUI.draw!(info::SimInfo, control::SimControl, sys::System)
    GUI.draw(info)
    GUI.draw!(control)
    GUI.draw!(sys)
end


################################################################################
################################## Loops #######################################

################################ SimInput ######################################

function start!(input::SimInput{D}) where {D}

    @unpack device, mapping, system, control, io_start, sys_lock = input

    @info("$D Interface: Starting on thread $(Threads.threadid())...")

    try

        IODevices.init!(device)
        wait(io_start)

        while true

            if !(@atomic control.running) || IODevices.should_close(device)
                @info("$D: Shutdown requested")
                break
            end

            IODevices.update_input!(device)
            lock(sys_lock) #ensure the target System is not currently being updated by the sim loop
                IODevices.assign_input!(system, device, mapping)
            unlock(sys_lock)

        end

    catch ex

        @error("$D: Error during execution: $ex")

    finally
        IODevices.shutdown!(device)
        @info("$D: Closed")
    end

end


################################ SimOutput #####################################

#the update rate for an output device is implicitly controlled by the simulation
#loop. the call to take! below will block until the simulation writes new data
function start!(output::SimOutput{D}) where {D}

    @unpack device, channel, control, io_start = output

    @info("$D: Starting on thread $(Threads.threadid())...")

    try

        IODevices.init!(device)
        wait(io_start)

        while true

            if !(@atomic control.running) || IODevices.should_close(device)
                @info("$D: Shutdown requested")
                break
            end

            output = take!(channel) #blocks until simulation writes new data
            IODevices.process_output!(device, output)

        end

    catch ex

        if ex isa InvalidStateException
            @info("$D: Channel closed")
        else
            @error("$D: Error during execution: $ex")
        end

    finally
        # close(channel)
        IODevices.shutdown!(device)
        @info("$D: Closed")
    end

end


################################## SimGUI ######################################

function start!(gui::SimGUI)

    @unpack renderer, control, io_start, sys_lock = gui

    @info("SimGUI: Starting on thread $(Threads.threadid())...")

    try

        #ensure VSync is disabled. otherwise, the call to GUI.update! will block
        #while holding the system lock, and therefore the sim loop will
        #not be able to step in the meantime
        @assert renderer.sync == 0
        GUI.init!(renderer)
        wait(io_start)

        while true

            if !(@atomic control.running) || GUI.should_close(renderer)
                @info("SimGUI: Shutdown requested")
                break
            end

            lock(sys_lock)
                GUI.update!(renderer)
            unlock(sys_lock)

        end

    catch ex

        @error("SimGUI: Error during execution: $ex")

    finally
        #abort simulation when GUI is closed
        @atomic control.paused = false #important!
        @atomic control.running = false
        renderer._initialized && GUI.shutdown!(renderer)
        @info("SimGUI: Closed")
    end

end


################################ Simulation ####################################

#compare the following:
# @time sleep(2)

# @time @async sleep(2)
# @time Threads.@spawn sleep(2)

# wait(@time @async sleep(2))
# wait(@time Threads.@spawn sleep(2))

# @time wait(@async sleep(2))
# @time wait(Threads.@spawn @sleep(2))

function start!(sim::Simulation)

    @unpack integrator, gui, info, control, io_start, sys_lock = sim

    t_start = sim.t[]
    t_end = integrator.sol.prob.tspan[2]
    algorithm = sim.integrator.alg |> typeof |> string

    # @atomic info.t_start = t_start
    # @atomic info.t_end = t_end
    # @atomic info.algorithm = algorithm

    try

        τ = let wall_time_ref = time()
            ()-> time() - wall_time_ref
        end

        isdone_err(sim)
        @info("Simulation: Starting on thread $(Threads.threadid())...")

        @atomic control.running = true
        @atomic control.paused = false
        notify(io_start)

        τ_last = τ()

        Δτ = @elapsed begin

            while sim.t[] < t_end

                #maybe yield here

                #lock(io_lock)


                #extract running, paused and pace from control to local variables, and write info fields

                #unlock(io_lock)

                # @atomic info.dt = integrator.dt
                # @atomic info.iter = integrator.iter
                # @atomic info.t = sim.t[]
                # @atomic info.τ = τ_last
                if !(@atomic control.running)
                    @info("Simulation: Aborted at t = $(sim.t[])")
                    break
                end

                # while (@atomic control.paused)
                #     τ_last = τ()
                #     # @atomic info.τ = τ_last
                # end

                if (@atomic control.paused)
                    τ_last = τ()
                    continue
                end

                τ_next = τ_last + get_proposed_dt(sim) / (@atomic control.pace)
                while τ_next > τ() end #busy wait (should do better, but it's not that easy)

                lock(sys_lock)
                    step!(sim)
                unlock(sys_lock)

                write_data!(sim)

                τ_last = τ_next

            end

        end

        @info("Simulation: Finished in $Δτ seconds")

    catch ex

        st = stacktrace(catch_backtrace())
        @error("Simulation: Terminated with $ex in $(st[1])")

    finally

        sim_cleanup!(sim)

    end

end

function sim_cleanup!(sim::Simulation)

    @unpack control, io_start = sim

    #if the simulation ran to conclusion, running will still be true. set it to
    #false to signal IO threads to shut down
    @atomic control.paused = false
    @atomic control.running = false

    #unblock any interfaces waiting for simulation to start in case we
    #exited with error and didn't get to notify them
    notify(io_start)

    #reset the event for the next sim execution
    reset(io_start)

    #unblock any output interfaces waiting for a take!
    write_data!(sim)

end


function isdone_err(sim::Simulation)
    isempty(sim.integrator.opts.tstops) &&
    @error("Simulation has hit its end time, call reinit! ",
            "or add further tstops using add_tstop!")
end


#apparently, if a task is launched from the main thread and it doesn't ever
#block, no other thread will get CPU time until it's done. threfore, we should
#never call start! directly from the main thread, because it will starve all IO
#threads. it must always be run from a Threads.@spawn'ed thread

function run!(sim::Simulation)

    @atomic sim.control.pace = Inf

    @sync begin
        for output in sim.outputs
            Threads.@spawn start!(output)
        end
        Threads.@spawn start!(sim)
    end

end

function run_interactive!(sim::Simulation; pace = 1.0)

    @atomic sim.control.pace = pace

    @sync begin
        for input in sim.inputs
            Threads.@spawn start!(input)
        end
        for output in sim.outputs
            Threads.@spawn start!(output)
        end
        Threads.@spawn start!(sim.gui)
        Threads.@spawn start!(sim)
    end

end


################################################################################
############################### TimeSeries ####################################

mutable struct TimeSeries{V, T <: AbstractVector{Float64}, D <: AbstractVector{V}}
    _t::T
    _data::D
    function TimeSeries(t::T, data::D) where {T <: AbstractVector{<:AbstractFloat}, D <: AbstractVector{V}} where {V}
        @assert length(t) == length(data)
        new{V, T, D}(t, data)
    end
end

TimeSeries(t::Real, data) = TimeSeries([Float64(t)], [data])

function TimeSeries(t::AbstractVector, M::Matrix)
    #each Matrix column interpreted as one Vector value
    TimeSeries(t, [M[:, i] for i in 1:size(M,2)])
end

Base.length(ts::TimeSeries) = length(ts._t)

function Base.getproperty(ts::TimeSeries, s::Symbol)
    t = getfield(ts, :_t)
    data = getfield(ts, :_data)
    if s === :_t
        return t
    elseif s === :_data
        return data
    else
        return TimeSeries(t, getproperty(StructArray(data), s))
    end
end

get_time(ts::TimeSeries) = getfield(ts, :_t)
get_data(ts::TimeSeries) = getfield(ts, :_data)

Base.getindex(ts::TimeSeries, i) = TimeSeries(ts._t[i], ts._data[i])

function Base.getindex(ts::TimeSeries{<:AbstractArray{T, N}}, time_ind, comp_ind::Vararg{Any, N}) where {T, N}

    t = ts._t[time_ind]
    data_voa = VectorOfArray(ts._data)[comp_ind..., time_ind]
    data = ndims(data_voa) == 1 ? data_voa : eachslice(data_voa; dims = ndims(data_voa))

    TimeSeries(t, data)

end

function Base.lastindex(ts::TimeSeries)
    lastindex(ts._t)
end
Base.view(ts::TimeSeries, i) = TimeSeries(view(ts._t, i), view(ts._data, i))

#for inspection
get_child_names(::T) where {T <: TimeSeries} = get_child_names(T)
get_child_names(::Type{<:TimeSeries{V}}) where {V} = fieldnames(V)

#could be rewritten as @generated to avoid allocation
function get_components(ts::TimeSeries{<:AbstractVector{T}}) where {T<:Real}
    (TimeSeries(ts._t, y) for y in ts._data |> StructArray |> StructArrays.components)
end

TimeSeries(sim::Simulation) = TimeSeries(sim.log.t, sim.log.saveval)


end #module