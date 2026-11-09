# Troubleshooting: Sidekiq pods on Kubernetes

Errors seen while adding the `sidekiq` Deployment (`config/kube/sidekiq.yml`), in the order they show up, and how to fix each one.

Start by looking at the pod's status, events and logs:

```sh
kubectl get pods -l app=sidekiq
kubectl describe pod <sidekiq-pod-name>   # the Events section at the bottom shows the reason
kubectl logs <sidekiq-pod-name>
```

## 1. `RunContainerError`: `exec: "sidekiq": executable file not found in $PATH`

```
Error: failed to create containerd task: ... exec: "sidekiq": executable file not found in $PATH
```

**This is not Redis.** The container couldn't even start, because the command it was told to run doesn't exist in the image.

**Causes:**

- The command was `["sidekiq"]`. Gem executables should be run through Bundler.
- The image was built **before** `gem "sidekiq"` was added to the `Gemfile`, so Sidekiq isn't installed in it (see section 2).

**Fix:** run Sidekiq through Bundler in `config/kube/sidekiq.yml`:

```yaml
command: ["bundle", "exec", "sidekiq"]
```

## 2. `Error` / `CrashLoopBackOff`: `bundler: command not found: sidekiq`

```
bundler: command not found: sidekiq
Install missing gem executables with `bundle install`
```

**Still not Redis.** The container now starts and Bundler runs, but the Sidekiq gem isn't in the image.

**Cause:** the pods are running an **old image** that was built before Sidekiq was added. Two things keep that old image in use:

- Both manifests use `nista24/kubernetes-rails-example:latest`.
- With `imagePullPolicy: IfNotPresent`, the cluster reuses the copy of `:latest` it already has. The events show:
  ```
  Container image "nista24/kubernetes-rails-example:latest" already present on machine
  ```

So even after you rebuild and push `:latest`, the cluster keeps running the old copy.

**Fix (current setup):** set `imagePullPolicy: Always` in both `config/kube/deployment.yml` and `config/kube/sidekiq.yml`, then rebuild, push and restart:

```sh
docker build -t nista24/kubernetes-rails-example:latest .
docker push nista24/kubernetes-rails-example:latest
kubectl apply -f config/kube
kubectl rollout restart deployment kubernetes-rails-example-deployment sidekiq
kubectl get pods -w
```

Check that the new image actually contains Sidekiq before deploying:

```sh
docker run --rm --entrypoint bundle nista24/kubernetes-rails-example:latest exec sidekiq --version
```

**Alternative:** use a versioned tag (`v2`) in both manifests instead of `:latest`. Then `kubectl apply` triggers the rollout on its own.

See [updating-the-deployment.md](updating-the-deployment.md#latest-vs-versioned-tags-v1-v2-) for a comparison of `:latest` and versioned tags.

## 3. `CrashLoopBackOff`: Redis connection refused

Once the image is fixed, Sidekiq starts and connects to Redis at the `REDIS_URL` from the `env` ConfigMap:

```
redis://redis.default.svc.cluster.local:6379/
```

If no Redis exists in the cluster, Sidekiq crashes with an error like `Connection refused` or `getaddrinfo: Name or service not known` for `redis.default.svc.cluster.local`.

**Check:**

```sh
kubectl get svc   # there must be a Service named "redis"
```

**Fix:** deploy Redis with a Deployment and a Service named `redis` in the `default` namespace, so that the hostname in `REDIS_URL` resolves to it. This is in `config/kube/redis.yml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7.4-alpine
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis       # becomes redis.default.svc.cluster.local
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
```

Deploy it and check that it responds:

```sh
kubectl apply -f config/kube/redis.yml
kubectl rollout status deployment redis
kubectl exec deploy/redis -- redis-cli ping   # should print PONG
```

This Redis has no persistent storage, so its data (including queued jobs) is lost if the pod restarts. That's fine for local learning; for real use, add a PersistentVolumeClaim or use a managed Redis.

## 4. Missing `secret_key_base` or env vars

Sidekiq boots the whole Rails app, so it needs the same configuration as the web pods. Without the master key, it fails with the same `Missing secret_key_base for 'production' environment` error as in [troubleshooting-missing-secret-key-base.md](troubleshooting-missing-secret-key-base.md).

Make sure the Sidekiq Deployment has the ConfigMap, the master key, and the registry secret.

## Working `config/kube/sidekiq.yml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sidekiq
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sidekiq
  template:
    metadata:
      labels:
        app: sidekiq
    spec:
      imagePullSecrets:
      - name: my-docker-secret
      containers:
      - name: sidekiq
        image: nista24/kubernetes-rails-example:latest   # must be built after adding the sidekiq gem
        imagePullPolicy: Always                          # pull the newest :latest on each pod start
        command: ["bundle", "exec", "sidekiq"]
        envFrom:
          - configMapRef:
              name: env          # includes REDIS_URL
        env:
        - name: RAILS_MASTER_KEY
          valueFrom:
            secretKeyRef:
              name: rails-secrets
              key: RAILS_MASTER_KEY
```

## Jobs aren't processed by Sidekiq

Even with Sidekiq running, `config/environments/production.rb` sets:

```ruby
config.active_job.queue_adapter = :solid_queue
```

With that setting, Active Job sends jobs to Solid Queue, not Sidekiq. To use Sidekiq, change it to:

```ruby
config.active_job.queue_adapter = :sidekiq
```

Then rebuild the image with a new tag and deploy it as in section 2.

## Quick reference

| Status / log message | Cause | Fix |
|---|---|---|
| `RunContainerError`, `exec: "sidekiq": executable file not found` | Wrong command and/or old image | `command: ["bundle", "exec", "sidekiq"]`, rebuild |
| `bundler: command not found: sidekiq` | Image built before adding the gem; cluster reuses old `:latest` | Rebuild with a new tag and update `image:` |
| `Connection refused` / can't resolve `redis.default.svc.cluster.local` | No Redis in the cluster | Deploy a Redis Deployment + Service named `redis` |
| `Missing secret_key_base` | No `RAILS_MASTER_KEY` | Add `rails-secrets` to the Sidekiq Deployment |
| Sidekiq running but jobs never processed | `queue_adapter = :solid_queue` | Set `queue_adapter = :sidekiq` |
