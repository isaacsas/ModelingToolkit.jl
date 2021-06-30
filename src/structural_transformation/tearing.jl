"""
    tear_graph(sys) -> sys

Tear the bipartite graph in a system.
"""
function tear_graph(sys)
    find_solvables!(sys)
    s = structure(sys)
    @unpack graph, solvable_graph, assign, inv_assign, scc = s

    @set! sys.structure.partitions = map(scc) do c
        ieqs = filter(eq->isalgeq(s, eq), c)
        vars = inv_assign[ieqs]

        td = TraverseDAG(graph.fadjlist, length(assign))
        SystemPartition(tearEquations!(td, solvable_graph.fadjlist, ieqs, vars)...)
    end
    return sys
end

function tearing_sub(expr, dict, s)
    expr = ModelingToolkit.fixpoint_sub(expr, dict)
    s ? simplify(expr) : expr
end

function tearing_reassemble(sys; simplify=false)
    s = structure(sys)
    @unpack fullvars, partitions, assign, inv_assign, graph, scc = s
    eqs = equations(sys)

    ### extract partition information
    rhss = []
    solvars = []
    ns, nd = nsrcs(graph), ndsts(graph)
    active_eqs  = trues(ns)
    active_vars = trues(nd)
    rvar2req = Vector{Int}(undef, nd)
    for (ith_scc, partition) in enumerate(partitions)
        @unpack e_solved, v_solved, e_residual, v_residual = partition
        for ii in eachindex(e_solved)
            ieq = e_solved[ii]; ns -= 1
            iv = v_solved[ii]; nd -= 1
            rvar2req[iv] = ieq

            active_eqs[ieq] = false
            active_vars[iv] = false

            eq = eqs[ieq]
            var = fullvars[iv]
            rhs = value(solve_for(eq, var; simplify=simplify, check=false))
            # if we don't simplify the rhs and the `eq` is not solved properly
            (!simplify && occursin(rhs, var)) && (rhs = SymbolicUtils.polynormalize(rhs))
            # Since we know `eq` is linear wrt `var`, so the round off must be a
            # linear term. We can correct the round off error by a linear
            # correction.
            rhs -= expand_derivatives(Differential(var)(rhs))*var
            @assert !(var in vars(rhs)) """
            When solving
            $eq
            $var remainded in
            $rhs.
            """
            push!(rhss, rhs)
            push!(solvars, var)
        end
        # DEBUG:
        #@show ith_scc solvars .~ rhss
        #Main._nlsys[] = eqs[e_solved], fullvars[v_solved]
        #ModelingToolkit.topsort_equations(solvars .~ rhss, fullvars)
        #empty!(solvars); empty!(rhss)
    end

    ### update SCC
    eq_reidx = Vector{Int}(undef, nsrcs(graph))
    idx = 0
    for (i, active) in enumerate(active_eqs)
        eq_reidx[i] = active ? (idx += 1) : -1
    end

    rmidxs = Int[]
    newscc = Vector{Int}[]; sizehint!(newscc, length(scc))
    for component′ in newscc
        component = copy(component′)
        for (idx, eq) in enumerate(component)
            if active_eqs[eq]
                component[idx] = eq_reidx[eq]
            else
                push!(rmidxs, idx)
            end
        end
        push!(newscc, component)
        deleteat!(component, rmidxs)
        empty!(rmidxs)
    end

    ### update graph
    var_reidx = Vector{Int}(undef, ndsts(graph))
    idx = 0
    for (i, active) in enumerate(active_vars)
        var_reidx[i] = active ? (idx += 1) : -1
    end

    newgraph = BipartiteGraph(ns, nd, Val(false))

    function visit!(ii, gidx, basecase=true)
        ieq = basecase ? ii : rvar2req[ii]
        for ivar in 𝑠neighbors(graph, ieq)
            # Note that we need to check `ii` against the rhs states to make
            # sure we don't run in circles.
            (!basecase && ivar === ii) && continue
            if active_vars[ivar]
                add_edge!(newgraph, gidx, var_reidx[ivar])
            else
                # If a state is reduced, then we go to the rhs and collect
                # its states.
                visit!(ivar, gidx, false)
            end
        end
        return nothing
    end

    ### update equations
    odestats = []
    for idx in eachindex(fullvars); isdervar(s, idx) && continue
        push!(odestats, fullvars[idx])
    end
    newstates = setdiff(odestats, solvars)
    varidxmap = Dict(newstates .=> 1:length(newstates))
    neweqs = Vector{Equation}(undef, ns)
    newalgeqs = falses(ns)

    dict = Dict(value.(solvars) .=> value.(rhss))

    for ieq in Iterators.flatten(scc); active_eqs[ieq] || continue
        eq = eqs[ieq]
        ridx = eq_reidx[ieq]

        visit!(ieq, ridx)

        if isdiffeq(eq)
            neweqs[ridx] = eq.lhs ~ tearing_sub(eq.rhs, dict, simplify)
        else
            newalgeqs[ridx] = true
            if !(eq.lhs isa Number && eq.lhs != 0)
                eq = 0 ~ eq.rhs - eq.lhs
            end
            rhs = tearing_sub(eq.rhs, dict, simplify)
            if rhs isa Symbolic
                neweqs[ridx] = 0 ~ rhs
            else # a number
                if abs(rhs) > 100eps(float(rhs))
                    @warn "The equation $eq is not consistent. It simplifed to 0 == $rhs."
                end
                neweqs[ridx] = 0 ~ fullvars[inv_assign[ieq]]
            end
        end
    end

    ### update partitions
    newpartitions = similar(partitions, 0)
    emptyintvec = Int[]
    for (ii, partition) in enumerate(partitions)
        @unpack e_residual, v_residual = partition
        isempty(v_residual) && continue
        new_e_residual = similar(e_residual)
        new_v_residual = similar(v_residual)
        for ii in eachindex(e_residual)
            new_e_residual[ii] = eq_reidx[ e_residual[ii]]
            new_v_residual[ii] = var_reidx[v_residual[ii]]
        end
        # `emptyintvec` is aliased to save memory
        # We need them for type stability
        newpart = SystemPartition(emptyintvec, emptyintvec, new_e_residual, new_v_residual)
        push!(newpartitions, newpart)
    end

    obseqs = solvars .~ rhss

    @set! s.graph = newgraph
    @set! s.scc = newscc
    @set! s.fullvars = fullvars[active_vars]
    @set! s.vartype = s.vartype[active_vars]
    @set! s.partitions = newpartitions
    @set! s.algeqs = newalgeqs

    @set! sys.structure = s
    @set! sys.eqs = neweqs
    @set! sys.states = newstates
    @set! sys.observed = [observed(sys); obseqs]
    return sys
end

"""
    algebraic_equations_scc(sys)

Find strongly connected components of algebraic equations in a system.
"""
function algebraic_equations_scc(sys)
    s = get_structure(sys)
    if !(s isa SystemStructure)
        sys = initialize_system_structure(sys)
        s = structure(sys)
    end

    # skip over differential equations
    algvars = isalgvar.(Ref(s), 1:ndsts(s.graph))
    eqs = equations(sys)
    assign = matching(s, algvars, s.algeqs)

    components = find_scc(s.graph, assign)
    inv_assign = inverse_mapping(assign)

    @set! sys.structure.assign = assign
    @set! sys.structure.inv_assign = inv_assign
    @set! sys.structure.scc = components
    return sys
end

"""
    tearing(sys; simplify=false)

Tear the nonlinear equations in system. When `simplify=true`, we simplify the
new residual residual equations after tearing.
"""
tearing(sys; simplify=false) = tearing_reassemble(tear_graph(algebraic_equations_scc(sys)); simplify=simplify)
