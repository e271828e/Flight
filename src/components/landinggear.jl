module LandingGear

using StaticArrays, ComponentArrays, LinearAlgebra, UnPack

using Flight.FlightCore
using Flight.FlightCore.Utils

using Flight.FlightPhysics

using ..Control.Continuous: PIVector, PIVectorY

export LandingGearUnit, Strut, Contact, SimpleDamper
export NoSteering, NoBraking, FreeSteering, DirectSteering, DirectBraking

#basis elements, for convenience
const e1 = SVector{3,Float64}(1,0,0)
const e3 = SVector{3,Float64}(0,0,1)


################################################################################
################################# Steering #####################################

abstract type AbstractSteering <: SystemDefinition end


################################ NoSteering ####################################

struct NoSteering <: AbstractSteering end

get_steering_angle(::System{NoSteering}, args...) = 0.0

################################ FreeSteering ##################################

@kwdef struct FreeSteering <: AbstractSteering end

function get_steering_angle(::System{FreeSteering}, v_eOc_rb_s::SVector{3, Float64})
    atan(v_eOc_rb_s[2], v_eOc_rb_s[1])
end

############################### DirectSteering #################################

@kwdef struct DirectSteering <: AbstractSteering
    ψ_max::Float64 = π/6
end

@kwdef struct DirectSteeringY
    ψ::Float64 = 0.0
end
#the contents of u must be mutable
Systems.U(::DirectSteering) = Ref(Ranged(0.0, -1., 1.))
Systems.Y(::DirectSteering) = DirectSteeringY() #steering angle

function Systems.f_ode!(sys::System{DirectSteering})
    sys.y = DirectSteeringY(Float64(sys.u[]) * sys.constants.ψ_max)
end

get_steering_angle(sys::System{DirectSteering}, args...) = sys.y.ψ

function GUI.draw(sys::System{DirectSteering})

    CImGui.Text("Steering Input: $(Float64(sys.u[]))")
    CImGui.Text("Steering Angle: $(rad2deg(sys.y.ψ)) deg")

end


################################################################################
################################# Braking ######################################

abstract type AbstractBraking <: SystemDefinition end


############################### NoBraking ######################################

struct NoBraking <: AbstractBraking end

get_braking_factor(::System{NoBraking}) = 0.0


############################# DirectBraking ####################################

@kwdef struct DirectBraking <: AbstractBraking
   η_br::Float64 = 1.0 #braking efficiency
end

@kwdef struct DirectBrakingY
   κ_br::Float64 = 0.0 #braking coefficient
end

Systems.U(::DirectBraking) = Ref(Ranged(0.0, 0., 1.))
Systems.Y(::DirectBraking) = DirectBrakingY()

function Systems.f_ode!(sys::System{DirectBraking})
    sys.y = DirectBrakingY(Float64(sys.u[]) * sys.constants.η_br)
end

get_braking_factor(sys::System{DirectBraking}) = sys.y.κ_br

function GUI.draw(sys::System{DirectBraking})

    CImGui.Text("Braking Input: $(Float64(sys.u[]))")
    CImGui.Text("Braking Coefficient: $(sys.y.κ_br)")

end

################################################################################
################################## Strut #######################################

################################### Damper #####################################

abstract type AbstractDamper end #not a System!

get_force(args...) = throw(MethodError(get_force, args))

@kwdef struct SimpleDamper <: AbstractDamper
    k_s::Float64 = 25000 #spring constant
    k_d_ext::Float64 = 1000 #extension damping coefficient
    k_d_cmp::Float64 = 1000 #compression damping coefficient
    F_max::Float64 = 50000 #maximum allowable damper force
end

#Force exerted by the damper along zs. The elongation ξ is positive along z_s.
# When the damper force is positive (weight on wheel), it pushes the piston rod
#assembly downwards along the positive z_s direction. When it is negative, it
#pulls the piston rod upwards along the negative z_s axis
function get_force(c::SimpleDamper, ξ::Real, ξ_dot::Real)
    k_d = (ξ_dot > 0 ? c.k_d_ext : c.k_d_cmp)
    F = -(c.k_s * ξ + k_d * ξ_dot)
    if abs(F) > c.F_max
        # println("Maximum allowable damper force exceeded, looks like a ground crash. Press Enter to abort...")
        # readline()
        # error("Ground Crash")
    end
    # @assert abs(F) < c.F_max "Maximum allowable damper force exceeded, looks like a ground crash."
    return F
end

########################### FrictionCoefficients ###############################

struct FrictionCoefficients
    μ_s::Float64 #static friction coefficient
    μ_d::Float64 #dynamic friction coefficient (μ_d < μ_s)
    v_s::Float64 #static friction upper velocity threshold
    v_d::Float64 #dynamic friction lower velocity threshold (v_d > v_s)

    function FrictionCoefficients(; μ_s = 0, μ_d = 0, v_s = 0, v_d = 1)
        @assert μ_s >= μ_d
        @assert v_s < v_d
        new(μ_s, μ_d, v_s, v_d)
    end
end

function get_μ(fr::FrictionCoefficients, v::Real)
    @unpack v_s, v_d, μ_s, μ_d = fr
    κ_sd = clamp((norm(v) - v_s) / (v_d - v_s), 0, 1)
    return κ_sd * μ_d + (1 - κ_sd) * μ_s
end

abstract type RollingOrSkidding end
struct Rolling <: RollingOrSkidding end
struct Skidding <: RollingOrSkidding end

FrictionCoefficients(::Rolling, ::SurfaceType) =
    FrictionCoefficients(μ_s = 0.03, μ_d = 0.02, v_s = 0.005, v_d = 0.01)

function FrictionCoefficients(::Skidding, srf::SurfaceType)
    if srf == DryTarmac
        FrictionCoefficients( μ_s = 0.75, μ_d = 0.25, v_s = 0.005, v_d = 0.01)
    elseif srf == WetTarmac
        FrictionCoefficients(μ_s = 0.25, μ_d = 0.15, v_s = 0.005, v_d = 0.01)
    elseif srf == IcyTarmac
        FrictionCoefficients(μ_s = 0.075, μ_d = 0.025, v_s = 0.005, v_d = 0.01)
    else
        error("Unrecognized surface type")
    end
end


################################## Strut #######################################

@kwdef struct GroundCrash <: Exception
    msg::String = ""
end

@kwdef struct Strut{D<:AbstractDamper} <: SystemDefinition
    t_bs::FrameTransform = FrameTransform() #vehicle to strut frame transform
    l_0::Float64 = 0.0 #strut natural length from airframe attachment point to wheel endpoint
    damper::D = SimpleDamper()
end

@kwdef struct StrutY #defaults should be consistent with wow = 0
    Δh::Float64 = 0.0 #height above ground
    wow::Bool = false #weight-on-wheel flag
    ξ::Float64 = 0.0 #damper elongation
    ξ_dot::Float64 = 0.0 #damper elongation rate
    F_dmp_zs::Float64 = 0.0 #axial damper force
    ψ_sw::Float64 = 0.0 #steering angle
    α_ts::Float64 = 0.0 #angle from terrain normal to strut axis
    t_sc::FrameTransform = FrameTransform() #strut to contact frame transform
    t_bc::FrameTransform = FrameTransform() #body to contact frame transform
    v_eOc_xy::SVector{2,Float64} = zeros(SVector{2}) #contact point velocity
    trn_data::TerrainData = TerrainData()
end

Systems.Y(::Strut) = StrutY()

function Systems.f_ode!(sys::System{<:Strut},
                        steering::System{<:AbstractSteering},
                        terrain::AbstractTerrain,
                        kin::KinData)

    @unpack t_bs, l_0, damper = sys.constants
    @unpack q_eb, q_nb, q_en, n_e, h_e, r_eOb_e, v_eOb_b, ω_eb_b = kin

    q_bs = t_bs.q #body frame to strut frame rotation
    r_ObOs_b = t_bs.r #strut frame origin

    #do we have contact
    q_es = q_eb ∘ q_bs
    ks_e = q_es(e3)
    r_ObOs_e = q_eb(r_ObOs_b)
    r_OsOw0_e = l_0 * ks_e
    r_eOw0_e = r_eOb_e + r_ObOs_e + r_OsOw0_e
    Ow0 = r_eOw0_e |> Cartesian |> Geographic
    h_Ow0 = HEllip(Ow0)

    loc_Ot = NVector(Ow0)
    trn_data = TerrainData(terrain, loc_Ot)
    h_Ot = HEllip(trn_data)

    Δh = h_Ow0 - h_Ot
    wow = Δh <= 0

    if !wow #no contact
        sys.y = StrutY(; Δh, wow) #everything else set to default
        return
    end

    Ot = Geographic(loc_Ot, h_Ot)
    r_eOt_e = Cartesian(Ot)[:]

    r_eOs_e = r_eOb_e + r_ObOs_e
    r_OsOt_e = r_eOt_e - r_eOs_e

    ut_n = trn_data.normal
    ut_e = q_en(ut_n)
    ut_ks = ut_e ⋅ ks_e #cosine of angle between strut and terrain normal
    l = (ut_e ⋅ r_OsOt_e) / ut_ks
    α_ts = acos(max(min(ut_ks, 1), -1))

    #if we are here, it means that Δh < 0, so in theory we should have l < l_0.
    #however due to numerical error we might get a small ξ > 0
    ξ = min(0.0, l - l_0)

    #contact frame origin
    r_OsOc_s = e3 * (l_0 + ξ)
    r_OsOc_b = q_bs(r_OsOc_s)
    r_ObOc_b = r_OsOc_b + r_ObOs_b

    #contact frame origin velocity due to rigid body motion, strut frame
    v_eOc_rb_b = v_eOb_b + ω_eb_b × r_ObOc_b
    v_eOc_rb_s = q_bs'(v_eOc_rb_b)

    #wheel frame axes
    ψ_sw = get_steering_angle(steering, v_eOc_rb_s)
    q_sw = Rz(ψ_sw) #rotate strut axes to get wheel axes
    q_ns = q_nb ∘ q_bs
    q_nw = q_ns ∘ q_sw #NED to contact axes rotation

    #contact frame axes
    kc_n = trn_data.normal #NED components of contact z-axis
    iw_n = q_nw(e1) #NED components of wheel x-axis
    iw_n_trn = iw_n - (iw_n ⋅ kc_n) * kc_n #projection of iw_n onto the terrain tangent plane
    ic_n = normalize(iw_n_trn) #NED components of contact x-axis
    jc_n = kc_n × ic_n #NED components of contact y-axis
    R_nc = RMatrix(SMatrix{3,3}([ic_n jc_n kc_n]), normalization = false)
    q_sc = q_ns' ∘ R_nc
    q_bc = q_bs ∘ q_sc

    #construct contact frame transforms
    t_sc = FrameTransform(r_OsOc_s, q_sc)
    t_bc = FrameTransform(r_ObOc_b, q_bc)

    #contact frame origin velocity due to rigid body motion, contact frame
    v_eOc_rb_c = q_bc'(v_eOc_rb_b)

    #compute the damper elongation rate required to cancel the rigid body
    #contribution to the contact point velocity along the contact frame z axis
    q_sc = q_bs' ∘ q_bc
    ks_c = q_sc'(e3)
    ξ_dot = -v_eOc_rb_c[3] / ks_c[3]

    #force exerted by the damper along the strut frame's z axis
    F_dmp_zs = get_force(damper, ξ, ξ_dot)

    #total contact point velocity, contact frame. its z-component must have been
    #cancelled out by the computed damper elongation rate
    v_eOc_dmp_c = ks_c * ξ_dot #contact point velocity due to elongation rate
    v_eOc_c = v_eOc_rb_c + v_eOc_dmp_c
    @assert abs(v_eOc_c[3]) < 1e-8

    #extract in-plane components
    v_eOc_xy = v_eOc_c[SVector(1,2)]

    sys.y = StrutY(; Δh, wow, ξ, ξ_dot, F_dmp_zs, ψ_sw, α_ts, t_sc, t_bc, v_eOc_xy, trn_data)

end

#this will be called after f_cb_step, so wow will have the final value for the
#last integration step
function Systems.f_step!(sys::System{<:Strut})

    #sanity checks for crash detection
    @unpack wow, α_ts, ξ_dot = sys.y

    #we should not be hitting the ground at an angle larger than some threshold
    (wow && rad2deg(α_ts) > 60) && throw(GroundCrash(
        "Terrain normal to strut angle α_ts = $(rad2deg(α_ts)) deg " *
        "at t = $(sys.t[]) s"))

    #damper compression rate should not exceed some threshold
    (-ξ_dot > 10) && throw(GroundCrash(
        "Damper compression rate ξ_dot = $(-sys.y.ξ_dot) m/s " *
        "at t = $(sys.t[]) s"))

    return nothing

end


################################## Plots #######################################

function Plotting.make_plots(ts::TimeSeries{<:StrutY}; kwargs...)

    pd = OrderedDict{Symbol, Any}()

    subplot_ξ = plot(ts.ξ;
        title = "Elongation", ylabel = L"$\xi \ (m)$",
        label = "", kwargs...)

    subplot_ξ_dot = plot(ts.ξ_dot;
        title = "Elongation Rate", ylabel = L"$\dot{\xi} \ (m/s)$",
        label = "", kwargs...)

    subplot_F = plot(ts.F_dmp_zs;
        title = "Force", ylabel = L"$F \ (N)$",
        label = "", kwargs...)

    pd[:dmp] = plot(subplot_ξ, subplot_ξ_dot, subplot_F;
        plot_title = "Damper",
        layout = (1,3), link = :none,
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

    return pd

end


#################################### GUI #######################################

function GUI.draw(sys::System{<:Strut}, window_label::String = "Strut")

    @unpack Δh, wow, ξ, ξ_dot, F_dmp_zs, ψ_sw, v_eOc_xy, trn_data = sys.y

        CImGui.Text(@sprintf("Height Above Ground: %.7f m", Δh))
        CImGui.Text("Weight on Wheel: $wow")
        CImGui.Text(@sprintf("Damper Elongation: %.7f m", ξ))
        CImGui.Text(@sprintf("Damper Elongation Rate: %.7f m/s", ξ_dot))
        CImGui.Text(@sprintf("Axial Damper Force: %.7f N", F_dmp_zs))
        CImGui.Text(@sprintf("Wheel Steering Angle: %.7f deg", rad2deg(ψ_sw)))
        GUI.draw(v_eOc_xy, "Contact Point Velocity (Oc / ECEF) [Contact]", "m/s")

        if CImGui.TreeNode("Terrain Data")

            @unpack location, altitude, normal, surface = trn_data
            @unpack ϕ, λ = LatLon(location)
            CImGui.Text(@sprintf("Latitude: %.7f deg", rad2deg(ϕ)))
            CImGui.Text(@sprintf("Longitude: %.7f deg", rad2deg(λ)))
            CImGui.Text(@sprintf("Altitude (Orthometric): %.7f m", Float64(altitude)))
            CImGui.Text("Surface Type: $surface")
            GUI.draw(normal, "Surface Normal [NED]")

            CImGui.TreePop()
        end

end

################################################################################
################################### Contact ####################################

@kwdef struct Contact <: SystemDefinition
    frc::PIVector{2} = PIVector{2}() #friction constraint compensator
end

@kwdef struct ContactY #defaults should be consistent with wow = 0
    μ_roll::Float64 = 0.0 #rolling friction coefficient
    μ_skid::Float64 = 0.0 #skidding friction coefficient
    κ_br::Float64 = 0.0 #braking factor
    ψ_cv::Float64 = 0.0 #tire slip angle
    μ_max::SVector{2,Float64} = zeros(SVector{2}) #maximum friction coefficient
    μ_eff::SVector{2,Float64} = zeros(SVector{2}) #effective friction coefficient
    f_c::SVector{3,Float64} = zeros(SVector{3}) #normalized contact force
    F_c::SVector{3,Float64} = zeros(SVector{3}) #contact force
    wr_b::Wrench = Wrench() #resulting Wrench on the vehicle frame
    frc::PIVectorY{2} = PIVectorY{2}() #contact friction regulator
end

Systems.Y(::Contact) = ContactY()

function Systems.init!(sys::System{Contact})
    #set up friction constraint compensator
    frc = sys.frc
    frc.u.k_p .= 5.0
    frc.u.k_i .= 400.0
    frc.u.k_l .= 0.2
    frc.u.bound_lo .= -1
    frc.u.bound_hi .= 1
end

function Systems.f_ode!(sys::System{Contact},
                        strut::System{<:Strut},
                        braking::System{<:AbstractBraking})

    @unpack wow, F_dmp_zs, t_sc, t_bc, v_eOc_xy, trn_data = strut.y

    frc = sys.frc
    frc.u.input .= -v_eOc_xy #if !wow, v_eOc_xy = [0,0]
    f_ode!(frc)

    if !wow
        sys.y = ContactY(; frc = frc.y) #everything else default
        return
    end

    norm_v = norm(v_eOc_xy)

    μ_roll = get_μ(FrictionCoefficients(Rolling(), trn_data.surface), norm_v)
    μ_skid = get_μ(FrictionCoefficients(Skidding(), trn_data.surface), norm_v)

    #longitudinal friction coefficient
    κ_br = get_braking_factor(braking)
    μ_x = μ_roll + (μ_skid - μ_roll) * κ_br

    #tire slip angle
    if norm_v < 1e-3 #prevents chattering in μ_y for near-zero contact velocity
        ψ_cv = π/2 #pure sideslip
    else
        ψ_cv = atan(v_eOc_xy[2], v_eOc_xy[1])
    end

    #lateral friction coefficient
    ψ_skid = deg2rad(10)
    ψ_abs = abs(ψ_cv)

    if ψ_abs < ψ_skid
        μ_y = μ_skid * ψ_abs / ψ_skid
    elseif ψ_abs > π - ψ_skid
        μ_y = μ_skid * (1 - (ψ_skid + ψ_abs - π)/ ψ_skid)
    else
        μ_y = μ_skid
    end

    μ_max = @SVector [μ_x, μ_y]
    μ_max *= min(1, μ_skid / norm(μ_max)) #scale μ_max so norm(μ_max) does not exceed μ_skid

    #scale μ_max with the feedback from the friction constraint compensator
    μ_eff = frc.y.output .* μ_max

    #normalized contact force projected on the contact frame
    f_c = SVector{3,Float64}(μ_eff[1], μ_eff[2], -1)
    f_s = t_sc.q(f_c) #project normalized force onto the strut frame
    # @assert f_s[3] < 0

    #the value of the ground's normal force must be such that its projection
    #along the strut cancels the damper's force
    N = -F_dmp_zs / f_s[3]
    N = max(0, N) #it must not be negative (might happen with large ξ_dot >0)
    F_c = f_c * N

    wr_c = Wrench(F = F_c)
    wr_b = t_bc(wr_c)

    sys.y = ContactY(; μ_roll, μ_skid, κ_br, ψ_cv, μ_max, μ_eff, f_c, F_c, wr_b, frc = frc.y)

end

function Systems.f_step!(contact::System{<:Contact}, strut::System{<:Strut})

    contact.frc.u.reset .= !strut.y.wow #if !wow, reset friction regulator
    f_step!(contact.frc)

end


################################ Plotting ######################################


function Plotting.make_plots(ts::TimeSeries{<:ContactY}; kwargs...)

    pd = OrderedDict{Symbol, Any}()

    (μ_max_x, μ_max_y) = get_components(ts.μ_max)
    (μ_eff_x, μ_eff_y) = get_components(ts.μ_eff)

    subplot_μ_roll = plot(ts.μ_roll; title = "Rolling Friction Coefficient",
        ylabel = L"$\mu_{roll}$", label = "", kwargs...)
    subplot_μ_skid = plot(ts.μ_skid; title = "Skidding Friction Coefficient",
        ylabel = L"$\mu_{skid}$", label = "", kwargs...)

    pd[:srf] = plot(subplot_μ_roll, subplot_μ_skid;
        plot_title = "Surface Friction",
        layout = (1,2), link = :y,
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

    subplot_κ_br = plot(ts.κ_br; title = "Braking Coefficient",
        ylabel = L"$\alpha_{br}$", label = "", kwargs...)
    subplot_μ_max_x = plot(μ_max_x; title = "Maximum Friction Coefficient",
        ylabel = L"$\mu_{max}^{x}$", label = "", kwargs...)
    subplot_μ_eff_x = plot(μ_eff_x; title = "Effective Friction Coefficient",
        ylabel = L"$\mu^{x}$", label = "", kwargs...)

    pd[:μ_x] = plot(subplot_κ_br, subplot_μ_max_x, subplot_μ_eff_x;
        plot_title = "Longitudinal Friction",
        layout = (1,3),
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

    subplot_ψ_cv = plot(ts._t, rad2deg.(ts.ψ_cv._data); title = "Tire Slip Angle",
        ylabel = L"$\psi_{cv} \ (deg)$", label = "", kwargs...)
    subplot_μ_max_y = plot(μ_max_y; title = "Maximum Friction Coefficient",
        ylabel = L"$\mu_{max}^{y}$", label = "", kwargs...)
    subplot_μ_eff_y = plot(μ_eff_y; title = "Effective Friction Coefficient",
        ylabel = L"$\mu^{y}$", label = "", kwargs...)

    pd[:μ_y] = plot(subplot_ψ_cv, subplot_μ_max_y, subplot_μ_eff_y;
        plot_title = "Lateral Friction",
        layout = (1,3),
        kwargs..., plot_titlefontsize = 20) #override titlefontsize after kwargs

    pd[:f_c] = plot(ts.f_c;
        plot_title = "Normalized Contact Force",
        ylabel = [L"$f_{Oc \ (trn)}^{c}$" L"$f_{Oc \ (trn)}^{c}$" L"$f_{Oc \ (trn)}^{c}$"],
        ts_split = :h, link = :none,
        kwargs...)

    pd[:F_c] = plot(ts.F_c;
        plot_title = "Contact Force",
        ylabel = [L"$F_{Oc \ (trn)}^{c} \ (N)$" L"$F_{Oc \ (trn)}^{c} \ (N)$" L"$F_{Oc \ (trn)}^{c} \ (N)$"],
        ts_split = :h, link = :none,
        kwargs...)

    pd[:wr_b] = plot(ts.wr_b;
        plot_title = "Wrench [Vehicle Axes]",
        wr_source = "trn", wr_frame = "b",
        kwargs...)

    pd[:frc] = make_plots(ts.frc; kwargs...)

    return pd

end

################################# GUI ##########################################

function GUI.draw(sys::System{<:Contact}, window_label::String = "Contact")

    @unpack μ_roll, μ_skid, μ_max, κ_br, ψ_cv, μ_eff, f_c, F_c, wr_b = sys.y
    frc = sys.frc

        CImGui.Text(@sprintf("Rolling Friction Coefficient: %.7f", μ_roll))
        CImGui.Text(@sprintf("Skidding Friction Coefficient: %.7f", μ_skid))
        CImGui.Text(@sprintf("Braking Factor: %.7f", κ_br))
        CImGui.Text(@sprintf("Tire Slip Angle: %.7f deg", rad2deg(ψ_cv)))
        GUI.draw(μ_max, "Maximum Friction Coefficient")
        GUI.draw(μ_eff, "Effective Friction Coefficient")
        GUI.draw(f_c, "Normalized Contact Force [Contact]")
        GUI.draw(F_c, "Contact Force [Contact]", "N")

        if CImGui.TreeNode("Friction Regulator")
            GUI.draw(frc, window_label)
            CImGui.TreePop()
        end

end


################################################################################
############################ LandingGearUnit ###################################

@kwdef struct LandingGearUnit{S <: AbstractSteering,
                            B <: AbstractBraking, L<:Strut} <: SystemDefinition
    steering::S = NoSteering()
    braking::B = NoBraking()
    strut::L = Strut()
    contact::Contact = Contact()
end

function Systems.f_ode!(sys::System{<:LandingGearUnit}, kinematics::KinData,
                        terrain::AbstractTerrain)

    @unpack strut, contact, steering, braking = sys

    f_ode!(steering)
    f_ode!(braking)
    f_ode!(strut, steering, terrain, kinematics)
    f_ode!(contact, strut, braking)

    assemble_y!(sys)

end

function Systems.f_step!(sys::System{<:LandingGearUnit})

    @unpack strut, contact, steering, braking = sys

    f_step!(steering)
    f_step!(braking)
    f_step!(strut)
    f_step!(contact, strut)

end

Dynamics.get_mp_b(::System{<:LandingGearUnit}) = MassProperties()
Dynamics.get_hr_b(::System{<:LandingGearUnit}) = zeros(SVector{3})
Dynamics.get_wr_b(sys::System{<:LandingGearUnit}) = sys.y.contact.wr_b


################################################################################
################################# GUI ##########################################

function GUI.draw(sys::System{<:LandingGearUnit}, p_open::Ref{Bool} = Ref(true),
                 window_label::String = "Landing Gear Unit")

    @unpack steering, braking, strut = sys

    CImGui.Begin(window_label, p_open)
        if CImGui.TreeNode("Strut")
            GUI.draw(sys.strut)
            CImGui.TreePop()
        end
        if CImGui.TreeNode("Steering")
            GUI.draw(sys.steering)
            CImGui.TreePop()
        end
        if CImGui.TreeNode("Braking")
            GUI.draw(sys.braking)
            CImGui.TreePop()
        end
        if CImGui.TreeNode("Contact")
            GUI.draw(sys.contact)
            CImGui.TreePop()
        end
    CImGui.End()

end

end #module