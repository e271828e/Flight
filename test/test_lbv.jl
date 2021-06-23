module TestLBV


########################### submodule Rbd ###################

module Airframe
using Flight.LBV
export XAirframe

@define_node XAirframe (att = LBVLeaf{4}, vel = LBVLeaf{3}, pos = LBVLeaf{4})

end #submodule

#################### submodule Ldg ########################

module Ldg
using Flight.LBV
export XLdg

@define_node XLdg (nlg = LBVLeaf{2}, mlg = LBVLeaf{2})

end #submodule

#################### submodule Aircraft ########################

module Aircraft
using Flight.LBV
using ..Airframe #needed to access XAirframe
using ..Ldg #needed to access XLdg
export XAircraft

@define_node XAircraft (rbd = XAirframe, ldg = XLdg, pwp = LBVLeaf{4}, null = LBVLeaf{0})

end #submodule

#################### Tests ########################

using Flight.LBV
using Reexport
@reexport using .Airframe
@reexport using .Ldg
@reexport using .Aircraft

export test_lbv

function test_lbv()

    #test that when broadcasting, the result is of the same type and numerically
    #correct
    #test that when broadcasting, numbers are promoted to the appropriate type
    #test that we can construct from a vector or from a view
    #when we extract a field, it is a view and it is equal to the appropriate
    #indices
    #when we change the field, it changes the original
    #when we extract a LBVLeaf, it is a Leaf
    #reject inappropriate length
    #test copy
    #test similar
    x = XAircraft()
    x_rbd = x.rbd
    x_rbd[4] = 0
    @show x
    v = XAircraft(view(x,:))
    v.pwp .= 3
    @show x
    #broadcasting with LBVLeafs of mixed parametric subtypes
    xv_rbd = x.pwp .+ v.pwp
    #broadcasting with LBVNodes of mixed parametric subtypes
    xv = x .+ v
    y = similar(x)
    @. y = x + sin(x) + 2x
    @show y

    z1 = XAircraft(zeros(Int32, length(XAircraft)))
    z2 = XAircraft(ones(Int64, length(XAircraft)))
    z = exp.(z1) + z2
    @show z

    # println(Aircraft.descriptor(z))

end


end #module