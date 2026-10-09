# Demo service and debug lab

Take-home for the DevOps / Platform Engineer exercise. Parts 1–3 are the demo
service. Part 4 is the debug lab under `lab/`. Part 5 is `ANSWERS.md`.

## Run

Needs Docker, kind, kubectl, and Helm on `PATH`. `./setup.sh` is bash
(Git Bash or Linux). It is safe to run twice.

```bash
./setup.sh
```

What it does:

1. Creates a kind cluster named `demo` if it does not exist, with host ports 80 and 443 forwarded to the node.
2. Installs ingress-nginx (the kind provider manifest, controller v1.15.1).
3. Builds `demo-service:1.0.0` from `service/` and loads it into the node.
4. Installs Helm release `demo` in namespace `demo`.

## Verify the demo service

Through the Ingress (host port 80):

```bash
curl -sS -H "Host: demo.local" http://127.0.0.1/
curl -sS -H "Host: demo.local" http://127.0.0.1/healthz
```

`GET /` returns `{"app": "demo", "version": "1.0.0", "pod": "<pod name>"}`.
`GET /healthz` returns 200.

Inside the cluster:

```bash
kubectl -n demo get deploy,svc,ingress,pods
kubectl -n demo port-forward svc/demo 8080:80
curl -sS localhost:8080/
```

A ConfigMap patch shows up on `GET /` without a restart. The process re-reads
`/config/APP_NAME` and `/config/VERSION` on each request. Kubelet's mount sync
is not instant; on this cluster it took about 40 seconds. The same keys are
also injected as environment variables, so a new pod sees them immediately.

```bash
kubectl -n demo patch configmap demo --type merge \
  -p '{"data":{"APP_NAME":"patched-app","VERSION":"9.9.9"}}'
curl -sS -H "Host: demo.local" http://127.0.0.1/
```

Chart overrides are not hardcoded. For example:

```bash
helm template demo chart \
  --set replicaCount=3 \
  --set config.appName=override-app \
  --set config.version=9.9.9 \
  --set ingress.host=other.local \
  --set image.repository=example.com/demo \
  --set image.tag=sha-abc
```

## Part 4

```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

Current result on this cluster: **9 checks passing, 2 failing**. Both failures
are the reporter. See `lab/FINDINGS.md`. I would not call Part 4 done.

## Resource requests and limits

| | CPU | memory |
|---|---|---|
| request | 50m | 64Mi |
| limit | 200m | 128Mi |

The process is a stdlib Python HTTP server. It does no real work per request.
A running container sits well under 64Mi. 50m is enough to start, pass probes,
and serve a handful of curls, and it is a real request so the pod is not
BestEffort. 200m and 128Mi stop a leak or a tight loop from taking the node,
without being so low that the probe timeouts fire under normal startup.
The same numbers fit under the lab LimitRange (`max` 1 CPU / 512Mi), which is
why metrics in the lab chart uses them too.

## What I skipped, and the risk

- **Image digest pin.** The Dockerfile tags `python:3.12.11-slim-bookworm`. That tag can move if the library image is rebuilt. A digest pin would make the build bit-for-bit repeatable. Risk: a surprise base-image change between two builds.
- **Ingress TLS, NetworkPolicy, PDB, HPA.** The demo is HTTP on `demo.local` with two replicas and no disruption budget. Risk: a node drain drops both pods together, and anything that can reach the Ingress can call the app.
- **Tests.** I checked the endpoints with curl against kind. There is no unit test. Risk: a later edit to `app.py` breaks the JSON shape and CI does not notice until the image runs.
- **`apt-get upgrade` in the image.** It patches Debian packages for the scanner, and it makes the build depend on the mirror at build time. Risk: a mirror outage fails `./setup.sh`, and two builds a week apart are not identical.
- **Reporter `/report`.** Still failing. Risk: the lab is not fully green. Details are in `lab/FINDINGS.md`.

## What I would change for production

- Pin the base image and the app image by digest. Build once, promote that digest.
- Run requests from a measured steady state, not from a guess. Keep the limit, and add a PDB plus topology spread so the two replicas are not on one node.
- Terminate TLS at the Ingress, and give the namespace a NetworkPolicy that only allows the Ingress controller to reach the Service.
- Replace the ConfigMap-file reload with a deliberate rollout if the config must be auditably versioned. The live file read is there so a harness patch is visible; it is a surprising way to ship config.
- Add a graceful shutdown (`SIGTERM` drains the HTTP server) so a rolling update does not cut requests.
- Keep the CI workflow: `helm lint`, image build, Trivy failing on HIGH and CRITICAL.

## How I used AI

I used Cursor's agent (Grok) for most of the writing and for driving the local
cluster.

- **Service, Dockerfile, Helm chart, `setup.sh`, CI, and `ANSWERS.md`.** Drafted with the agent, then checked. `helm template` with overrides, a real `./setup.sh` (twice), and curl through the Ingress are what I trust, not the draft.
- **ConfigMap behaviour.** The first version only put `APP_NAME` and `VERSION` in the environment. A patched ConfigMap does not change a running process's env. The agent added a volume mount that the process re-reads per request. I confirmed that with a patch: `GET /` switched to `patched-app` / `9.9.9` after about 40 seconds.
- **Part 4.** The agent ran `kubectl` against this kind cluster and we followed the logs. The fixes in `lab/broken-chart/` come from those errors (Job `restartPolicy`, non-numeric `runAsNonRoot`, LimitRange CPU, RoleBinding subject, `PORT`, worker cache volume, gateway `BACKEND_URL`). I corrected the early guess that metrics was only "too big for the node": the event is admission (`maximum cpu usage per Container is 1, but limit is 4`), and only after the LimitRange exists.
- **What is still wrong.** The reporter lists pods successfully at the apiserver and then fails with `parse pod list: unexpected end of JSON input`. Disabling HTTP/2 and mounting a cache dir did not fix it. I am not pretending that check is green.

The code is short on purpose so it can be changed live in a follow-up.
