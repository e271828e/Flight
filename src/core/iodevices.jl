module IODevices

using StaticArrays
using UnPack
using Logging

export IODevice, InputDevice, OutputDevice, IOMapping


################################################################################
################################# IOMapping ####################################

abstract type IOMapping end

################################################################################
################################# IODevice #####################################

#T: data type produced or expected by the IODevice
abstract type IODevice{T} end

init!(::D) where {D<:IODevice} = nothing
shutdown!(::D) where {D<:IODevice} = nothing
should_close(::D) where {D<:IODevice} = false

#data type produced or expected by the IODevice
# function data_type(device::D) where {D <: IODevice}
#     MethodError(data_type, (device)) |> throw
# end

################################################################################
############################### InputDevice ####################################

abstract type InputDevice{T} <: IODevice{T} end

#returns a new instance of input data. may block
function get_data!(device::D) where {D<:InputDevice}
    MethodError(get_data!, (device, )) |> throw
end


################################################################################
############################## OutputDevice ####################################

abstract type OutputDevice{T} <: IODevice{T} end

#processes an instance of output data. may block
function handle_data!(device::D, data::Any) where {D<:OutputDevice}
    MethodError(handle_data!, (device, data)) |> throw
end


end