# Plan: Initialization Function Approach with MTKParameters Access

## Overview
Redesign symbolic parameter handling in discrete callbacks using compiled initialization functions instead of explicit parameter map threading. This approach uses MTKParameters extraction similar to how condition and affect functions are generated.

## Phase 1: Initialization Function Generation Infrastructure
1. **Create initialization function generator** in `callbacks.jl`
   - New function `generate_initialization_function(cb::SymbolicDiscreteCallback, sys, dvs, ps)`
   - Similar to existing `generate_condition_function` and `generate_affect_function`
   - Returns a compiled function that takes `(integrator, p, t)` and adds tstops

2. **Extend callback compilation pipeline**
   - Modify `generate_callback` to detect symbolic time conditions
   - When symbolic parameters detected, generate initialization function instead of resolving at problem construction
   - Pass initialization function via `initialize` keyword to `PeriodicCallback`/`PresetTimeCallback`

## Phase 2: Initialization Function Implementation
1. **For PeriodicCallback with symbolic period**
   - Use `build_function` to compile period expression with proper parameter indexing
   - Generated function directly accesses `p[param_idx]` or `p.component.param` for MTKParameters
   - Compiled function computes period value and calls `add_tstop!(integrator, t + period_value)`
   - Handle edge cases (period ≤ 0, first callback timing)

2. **For PresetTimeCallback with symbolic times**
   - Use `build_function` to compile time expressions with MTKParameters access patterns
   - Generated functions directly extract parameter values from `p` structure
   - Sorts resolved times and adds them via `add_tstop!(integrator, time)`
   - Filter out times ≤ current time

## Phase 3: Parameter Indexing and Compilation
1. **Leverage existing parameter indexing**
   - Use ModelingToolkit's existing parameter ordering and indexing system
   - Let `build_function` handle the parameter access pattern generation
   - Ensure symbolic parameters in time conditions are included in the parameter list

2. **Symbolic expression compilation**
   - Use `build_function(time_expr, [], ps, ...)` to generate functions that access `p` correctly
   - Follow same patterns as condition/affect function generation
   - Handle both scalar expressions and vector expressions for multiple times

## Phase 4: Integration with DifferentialEquations.jl
1. **Callback constructor modifications**
   - When symbolic time conditions detected, pass `initialize` function to callback constructors
   - Remove parameter resolution from `generate_discrete_callbacks`
   - Let DifferentialEquations.jl handle initialization function calls

2. **Error handling**
   - Initialization functions should validate parameter values at runtime
   - Provide clear error messages for undefined parameters or invalid time values

## Phase 5: API Cleanup and Testing
1. **Remove parameter_map threading**
   - Remove `parameter_map` arguments from `generate_discrete_callbacks`
   - Remove parameter resolution logic from `problem_utils.jl`
   - Simplify callback generation pipeline

2. **Update test suite**
   - Modify existing tests to verify initialization functions work correctly
   - Test that tstops are properly added during integration
   - Verify parameter changes during integration are handled

## Key Technical Implementation Details
- **Parameter access**: Use `build_function(expr, [], ps, ...)` to generate functions with proper `p` indexing
- **MTKParameters compatibility**: Generated functions will handle both simple parameter vectors and structured MTKParameters objects
- **Compilation consistency**: Follow exact same patterns as existing condition/affect function generation
- **No substitute calls**: All parameter values extracted directly from `p` argument at runtime

## Benefits of This Approach
- **Consistent with MTK patterns**: Uses same parameter access methods as condition/affect functions
- **Efficient**: Compiled parameter access instead of runtime substitution
- **MTKParameters compatible**: Works with structured parameter objects
- **Runtime flexibility**: Can handle parameter changes during integration
- **Cleaner API**: No parameter map threading required

This approach ensures the initialization functions follow ModelingToolkit's established patterns for parameter access in generated functions.