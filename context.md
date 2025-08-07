# Context for Symbolic Timed Events Implementation

## Current State
- Branch: `symbolic_callback_tstops`
- Status: Current implementation complete and verified, ready to implement alternative design using initialization functions

## Problem Statement
ModelingToolkit currently requires numeric values for discrete callback time conditions (periodic and preset times). The goal is to enable symbolic parameters that get resolved at runtime.

## Current Implementation (Parameter Map Approach)
The following functions were implemented in `src/systems/callbacks.jl`:

### Key Functions Added:
1. **`is_symbolic_timed_condition(condition)` (lines 474-490)**
   - Detects if a time condition contains symbolic parameters
   - Handles scalar conditions, vector conditions, and nested expressions
   - Uses `iscall(condition, +)` and parameter detection logic

2. **`has_symbolic_timed_condition(cb::SymbolicDiscreteCallback)` (lines 492-494)**
   - Wrapper to check if a callback has symbolic time conditions

3. **`resolve_symbolic_timed_condition(condition, parameter_map)` (lines 766-772)**
   - Resolves symbolic parameters in time conditions using parameter maps
   - Handles both scalar and vector cases
   - Returns resolved numeric values

4. **Modified `generate_callback()` (lines 774-829)**
   - Enhanced to handle symbolic parameter resolution
   - Calls `resolve_symbolic_timed_condition` when needed
   - Passes resolved values to callback constructors

### Integration Points:
- **`src/systems/problem_utils.jl`**: Modified `process_kwargs()` (lines 1514-1543) to extract parameter maps and pass them to callback generation
- **Test suite**: Added comprehensive tests in `test/symbolic_events.jl` (lines 1423-1491)

## ModelingToolkit Patterns to Follow

### Function Generation Patterns:
```julia
# Example from existing code - how condition functions are generated:
function generate_condition_function(cb, sys, dvs, ps)
    # Uses build_function to create compiled functions
    # Parameters accessed via p[idx] or p.component.param
    build_function(condition_expr, dvs, ps, ...)
end
```

### Parameter Access in Generated Functions:
- Use `build_function(expr, [], ps, ...)` for expressions that only depend on parameters
- Generated functions receive `(integrator, p, t)` arguments
- `p` is MTKParameters object with structured access: `p.component.param`
- No `substitute()` calls - direct parameter extraction from `p`

### Callback Construction:
```julia
# Existing pattern for callbacks with initialization:
PeriodicCallback(affect_fn, period; initialize = init_fn)
PresetTimeCallback(affect_fn, times; initialize = init_fn)
```

## Alternative Design (To Implement)
Replace parameter map threading with compiled initialization functions:

1. **Generate initialization functions** using `build_function` similar to condition/affect functions
2. **Pass via `initialize` keyword** to callback constructors
3. **Remove parameter_map arguments** from callback generation pipeline
4. **Let DifferentialEquations.jl handle** initialization function calls

## Key Files and Locations

### Primary Implementation File:
- `src/systems/callbacks.jl` - All callback generation logic

### Integration Points:
- `src/systems/problem_utils.jl` - Problem construction and parameter handling
- `test/symbolic_events.jl` - Test suite for symbolic events

### Important Functions to Reference:
- `generate_condition_function` - Pattern for using build_function
- `generate_affect_function` - Parameter access patterns  
- `build_function` usage throughout codebase - Parameter indexing examples

## Current Branch State
- All current implementation is working and tested
- Ready to implement alternative design from `symbolic_timed_event_work_plan.md`
- Can reference existing parameter resolution logic for understanding, but will be replaced

## Implementation Notes
- `Num <: Real <: Number` - No need for explicit type additions
- Symbolic parameters detected via `iscall` and parameter checking
- MTKParameters structure handles both simple vectors and structured parameter objects
- Initialization functions should follow same compilation patterns as existing generated functions

## Testing Approach
- Verify tstops are properly added during integration
- Test both PeriodicCallback and PresetTimeCallback cases  
- Ensure parameter changes during integration work
- Maintain compatibility with existing non-symbolic workflows