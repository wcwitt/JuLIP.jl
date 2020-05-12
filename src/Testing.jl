

"""
This module supplies some functions for testing of the implementation.
Look at `?` for

* `fdtest` : general finite-difference test
* `fdtest_R2R`: fd test for F : ℝ → ℝ
"""
module Testing

using Test
using JuLIP: AbstractCalculator, AbstractAtoms, energy, gradient, forces,
         calculator, set_positions!, dofs,
         mat, vecs, positions, rattle!, set_dofs!, set_calculator!
using JuLIP.Potentials: PairPotential, evaluate, evaluate_d, @D
using Printf
using LinearAlgebra: norm

using JuLIP.FIO: read_dict, write_dict, save_dict, load_dict

export fdtest, fdtest_hessian, h0, h1, h2, h3, print_tf, test_fio

"""
first-order finite-difference test for scalar F

* `fdtest(F::Function, dF::Function, x)`
* `fdtest(V::PairPotential, r::Vector{Float64})`
* `fdtest(calc::AbstractCalculator, at::AbstractAtoms)`
"""
function fdtest(F::Function, dF::Function, x; verbose=true)
   errors = Float64[]
   E = F(x)
   dE = dF(x)
   # loop through finite-difference step-lengths
   verbose && @printf("---------|----------- \n")
   verbose && @printf("    h    | error \n")
   verbose && @printf("---------|----------- \n")
   for p = 2:11
      h = 0.1^p
      dEh = copy(dE)
      for n = 1:length(dE)
         x[n] += h
         dEh[n] = (F(x) - E) / h
         x[n] -= h
      end
      push!(errors, norm(dE - dEh, Inf))
      verbose && @printf(" %1.1e | %4.2e  \n", h, errors[end])
   end
   verbose && @printf("---------|----------- \n")
   if minimum(errors) <= 1e-3 * maximum(errors)
      verbose && println("passed")
      return true
   else
      @warn("""It seems the finite-difference test has failed, which indicates
      that there is an inconsistency between the function and gradient
      evaluation. Please double-check this manually / visually. (It is
      also possible that the function being tested is poorly scaled.)""")
      return false
   end
end


function fdtest_hessian(F::Function, dF::Function, x; verbose=true)
   errors = Float64[]
   F0 = F(x)
   dF0 = dF(x)
   dFh = copy(Matrix(dF0))
   @assert size(dFh) == (length(F0), length(x))
   # loop through finite-difference step-lengths
   verbose &&  @printf("---------|----------- \n")
   verbose &&  @printf("    h    | error \n")
   verbose &&  @printf("---------|----------- \n")
   for p = 2:11
      h = 0.1^p
      for n = 1:length(x)
         x[n] += h
         dFh[:, n] = (F(x) - F0) / h
         x[n] -= h
      end
      push!(errors, norm(dFh - dF0, Inf))
      verbose &&  @printf(" %1.1e | %4.2e  \n", h, errors[end])
   end
   @printf("---------|----------- \n")
   if minimum(errors) <= 1e-3 * maximum(errors)
      verbose &&  println("passed")
      return true
   else
      @warn("""It seems the finite-difference test has failed, which indicates
            that there is an inconsistency between the function and gradient
            evaluation. Please double-check this manually / visually. (It is
            also possible that the function being tested is poorly scaled.)""")
      return false
   end
end


"finite-difference test for a function V : ℝ → ℝ"
function fdtest_R2R(F::Function, dF::Function, x::Vector{Float64};
                     verbose=true)
   errors = Float64[]
   E = [ F(t) for t in x ]
   dE = [ dF(t) for t in x ]
   # loop through finite-difference step-lengths
   if verbose
      @printf("---------|----------- \n")
      @printf("    h    | error \n")
      @printf("---------|----------- \n")
   end
   for p = 2:11
      h = 0.1^p
      dEh = ([F(t+h) for t in x ] - E) / h
      push!(errors, norm(dE - dEh, Inf))
      if verbose
         @printf(" %1.1e | %4.2e  \n", h, errors[end])
      end
   end
   if verbose
      @printf("---------|----------- \n")
   end
   if minimum(errors) <= 1e-3 * maximum(errors[1:2])
      println("passed")
      return true
   else
      @warn("""is seems the finite-difference test has failed, which indicates
            that there is an inconsistency between the function and gradient
            evaluation. Please double-check this manually / visually. (It is
            also possible that the function being tested is poorly scaled.)""")
      return false
   end
end


fdtest(V::PairPotential, r::AbstractVector; kwargs...) =
               fdtest_R2R(s -> V(s), s -> (@D V(s)), collect(r); kwargs...)



function fdtest(calc::AbstractCalculator, at::AbstractAtoms;
                verbose=true, rattle=0.01)
   X0 = copy(positions(at))
   calc0 = calculator(at)
   set_calculator!(at, calc)
   # random perturbation to positions (and cell for VariableCell)
   # perturb atom positions a bit to get out of equilibrium states
   # Don't use `rattle!` here which screws up the `VariableCell` constraint
   # test!!! (but why?!?!?)
   x = dofs(at)
   x += rattle * rand(length(x))
   # call the actual FD test
   result = fdtest( x -> energy(at, x), x -> gradient(at, x), x;
                    verbose = verbose )
   # restore original atom positions
   set_positions!(at, X0)
   set_calculator!(at, calc0)
   return result
end


function h0(str)
   dashes = "≡"^(length(str)+4)
   printstyled(dashes, color=:magenta); println()
   printstyled("  "*str*"  ", bold=true, color=:magenta); println()
   printstyled(dashes, color=:magenta); println()
end

function h1(str)
   dashes = "="^(length(str)+2)
   printstyled(dashes, color=:magenta); println()
   printstyled(" " * str * " ", bold=true, color=:magenta); println()
   printstyled(dashes, color=:magenta); println()
end

function h2(str)
   dashes = "-"^length(str)
   printstyled(dashes, color=:magenta); println()
   printstyled(str, bold=true, color=:magenta); println()
   printstyled(dashes, color=:magenta); println()
end

h3(str) = (printstyled(str, bold=true, color=:magenta); println())


print_tf(::Test.Pass) = printstyled("+", bold=true, color=:green)
print_tf(::Test.Fail) = printstyled("-", bold=true, color=:red)
print_tf(::Tuple{Test.Error,Bool}) = printstyled("x", bold=true, color=:magenta)



function test_dirderiv()

end


"""
`test_fio(obj): `  performs two tests:

- encodes `obj` as a Dict using `write_dict`, then decodes it using
`read_dict` and tests whether the two objects are equivalent using `==`
- writes `Dict` to file then reads it and decodes it and test the result is
again equivalent to `obj`

The two results are returned as Booleans.
"""
function test_fio(obj)
   D = write_dict(obj)
   test1 = (obj == read_dict(D))
   tmpf = tempname() * ".json"
   save_dict(tmpf, D)
   test2 = (obj == read_dict(load_dict(tmpf)))
   return test1, test2
end

end
