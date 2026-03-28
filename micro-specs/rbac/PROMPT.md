## Role-Based Access Control

A system has users, roles, and permissions. A permission is a string like "read:orders" or "write:inventory". Roles group permissions — each role has a set of permissions.

Users are assigned one or more roles. A user's effective permissions are the union of all permissions from their assigned roles.

Protected resources each require a set of permissions to access. A user can access a resource only if the resource's required permissions are a subset of the user's effective permissions.

The rules:

- A role must have at least one permission.
- A user must have at least one role.
- No two roles should have identical permission sets (they'd be redundant).
- A user can access a resource only if they have all required permissions.
- Revoking a role from a user immediately removes permissions not covered by remaining roles.
