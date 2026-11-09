# Updating the deployment (ConfigMaps, Secrets and new images)

How to roll out changes to `config/kube/`, and what restarts automatically.

## Apply changes

Apply the whole folder. Kubernetes only changes what differs from what's already running:

```sh
kubectl diff -f config/kube                 # optional: preview the changes
kubectl apply -f config/kube
kubectl rollout status deployment kubernetes-rails-example-deployment
```

To check a change without applying it, use a server dry run. It catches invalid fields that a plain `apply` would reject:

```sh
kubectl apply -f config/kube --dry-run=server
```

## Do pods restart automatically?

| What changed | Pods restart automatically? | What to run |
|---|---|---|
| Deployment file (e.g. adding `envFrom`) | Yes, new pods roll out | `kubectl apply -f config/kube` |
| **Only the ConfigMap values** | **No.** Pods read env vars only when they start | `apply`, then `kubectl rollout restart deployment kubernetes-rails-example-deployment` |
| Secret values | No | Same as the ConfigMap row |
| New app code / image (`:latest`) | No, see [Deploying new code](#deploying-new-code) | Rebuild, push, `apply`, then `kubectl rollout restart deployment kubernetes-rails-example-deployment sidekiq` |
| New image tag in the manifests (`v2`) | Yes | Rebuild, push, `kubectl apply -f config/kube` |

## Using a ConfigMap for environment variables

`config/kube/env.yml` defines a ConfigMap named `env`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: env
data:
  RAILS_ENV: production
  RAILS_LOG_TO_STDOUT: enabled
  RAILS_SERVE_STATIC_FILES: enabled
```

`config/kube/deployment.yml` loads every key in it as an environment variable with `envFrom`:

```yaml
containers:
- name: rails-app
  image: nista24/kubernetes-rails-example:latest
  envFrom:
    - configMapRef:
        name: env        # must be indented under configMapRef
```

### Pitfall: indentation of `name`

If `name: env` is at the same indentation as `configMapRef`, Kubernetes reads it as a separate field, and the Deployment is rejected:

```
strict decoding error: unknown field "spec.template.spec.containers[0].envFrom[0].name"
```

`name` must be indented further than `configMapRef`, as shown above.

### Pitfall: `DATABASE_URL` / `REDIS_URL`

The app uses **SQLite** and only has the `sqlite3` gem. If you set `DATABASE_URL` to a `postgresql://...` URL, Rails tries to load the Postgres adapter on boot and every pod crashes (`CrashLoopBackOff`). Keep it commented out until you've added the `pg` gem, rebuilt the image, and deployed Postgres to the cluster.

`REDIS_URL` only works once Redis is running in the cluster. It's now deployed by `config/kube/redis.yml` (see [troubleshooting-sidekiq.md](troubleshooting-sidekiq.md#3-crashloopbackoff-redis-connection-refused)), so it's enabled:

```yaml
  # DATABASE_URL: postgresql://example.com/mydb
  REDIS_URL: redis://redis.default.svc.cluster.local:6379/
```

### ConfigMap vs Secret

Use a ConfigMap for plain settings. Values like `RAILS_MASTER_KEY` or database passwords belong in a Secret (e.g. `rails-secrets`), referenced with `secretKeyRef` or `secretRef`.

## Deploying new code

**Current setup:** both `config/kube/deployment.yml` (web) and `config/kube/sidekiq.yml` use `nista24/kubernetes-rails-example:latest` with `imagePullPolicy: Always`.

Whenever you change the app's code or `Gemfile`, you **must rebuild and push the image**. The cluster only runs what's on Docker Hub, not your local files.

### Workflow with `:latest` (current setup)

```sh
docker build -t nista24/kubernetes-rails-example:latest .
docker push nista24/kubernetes-rails-example:latest
kubectl apply -f config/kube
kubectl rollout restart deployment kubernetes-rails-example-deployment sidekiq
kubectl get pods -w
```

`apply` alone doesn't pick up the new image: the manifest still says `:latest`, so from Kubernetes' point of view nothing changed. `rollout restart` creates new pods, and with `Always`, each new pod pulls the newest `:latest` from Docker Hub.

### How `imagePullPolicy` works

| Policy | What happens when a pod starts | Effect with `:latest` |
|---|---|---|
| `Always` | Checks the registry and pulls if the image has changed | Gets the newest push, **as long as the pods are restarted** |
| `IfNotPresent` | Uses the node's copy if it has one; pulls only if missing | **Keeps running the old image** after a new push. The events show `Container image "...:latest" already present on machine` |
| `Never` | Only uses the node's copy, never pulls | Only works with images put on the node by hand (`minikube image load`) |

If you don't set `imagePullPolicy`, Kubernetes defaults to `Always` for `:latest` (or no tag) and `IfNotPresent` for any other tag.

With `Always`, `minikube image load` doesn't help, because the cluster pulls from Docker Hub every time a pod starts. Always push.

### `:latest` vs versioned tags (`v1`, `v2`, ...)

A tag is only a name. Kubernetes has no way to know that `:latest` now points to a different image than before.

| | `:latest` + `Always` | Versioned tags (`v2`, `v3`, ...) |
|---|---|---|
| Deploy a new build | Build, push, `apply`, **then `rollout restart`** | Build, push, change the tag in the manifests, `apply` |
| Rollout triggered by `apply`? | No, the manifest doesn't change | Yes, the tag change triggers it |
| See which version is running | Hard: every pod says `:latest` | Easy: `kubectl describe pod` shows `v2` |
| Rollback (`kubectl rollout undo`) | Doesn't really work: the "previous" version is also `:latest`, which now points to the new code | Works: goes back to the previous tag |
| All pods run the same code? | Not guaranteed: pods started at different times can pull different images | Yes |
| Pull on every pod start | Yes (slower startup, needs Docker Hub access) | Only when the node doesn't have the tag yet |
| Good for | Local learning, quick experiments | Anything shared, staging, production |

See [why-not-latest-image-tag.md](why-not-latest-image-tag.md) for more on the risks of `:latest`, including migrations.

### Workflow with versioned tags

```sh
docker build -t nista24/kubernetes-rails-example:v2 .
docker push nista24/kubernetes-rails-example:v2
```

Change `image:` to `nista24/kubernetes-rails-example:v2` in **both** `config/kube/deployment.yml` and `config/kube/sidekiq.yml`, then:

```sh
kubectl apply -f config/kube
kubectl rollout status deployment kubernetes-rails-example-deployment
kubectl rollout status deployment sidekiq
```

No `rollout restart` is needed, since the changed tag triggers the rollout. With versioned tags you can switch back to `imagePullPolicy: IfNotPresent` to avoid pulling on every start.

You can also change the image without editing the files, but then the manifests no longer match what's running:

```sh
kubectl set image deployment/kubernetes-rails-example-deployment rails-app=nista24/kubernetes-rails-example:v2
kubectl set image deployment/sidekiq sidekiq=nista24/kubernetes-rails-example:v2
```

### Check the image before deploying

For example, to confirm a new build contains Sidekiq:

```sh
docker run --rm --entrypoint bundle nista24/kubernetes-rails-example:latest exec sidekiq --version
```

## Rolling back

If a rollout goes wrong:

```sh
kubectl rollout undo deployment kubernetes-rails-example-deployment
```

## Checking the result

```sh
kubectl get pods                          # all pods should be 1/1 Running
kubectl exec deploy/kubernetes-rails-example-deployment -- env | sort   # check env vars inside a pod
kubectl logs deploy/kubernetes-rails-example-deployment
```

If pods fail, see the troubleshooting section in [local-kubernetes-with-minikube.md](local-kubernetes-with-minikube.md#7-troubleshooting-pods).
