module Network

using Sockets
using UnPack
using GLFW
using JSON3

using ..IODevices

export UDPOutput, UDPInput
export XPCClient, XPCPosition


################################################################################
################################# UDInput ######################################

@kwdef mutable struct UDPInput{T <: IPAddr} <: InputDevice
    socket::UDPSocket = UDPSocket()
    address::T = IPv4("127.0.0.1") #IP address we'll be listening at
    port::Int = 49017 #port we'll be listening at
end

function IODevices.init!(input::UDPInput)
    input.socket = UDPSocket() #create a new socket on each initialization
    @unpack socket, address, port = input
    if !bind(socket, address, port; reuseaddr=true)
        @error( "Failed to bind socket to address $address, port $port")
    end
end

IODevices.shutdown!(input::UDPInput) = close(input.socket)
IODevices.data_type(::UDPInput) = Vector{UInt8}

function IODevices.get_data(input::UDPInput)
    data = recv(input.socket)
    return data
end


################################################################################
################################# UDPOutput ####################################

@kwdef mutable struct UDPOutput{T <: IPAddr} <: OutputDevice
    socket::UDPSocket = UDPSocket()
    address::T = IPv4("127.0.0.1") #IP address we'll be sending to
    port::Int = 49017 #port we'll be sending to
end

function IODevices.init!(output::UDPOutput)
    output.socket = UDPSocket() #get a new socket on each initialization
end

IODevices.shutdown!(output::UDPOutput) = close(output.socket)
IODevices.data_type(::UDPOutput) = Vector{UInt8}

function IODevices.handle_data(output::UDPOutput, data::Vector{UInt8})
    try
        # @info "Sending $(length(data)) bytes"
        !isempty(data) && send(output.socket, output.address, output.port, data)
    catch ex
        st = stacktrace(catch_backtrace())
        @warn("UDPOutput failed with $ex in $(st[1])")
    end
end


################################################################################
################################# XPCClient ####################################

@kwdef struct XPCPosition
    ϕ::Float64 = 0.0 #degrees
    λ::Float64 = 0.0 #degrees
    h::Float64 = 0.0 #meters
    ψ::Float32 = 0.0 #degrees
    θ::Float32 = 0.0 #degrees
    φ::Float32 = 0.0 #degrees
    aircraft::UInt8 = 0 #aircraft number
end

struct XPCClient{T <: IPAddr} <: OutputDevice
    udp::UDPOutput{T}
end

XPCClient(args...; kwargs...) = XPCClient(UDPOutput(args...; kwargs...))

#disable X-Plane physics
function IODevices.init!(xpc::XPCClient)
    IODevices.init!(xpc.udp)
    IODevices.handle_data(xpc.udp, dref_cmd(
        "sim/operation/override/override_planepath", 1))
end

IODevices.shutdown!(xpc::XPCClient) = IODevices.shutdown!(xpc.udp)
IODevices.data_type(::XPCClient) = XPCPosition

function IODevices.handle_data(xpc::XPCClient, data::XPCPosition)
    IODevices.handle_data(xpc.udp, pos_cmd(data))
end

############################ XPC Command Messages ##############################

#write a scalar or vector value to an arbitrary DREF
function dref_cmd(id::AbstractString, value::Union{Real, AbstractVector{<:Real}})

    #ascii() ensures ASCII data, codeunits returns a CodeUnits object, which
    #behaves similarly to a byte array. this is equivalent to b"text".
    #Vector{UInt8}(id) would also work
    buffer = IOBuffer()
    write(buffer,
        b"DREF\0",
        id |> length |> UInt8,
        id |> ascii |> codeunits,
        value |> length |> UInt8,
        Float32.(value))

    return take!(buffer)
end

#set aircraft position and attitude
function pos_cmd(pos::XPCPosition)

    @unpack ϕ, λ, h, ψ, θ, φ, aircraft = pos

    buffer = IOBuffer(sizehint = 64)
    write(buffer, b"POSI\0", aircraft, ϕ, λ, h, θ, φ, ψ, Float32(-998))

    return take!(buffer)

end

end #module