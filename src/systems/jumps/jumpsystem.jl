JumpType = Union{VariableRateJump, ConstantRateJump, MassActionJump}

"""
$(TYPEDEF)

A system of jump processes.

# Fields
$(FIELDS)

# Example

```julia
using ModelingToolkit

@parameters β γ t
@variables S I R
rate₁   = β*S*I
affect₁ = [S ~ S - 1, I ~ I + 1]
rate₂   = γ*I
affect₂ = [I ~ I - 1, R ~ R + 1]
j₁      = ConstantRateJump(rate₁,affect₁)
j₂      = ConstantRateJump(rate₂,affect₂)
j₃      = MassActionJump(2*β+γ, [R => 1], [S => 1, R => -1])
js      = JumpSystem([j₁,j₂,j₃], t, [S,I,R], [β,γ])
```
"""
struct JumpSystem{U <: ArrayPartition} <: AbstractSystem
    """
    The jumps of the system. Allowable types are `ConstantRateJump`,
    `VariableRateJump`, `MassActionJump`.
    """
    eqs::U
    """The independent variable, usually time."""
    iv::Variable
    """The dependent variables, representing the state of the system."""
    states::Vector{Variable}
    """The parameters of the system."""
    ps::Vector{Variable}
    pins::Vector{Variable}
    observed::Vector{Equation}
    """The name of the system."""
    name::Symbol
    """The internal systems."""
    systems::Vector{JumpSystem}
end

function JumpSystem(eqs, iv, states, ps;
                    pins = Variable[],
                    observed = Equation[],
                    systems = JumpSystem[],
                    name = gensym(:JumpSystem))

    ap = ArrayPartition(MassActionJump[], ConstantRateJump[], VariableRateJump[])
    for eq in eqs
        if eq isa MassActionJump
            push!(ap.x[1], eq)
        elseif eq isa ConstantRateJump
            push!(ap.x[2], eq)
        elseif eq isa VariableRateJump
            push!(ap.x[3], eq)
        else
            error("JumpSystem equations must contain MassActionJumps, ConstantRateJumps, or VariableRateJumps.")
        end
    end

    JumpSystem{typeof(ap)}(ap, convert(Variable,iv), convert.(Variable, states), convert.(Variable, ps), pins, observed, name, systems)
end

generate_rate_function(js, rate) = build_function(rate, states(js), parameters(js),
                                        independent_variable(js),
                                        expression=Val{true})

generate_affect_function(js, affect, outputidxs) = build_function(affect, states(js),
                                                      parameters(js),
                                                      independent_variable(js),
                                                      expression=Val{true},
                                                      headerfun=add_integrator_header,
                                                      outputidxs=outputidxs)[2]

function assemble_vrj(js, vrj, statetoid)
    rate   = eval(generate_rate_function(js, vrj.rate))
    outputvars = (convert(Variable,affect.lhs) for affect in vrj.affect!)
    outputidxs = ((statetoid[var] for var in outputvars)...,)
    affect = eval(generate_affect_function(js, vrj.affect!, outputidxs))
    VariableRateJump(rate, affect)
end

function assemble_vrj_expr(js, vrj, statetoid)
    rate   = generate_rate_function(js, vrj.rate)
    outputvars = (convert(Variable,affect.lhs) for affect in vrj.affect!)
    outputidxs = ((statetoid[var] for var in outputvars)...,)
    affect = generate_affect_function(js, vrj.affect!, outputidxs)
    quote
        rate = $rate
        affect = $affect
        VariableRateJump(rate, affect)
    end
end

function assemble_crj(js, crj, statetoid)
    rate   = eval(generate_rate_function(js, crj.rate))
    outputvars = (convert(Variable,affect.lhs) for affect in crj.affect!)
    outputidxs = ((statetoid[var] for var in outputvars)...,)
    affect = eval(generate_affect_function(js, crj.affect!, outputidxs))
    ConstantRateJump(rate, affect)
end

function assemble_crj_expr(js, crj, statetoid)
    rate   = generate_rate_function(js, crj.rate)
    outputvars = (convert(Variable,affect.lhs) for affect in crj.affect!)
    outputidxs = ((statetoid[var] for var in outputvars)...,)
    affect = generate_affect_function(js, crj.affect!, outputidxs)
    quote
        rate = $rate
        affect = $affect
        ConstantRateJump(rate, affect)
    end
end

function numericrate(rate, subber)
    if rate isa Operation
        rval = subber(rate).value
    elseif rate isa Variable
        rval = subber(rate()).value
    else
        rval = rate
    end
    rval
end

function numericrstoich(mtrs::Vector{Pair{V,W}}, statetoid) where {V,W}
    rs = Vector{Pair{Int,W}}()
    for (spec,stoich) in mtrs
        if !(spec isa Operation) && iszero(spec)
            push!(rs, 0 => stoich)
        else
            push!(rs, statetoid[convert(Variable,spec)] => stoich)
        end
    end
    sort!(rs)
    rs
end

function numericnstoich(mtrs::Vector{Pair{V,W}}, statetoid) where {V,W}
    ns = Vector{Pair{Int,W}}()
    for (spec,stoich) in mtrs
        !(spec isa Operation) && iszero(spec) && error("Net stoichiometry can not have a species labelled 0.")
        push!(ns, statetoid[convert(Variable,spec)] => stoich)
    end
    sort!(ns)
end

# assemble a numeric MassActionJump from a MT MassActionJump representing one rx.
function assemble_maj(maj::MassActionJump, statetoid, subber, invttype)
    rval = numericrate(maj.scaled_rates, subber)
    rs   = numericrstoich(maj.reactant_stoch, statetoid)
    ns   = numericnstoich(maj.net_stoch, statetoid)
    maj  = MassActionJump(convert(invttype, rval), rs, ns, scale_rates = false)
    maj
end

# For MassActionJumps that contain many reactions
# function assemble_maj(maj::MassActionJump{U,V,W}, statetoid, subber,
#                       invttype) where {U <: AbstractVector,V,W}
#     rval = [convert(invttype,numericrate(sr, subber)) for sr in maj.scaled_rates]
#     rs   = [numericrstoich(rs, statetoid) for rs in maj.reactant_stoch]
#     ns   = [numericnstoich(ns, statetoid) for ns in maj.net_stoch]
#     maj  = MassActionJump(rval, rs, ns, scale_rates = false)
#     maj
# end

function varmap_to_vars_dict(varmap::AbstractArray{<:Pair{S,T}}, varlist::AbstractVector{Variable}) where {S <: Operation,T}
    vard = Dict( v[1].op.name => v[2] for v in varmap)    
    [vard[v.name] for v in varlist]
end

function varmap_to_vars_dict(varmap::AbstractArray{<:Pair{S,T}}, varlist::AbstractVector{Variable}) where {S <: Variable,T}
    vard = Dict( v[1].name => v[2] for v in varmap)    
    [vard[v.name] for v in varlist]
end

# for if Dicts are ever supported as input maps
# function varmap_to_vars_dict(varmap::Dict{S,T}, varlist::AbstractVector{Variable}) where {S <: Variable,T}
#     [varmap[v] for v in varlist]
# end

# function varmap_to_vars_dict(varmap::Dict{S,T}, varlist::AbstractVector{Variable}) where {S <: Operation,T}
#     [varmap[v()] for v in varlist]
# end

"""
```julia
function DiffEqBase.DiscreteProblem(sys::JumpSystem, u0map, tspan,
                                    parammap=DiffEqBase.NullParameters; kwargs...)
```

Generates a blank DiscreteProblem for a pure jump JumpSystem to utilize as
its `prob.prob`. This is used in the case where there are no ODEs
and no SDEs associated with the system.

Continuing the example from the [`JumpSystem`](@ref) definition:
```julia
using DiffEqBase, DiffEqJump
u₀map = [S => 999, I => 1, R => 0]
parammap = [β => .1/1000, γ => .01]
tspan = (0.0, 250.0)
dprob = DiscreteProblem(js, u₀map, tspan, parammap)
```
"""
function DiffEqBase.DiscreteProblem(sys::JumpSystem, u0map, tspan::Tuple,
                                    parammap=DiffEqBase.NullParameters(); kwargs...)

    u0 = varmap_to_vars_dict(u0map, states(sys))
    p = (parammap == DiffEqBase.NullParameters()) ? parammap : varmap_to_vars_dict(parammap, parameters(sys))

    # EvalFunc because we know that the jump functions are generated via eval
    f  = DiffEqBase.EvalFunc(DiffEqBase.DISCRETE_INPLACE_DEFAULT)
    df = DiscreteFunction(f, syms=Symbol.(states(sys)))
    DiscreteProblem(df, u0, tspan, p; kwargs...)
end

"""
```julia
function DiffEqBase.DiscreteProblemExpr(sys::JumpSystem, u0map, tspan,
                                    parammap=DiffEqBase.NullParameters; kwargs...)
```

Generates a black DiscreteProblem for a JumpSystem to utilize as its
solving `prob.prob`. This is used in the case where there are no ODEs
and no SDEs associated with the system.

Continuing the example from the [`JumpSystem`](@ref) definition:
```julia
using DiffEqBase, DiffEqJump
u₀map = [S => 999, I => 1, R => 0]
parammap = [β => .1/1000, γ => .01]
tspan = (0.0, 250.0)
dprob = DiscreteProblem(js, u₀map, tspan, parammap)
```
"""
function DiscreteProblemExpr(sys::JumpSystem, u0map, tspan::Tuple,
                                    parammap=DiffEqBase.NullParameters(); kwargs...)

    u0 = varmap_to_vars_dict(u0map, states(sys))
    p = (parammap == DiffEqBase.NullParameters()) ? parammap : varmap_to_vars_dict(parammap, parameters(sys))

    # identity function to make syms works
    # EvalFunc because we know that the jump functions are generated via eval
    quote
        f  = DiffEqBase.EvalFunc(DiffEqBase.DISCRETE_INPLACE_DEFAULT)
        u0 = $u0
        p = $p
        tspan = $tspan
        df = DiscreteFunction(f, syms=$(Symbol.(states(sys))))
        DiscreteProblem(df, u0, tspan, p; kwargs...)
    end
end

using TimerOutputs

"""
```julia
function DiffEqBase.JumpProblem(js::JumpSystem, prob, aggregator; kwargs...)
```

Generates a JumpProblem from a JumpSystem.

Continuing the example from the [`DiscreteProblem`](@ref) definition:
```julia
jprob = JumpProblem(js, dprob, Direct())
sol = solve(jprob, SSAStepper())
```
"""
function DiffEqJump.JumpProblem(js::JumpSystem, prob, aggregator; kwargs...)

    sts       = states(js)
    statetoid = Dict(state => i for (i,state) in enumerate(sts))
    eqs       = equations(js)
    invttype  = typeof(1 / prob.tspan[2])

    # handling parameter substition and empty param vecs
    p = (prob.p == DiffEqBase.NullParameters()) ? Operation[] : prob.p
    parammap  = map((x,y)->Pair(x(),y), parameters(js), p)
    subber    = substituter(parammap)
   
    to = TimerOutput()
    @timeit to "majs" majs = MassActionJump[assemble_maj(j, statetoid, subber, invttype) for j in eqs.x[1]]
    crjs = ConstantRateJump[assemble_crj(js, j, statetoid) for j in eqs.x[2]]
    vrjs = VariableRateJump[assemble_vrj(js, j, statetoid) for j in eqs.x[3]]
    ((prob isa DiscreteProblem) && !isempty(vrjs)) && error("Use continuous problems such as an ODEProblem or a SDEProblem with VariableRateJumps")
    jset = JumpSet(Tuple(vrjs), Tuple(crjs), nothing, isempty(majs) ? nothing : majs)

    if needs_vartojumps_map(aggregator) || needs_depgraph(aggregator)
        @timeit to "set" variables = Set{typeof(first(sts))}(sts)
        @timeit to "dict" variablestoids = Dict( st.name => i for (i,st) in enumerate(sts))         
        @timeit to "asgraph" jdeps = asgraph(js, variables=variables, variablestoids=variablestoids)
        @timeit to "vdeps" vdeps = variable_dependencies(js, variables=variables, variablestoids=variablestoids)
        vtoj = jdeps.badjlist
        jtov = vdeps.badjlist
        @timeit to "eqeq_deps" jtoj = needs_depgraph(aggregator) ? eqeq_dependencies(jdeps, vdeps).fadjlist : nothing
    else
        vtoj = nothing; jtov = nothing; jtoj = nothing
    end

    @show to

    JumpProblem(prob, aggregator, jset; dep_graph=jtoj, vartojumps_map=vtoj, jumptovars_map=jtov, kwargs...)
end


### Functions to determine which states a jump depends on
function get_variables!(dep, jump::Union{ConstantRateJump,VariableRateJump}, variables) 
    (jump.rate isa Operation) && get_variables!(dep, jump.rate, variables)
    dep
end

function get_variables!(dep, jump::MassActionJump, variables)
    sr = jump.scaled_rates
    (sr isa Operation) && get_variables!(dep, sr, variables)
    for varasop in jump.reactant_stoch
        (varasop[1].op in variables) && push!(dep, varasop[1])
    end
    dep
end

### Functions to determine which states are modified by a given jump
function modified_states!(mstates, jump::Union{ConstantRateJump,VariableRateJump}, sts)
    for eq in jump.affect!
        st = eq.lhs
        (st.op in sts) && push!(mstates, st)
    end
end

function modified_states!(mstates, jump::MassActionJump, sts)
    for (state,stoich) in jump.net_stoch
        (state.op in sts) && push!(mstates, state)
    end
end
