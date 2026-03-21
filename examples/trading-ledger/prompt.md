Model a multi-currency trading ledger.

 Entities:
 - trader — has an id, name, a tier (retail, professional, or market-maker), a numeric margin-ratio defaulting to 1.0, and a boolean suspended flag defaulting to false. A trader has many positions and many orders.
 - position — has an id, instrument (string), quantity (number), entry-price (number), notional (number), and a side (long or short). Belongs to a trader.
 - order — has an id, instrument, side (buy or sell), quantity, price, a state (pending, validated, filled, rejected, cancelled) defaulting to pending, a fill-price defaulting to 0, and a slippage defaulting to 0. Belongs to a trader.
 - risk-limit — has an id, max-notional (number), max-position-count (integer), max-single-order (number), and max-slippage-pct (number, default 5.0). Belongs to a trader.

Rules:
 - validate-order — fires when an order is pending. Requires: the trader is not suspended, quantity and price are positive, and quantity * price does not exceed the trader's risk-limit max-single-order. Ensures: order state becomes validated.
 - fill-order — fires when an order is validated. Requires: fill-price is positive and the percentage slippage (|fill-price - price| / price * 100) does not exceed the trader's max-slippage-pct. Ensures: state becomes filled and fill-price is positive.
 - reject-order — fires when an order is pending. Requires: either the trader is suspended, or quantity is not positive, or price is not positive. Ensures: state becomes rejected.
 - cancel-order — fires when an order is pending or validated (but not filled). Ensures: state becomes cancelled.
 - suspend-trader — fires when a trader's margin-ratio drops below 0.5. Ensures: suspended becomes true.

Invariants (these are the interesting ones for PBT):
 1. order-positive-values — on order: any order not in rejected or cancelled state must have quantity > 0 and price > 0.
 2. fill-price-consistency — on order: filled orders must have fill-price > 0; non-filled orders must have fill-price = 0.
 3. non-negative-slippage — on order: slippage is always >= 0.
 4. position-notional-correct — on position: notional must equal quantity * entry-price.
 5. no-negative-margin — on trader: margin-ratio must be >= 0.
 6. suspended-means-low-margin — on trader: if suspended is true, margin-ratio must be < 0.5.
 7. risk-limit-sane — on risk-limit: max-notional, max-position-count, and max-single-order must all be positive, and max-slippage-pct must be between 0 and 100.

 After defining everything, validate the specs, then run PBT with 500 trials. Show me the counterexamples.
