#=
nufft.jl
Non-uniform FFT (NUFFT), currently a wrapper around NFFT.jl
todo: open issues: small N, odd N, nufft!, adjoint!
2019-06-06, Jeff Fessler, University of Michigan
=#

export Anufft, nufft_init

#using MIRT: dtft_init, map_many
#include("../utility/map_many.jl")
using NFFT
using LinearAlgebra: norm
using LinearMapsAA: LinearMapAA, LinearMapAM, LinearMapAO


"""
    nufft_eltype(::DataType)
ensure plan_nfft eltype is Float32 or Float64
"""
nufft_eltype(::Type{<:Integer}) = Float32
nufft_eltype(::Type{<: Union{Float16,Float32}}) = Float32
nufft_eltype(::Type{Float64}) = Float64
nufft_eltype(T::DataType) = throw("unknown type $T")


# the following convenience routine ensures correct type passed to nfft()
# see https://github.com/tknopp/NFFT.jl/pull/33
# todo: may be unnecessary with future version of nfft()
"""
    nufft_typer(T::DataType, x::AbstractArray{<:Real} ; warn::Bool=true)
type conversion wrapper for `nfft()`
"""
nufft_typer(::Type{T}, x::T ; warn::Bool=true) where {T} = x # cf convert()

function nufft_typer(T::Type{TT}, x ; warn::Bool=true) where {TT}
    isinteractive() && @warn("converting $(eltype(x)) to $(eltype(T))")
    convert(T, x)
end


"""
    p = nufft_init(w, N ; nfft_m=4, nfft_sigma=2.0, pi_error=true, n_shift=0)

Setup 1D NUFFT,
for computing fast ``O(N \\log N)`` approximation to

``X[m] = \\sum_{n=0}^{N-1} x[n] \\exp(-i w[m] (n - n_{shift})), m=1,…,M``

in
- `w::AbstractArray{<:Real}` `[M]` frequency locations (units radians/sample)
   + `eltype(w)` determines the `plan_nfft` type; so to save memory use Float32!
   + `size(w)` determines `odim` for `A` if `operator=true`
- `N::Int` signal length

option
- `nfft_m::Int`		see NFFT.jl documentation; default 4
- `nfft_sigma::Real`	"", default 2.0
- `n_shift::Real`		often is N/2; default 0
- `pi_error::Bool`		throw error if ``|w| > π``, default `true`
   + Set to `false` only if you are very sure of what you are doing!
- `do_many::Bool`	support extended inputs via `map_many`? default `true`
- `operator::Bool=true` set to `false` to make `A` an `LinearMapAM`

out
- `p NamedTuple`
`(nufft = x -> nufft(x), adjoint = y -> nufft_adj(y), A::LinearMapAO)`

The default settings are such that for a 1D signal of length N=512,
the worst-case error is below 1e-5 which is probably adequate
for typical medical imaging applications.
To verify this statement, run `nufft_plot1()` and see plot.
"""
function nufft_init(
	w::AbstractArray{<:Real},
	N::Int ;
	n_shift::Real = 0,
	nfft_m::Int = 4,
	nfft_sigma::Real = 2.0,
	pi_error::Bool = true,
	do_many::Bool = true,
	operator::Bool = true, # !
)

	N < 6 && throw("NFFT may be erroneous for small N")
	isodd(N) && throw("NFFT erroneous for odd N")
	pi_error && any(abs.(w) .> π) &&
		throw(ArgumentError("|w| > π is likely an error"))

	T = nufft_eltype(eltype(w))
	CT = Complex{T}
	CTa = AbstractArray{Complex{T}}
	f = convert(Array{T}, vec(w)/(2π)) # note: plan_nfft must have correct type
	p = plan_nfft(f, N, nfft_m, nfft_sigma) # create plan
	M = length(w)
	# extra phase here because NFFT always starts from -N/2
	phasor = convert(CTa, cis.(-vec(w) * (N/2 - n_shift)))
	phasor_conj = conj.(phasor)
	forw1 = x -> nfft(p, nufft_typer(CTa, x)) .* phasor
#	forw! = x,y -> nfft!(p, nufft_typer(CTa, x)) .* phasor # todo
	back1 = y -> nfft_adjoint(p, nufft_typer(CTa, y .* phasor_conj))

	prop = (name="nufft1", w=w, N=(N,), n_shift=n_shift,
			nfft_m=nfft_m, nfft_sigma=nfft_sigma)
	A = LinearMapAA(forw1, back1, (M, N) ; # no "many" here!
		prop = prop, T=CT, operator = operator, # effectively "many" if true
		odim = operator ? size(w) : (length(w),),
	)

	if do_many
		forw = x -> map_many(forw1, x, (N,))
		back = y -> map_many(back1, y, (M,))
	else
		forw = forw1
		back = back1
	end

	return (nufft=forw, adjoint=back, A=A)
end


"""
    p = nufft_init(w, N ; nfft_m=4, nfft_sigma=2.0, pi_error=true, n_shift=?)

Setup multi-dimensional NUFFT,
for computing fast ``O(N \\log N)`` approximation to

``X[m] = \\sum_{n=0}^{N-1} x[n] \\exp(-i w[m,:] (n - n_{shift})), m=1,…,M``

in
- `w::AbstractArray{<:Real}` `[M,D]` frequency locations (units radians/sample)
	+ `eltype(w)` determines the `plan_nfft` type; so to save memory use Float32!
	+ `size(w)[1:(end-1)]` determines `odim` if `operator=true`
- `N::Dims{D}` signal dimensions

option
- `nfft_m::Int`		see NFFT.jl documentation; default 4
- `nfft_sigma::Real`	"", default 2.0
- `n_shift::AbstractVector{<:Real}`	`[D]`	often is N/2; default zeros(D)
- `pi_error::Bool`		throw error if ``|w| > π``, default `true`
   + Set to `false` only if you are very sure of what you are doing!
- `do_many::Bool`	support extended inputs via `map_many`? default `true`
- `operator::Bool=true` set to `false` to make `A` an `LinearMapAM`

The default `do_many` option is designed for parallel MRI where the k-space
sampling pattern applies to every coil.
It may also be useful for dynamic MRI with repeated sampling patterns.
The coil and/or time dimensions must come after the spatial dimensions.

out
- `p NamedTuple` with fields
	`nufft = x -> nufft(x), adjoint = y -> nufft_adj(y), A=LinearMapAO`
	(Using `operator=true` allows the `LinearMapAO` to support `do_many`.)
"""
function nufft_init(
	w::AbstractArray{<:Real},
	N::Dims{D} ;
	n_shift::AbstractVector{<:Real} = zeros(Int, length(N)),
	nfft_m::Int = 4,
	nfft_sigma::Real = 2.0,
	pi_error::Bool = true,
	do_many::Bool = true,
	operator::Bool = true, # !
) where {D}

	any(N .< 6) && throw("NFFT may be erroneous for small N")
	any(isodd.(N)) && throw("NFFT erroneous for odd N")
	pi_error && any(abs.(w) .> π) &&
		throw(ArgumentError("|w| > π is likely an error"))

	ndims(w) > 1 || throw("ndims(w)==1 invalid")
	size(w)[end] != D && throw(DimensionMismatch("$(size(w)) vs D=$D"))
	length(n_shift) != D && throw(DimensionMismatch("length(n_shift) vs D=$D"))
	odim = size(w)[1:(end-1)] # trick, e.g., for radial sampling
	w = reshape(w, :, D) # [M,D]
	M = size(w)[1]

	T = nufft_eltype(eltype(w))
	CT = Complex{T}
	CTa = AbstractArray{Complex{T}}
	f = convert(Array{T}, w/(2π)) # note: plan_nfft must have correct type
	p = plan_nfft(f', N, nfft_m, nfft_sigma) # create plan

	# extra phase here because NFFT.jl always starts from -N/2
	phasor = convert(CTa, cis.(-w * (collect(N)/2. - n_shift)))
	phasor_conj = conj.(phasor)
	# todo: in-place
	forw1 = x -> nfft(p, nufft_typer(CTa, x)) .* phasor
	back1 = y -> nfft_adjoint(p, nufft_typer(CTa, y .* phasor_conj))

	prop = (name="nufft$(length(N))", w=w, N=N, n_shift=n_shift,
			nfft_m=nfft_m, nfft_sigma=nfft_sigma)
	if operator # LinearMapAO
		A = LinearMapAA(forw1, back1, (M, prod(N)) ;
			prop = prop, T = CT,
			operator = true, odim = odim, idim = N,
		)
	else
		# no "many" for LinearMapAM:
		A = LinearMapAA(x -> forw1(reshape(x,N)), y -> vec(back1(y)),
			(M, prod(N)) ; prop = prop, T = CT,
		)
	end

	if do_many
		forw = x -> map_many(forw1, x, N)
		back = y -> map_many(back1, y, (M,))
	else
		forw = forw1
		back = back1
	end

	return (nufft=forw, adjoint=back, A=A)
end


"""
    Anufft(ω, N ; kwargs ...)

Make a `LinearMapAO` object of size `length(ω) × prod(N)`.
See `nufft_init` for options.
"""
Anufft(w::AbstractArray{<:Real}, N::Int ; kwargs...) =
	nufft_init(w, N ; kwargs...).A
Anufft(w::AbstractArray{<:Real}, N::Dims ; kwargs...) =
	nufft_init(w, N ; kwargs...).A


"""
w, errs = nufft_errors( ; M=?, w=?, N=?, n_shift=?, ...)

Compute worst-case errors for NUFFT (for signal of length N of unit norm)
"""
function nufft_errors( ;
	M::Int = 401,
	N::Int = 512,
	w::AbstractArray{<:Real} = LinRange(0, 2π/N, M),
	n_shift::Real = 0,
	kwargs...,
)

	sd = dtft_init(w, N ; n_shift=n_shift)
	sn = nufft_init(w, N ; n_shift=n_shift, kwargs...)
	E = Matrix(sn.A - sd.A)
	return w, vec(mapslices(norm, E, dims=2)) # [M]
end
