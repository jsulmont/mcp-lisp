## Warehouse Bin Packing

A warehouse has bins (shelves/containers) for storing items. Each bin has a maximum weight capacity in kg and a maximum volume capacity in liters.

Items arrive in shipments. Each item has a weight, a volume, and a category (fragile, hazardous, standard). An item is assigned to exactly one bin.

The rules:

- The total weight of all items in a bin must not exceed the bin's weight capacity.
- The total volume of all items in a bin must not exceed the bin's volume capacity.
- Hazardous items cannot share a bin with fragile items.
- Each bin has a maximum item count (varies per bin).
- A bin can be open (accepting items) or sealed. Sealed bins cannot accept new items.
