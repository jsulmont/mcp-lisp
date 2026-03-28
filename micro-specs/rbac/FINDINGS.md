## Findings

### No rule for record deletion
- **What the prompt asks for**: Revoking a role from a user immediately removes permissions not covered by remaining roles
- **What the DSL can express**: The effective-permissions-are-union invariant verifies that effective permissions are always the union of assigned role permissions, so revocation correctness holds by construction. However, there is no way to model the revocation action itself as a `defrule` — rules require a `:when` state guard on a `(member ...)` field and model field mutations, not record deletion.
- **Workaround**: Modeled as a structural property (invariant over the join table shape) rather than as an operational rule
- **Suggested fix**: Support `defrule` for record creation/deletion events, not just state transitions on existing records

### No many-to-many relation type
- **What the prompt asks for**: Roles have permissions, users have roles, resources require permissions — all many-to-many
- **What the DSL can express**: Each many-to-many requires a manual join entity (role-permission, user-role, resource-permission) with explicit FK fields and `:unique-together`. A 3-entity domain (user, role, permission) became 7 entities. The scenario generator must wire all FK fields by hand.
- **Workaround**: Join entities with string FK fields, `:unique-together` for uniqueness, `defhelper` functions to traverse the joins
- **Suggested fix**: A `:has-many-through` or `:many-to-many` relation type that generates the join entity implicitly and provides traversal accessors (e.g. `(role-permissions role)` returns the permission instances, not the join rows)

### Set operations available via defhelper, not needed as primitives
- **What the prompt asks for**: "effective permissions = union of role permissions", "required permissions ⊆ effective permissions"
- **What the DSL can express**: All of it — via `defhelper` using full CL (`remove-duplicates`, `loop`/`collect`, `every`/`member`). No DSL extension needed.
- **Workaround**: Not a workaround — `defhelper` is the intended mechanism. `subsetp` was reimplemented as `(every (lambda (req) (member req set :test #'equal)) required)`.
- **Takeaway**: This validates that `defhelper` + full CL in the sandbox is sufficient for set operations. Adding `subsetp`/`union`/`intersection` as invariant primitives would be ergonomic sugar, not a capability gap.
