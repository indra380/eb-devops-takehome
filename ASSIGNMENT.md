# Take-Home Assignment — DevOps / Platform Engineer (v2)

Thanks for your interest in the DevOps Engineer role at Enterprise Bot GmbH.

This exercise is designed to take **about 3 hours**. Please don't spend
significantly more than that — we would much rather see an incomplete
submission with honest notes than a polished one that cost you a weekend. If
you run out of time, write down what you would have done next; that section is
read carefully.

**Deadline:** 24 hours from receipt.
**Deliverable:** a link to a public Git repository (GitHub or GitLab).

## Our AI policy — read this first

You may use AI assistants (Claude, ChatGPT, Copilot, agents — anything). We
use them daily ourselves and we won't pretend you don't have them. Three
conditions:

1. **Disclose it.** Your README must contain a short "How I used AI" section:
   which tools, for which parts, and what you had to correct. "None" is a
   perfectly fine answer; an implausible "none" is not a good look in the
   follow-up interview.
2. **Everything is defended live.** Shortlisted candidates walk us through
   their own submission in a screen-share, modify it on the spot, and debug a
   fresh problem we introduce. Submitting work you can't explain wastes your
   time as much as ours.
3. **Evidence must be real.** Part 4 requires a recorded terminal session and
   pasted command output from *your* cluster. Our grading harness re-runs your
   work; fabricated output is very detectable and treated as disqualifying.

In short: use AI to go faster, not to go somewhere you've never been.

## Environment

Everything runs locally. No cloud account, no paid tooling, no credit card.
You will need: Docker, `kubectl`, `helm`, and **`kind`** (we grade with kind;
minikube probably works but kind is what we verify against).

## Required repository layout

Our grading harness is automated. It clones your repo and expects **exactly**
this top-level layout — a submission that runs but is laid out differently
scores zero on the automated gates, which would be a silly way to lose points:

```
your-repo/
├── setup.sh            # Part 3 — executable, at the root
├── README.md           # Part 6
├── ANSWERS.md          # Part 5
├── service/            # Part 1 — app source, Dockerfile, .dockerignore
├── chart/              # Part 2 — your Helm chart
└── lab/                # Part 4 — copy the handout's lab/ folder here as-is
    ├── scenario.sh     #   (unmodified)
    ├── cluster-state/  #   (unmodified — see lab rules)
    ├── broken-chart/   #   your fixes live here
    ├── FINDINGS.md     #   fill in the provided template
    └── part4-session.log   # or part4-session.cast (see Part 4)
```

Commit incrementally as you work, not as one dump at the end — we look at the
history. Do not commit secrets or credentials.

---

## Part 1 — Containerize a small service (~40 min)

Write a small HTTP service in **Python or Node.js** (your choice) that exposes:

| Endpoint | Behaviour |
|---|---|
| `GET /` | Returns JSON: `{"app": "<APP_NAME>", "version": "<VERSION>", "pod": "<hostname>"}` |
| `GET /healthz` | Returns `200` when the service is healthy |

`APP_NAME` and `VERSION` must be read from environment variables — not
hardcoded. (Our harness changes them at runtime and expects `GET /` to follow.)

Write a `Dockerfile` for it that uses a multi-stage build, runs the process as
a **non-root** user, pins the base image to a specific tag (not `latest`), and
is accompanied by a `.dockerignore`.

## Part 2 — Helm chart (~40 min)

Create a Helm chart at `chart/` that deploys the service with:

- a Deployment with **2 replicas** by default
- **liveness and readiness probes** pointing at `/healthz`
- CPU and memory **requests and limits**
- `APP_NAME` and `VERSION` supplied via a **ConfigMap**
- a Service, and an Ingress for the host `demo.local`

So the harness can exercise it, your `values.yaml` must expose at least these
keys (add whatever else you like):

```yaml
replicaCount: 2
image:
  repository: ...
  tag: ...
config:
  appName: ...
  version: ...
ingress:
  host: demo.local
resources:
  requests: {...}
  limits: {...}
```

Templates must not contain hardcoded values for any of the above — we render
your chart with overrides (`--set replicaCount=3`, `--set config.appName=...`)
and check that the output follows.

## Part 3 — One-command setup (~20 min)

Provide an executable `setup.sh` at the repository root. Starting from a clean
machine that has Docker, kind, kubectl and helm installed, `./setup.sh` must do
everything end to end:

- create (or reuse) a kind cluster named **`demo`**
- install the **ingress-nginx** controller
- build your image and load it into the cluster
- install your chart as release **`demo`** into namespace **`demo`**

It must be **idempotent** — running it a second time must not fail. The
harness runs it twice and fails the gate if the second run exits non-zero.

Document in the README the exact commands to verify the service is working.

---

## Part 4 — Debug the lab (~75 min)

The `lab/` folder deploys a small slice of a platform: a **gateway** that
fronts a **backend**, a **worker**, a **reporter** that watches the namespace,
a **metrics** service, and a one-shot migration **Job**. It uses a prebuilt
image of ours; you get the image, not its source. There is no shell in the
image — `kubectl logs`, `kubectl describe`, `kubectl debug`, and
port-forwarding are your tools, and they are enough.

```bash
cd lab
./scenario.sh up        # install the (broken) lab into your cluster
./scenario.sh verify    # shows exactly what "done" means — same checks we run
```

There are **six independent defects**. Some mask others — fixing one may
change another's symptom, exactly like a real incident. The manifests may look
reasonable; trust the cluster, not your assumptions about the YAML.

**Rules:**

- Fix the chart (`lab/broken-chart/` — values or templates, your call).
- Do **not** modify `lab/cluster-state/` — that's the environment, not the bug.
  The harness re-applies the pristine copy before evaluating your chart.
- Do **not** change the image repository or tag.
- Do **not** delete or disable workloads to make a symptom disappear. Making
  an alert stop firing without understanding it is the exact habit we don't
  want on call — it's an automatic fail.

**Deliverables:**

1. Your fixed `lab/broken-chart/` — `./scenario.sh verify` must be green.
2. `lab/FINDINGS.md` — one entry per defect: **Symptom** (with the actual
   command output you saw, pasted), **Cause**, **Fix**, and **How I found it**.
   The diagnostic path matters more to us than the fix.
3. A recording of your debugging session: run `script -q part4-session.log`
   (or `asciinema rec part4-session.cast`) before you start investigating, and
   commit the file. We skim it for the path you took, not for speed or polish —
   dead ends and backtracking are normal and cost you nothing.

## Part 5 — Written question (~15 min)

Answer in `ANSWERS.md`, roughly 200 words — bullet points are fine. There is
no single correct answer; we are interested in how you reason about risk.
(More questions like this come up in the live interview.)

**Q1.** A platform is running around 40 Ingress objects on `ingress-nginx`,
which has reached end-of-life. You need to migrate to the Kubernetes Gateway
API with no downtime. Outline your approach, the order you would do things in,
and what you expect to break along the way.

## Part 6 — README

Your `README.md` should cover:

- how to run and verify your work
- the resource requests and limits you chose, and **why** those numbers
- **what you deliberately skipped, and the risk of skipping it**
- what you would change to make this production-ready
- **How I used AI** (see policy above)

## Optional bonus

A `.gitlab-ci.yml` or GitHub Actions workflow that lints the chart, builds the
image, and scans it with Trivy, failing the pipeline on HIGH or CRITICAL
findings.

---

## How this is graded

We're transparent about this because the checks *are* the spec:

1. An automated harness clones your repo, runs `./setup.sh` twice, exercises
   your chart with value overrides, patches your ConfigMap and expects `GET /`
   to follow, curls your service through the Ingress, then re-runs the Part 4
   lab against your fixed chart and scores each defect from cluster behaviour.
2. Humans read `FINDINGS.md`, your README's reasoning sections, and your
   session recording — for the shortlist, carefully.
3. Shortlisted candidates get a live session: walk us through your submission,
   extend it on the spot, and debug something new.

Honest reasoning carries real weight. Naming a gap is a strength, not an
admission. Any questions, reply to this email — asking a clarifying question
is never held against you.
