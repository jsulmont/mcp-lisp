## Distributed Lease Lock

A cluster of nodes coordinate access to a shared resource using time-bounded leases. A lease grants exclusive access to exactly one node for a fixed duration.

Entities: nodes and leases.

A node can be idle, requesting, holding, or expired. A lease tracks which node holds it, the grant time, and the duration.

The rules:

- An idle node may request the lease if no other node currently holds a valid (non-expired) lease.
- A requesting node is granted the lease atomically: the node becomes holding AND the lease records the holder and grant time. Both must happen together — you can't have a node in "holding" without a lease pointing to it, or a lease granted without the node's state changing.
- When the lease duration elapses, the holding node transitions to expired and the lease is released. This must also be atomic.
- An expired node returns to idle.
- At most one node may be in the "holding" state at any time (mutual exclusion).
- A node's state and the lease's holder field must always agree — if the lease says node X holds it, node X's state must be "holding", and vice versa.
