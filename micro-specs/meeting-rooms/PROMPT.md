## Meeting Room Booking

We manage a set of meeting rooms in an office building. Each room has a name, a seating capacity, and optional equipment (projector, video conferencing).

People book rooms for meetings. A booking has a start time, a duration in minutes, a title, an organizer, and the number of attendees. Bookings start as tentative, can be confirmed or cancelled. Confirmed bookings can also be cancelled.

The core rules:

- A booking's attendee count must not exceed the room's capacity.
- You can only request equipment (projector, video conf) that the room actually has.
- No two non-cancelled bookings in the same room may overlap in time.
- Booking duration must be between 15 and 480 minutes.
