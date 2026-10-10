# Findings — Part 4 debug lab

I did this on a local kind cluster named `demo`, Kubernetes v1.33.1.
This PC is Windows, so `part4-session.log` is the command log from the session.
I do not have `script` or asciinema here. The commands and the output below are from that cluster.

After the chart changes, `./scenario.sh verify` was 9 passing and 2 failing.
Both failures are the reporter: it is not Ready, and `/report` does not return a pod count.
The last section is what I would try next. I did not finish that.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):

`./scenario.sh up` failed the install:

```
Error: 1 error occurred:
	* Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

`./scenario.sh verify` then said `migrate Job has not completed`. There was no Job.

**Cause:** `migrate` is a Job, and the pod template had `restartPolicy: Always`. A Job only accepts `Never` or `OnFailure`. The API rejected the object and Helm printed the error. The other objects were already applied.

**Fix:** I set `restartPolicy: OnFailure`. A failed run can still retry up to `backoffLimit`, and a successful run stays complete.

**How I found it:** The scenario script says a Helm error is part of the exercise. The first `./scenario.sh up` printed this before any pod existed, so I did not have to guess it from the YAML.

---

## Defect 2

**Symptom:**

Once the Job was accepted, every workload was stuck the same way:

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

Gateway, worker, reporter, and metrics had the same warning.

**Cause:** The containers set `runAsNonRoot: true` and do not set a numeric `runAsUser`. The image `USER` is the name `nonroot`. Kubelet will not start that, because it will not trust a name. `/etc/passwd` in the image has `nonroot:x:65532:65532`.

**Fix:** I set `runAsUser: 65532` and `runAsGroup: 65532` on every workload, including the migration Job. I left `runAsNonRoot: true`. I did not change the image.

**How I found it:** The container status above. `docker inspect` showed `User=nonroot`. I copied `/etc/passwd` out of the image and that line was `nonroot:x:65532:65532`.

---

## Defect 3

**Symptom:**

I deleted the metrics pod so it would be created again after the LimitRange was in place:

```
Warning  FailedCreate  replicaset/metrics-5c775b5b77
  Error creating: pods "metrics-5c775b5b77-drjzr" is forbidden:
  maximum cpu usage per Container is 1, but limit is 4
```

The Deployment was `ReplicaFailure=True` and `0/1` available. The pod is never created, so this is not a crash loop.

**Cause:** `cluster-state/limits.yaml` allows at most 1 CPU and 512Mi per container. Metrics requested `cpu: "2"` and set the limit to `cpu: "4"`. The other workloads use 50m and 200m. I left the LimitRange alone. The harness puts it back.

**Fix:** I gave metrics the same numbers as the other workloads: request 50m and 64Mi, limit 200m and 128Mi. It is the same process, just `APP_MODE=api`. Those numbers are under the limit and they schedule on this kind node.

**How I found it:** The first metrics pod had already been admitted. The first `kubectl apply -f cluster-state/` created the namespace and then failed the LimitRange with namespace not found, so the guardrail was missing for a moment. I applied `limits.yaml` again and deleted the pod. The ReplicaSet event was the message above. `kubectl -n debug-lab describe limitrange debug-lab-guardrails` shows max cpu 1.

---

## Defect 4

**Symptom:**

```
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no
```

`./scenario.sh verify` said `ServiceAccount debug-lab/reporter cannot list pods`.

The RoleBinding subject was:

```
subjects:
- kind: ServiceAccount
  name: default
  namespace: debug-lab
```

After the reporter process could start, `GET /report` was:

```
kubernetes API returned HTTP 403: ... pods is forbidden:
User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods"
in API group "" in the namespace "debug-lab"
```

**Cause:** Role `reporter-read` allows `get` and `list` on pods, and the Deployment uses ServiceAccount `reporter`. The RoleBinding attached that Role to the `default` ServiceAccount.

**Fix:** The subject is now `{{ .Values.reporter.serviceAccountName }}`, which is `reporter`, in the release namespace. After that, the same `can-i` command returns `yes`.

**How I found it:** The verify script tells you the `can-i` command. The binding said `name: default`. `kubectl -n debug-lab get sa` showed a separate `reporter` account, and the Deployment sets `serviceAccountName: reporter`.

---

## Defect 5

**Symptom:**

With the containers running, backend and gateway logged:

```
eb-debug-app 2.0.0 starting: mode=api pod=backend-57f5646b8d-j89fg
  listening on :8081 (image default is 8081; set PORT to override)
```

The probes are `httpGet` on port 8080, and the Services use `common.port`, which is 8080. The pods stayed Running and never became Ready.

**Cause:** The process listens on 8081 unless `PORT` is set. The chart did not set `PORT`, so the probes and the Service targetPorts hit a port with nothing on it.

**Fix:** I set `PORT` from `.Values.common.port` (8080) on backend, gateway, worker, reporter, and metrics. The Service ports stay 8080 for backend and reporter. The gateway Service stays on 80 and forwards to 8080. I did not change the image.

**How I found it:** `kubectl logs` on the new pods. The log line says the default and how to override it. After `PORT` was set, the log said `listening on :8080` and the probes returned 200.

---

## Defect 6

**Symptom:**

The worker, once it was allowed to start:

```
worker-5487dc58f6-p6djd   0/1   CrashLoopBackOff
```

```
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system
— the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

I also ran the image locally without a read-only root. The same mkdir failed with `permission denied`. Uid 65532 cannot create `/var/cache/app` either way.

**Cause:** `APP_MODE=worker` writes a cache under `/var/cache/app`. The container has `readOnlyRootFilesystem: true`, and that path is not a volume. `/var/cache` in the image is owned by root, so a writable root would still fail for this uid.

**Fix:** I mounted an emptyDir at `/var/cache/app` on the worker only. The mount is writable even when the root filesystem is read-only. I left the read-only root in place.

**How I found it:** `kubectl logs deploy/worker` after defect 2 was fixed. The process prints the path and the two ways to fix it. The worker then became 1/1 Ready and logged `GET /healthz -> 200`.

---

## Also fixed: gateway backend URL

This only showed up after the gateway was listening.

I port-forwarded to the gateway pod on 8081 and called `GET /status`:

```
HTTP/1.1 503 Service Unavailable
{"app":"gateway","backend":"error: GET http://backend.default.svc:8080/healthz:
 Get \"http://backend.default.svc:8080/healthz\": dial tcp: lookup backend.default.svc
 on 10.96.0.10:53: no such host","backend_url":"http://backend.default.svc:8080",
 "self":"ok", ...}
```

`GET /healthz` on the gateway failed the same lookup, so the readiness probe failed while the process was up.

**Cause:** `BACKEND_URL` was `http://backend.default.svc:8080`. The backend Service is in `debug-lab`, not `default`. Nothing named `backend` exists in `default`, so DNS returns no such host. The gateway treats that as unhealthy.

**Fix:** I set it to `http://backend:8080`. That name resolves in the pod's own namespace, and 8080 is the Service port. Writing `debug-lab` into the URL would also work. The short name still works if the release namespace changes.

**How I found it:** Port-forward. The image has no shell and no wget. `/status` prints `backend_url`, so the bad host was in the response.

---

## Not finished: the reporter still cannot parse the pod list

RBAC is fixed. `can-i` is yes, and the reporter listens on 8080. It is still not Ready:

```
pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503
```

`GET /report` returns:

```
HTTP/1.1 503
{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}
```

What I already checked:

- The ServiceAccount can list pods. `kubectl get --raw /api/v1/namespaces/debug-lab/pods?limit=100 --as=system:serviceaccount:debug-lab:reporter` returns a PodList of about 48KB. Python `json` parses it, and `items` is there. The process calls `https://kubernetes.default.svc/api/v1/namespaces/<namespace>/pods?limit=100`. I confirmed that by pointing the name at a logger and seeing the request, then the error.
- A namespace with one pod, about 6KB of JSON, failed the same way. A bigger list failed with `invalid character ' ' in string escape code`. That is what `encoding/json` says when a string is cut in the middle of an escape. It looks like a truncated body. I could not get a list small enough to prove a size limit, and `GODEBUG=http2client=0` did not change the error.
- An emptyDir on `/var/cache/app` and `CACHE_DIR` did nothing. A test pod without `readOnlyRootFilesystem` still failed, so this is not the worker cache bug.
- `can-i` is already yes, so this is not the RoleBinding anymore. Before that fix the error was the 403 in defect 4. The parse error was hidden behind it.

What I would do next:

1. Put a TLS proxy in front of `kubernetes.default.svc`, with a certificate signed by the kind CA, and log the body the process actually reads, next to the body the apiserver sent.
2. If those two bodies differ, the client is cutting the response. A smaller pod list only helps if the limit is bigger than the six pods this lab has to keep.
3. If the bodies match, the decoder does not like this PodList. I would compare a tiny `{"items":[...]}` with the real document and only change the chart if a field we set is what it rejects.

I am not going to delete the reporter, or point it at a fake list, to make the check pass.
