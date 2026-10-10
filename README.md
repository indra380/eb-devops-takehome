# Demo service and debug lab

Parts 1–3 are the small HTTP service. Part 4 is the lab under `lab/`. Part 5 is `ANSWERS.md`.

## Run

You need Docker, kind, kubectl, and Helm on `PATH`. `./setup.sh` is bash, so on Windows use Git Bash. Running it twice is fine. The second run has to exit 0.

```bash
./setup.sh
```

It does four things:

1. Creates a kind cluster named `demo` if you do not already have one, and forwards host ports 80 and 443 into the node.
2. Installs ingress-nginx, controller v1.15.1, using the kind provider manifest.
3. Builds `demo-service:1.0.0` from `service/` and loads it into the node.
4. Installs Helm release `demo` in namespace `demo`.

## Check the service

The Ingress rule is the host `demo.local`. A browser request to `http://localhost` gets an nginx 404, because the Host header is `localhost`.

```bash
curl -sS -H "Host: demo.local" http://127.0.0.1/
curl -sS -H "Host: demo.local" http://127.0.0.1/healthz
```

`GET /` looks like `{"app": "demo", "version": "1.0.0", "pod": "<pod name>"}`.
`GET /healthz` is 200.

From inside the cluster:

```bash
kubectl -n demo get deploy,svc,ingress,pods
kubectl -n demo port-forward svc/demo 8080:80
curl -sS localhost:8080/
```

The port-forward holds the terminal. Use another window for curl, or stop it with Ctrl+C.

A ConfigMap patch shows up on `GET /` without a restart. The process reads `/config/APP_NAME` and `/config/VERSION` on each request. On my cluster the file took about 40 seconds to update. The same keys are also environment variables, so a new pod sees them straight away.

```bash
kubectl -n demo patch configmap demo --type merge \
  -p '{"data":{"APP_NAME":"patched-app","VERSION":"9.9.9"}}'
curl -sS -H "Host: demo.local" http://127.0.0.1/
```

Nothing the harness overrides is hardcoded in the templates:

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

On my cluster that ended at 9 passing and 2 failing. Both failures are the reporter. Notes are in `lab/FINDINGS.md`. I do not count Part 4 as finished.

## Requests and limits

| | CPU | memory |
|---|---|---|
| request | 50m | 64Mi |
| limit | 200m | 128Mi |

The process is the Python stdlib HTTP server. It does almost nothing per request, and the container sits under 64Mi. I still set a request, because 50m is enough to start and serve a few curls, and a pod with no request is BestEffort. The limit is 200m and 128Mi so a tight loop or a leak does not take the node. I did not want the limit so low that the probes fail while Python is starting. The lab LimitRange allows at most 1 CPU and 512Mi, and these numbers fit under that, which is also why the lab metrics container uses the same ones.

## What I left out

- The base image is `python:3.12.11-slim-bookworm`, not a digest. If that tag is rebuilt, the next build is a different image. I would pin the digest before this went anywhere shared.
- No TLS on the Ingress, no NetworkPolicy, no PodDisruptionBudget, no HPA. A drain can take both replicas at once, and anything that can reach the Ingress can call the app.
- No unit tests. I checked the endpoints with curl. A bad edit to `app.py` would not show up until the image runs.
- The Dockerfile runs `apt-get upgrade`. That is there so the image scan sees fewer old Debian packages. The build then depends on the mirror, and two builds a week apart are not the same image.
- Reporter `/report` still fails. `lab/FINDINGS.md` has the detail. The lab is not fully green.

## What I would change for production

- Pin the base image and the app image by digest. Build once and promote that digest.
- Set the requests from a measurement, not from this guess. Keep a limit. Add a PDB and spread the two replicas so they are not on one node.
- Terminate TLS on the Ingress. Add a NetworkPolicy so only the ingress controller can reach the Service.
- The live file read is only there so a ConfigMap patch shows up without a restart. For a real service I would roll the pods on purpose when config changes, so the running version is obvious.
- Handle `SIGTERM` and stop accepting new requests before exit. A rolling update currently cuts whatever was in flight.
- Keep the GitHub Actions workflow: `helm lint`, build the image, fail Trivy on HIGH or CRITICAL. I have not run that workflow.

## How I used AI

I used an AI tool (Cursor, Grok) for the scripting and for the `.md` files.

Scripting was `service/app.py`, the Dockerfile, the Helm templates, `setup.sh`, and `.github/workflows/ci.yml`. The markdown was `README.md`, `ANSWERS.md`, and `lab/FINDINGS.md`. I read those and changed wording that did not sound like me.

What I had to correct: the first service only read `APP_NAME` and `VERSION` from the environment. A ConfigMap patch did not show up on a running pod, so the app now re-reads the mounted files on each request. I checked that with curl. On the lab, the metrics failure is the LimitRange (cpu limit 4, max is 1), not the node being too small. The reporter still fails with `parse pod list: unexpected end of JSON input`. I left that check red. I ran `./setup.sh` twice on my own kind cluster.
