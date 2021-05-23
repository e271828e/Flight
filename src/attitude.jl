module Attitude

# https://discourse.julialang.org/t/writing-functions-for-types-defined-in-another-module/31895
# https://discourse.julialang.org/t/what-is-the-preferred-way-to-use-multiple-files/30687/6

using StaticArrays: MVector #this form of using does not allow method extension
using ..Quaternions: UnitQuat

export Rotation, RQuat

#########################

#implements a passive (alias) rotation, that is, a rotation describing the
#relative attitude between two reference frames.

abstract type Rotation end

############################# RQuat ###############################

struct RQuat <: Rotation
    quat::UnitQuat
    #if input is already a UnitQuat, new will not call convert, and therefore a
    #reference instead of a copy will be assigned to field quat. however, this
    #is no concern, since UnitQuats are virtually immutable (except for
    #normalize!), and there is garbage collection
end

RQuat() = RQuat(UnitQuat())

# Base.:*(::Rotation, ::AbstractVector) = transform(r, v)
# Base.:*(::Rotation, ::Rotation) = compose(r1, r2)


# declare RMat, RVec, RQuat, AxAng, Euler types and work with them, providing
# convert() methods between them as required. in general, only to and from
# quaternion will be required.

#AxAng, RVec and Euler should all promote to Quat.

#conversions to provide:
# RMat, AxAng, RVec and Euler to and from RQuat
# RMat to and from Quat
# with that, can provide two-step conversion to and from RMat to AxAng, RVec and
# Euler. maybe Euler could be direct.


#RQuat is the center. every RotationType subtype must provide a:
#convert(::Type{RotationType}, input::RQuat)
#convert(::Type{RQuat}, input::RotationType)

#for example:
# convert(::Type{AxAng}, input::RQuat) = ...

#with this, any conversion is possible in two steps as:
# convert(::Type{AxAng}, input::Euler) = convert(AxAng, convert(RQuat, input))
#more generally:
# convert(::Type{T}, input::Rotation) where {T<:Rotation}= convert(T, convert(RQuat, input))
#in the specific case in which input is already a RQuat, the conversion output
#is itself, it will be bypassed

#in some cases, we can override the convert method and replace it with a direct
#conversion. for example, from axis-angle to rotation vector it is
#straightforward, makes little sense to go through quaternion. or maybe i could
#provide direct conversions to and from RMat and Euler

#put println statements in each conversion method to know when it's been called

# struct AxAng <: Rotation
#     axis::Float64
#     angle::SVector{3, Float64}
# end

#Rotation is an abstract type, of which these are concrete subtypes. not all
#operations are defined for every one of them.

#how do i make RVec(input) work for input<:Rotation? Simply make the constructor
#convert input to RQuat, then from RQuat to RVec
#convert(RQuat, input)
#convert(RVec, input)
#in fact, since we know that we will support conversions to Quat for all
#Rotation subtypes, we can simply do:
#RVec(input::Rotation) = RVec(RQ)
#Euler(1, 2, 3)

#a RMat can be constructed from a 3x3 Matrix. in that case, orthonormality is
#always enforced by applying QR factorization. if it comes from a conversion, it
#is not necessary

#create normalize! and normalize methods for RMat

#i can admit * of rotation matrices without converting to RQuat, and also
#transforming vectors! only use promote when absolutely required!
#define promote_rule(R, q) = q (always prefer q)

#Euler can be a struct with fields upsi, utheta, uphi

#replace argument types with StaticArrays to fix lengths. also, allow different
#Real subtypes

#go to Flight folder
#enter package manager
#activate .
#do not do activate Flight. in that case, the test and using commands do not
#work. they expect to be run from Flight's parent folder. why??

#must fail when passed a 1D array of size other than 3
#how do we do this? by defining StaticArrays types


end