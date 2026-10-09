# Findings — Part 4 debug lab

Recorded on a local kind cluster (`demo`, Kubernetes v1.33.1) while investigating.
The host is Windows, so this session is a command log in `part4-session.log`
rather than `script`/`asciinema` output. The commands and the cluster output are real.

`./scenario.sh verify` after the chart fixes: **9 passing, 2 failing**.
The two failures are both the reporter (`0/1` ready, and `/report` has no pod count).
What I would try next is at the bottom. That part is not done.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):

`./scenario.sh up` did not install the release:

```
Error: 1 error occurred:
	* Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

`./scenario.sh verify` then reported `migrate Job has not completed`. There was no Job object.

**Cause:** `migrate` is a Job, and its pod template set `restartPolicy: Always`. The Job API only accepts `Never` or `OnFailure`, so the apiserver rejected the object and Helm returned an error. The other resources had already been applied.

**Fix:** Set `restartPolicy: OnFailure` so a failed migration can retry up to `backoffLimit`, and a successful one is recorded as complete. `Never` would also be accepted; `OnFailure` matches the existing backoff.

**How I found it:** The scenario script says a Helm error is part of the exercise. The first `./scenario.sh up` printed the restartPolicy validation error before any pod existed, so this one did not need a guess from the YAML.

---

## Defect 2

**Symptom:**

After the Job was out of the way, every workload was stuck:

```
backend-5cb957846d-4clcf    0/1   CreateContainerConfigError
gateway-789b7b6656-b7qmk    0/1   CreateContainerConfigError
worker-f58fd49b-6l2z9       0/1   CreateContainerConfigError
reporter-67795687bf-m4s5z   0/1   CreateContainerConfigError
metrics-6ff48bbdc7-w84mk    0/1   CreateContainerConfigError
```

`kubectl -n debug-lab get pod -l app=backend -o jsonpath='{.items[0].status.containerStatuses[0].state}'`:

```
container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

The same warning was on the gateway, worker, reporter, and metrics pods.

**Cause:** Every container sets `runAsNonRoot: true` but not a numeric `runAsUser`. The image `USER` is the name `nonroot`. Kubelet will not start that combination, because it will not trust a non-numeric user. `/etc/passwd` in the image maps that name to uid/gid **65532**.

**Fix:** Set `runAsUser: 65532` and `runAsGroup: 65532` on every workload, including the migration Job. That keeps `runAsNonRoot` (dropping it would also boot the container, and would drop the control). I did not change the image.

**How I found it:** `kubectl describe` / the container status above. Then `docker inspect` showed `User=nonroot`, and copying `/etc/passwd` out of the image showed `nonroot:x:65532:65532`.

---

## Defect 3

**Symptom:**

Deleting the metrics pod so it was recreated after the LimitRange existed:

```
Warning  FailedCreate  replicaset/metrics-5c775b5b77
  Error creating: pods "metrics-5c775b5b77-drjzr" is forbidden:
  maximum cpu usage per Container is 1, but limit is 4
```

The Deployment condition was `ReplicaFailure=True`, `0/1` available. This is not a CrashLoop: the pod is never created.

**Cause:** `cluster-state/limits.yaml` caps a container at 1 CPU and 512Mi. Metrics requested `cpu: "2"` and limited `cpu: "4"`. The other workloads use 50m/200m. I did not change the LimitRange; the harness restores it.

**Fix:** Give metrics the same requests and limits as the other workloads (`50m`/`64Mi` request, `200m`/`128Mi` limit). It is the same process in `APP_MODE=api`. Those numbers are under the guardrail and schedule on a kind node.

**How I found it:** The first metrics pod had been admitted before the LimitRange apply raced (see the session: `limits.yaml` failed once with namespace not found). After `kubectl apply -f cluster-state/limits.yaml` and a delete, the ReplicaSet events showed the admission error. `kubectl -n debug-lab describe limitrange debug-lab-guardrails` matches the message (`max.cpu` is 1).

---

## Defect 4

**Symptom:**

```
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no
```

`./scenario.sh verify`: `ServiceAccount debug-lab/reporter cannot list pods`.

The RoleBinding subject was:

```
subjects:
- kind: ServiceAccount
  name: default
  namespace: debug-lab
```

Once the reporter process could start, `GET /report` was:

```
kubernetes API returned HTTP 403: ... pods is forbidden:
User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods"
in API group "" in the namespace "debug-lab"
```

**Cause:** The Role `reporter-read` allows `get` and `list` on pods, and the Deployment uses the `reporter` ServiceAccount. The RoleBinding bound that Role to the `default` ServiceAccount instead.

**Fix:** Bind the subject to `{{ .Values.reporter.serviceAccountName }}` (`reporter`), in the release namespace. After that, `kubectl auth can-i list pods --as=system:serviceaccount:debug-lab:reporter` returns `yes`.

**How I found it:** The verify check names the exact `can-i` to run. The binding YAML showed `name: default` while `kubectl -n debug-lab get sa` showed a separate `reporter` account, and the Deployment sets `serviceAccountName: reporter`.

---

## Defect 5

**Symptom:**

With the containers finally running, backend and gateway logs:

```
eb-debug-app 2.0.0 starting: mode=api pod=backend-57f5646b8d-j89fg
  listening on :8081 (image default is 8081; set PORT to override)
```

Readiness probes are `httpGet` on port **8080**, and the Services target `common.port` (8080). The pods stayed `Running` but not `Ready`.

**Cause:** The process listens on 8081 unless `PORT` is set. The chart never set `PORT`, so probes and Service targetPorts hit a port with nothing listening.

**Fix:** Set `PORT` from `.Values.common.port` (`8080`) on backend, gateway, worker, reporter, and metrics. The Service ports stay 8080 (backend, reporter) and 80 (gateway, which forwards to 8080). I did not change the image.

**How I found it:** `kubectl logs` on the new pods. The line says the default and the override. After setting `PORT`, the same log line says `listening on :8080` and the probes return 200.

---

## Defect 6

**Symptom:**

Worker, after it was allowed to start:

```
worker-5487dc58f6-p6djd   0/1   CrashLoopBackOff
```

```
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system
— the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

A local `docker run` without the read-only root failed the same mkdir with `permission denied`. The image user cannot create `/var/cache/app` either way.

**Cause:** `APP_MODE=worker` writes a cache under `/var/cache/app`. The container has `readOnlyRootFilesystem: true`, and that path is not a volume. `/var/cache` is root-owned in the image, so a writable root would still fail for uid 65532.

**Fix:** Mount an `emptyDir` at `/var/cache/app` on the worker only. A volume mount stays writable when the root filesystem is read-only, and the emptyDir is writable by the container uid. I kept the read-only root.

**How I found it:** `kubectl logs deploy/worker` after defect 2 was fixed. The process prints the path and the two remedies. The worker then became `1/1` Ready and logged `GET /healthz -> 200`.

---

## Also fixed: gateway backend URL

This showed up only after the gateway was listening.

`kubectl port-forward` to the gateway pod on 8081, then `GET /status`:

```
HTTP/1.1 503 Service Unavailable
{"app":"gateway","backend":"error: GET http://backend.default.svc:8080/healthz:
 Get \"http://backend.default.svc:8080/healthz\": dial tcp: lookup backend.default.svc
 on 10.96.0.10:53: no such host","backend_url":"http://backend.default.svc:8080",
 "self":"ok", ...}
```

`GET /healthz` on the gateway returned the same lookup failure, so the readiness probe failed even though the process was up.

**Cause:** `BACKEND_URL` was `http://backend.default.svc:8080`. The backend Service is in `debug-lab`, not `default`. There is no `backend` Service in `default`, so DNS returns NXDOMAIN. The gateway treats that as unhealthy.

**Fix:** `http://backend:8080`. That is the Service DNS name in the pod's own namespace, and 8080 is the Service port (not the container port). Hardcoding `debug-lab` would also work; the short name keeps working if the release namespace changes.

**How I found it:** Port-forward, because the image has no shell and no wget. `/status` echoes `backend_url`, so the bad host was in the response rather than only in the values file.

---

## Not finished: reporter still cannot parse the pod list

RBAC is fixed (`can-i` is yes) and the reporter listens on 8080, but it is not Ready:

```
pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503
```

`GET /report` returns:

```
HTTP/1.1 503
{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
```

What I checked, and what it ruled out:

- The ServiceAccount can list pods. `kubectl get --raw /api/v1/namespaces/debug-lab/pods?limit=100 --as=system:serviceaccount:debug-lab:reporter` returns a valid PodList (about 48KB, `items` present, Python `json` parses it). The URL the process calls is `https://kubernetes.default.svc/api/v1/namespaces/<namespace>/pods?limit=100` (confirmed by pointing that name at a logger and reading the ClientHello, then the error path).
- A one-pod namespace whose list was about 6KB failed the same way. A larger list failed with `invalid character ' ' in string escape code`, which is what `encoding/json` says when a string is cut in the middle of an escape. That looks like a truncated body, but I could not get a list small enough to prove a byte cap, and `GODEBUG=http2client=0` did not change it.
- An `emptyDir` on `/var/cache/app` plus `CACHE_DIR` did not change it. The size-test pod did not have `readOnlyRootFilesystem` and still failed, so this is not the worker's cache bug.
- `kubectl auth can-i` is already yes, so this is not the RoleBinding anymore. Before that fix the error was the 403 quoted under defect 4. The parse error was hidden behind it.

**What I would do next:**

1. Put a TLS reverse proxy in front of `kubernetes.default.svc` (certificate signed by the kind CA) and log the response body the process actually unmarshals, byte for byte, next to the apiserver's body.
2. If those differ, the client is truncating (Content-Length vs chunked, or a fixed buffer). The chart-side fix would be whatever makes the list the client reads a complete document: a smaller pod list only helps if the cap is above the size of the six required pods.
3. If the bodies match, the decoder is rejecting this PodList shape. I would diff a minimal `{"items":[...]}` against the real document (managedFields, continue tokens) and change only the chart if some field we set is what it rejects.

I am not going to delete the reporter or point it at a fake list to turn the check green.
