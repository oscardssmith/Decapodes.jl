using Catlab
using Catlab.Graphics
using CombinatorialSpaces
using CombinatorialSpaces.ExteriorCalculus
using Decapodes
using MultiScaleArrays
using MLStyle
using OrdinaryDiffEq
using LinearAlgebra
using GLMakie
using Logging
using JLD2
using Printf

using GeometryBasics: Point2, Point3
Point2D = Point2{Float64}
Point3D = Point3{Float64}

Brusselator = @decapode begin
  # Values living on vertices.
  (U, V)::Form0{X} # State variables.
  (U2V, One)::Form0{X} # Named intermediate variables.
  (U̇, V̇)::Form0{X} # Tangent variables.
  # Scalars.
  (α)::Constant{X}
  F::Parameter{X}
  # A named intermediate variable.
  U2V == (U .* U) .* V
  # Specify how to compute the tangent variables.
  U̇ == 1 + U2V - (4.4 * U) + (α * Δ(U)) + F
  V̇ == (3.4 * U) - U2V + (α * Δ(U))
  # Associate tangent variables with a state variable.
  ∂ₜ(U) == U̇
  ∂ₜ(V) == V̇
end
# Visualize. You must have graphviz installed.
to_graphviz(Brusselator)

# We resolve types of intermediate variables using sets of rules.

infer_types!(Brusselator)
# Visualize. Note that variables now all have types.
to_graphviz(Brusselator)

# Resolve overloads. i.e. ~dispatch
resolve_overloads!(Brusselator)
# Visualize. Note that functions are renamed.
to_graphviz(Brusselator)

# TODO: Create square domain of approximately 32x32 vertices.
s = loadmesh(Rectangle_30x10())
scaling_mat = Diagonal([1/maximum(x->x[1], s[:point]),
                        1/maximum(x->x[2], s[:point]),
                        1.0])
s[:point] = map(x -> scaling_mat*x, s[:point])
s[:edge_orientation] = false
orient!(s)
# Visualize the mesh.
GLMakie.wireframe(s)
sd = EmbeddedDeltaDualComplex2D{Bool,Float64,Point2D}(s)
subdivide_duals!(sd, Circumcenter())

# Define how operations map to Julia functions.
hodge = GeometricHodge()
Δ₀ = δ(1, sd, hodge=hodge) * d(0, sd)
function generate(sd, my_symbol; hodge=GeometricHodge())
  op = @match my_symbol begin
    # The Laplacian operator on 0-Forms is the codifferential of
    # the exterior derivative. i.e. dδ
    :Δ₀ => x -> Δ₀ * x
    :.* => (x,y) -> x .* y
    x => error("Unmatched operator $my_symbol")
  end
  return (args...) -> op(args...)
end

# Create initial data.
@assert all(map(sd[:point]) do (x,y)
  0.0 ≤ x ≤ 1.0 && 0.0 ≤ y ≤ 1.0
end)

U = map(sd[:point]) do (_,y)
  22 * (y *(1-y))^(3/2)
end

V = map(sd[:point]) do (x,_)
  27 * (x *(1-x))^(3/2)
end

# TODO: Try making this sparse.
F₁ = map(sd[:point]) do (x,y)
 (x-0.3)^2 + (y-0.6)^2 ≤ (0.1)^2 ? 5.0 : 0.0
end
GLMakie.mesh(s, color=F₁, colormap=:jet)

# TODO: Try making this sparse.
F₂ = zeros(nv(sd))

One = ones(nv(sd))

constants_and_parameters = (
  fourfour = 4.4,
  threefour = 3.4,
  α = 0.001,
  F = t -> t ≥ 1.1 ? F₂ : F₁)

# Generate the simulation.
gensim(expand_operators(Brusselator))
sim = eval(gensim(expand_operators(Brusselator)))
fₘ = sim(sd, generate)

# Create problem and run sim for t ∈ [0,tₑ).
# Map symbols to data.
u₀ = construct(PhysicsState,
  [VectorForm(U), VectorForm(V), VectorForm(One)], Float64[],
  [:U, :V, :One])

# Visualize the initial conditions.
# If GLMakie throws errors, then update your graphics drivers,
# or use an alternative Makie backend like CairoMakie.
fig_ic = GLMakie.Figure()
p1 = GLMakie.mesh(fig_ic[1,2], s, color=findnode(u₀, :U), colormap=:jet)
p2 = GLMakie.mesh(fig_ic[1,3], s, color=findnode(u₀, :V), colormap=:jet)

tₑ = 11.5

@info("Precompiling Solver")
prob = ODEProblem(fₘ, u₀, (0, 1e-4), constants_and_parameters)
soln = solve(prob, Tsit5())
soln.retcode != :Unstable || error("Solver was not stable")
@info("Solving")
prob = ODEProblem(fₘ, u₀, (0, tₑ), constants_and_parameters)
soln = solve(prob, Tsit5())
@info("Done")

@save "brusselator.jld2" soln

# Visualize the final conditions.
GLMakie.mesh(s, color=findnode(soln(tₑ), :U), colormap=:jet)

begin # BEGIN Gif creation
frames = 100
# Initial frame
fig = GLMakie.Figure(resolution = (1200, 800))
p1 = GLMakie.mesh(fig[1,2], s, color=findnode(soln(0), :U), colormap=:jet, colorrange=extrema(findnode(soln(0), :U)))
p2 = GLMakie.mesh(fig[1,4], s, color=findnode(soln(0), :V), colormap=:jet, colorrange=extrema(findnode(soln(0), :V)))
ax1 = Axis(fig[1,2], width = 400, height = 400)
ax2 = Axis(fig[1,4], width = 400, height = 400)
hidedecorations!(ax1)
hidedecorations!(ax2)
hidespines!(ax1)
hidespines!(ax2)
Colorbar(fig[1,1])
Colorbar(fig[1,5])
Label(fig[1,2,Top()], "U")
Label(fig[1,4,Top()], "V")
lab1 = Label(fig[1,3], "")

# Animation
record(fig, "brusselator.gif", range(0.0, tₑ; length=frames); framerate = 15) do t
    p1.plot.color = findnode(soln(t), :U)
    p2.plot.color = findnode(soln(t), :V)
    lab1.text = @sprintf("%.2f",t)
end

end # END Gif creation

# Run on the sphere.
# You can use lower resolution meshes, such as Icosphere(3).
s = loadmesh(Icosphere(5))
s[:edge_orientation] = false
orient!(s)
# Visualize the mesh.
GLMakie.wireframe(s)
sd = EmbeddedDeltaDualComplex2D{Bool,Float64,Point3D}(s)
subdivide_duals!(sd, Circumcenter())

# Define how operations map to Julia functions.
hodge = GeometricHodge()
Δ₀ = δ(1, sd, hodge=hodge) * d(0, sd)
function generate(sd, my_symbol; hodge=GeometricHodge())
  op = @match my_symbol begin
    # The Laplacian operator on 0-Forms is the codifferential of
    # the exterior derivative. i.e. dδ
    :Δ₀ => x -> Δ₀ * x
    :.* => (x,y) -> x .* y
    x => error("Unmatched operator $my_symbol")
  end
  return (args...) -> op(args...)
end

# Create initial data.
U = map(sd[:point]) do (_,y,_)
  abs(y)
end

V = map(sd[:point]) do (x,_,_)
  abs(x)
end

# TODO: Try making this sparse.
F₁ = map(sd[:point]) do (_,_,z)
  z ≥ 0.8 ? 5.0 : 0.0
end
GLMakie.mesh(s, color=F₁, colormap=:jet)

# TODO: Try making this sparse.
F₂ = zeros(nv(sd))

One = ones(nv(sd))

constants_and_parameters = (
  fourfour = 4.4,
  threefour = 3.4,
  α = 0.001,
  F = t -> t ≥ 1.1 ? F₁ : F₂
  )

# Generate the simulation.
fₘ = sim(sd, generate)

# Create problem and run sim for t ∈ [0,tₑ).
# Map symbols to data.
u₀ = construct(PhysicsState, [VectorForm(U), VectorForm(V), VectorForm(One)], Float64[], [:U, :V, :One])

# Visualize the initial conditions.
# If GLMakie throws errors, then update your graphics drivers,
# or use an alternative Makie backend like CairoMakie.
fig_ic = GLMakie.Figure()
p1 = GLMakie.mesh(fig_ic[1,2], s, color=findnode(u₀, :U), colormap=:jet)
p2 = GLMakie.mesh(fig_ic[1,3], s, color=findnode(u₀, :V), colormap=:jet)
display(fig_ic)

tₑ = 11.5

@info("Precompiling Solver")
prob = ODEProblem(fₘ, u₀, (0, 1e-4), constants_and_parameters)
soln = solve(prob, Tsit5())
soln.retcode != :Unstable || error("Solver was not stable")
@info("Solving")
prob = ODEProblem(fₘ, u₀, (0, tₑ), constants_and_parameters)
soln = solve(prob, Tsit5())
@info("Done")

@save "brusselator_sphere.jld2" soln

# Visualize the final conditions.
GLMakie.mesh(s, color=findnode(soln(tₑ), :U), colormap=:jet)

begin # BEGIN Gif creation
frames = 800
# Initial frame
fig = GLMakie.Figure(resolution = (1200, 1200))
p1 = GLMakie.mesh(fig[1,1], s, color=findnode(soln(0), :U), colormap=:jet, colorrange=extrema(findnode(soln(0), :U)))
p2 = GLMakie.mesh(fig[2,1], s, color=findnode(soln(0), :V), colormap=:jet, colorrange=extrema(findnode(soln(0), :V)))
Colorbar(fig[1,2])
Colorbar(fig[2,2])

# Animation
record(fig, "brusselator_sphere.gif", range(0.0, tₑ; length=frames); framerate = 30) do t
    p1.plot.color = findnode(soln(t), :U)
    p2.plot.color = findnode(soln(t), :V)
end

end # END Gif creation
