## Order Fulfillment with Time Constraints

An e-commerce system tracks orders through fulfillment. Each order has a creation time, items, and a promised delivery deadline.

Orders go through stages: placed, payment-confirmed, picking, packed, shipped, delivered. They can also be cancelled (before shipping) or returned (after delivery, within 14 days).

The rules:

- Payment must be confirmed within 2 hours of placement or the order is auto-cancelled.
- Picking must start within 4 hours of payment confirmation.
- Each stage transition records a timestamp. Timestamps must be strictly increasing through the lifecycle.
- An order cannot be shipped after its promised delivery deadline minus 24 hours (not enough transit time).
- Returns are only allowed within 14 days of delivery.
- A cancelled or returned order must record a reason.
- The total time from placement to delivery must not exceed 7 days.
