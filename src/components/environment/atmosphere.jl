module Atmosphere

using StaticArrays, StructArrays, ComponentArrays, LinearAlgebra, UnPack
using CImGui, CImGui.CSyntax, Printf

using Flight.Engine.Systems #?
using Flight.Engine.Plotting
using Flight.Engine.Utils
using Flight.Engine.GUI

using Flight.Physics.Attitude
using Flight.Physics.Geodesy
using Flight.Physics.Kinematics

export AbstractISAModel, TunableISA
export AbstractWindModel, TunableWind
export AbstractAtmosphere, SimpleAtmosphere

export SeaLevelConditions, ISAData, WindData, AtmosphericData, AirData
export get_velocity_vector, get_airflow_angles, get_wind_axes, get_stability_axes

### see ISO 2553

################################################################################
############################## ISA Model #######################################

#a System{<:AbstractISAModel} may have an output type of its own, as any other
#System. however, this output generally will not be an ISAData instance. the
#ISAData returned by a ISA System depends on the location specified in the
#query. instead, the output from an ISA System may hold quantities of interest
#related to its own internal state, if it has one due to it being a dynamic ISA
#implementation.

#AbstractISAModel subtypes: ConstantUniformISA (TunableISA), ConstantFieldISA,
#DynamicUniformISA, DynamicFieldISA.

abstract type AbstractISAModel <: Component end

const R = 287.05287 #gas constant for dry ISA
const γ = 1.40 #heat capacity ratio for dry ISA
const βs = 1.458e-6 #Sutherland's empirical constant for dynamic viscosity
const S = 110.4 #Sutherland's empirical constant for dynamic viscosity

const T_std = 288.15
const p_std = 101325.0
const ρ_std = p_std / (R * T_std)
const g_std = 9.80665

@inline density(p,T) = p/(R*T)
@inline speed_of_sound(T) = √(γ*R*T)
@inline dynamic_viscosity(T) = (βs * T^1.5) / (T + S)


############################# SeaLevelConditions ###############################

Base.@kwdef struct SeaLevelConditions
    p::Float64 = p_std
    T::Float64 = T_std
end

#when queried, any ISA System must provide the sea level atmospheric conditions
#at any given 2D location. these may be stationary or time-evolving.
function SeaLevelConditions(::T, ::Abstract2DLocation) where {T<:System{<:AbstractISAModel}}
    error("SeaLevelConditions constructor not implemented for $T")
end


############################### ISAData ########################################

struct ISAData
    p::Float64
    T::Float64
    ρ::Float64
    a::Float64
    μ::Float64
end

const ISA_layers = StructArray(
    β =      SVector{7,Float64}([-6.5e-3, 0, 1e-3, 2.8e-3, 0, -2.8e-3, -2e-3]),
    h_ceil = SVector{7,Float64}([11000, 20000, 32000, 47000, 51000, 71000, 84852]))

@inline ISA_temperature_law(h::Real, T_b, h_b, β)::Float64 = T_b + β * (h - h_b)

@inline function ISA_pressure_law(h::Real, g0, p_b, T_b, h_b, β)::Float64
    if β != 0.0
        p_b * (1 + β/T_b * (h - h_b)) ^ (-g0/(β*R))
    else
        p_b * exp(-g0/(R*T_b) * (h - h_b))
    end
end

#compute ISAData at a given geopotential altitude, using ISA_temperature_law and
#ISA_pressure_law to propagate the given sea level conditions upwards through
#the successive ISA_layers up to the requested altitude
@inline function ISAData(h_geo::HGeop, sl::SeaLevelConditions = SeaLevelConditions())

    h = Float64(h_geo)
    h_base = 0; T_base = sl.T; p_base = sl.p; g0 = g_std #g0 = sl.g

    for i in eachindex(ISA_layers)
        β, h_ceil = ISA_layers[i]
        if h < h_ceil
            T = ISA_temperature_law(h, T_base, h_base, β)
            p = ISA_pressure_law(h, g0, p_base, T_base, h_base, β)
            return ISAData(p, T, density(p, T), speed_of_sound(T), dynamic_viscosity(T) )
        end
        T_ceil = ISA_temperature_law(h_ceil, T_base, h_base, β)
        p_ceil = ISA_pressure_law(h_ceil, g0, p_base, T_base, h_base, β)
        h_base = h_ceil; T_base = T_ceil; p_base = p_ceil
    end

    throw(ArgumentError("Altitude out of bounds"))

end

# #top-down / recursive implementation
# @inline function get_tp(h::Real, T0::Real = T0_std, p0::Real = p0_std, g0::Real = g0_std)

#     h == 0 && return (T0, p0)
#     (h_b, β) = layer_parameters(h)
#     (T_b, p_b) = get_tp(h_b, T0, p0, g0) #get pt at the layer base
#     T = ISA_temperature_law(h, T_b, h_b, β)
#     p = ISA_pressure_law(h, g0, p_b, T_b, h_b, β)
#     return (T, p)
# end

@inline ISAData() = ISAData(HGeop(0))

@inline function ISAData(sys::System{<:AbstractISAModel}, loc::Geographic)

    h_geop = Altitude{Geopotential}(loc.h, loc.loc)
    sl = SeaLevelConditions(sys, loc.loc)
    ISAData(h_geop, sl)

end

############################ TunableISA ########################################

#a simple ISA model. it does not have a state and therefore cannot evolve on its
#own. but its input vector can be used to manually tune the SeaLevelConditions
#during simulation

struct TunableISA <: AbstractISAModel end #Constant, Uniform ISA

Base.@kwdef mutable struct UTunableISA #only allocates upon System instantiation
    T_sl::Float64 = T_std
    p_sl::Float64 = p_std
end

Systems.init(::SystemU, ::TunableISA) = UTunableISA()

function SeaLevelConditions(s::System{<:TunableISA}, ::Abstract2DLocation)
    SeaLevelConditions(T = s.u.T_sl, p = s.u.p_sl)
    #alternative using actual local SL gravity:
    # return (T = s.u.T_sl, p = s.u.p_sl, g = gravity(Geographic(loc, HOrth(0.0))))
end

################################################################################
################################ WindModel #####################################

abstract type AbstractWindModel <: Component end

Base.@kwdef struct WindData
    v_ew_n::SVector{3,Float64} = zeros(SVector{3})
end

function WindData(::T, ::Abstract3DPosition) where {T<:System{<:AbstractWindModel}}
    error("WindData constructor not implemented for $T")
end

############################### TunableWind ####################################

struct TunableWind <: AbstractWindModel end

Base.@kwdef mutable struct USimpleWind
    v_ew_n::MVector{3,Float64} = zeros(MVector{3}) #MVector allows changing single components
end

Systems.init(::SystemU, ::TunableWind) = USimpleWind()

function WindData(wind::System{<:TunableWind}, ::Abstract3DPosition)
    wind.u.v_ew_n |> SVector{3,Float64} |> WindData
end

################################################################################
############################# Atmospheric Model ################################

abstract type AbstractAtmosphere <: Component end

Base.@kwdef struct SimpleAtmosphere{S <: AbstractISAModel, W <: AbstractWindModel} <: AbstractAtmosphere
    ISA::S = TunableISA()
    wind::W = TunableWind()
end

Base.@kwdef struct AtmosphericData
    ISA::ISAData = ISAData()
    wind::WindData = WindData()
end

function AtmosphericData(atm::System{<:SimpleAtmosphere}, loc::Geographic)
    AtmosphericData( ISAData(atm.ISA, loc), WindData(atm.wind, loc))
end

################################################################################
############################### AirData ########################################

@inline SI2kts(v::Real) = 1.94384v

#compute aerodynamic velocity vector from TAS and airflow angles
@inline function get_velocity_vector(TAS::Real, α::Real, β::Real)
    cos_β = cos(β)
    return TAS * SVector(cos(α) * cos_β, sin(β), sin(α) * cos_β)
end

#compute airflow angles at frame c from the c-frame aerodynamic velocity
@inline function get_airflow_angles(v_wOc_c::AbstractVector{<:Real})::Tuple{Float64, Float64}
    α = atan(v_wOc_c[3], v_wOc_c[1])
    β = atan(v_wOc_c[2], √(v_wOc_c[1]^2 + v_wOc_c[3]^2))
    return (α, β)
end

@inline function get_wind_axes(v_wOc_c::AbstractVector{<:Real})
    α, β = get_airflow_angles(v_wOc_c)
    get_wind_axes(α, β)
end

@inline function get_wind_axes(α::Real, β::Real)
    q_bw = Ry(-α) ∘ Rz(β)
    return q_bw
end

@inline function get_stability_axes(α::Real)
    q_bs = Ry(-α)
    return q_bs
end

struct AirData
    v_ew_n::SVector{3,Float64} #wind velocity, NED axes
    v_ew_b::SVector{3,Float64} #wind velocity, vehicle axes
    v_eOb_b::SVector{3,Float64} #vehicle velocity vector, vehicle axes
    v_wOb_b::SVector{3,Float64} #vehicle aerodynamic velocity, vehicle axes
    α_b::Float64 #vehicle frame AoA
    β_b::Float64 #vehicle frame AoS
    T::Float64 #static temperature
    p::Float64 #static pressure
    ρ::Float64 #density
    a::Float64 #speed of sound
    μ::Float64 #dynamic viscosity
    M::Float64 #Mach number
    Tt::Float64 #total temperature
    pt::Float64 #total pressure
    Δp::Float64 #impact pressure
    q::Float64 #dynamic pressure
    TAS::Float64 #true airspeed
    EAS::Float64 #equivalent airspeed
    CAS::Float64 #calibrated airspeed
end

AirData() = AirData(KinematicData(), AtmosphericData())

function AirData(kin::KinematicData, atm_data::AtmosphericData)

    v_eOb_b = kin.v_eOb_b
    v_ew_n = atm_data.wind.v_ew_n
    v_ew_b = kin.q_nb'(v_ew_n)
    v_wOb_b = v_eOb_b - v_ew_b
    α_b, β_b = get_airflow_angles(v_wOb_b)

    @unpack T, p, ρ, a, μ = atm_data.ISA
    TAS = norm(v_wOb_b)
    M = TAS / a
    Tt = T * (1 + (γ - 1)/2 * M^2)
    pt = p * (Tt/T)^(γ/(γ-1))
    Δp = pt - p
    q = 1/2 * ρ * TAS^2

    EAS = TAS * √(ρ / ρ_std)
    CAS = √(2γ/(γ-1) * p_std/ρ_std * ( (1 + q/p_std)^((γ-1)/γ) - 1) )

    AirData(v_ew_n, v_ew_b, v_eOb_b, v_wOb_b, α_b, β_b, T, p, ρ, a, μ, M, Tt, pt, Δp, q, TAS, EAS, CAS)

end

function AirData(kin_data::KinematicData, atm_sys::System{<:AbstractAtmosphere})

    pos = Geographic(kin_data.n_e, kin_data.h_o)

    #query the atmospheric System for the atmospheric data at our position
    atm_data = AtmosphericData(atm_sys, pos)
    AirData(kin_data, atm_data)
end

################################## Plotting ####################################

function Plotting.make_plots(th::TimeHistory{<:AirData}; kwargs...)

    pd = OrderedDict{Symbol, Plots.Plot}()

    pd[:v_ew_n] = plot(th.v_ew_n;
        plot_title = "Velocity (Wind / ECEF) [NED Axes]",
        label = ["North" "East" "Down"],
        ylabel = [L"$v_{ew}^{N} \ (m/s)$" L"$v_{ew}^{E} \ (m/s)$" L"$v_{ew}^{D} \ (m/s)$"],
        th_split = :h,
        kwargs...)

    pd[:v_ew_b] = plot(th.v_ew_b;
        plot_title = "Velocity (Wind / ECEF) [Vehicle Axes]",
        ylabel = [L"$v_{ew}^{x_b} \ (m/s)$" L"$v_{ew}^{y_b} \ (m/s)$" L"$v_{ew}^{z_b} \ (m/s)$"],
        th_split = :h,
        kwargs...)

    pd[:v_eOb_b] = plot(th.v_eOb_b;
        plot_title = "Velocity (Vehicle / ECEF) [Vehicle Axes]",
        ylabel = [L"$v_{eb}^{x_b} \ (m/s)$" L"$v_{eb}^{y_b} \ (m/s)$" L"$v_{eb}^{z_b} \ (m/s)$"],
        th_split = :h,
        kwargs...)

    pd[:v_wOb_b] = plot(th.v_wOb_b;
        plot_title = "Velocity (Vehicle / Wind) [Vehicle Axes]",
        ylabel = [L"$v_{eb}^{x_b} \ (m/s)$" L"$v_{eb}^{y_b} \ (m/s)$" L"$v_{eb}^{z_b} \ (m/s)$"],
        th_split = :h,
        kwargs...)

        subplot_α = plot(th.α_b;
            title = "Angle of Attack", ylabel = L"$α_b \ (rad)$",
            label = "", kwargs...)

        subplot_β = plot(th.β_b;
            title = "Angle of Sideslip", ylabel = L"$β_b \ (rad)$",
            label = "", kwargs...)

    pd[:α_β] = plot(subplot_α, subplot_β;
        plot_title = "Airflow Angles [Vehicle Axes]",
        layout = (1,2),
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

        subplot_a = plot(th.a;
            title = "Speed of Sound", ylabel = L"$a \ (m/s)$",
            label = "", kwargs...)

        subplot_ρ = plot(th.ρ;
            title = "Density", ylabel = L"$\rho \ (kg/m^3)$",
            label = "", kwargs...)

        subplot_μ = plot(th.μ;
            title = "Dynamic Viscosity", ylabel = L"$\mu \ (Pa \ s)$",
            label = "", kwargs...)

    pd[:ρ_a] = plot(subplot_ρ, subplot_a, subplot_μ;
        plot_title = "Freestream Properties",
        layout = (1,3),
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs


        subplot_T = plot(
            TimeHistory(th._t, hcat(th.T._data, th.Tt._data)' |> collect);
            title = "Temperature",
            label = ["Static"  "Total"],
            ylabel = L"$T \ (K)$",
            th_split = :none, kwargs...)

        subplot_p = plot(
            TimeHistory(th._t, 1e-3*hcat(th.p._data, th.pt._data)' |> collect);
            title = "Pressure",
            label = ["Static"  "Total"],
            ylabel = L"$p \ (kPa)$",
            th_split = :none, kwargs...)

    pd[:T_p] = plot(subplot_T, subplot_p;
        plot_title = "Freestream Properties",
        layout = (1,2),
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

        subplot_airspeed = plot(
            TimeHistory(th._t, hcat(th.TAS._data, th.EAS._data, th.CAS._data)' |> collect);
            title = "Airspeed",
            label = ["True" "Equivalent" "Calibrated"],
            ylabel = L"$v \ (m/s)$",
            th_split = :none, kwargs...)

        subplot_Mach = plot(th.M;
            title = "Mach", ylabel = L"M",
            label = "", kwargs...)

        subplot_q = plot(th._t, th.q._data/1000;
            title = "Dynamic Pressure", ylabel = L"$q \ (kPa)$",
            label = "", kwargs...)

    l3 = @layout [a{0.5w} [b; c{0.5h}]]

    pd[:airspeed_M_q] = plot(
        subplot_airspeed, subplot_Mach, subplot_q;
        layout = l3,
        plot_title = "Freestream Properties",
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

    return pd

end

################################################################################
################################# GUI ##########################################

function GUI.draw!(air::AirData)

    @unpack v_ew_n, v_wOb_b, T, p, ρ, a, μ, M, Tt, pt, Δp, q, TAS, EAS, CAS = air

    CImGui.Begin("Air Data")

    if CImGui.TreeNode("Wind")

        CImGui.Text(@sprintf("[North]: %.3f m/s", v_ew_n[1]))
        CImGui.Text(@sprintf("[East]: %.3f m/s", v_ew_n[2]))
        CImGui.Text(@sprintf("[Down]: %.3f m/s", v_ew_n[3]))

        CImGui.TreePop()
    end

    if CImGui.TreeNode("Velocity")

        CImGui.Text(@sprintf("[X-Body]: %.3f m/s", v_wOb_b[1]))
        CImGui.Text(@sprintf("[Y-Body]: %.3f m/s", v_wOb_b[2]))
        CImGui.Text(@sprintf("[Z-Body]: %.3f m/s", v_wOb_b[3]))

        CImGui.TreePop()
    end

    if CImGui.TreeNode("Airspeed")

        CImGui.Text(@sprintf("CAS: %.3f kts", SI2kts(CAS)))
        CImGui.Text(@sprintf("EAS: %.3f kts", SI2kts(EAS)))
        CImGui.Text(@sprintf("TAS: %.3f kts", SI2kts(TAS)))

        CImGui.TreePop()
    end

    if CImGui.TreeNode("Freestream Properties")

        CImGui.Text(@sprintf("Static Temperature: %.3f K", T))
        CImGui.Text(@sprintf("Total Temperature: %.3f K", Tt))
        CImGui.Text(@sprintf("Static Pressure: %.3f Pa", p))
        CImGui.Text(@sprintf("Total Pressure: %.3f Pa", pt))
        CImGui.Text(@sprintf("Impact Pressure: %.3f Pa", Δp))
        CImGui.Text(@sprintf("Dynamic Pressure: %.3f Pa", q))
        CImGui.Text(@sprintf("Density: %.3f kg/m3", ρ))
        CImGui.Text(@sprintf("Speed of Sound: %.3f m/s", a))
        CImGui.Text(@sprintf("Mach: %.3f", M))

        CImGui.TreePop()
    end

    CImGui.End()

end


end