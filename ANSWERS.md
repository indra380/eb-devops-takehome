# Part 5 — Written answer

## Q1. Migrating ~40 Ingresses from ingress-nginx to the Gateway API with no downtime

I would not cut all 40 hosts over in one change. Gateway API is a different object model, and its data plane is a different set of pods from the ingress-nginx controller. The old controller stays until the last host has been observed on the new one.

**Order**

1. Inventory every Ingress: host, path, TLS secret, annotations, canaries, body size, timeouts, allow-lists, and who owns DNS and certificates. Annotations are where the downtime hides.
2. Install one pinned Gateway implementation beside ingress-nginx. Do not remove the old controller.
3. Prove a single low-traffic host on the new data plane. Compare status, certificate, headers, and any websocket or large-body behavior.
4. Translate hosts to HTTPRoutes in batches, leaving the Ingress in place. Shift one hostname at a time (short DNS TTL, or a second address) and watch error rate and latency. Roll back that host by pointing DNS back.
5. After a full certificate renewal cycle on the new path, delete the Ingress objects, then uninstall ingress-nginx.

**What I expect to break**

- Annotation behavior with no HTTPRoute equivalent: regex locations, snippets, sticky sessions, external auth, rate limits.
- TLS. The new Gateway must be allowed to read secrets (ReferenceGrant). cert-manager HTTP-01 solvers that target the old class fail until they target the Gateway.
- Clients and firewalls pinned to the old address, node ports, or source ranges.
- Routes that are Accepted but not Programmed, usually a Service port name or a missing cross-namespace grant.
- Clients that depended on ingress-nginx-specific headers or rewrite behavior.
