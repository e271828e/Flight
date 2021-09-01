module Plotting

using Reexport
@reexport using RecursiveArrayTools
@reexport using LaTeXStrings
@reexport using Plots

export TimeHistory, thplot

# https://daschw.github.io/recipes/
# http://docs.juliaplots.org/latest/recipes/

"""
quiza definir varios niveles de detalle como argumento de entrada a los rplot
que me permita decidir si quiero TODAS las figuras para debugging o solo el set
minimo. y tambien puedo pintar algunas cosas mas compactas o menos, metiendo mas
cosas en la misma figura. por ejemplo, el nivel :compact para wrench me pinta F
en un mismo plotm M en un mismo plot y luego emoaqueta ambas como subplots de un
mismo plot
"""

"""
necesito un recipe para Wrench tambien? depende, si voy a generar un solo plot
con dos subplots, puedo hacerlo. si no, tengo que generar un rplot para Wrench
que llame a la recipe Vector3DPlot(t, F) y Vector3DPlot(t, M). esto ultimo es lo
mejor. o en su defecto, extraer a mano en cada rplot F y M y pintarlas como me
venga mejor cada una. si no quiero ese control, puedo hacer que rplot(::Wrench)
me genere ya dos figuras a Vector3DPlot. pero Wrench es omnipresente, seria
bueno generar un rplot aunque sea a expensas de usar los mismos kwargs para
ambas figuras.

"""


############################ TimeHistory #################################

mutable struct TimeHistory{D}
    t::AbstractVector{<:Real}
    data::D
end

thplot(t, data; kwargs...) = plot(TimeHistory(t, data); kwargs...)

@recipe function f(th::TimeHistory{<:AbstractVector{<:Real}})

    xguide --> L"$t \: (s)$"
    return th.t, th.data

end

@recipe function f(th::TimeHistory{<:AbstractMatrix{<:Real}}; split = :none)

    xguide --> L"$t \: (s)$"

    vlength = size(th.data)[2]
    label --> (vlength <= 3 ?  ["x" "y" "z"][:, 1:vlength] : (1:vlength)')
    if split === :h
        layout --> (1, vlength)
        link --> :y #alternative: :none
    elseif split === :v
        layout --> (vlength, 1)
    else
        layout --> 1
    end
    delete!(plotattributes, :split)

    return th.t, th.data

end

#convert to TimeHistory{Matrix} and return it to the pipeline for dispatching
@recipe function f(th::TimeHistory{<:AbstractVector{<:AbstractVector{<:Real}}})
    return TimeHistory(th.t, Array(VectorOfArray(th.data))')
end

end