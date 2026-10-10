# Part 5

## Q1. Moving about 40 Ingresses from ingress-nginx to the Gateway API, without downtime

I would not move all 40 hosts at once. Gateway API is a different object model, and the pods serving traffic are a different controller. ingress-nginx stays until I have seen the last host work on the new one.

Order:

1. List every Ingress first: host, path, TLS secret, annotations, canaries, body size, timeouts, allow-lists, and who owns DNS and the certificates. The annotations are where a straight conversion usually loses behaviour.
2. Install one Gateway controller beside ingress-nginx and pin its version. Do not remove the old one.
3. Move one quiet host. Check route status, the certificate, headers, and any websocket or large upload.
4. Convert the rest to HTTPRoutes in small batches, and leave the old Ingress in place. Shift one hostname at a time with a short TTL. Watch errors and latency. If that host looks wrong, point DNS back.
5. After the certificates have renewed once on the new path, delete the Ingress objects, then uninstall ingress-nginx.

What I expect to break:

- Annotation features with no direct HTTPRoute match: regex locations, snippets, sticky sessions, external auth, rate limits.
- TLS. The Gateway needs a ReferenceGrant to read a secret in another namespace. cert-manager HTTP-01 solvers aimed at the old class fail until they target the Gateway.
- Clients and firewall rules stuck on the old address, a node port, or a source range.
- A route that is Accepted but not Programmed. That is usually a Service port name, or a missing grant between namespaces.
- Clients that needed a header or a rewrite only ingress-nginx added.
