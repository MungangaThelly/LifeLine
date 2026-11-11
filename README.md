# LifeLine

A resilient emergency communication and coordination platform, presented here as a working command-center prototype. The dashboard brings incident intake, responder coordination, local resources, and queued offline reports into one view.

## Run the application

Install Erlang/OTP and Rebar3, then from this folder run:

```powershell
rebar3 get-deps
rebar3 shell
```

The Cowboy service serves the dashboard at `http://localhost:8080/` and stores incidents under `data/incidents.dets`. Set the OTP `delivery_url` application environment value to an authenticated receiver URL to enable downstream delivery. With no receiver configured, incidents remain durably queued. The browser stores unsent reports in IndexedDB and retries them when it reconnects to the service.

## API

- `GET /api/health` — service health.
- `GET /api/incidents` — incidents, newest first.
- `GET /api/incidents/:id` — one incident.
- `POST /api/incidents` — submit an incident. Required JSON fields: `type`, `description`, and `location`. An optional stable `id` makes retries idempotent. New reports return `202 Accepted`; duplicates return the already stored incident.

The POST endpoint accepts at most 64 KiB. It validates required fields and stores the incident before acknowledging it. Delivery attempts use the incident ID as an `Idempotency-Key`; non-2xx responses and connection errors leave the incident queued for retry. This outbound integration is deliberately a generic receiver contract—the receiving organization must support idempotency for end-to-end duplicate protection.

The interface is responsive and its incident queue, map layers, map mode, search, report form, export, and map zoom controls are interactive.

## Erlang/OTP direction

The product backend should treat message acceptance and message delivery as separate operations. A client report is acknowledged and durably queued locally; delivery is retried when a path is available. The dashboard can connect to an OTP application through a JSON API and WebSocket event stream.

The initial OTP application layout in this repository:

```text
apps/lifeline/
  src/lifeline_app.erl          application callback
  src/lifeline_sup.erl          one-for-one root supervisor
  src/incident_store.erl        DETS-backed durable incident repository
  src/delivery_queue.erl        supervised outbound retry worker
  src/lifeline_api_handler.erl  JSON incident API
  src/lifeline_http.erl         Cowboy HTTP/static asset listener
```

DETS is suitable for this single-node starter, not a multi-node production deployment. Before production, use replicated durable storage, authenticate and authorize operators, add encrypted transport, audit access, and define retention policies. Supervision can restart workers; it cannot replace durable storage. Devices and field gateways should persist outbound messages, use stable IDs for idempotent retries, and encrypt content end to end where operational requirements allow. Erlang distribution should remain on trusted infrastructure; clients should connect through authenticated, encrypted public protocols.

## Product principles

- Accept reports when disconnected, preserve them locally, and show their delivery state clearly.
- Prioritize incidents without implying that automated scoring is a substitute for dispatch judgment.
- Track report provenance and verification separately from public visibility.
- Minimize sensitive location and identity data and apply role-based access.
- Make degraded connectivity visible to operators and field teams.
