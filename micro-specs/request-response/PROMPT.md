## Message-Driven Request-Response

Two nodes communicate via a message channel. Node A sends a request, node B processes it and sends a response, node A consumes the response.

Entities: nodes and messages.

A node has a role (requester or responder) and a status. A message has a type (request or response), a sender, a receiver, a payload, and a delivery status (pending, delivered).

The rules:

- The requester may send a request only when it is idle. After sending, it moves to "waiting."
- When a request message is delivered to the responder, the responder must process it: it moves from idle to processing, and its behavior depends on the message payload. If the payload value is above a threshold, the responder accepts; otherwise it rejects.
- The responder sends a response (accept/reject) and returns to idle.
- When the response is delivered to the requester, the requester moves from "waiting" to either "accepted" or "rejected" based on the response content.
- A message cannot be delivered to the wrong node — the receiver field must match.
- The requester cannot send a new request while waiting for a response.
- The responder's decision (accept/reject) must be consistent with the payload: payload >= threshold means accept, payload < threshold means reject.
