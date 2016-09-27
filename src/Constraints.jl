
"""
`module Constraints`

TODO: write documentation
"""
module Constraints

using JuLIP: Dofs, AbstractConstraint, mat, vecs, JVecs, AbstractAtoms,
         set_positions!, set_cell!, stress, defm, set_defm!

import JuLIP: dofs, project!, set_dofs!, positions, gradient


export FixedCell, VariableCell


function zeros_free{T}(n::Integer, x::Vector{T}, free::Vector{Int})
   z = zeros(T, n)
   z[free] = x
   return z
end

function insert_free!{T}(p::Array{T}, x::Vector{T}, free::Vector{Int})
   p[free] = x
   return p
end

# a helper function to get a valid positions array from a dof-vector
positions{TI<:Integer}(at::AbstractAtoms, ifree::AbstractVector{TI}, dofs::Dofs) =
      insert_free!(positions(at) |> mat, dofs, ifree) |> vecs


# ========================================================================
#          FIXED CELL IMPLEMENTATION
# ========================================================================

"""
`FixedCell`: no constraints are placed on the motion of atoms, but the
cell shape is fixed

Constructor:
```julia
FixedCell(at::AbstractAtoms; free=..., clamp=..., mask=...)
```
Set at most one of the kwargs:
* no kwarg: all atoms are free
* `free` : list of free atom indices (not dof indices)
* `clamp` : list of clamped atom indices (not dof indices)
* `mask` : 3 x N Bool array to specify individual coordinates to be clamped
"""
type FixedCell <: AbstractConstraint
   ifree::Vector{Int}
end

function analyze_mask(at, free, clamp, mask)
   if length(find((free != nothing, clamp != nothing, mask != nothing))) > 1
      error("FixedCell: only one of `free`, `clamp`, `mask` may be provided")
   elseif all( (free == nothing, clamp == nothing, mask == nothing) )
      # in this case (default) all atoms are free
      return collect(1:3*length(at))
   end
   # determine free dof indices
   Nat = length(at)
   if clamp != nothing
      # revert to setting free
      free = setdiff(1:Nat, clamp)
   end
   if free != nothing
      # revert to setting mask
      mask = Matrix{Bool}(3, Nat)
      fill!(mask, false)
      mask[:, free] = true
   end
   return mask[:]
end

FixedCell(at::AbstractAtoms; free=nothing, clamp=nothing, mask=nothing) =
   FixedCell(analyze_mask(at, free, clamp, mask))

# convert positions to a dofs vector; TODO: use unsafe_positions????
dofs(at::AbstractAtoms, cons::FixedCell) = mat(positions(at))[cons.ifree]

set_dofs!(at::AbstractAtoms, cons::FixedCell, x::Dofs) =
      set_positions!(at, positions(at, cons.ifree, x))

project!(at::AbstractAtoms, cons::FixedCell) = at

# TODO: this is a temporaruy hack, and I think we need to
#       figure out how to do this for more general constraints
#       maybe not too terrible
project!(cons::FixedCell, A::SparseMatrixCSC) = A[cons.ifree, cons.ifree]

gradient(at::AbstractAtoms, cons::FixedCell) = mat(gradient(at))[cons.ifree]



# ========================================================================
#          VARIABLE CELL IMPLEMENTATION
# ========================================================================

# F = Q U, U spd but in any case symmetric, so we should just allow F
# to be symmetric.
#
# consider the perturbation
#  F   -> F + t U
#  x_i -> (F+t U) F^{-1} x_i = x_i + t U F^{-1} x_i  =: x_i^t
# E({x_i^t}) ~ E({x_i}) + t ∑_i g_i ⋅ (U F^{-1} x_i) + O(t^2)
#            ~ E({x_i}) + t ∑_i g_ia U_ab [F_{-1} x_i]_b
#            ~ E({x_i}) + t U_ab : [ ∑_i g_{ia} [F^{-1} x_i]_b  ]_ab
#            ~ E({x_i}) + t U : ∑_i g_i ⊗ (F^{-1} x_i)
#
# now consider
#  x_i^t = (F + t U) F^{-1} (x_i + t u_i)
#        ~ x_i + t u_i + t U F^{-1} x_i + O(t^2)
#
#   small issue: this is a nonlinear search path !!!


"""
`VariableCell`: both atom positions and cell shape are free;

**WARNING:** read *meaning of dofs* instructions at bottom of help text.

Constructor:
```julia
VariableCell(at::AbstractAtoms; free=..., clamp=..., mask=..., fixvolume=false)
```
Set at most one of the kwargs:
* no kwarg: all atoms are free
* `free` : list of free atom indices (not dof indices)
* `clamp` : list of clamped atom indices (not dof indices)
* `mask` : 3 x N Bool array to specify individual coordinates to be clamped

### Meaning of dofs

On call to the constructor, `VariableCell` stored positions and deformation
`X0, F0`, dofs are understood *relative* to this "initial configuration".

`dofs(at, cons::VariableCell)` returns a vector that represents a pair
`(U, F1)` of a displacement and a deformation matrix. These are to be understood
*relative* to the reference `X0, F0` stored in `cons` as follows:
* `F = F1`   (the cell is then `F'`)
* `X = [F1 * (F0 \ x0) + u  for (x0, u) in zip(X0, U)]`

One aspect of this definition is that clamped atom positions still change via
`F`.
"""
type VariableCell <: AbstractConstraint
   ifree::Vector{Int}
   X0::JVecsF
   F0::JMatF
end



VariableCell(at::AbstractAtoms;
               free=nothing, clamp=nothing, mask=nothing) =
   VariableCell( analyze_mask(at, free, clamp, mask),
                 positions(at), JMat(cell(at)') )

# reverse map:
#   F -> F
#   U[n] = X[n] - A * X0[n]

function dofs(at::AbstractAtoms, cons::VariableCell)
   X = positions(at)
   F = defm(at)
   A = F / const.F0
   U = [x - A * x0 for (x,x0) in zip(X, cons.X0)]
   return [mat(U)[cons.ifree]; Matrix(F)[:]]
end

celldofs(x) = x[end-8:end]
posdofs(x) = x[1:end-9]

function set_dofs!(at::AbstractAtoms, cons::VariableCell, x::Dofs)
   F = JMatF(celldofs(x))
   A = F / cons.F0
   X = [A * x for x in cons.X0]
   mat(X)[cons.ifree] += posdofs(x)

   set_positions!(at, X)
   set_defm!(at, F)
   return at
end

function gradient(at::AbstractAtoms, cons::VariableCell)
   G = gradient(at)                  # neg. forces
   S = stress(at) / cell(at)'        # ∂E / ∂F
   return [ mat(G)[cons.ifree]; Array(S)[:] ]
end

# TODO: fix this once we implement the volume constraint ??????
project!(at::AbstractAtoms, cons::VariableCell) = at

# project!(cons::FixedCell, A::SparseMatrixCSC) = A[cons.ifree, cons.ifree]


end # module
