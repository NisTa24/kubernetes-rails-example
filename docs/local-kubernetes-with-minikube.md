# Local Kubernetes cluster with minikube (instead of DigitalOcean)

This guide replaces the **"The Kubernetes cluster"** step of [kubernetes-rails.com](https://kubernetes-rails.com/), which uses DigitalOcean. Instead, it runs a cluster on your Mac with [minikube](https://minikube.sigs.k8s.io/). The later steps of the article still apply, apart from the differences listed under [Differences from the article](#differences-from-the-article).

## 1. Install the tools

```sh
brew install minikube kubectl
```

minikube runs the cluster inside a Docker container, so Docker Desktop (or another Docker runtime) must be running.

## 2. Create the cluster

```sh
minikube start --driver=docker --cpus=2 --memory=4096
```

This replaces creating a cluster in the DigitalOcean control panel. It takes a minute or two the first time.

## 3. The kubeconfig step

In the article, you download a kubeconfig file from DigitalOcean and point `kubectl` at it, for example:

```sh
export KUBECONFIG=~/Downloads/<cluster-name>-kubeconfig.yaml
```

**With minikube you don't need to download anything.** `minikube start` writes the cluster's credentials into your default kubeconfig (`~/.kube/config`) and switches `kubectl` to a context named `minikube`.

Check that `kubectl` is talking to minikube:

```sh
kubectl config current-context   # should print: minikube
kubectl get nodes                # should list one node named "minikube" with STATUS Ready
```

### If that doesn't work

- **You exported `KUBECONFIG` earlier** (for example, while following the DigitalOcean steps). Then `kubectl` is still reading that file. Clear it, and remove it from `~/.zshrc` if you added it there:
  ```sh
  unset KUBECONFIG
  kubectl config use-context minikube
  ```
- **The context is set to a different cluster:**
  ```sh
  kubectl config get-contexts
  kubectl config use-context minikube
  ```
- **The cluster isn't running** (for example, after a reboot):
  ```sh
  minikube status
  minikube start
  ```
- **You want a standalone kubeconfig file**, so the article's `export KUBECONFIG=...` line still works:
  ```sh
  kubectl config view --minify --flatten --context=minikube > ~/.kube/minikube-config.yaml
  export KUBECONFIG=~/.kube/minikube-config.yaml
  ```

## 4. Make the app image available to the cluster

Choose one option.

**Option A: push to Docker Hub** (works the same as the article). Building the image isn't enough; Kubernetes pulls from Docker Hub, so it must be pushed first:

```sh
docker push nista24/kubernetes-rails-example:latest
```

If you use an Apple Silicon Mac, your image is built for `arm64`. That's fine for minikube, which runs on the same architecture. A real cloud cluster would usually need `linux/amd64`.

**Option B: load the local image straight into minikube** (no push needed):

```sh
minikube image load nista24/kubernetes-rails-example:latest
```

Then set `imagePullPolicy: IfNotPresent` (or `Never`) on the container in your Deployment, so Kubernetes uses the loaded image instead of pulling it.

### Registry secret (only for private Docker Hub repositories)

If the repository on Docker Hub is **private**, Kubernetes needs credentials to pull the image. You don't need this if the repository is public, or if you use Option B.

Create a Docker Hub **access token** under **Account settings → Personal access tokens**, with read-only access. Use it instead of your account password. Then create the secret:

```sh
read -s DOCKER_TOKEN   # paste the token and press Enter; it won't be echoed

kubectl create secret docker-registry my-docker-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=nista24 \
  --docker-password="$DOCKER_TOKEN" \
  --docker-email=n.tamang@paicon.com

unset DOCKER_TOKEN
```

- Replace every value with a real one. `--docker-server=DOCKER_REGISTRY_SERVER` copied literally creates a secret that can't authenticate.
- Reading the token with `read -s` keeps it out of your shell history.
- `--docker-email` is optional; Docker Hub doesn't check it.
- The secret must be in the same namespace as the Deployment. Add `-n <namespace>` if you don't use `default`.

Check it:

```sh
kubectl get secret my-docker-secret
kubectl get secret my-docker-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

The second command should print JSON containing `https://index.docker.io/v1/` and your username.

Reference it in the Deployment's pod spec, at the same level as `containers`:

```yaml
spec:
  imagePullSecrets:
    - name: my-docker-secret
  containers:
    - name: ...
```

**To change the secret** (for example, after rotating the token), delete it and create it again:

```sh
kubectl delete secret my-docker-secret
# then run the create command above
```

If the delete fails with `Error from server (NotFound): secrets "my-docker-secret" not found`, the secret isn't in the current cluster and namespace. Check where it is:

```sh
kubectl config current-context            # should print: minikube
kubectl get secrets -A | grep my-docker-secret
```

If it's in another namespace, delete it with `-n <namespace>`. If it doesn't show up at all, skip the delete and just create it.

## 5. Add the Rails master key as a Secret

This is a separate secret from the registry secret above: it holds the key that decrypts Rails credentials.

The container needs `RAILS_MASTER_KEY` to start (see [troubleshooting-missing-secret-key-base.md](troubleshooting-missing-secret-key-base.md)):

```sh
kubectl create secret generic rails-secrets \
  --from-file=RAILS_MASTER_KEY=config/master.key
```

Reference it in the Deployment:

```yaml
env:
  - name: RAILS_MASTER_KEY
    valueFrom:
      secretKeyRef:
        name: rails-secrets
        key: RAILS_MASTER_KEY
```

The container listens on **port 80** (Thruster), so use `containerPort: 80` and set the Service's `targetPort` to `80`.

## 6. Reach the app

On DigitalOcean, a `LoadBalancer` Service gets a public IP. Locally, it stays `<pending>` until you do one of the following:

- **Run `minikube tunnel`** in a separate terminal and leave it running. The Service then gets an external IP that you can reach from your Mac:
  ```sh
  minikube tunnel
  kubectl get svc   # EXTERNAL-IP is now set, usually 127.0.0.1
  ```
- **Use `minikube service`** to open the Service in your browser:
  ```sh
  minikube service <service-name>
  ```
- **Port-forward**, which works with any Service type:
  ```sh
  kubectl port-forward svc/<service-name> 3000:80
  # then open http://localhost:3000
  ```

## 7. Troubleshooting pods

Deploy and watch the pods:

```sh
kubectl apply -f config/kube
kubectl get pods -w
```

If a pod isn't `Running`, find out why:

```sh
kubectl describe pod <pod-name>   # the Events section at the bottom shows the reason
kubectl logs <pod-name>           # app output, once the container has started
```

### `ErrImagePull` / `ImagePullBackOff`

Kubernetes couldn't download the image, so the container never started. This is **not** related to the Rails master key. Check the pod's events:

- **`...kubernetes-rails-example:latest: not found`** or **`pull access denied, repository does not exist`**: the image isn't on Docker Hub. It only exists in your local Docker. Either push it or load it into minikube:
  ```sh
  docker push nista24/kubernetes-rails-example:latest
  # or
  minikube image load nista24/kubernetes-rails-example:latest
  ```
- **`unauthorized` / `authorization failed`** on a private repository: the Deployment needs `imagePullSecrets` pointing at the registry secret, and the secret must contain valid credentials (see [Registry secret](#registry-secret-only-for-private-docker-hub-repositories)).

### `CrashLoopBackOff` / `Error`

The image was pulled, but the app exits on startup. Check `kubectl logs <pod-name>`. If it shows `Missing secret_key_base for 'production' environment`, the container has no `RAILS_MASTER_KEY`. Create the `rails-secrets` secret (step 5) and make sure the Deployment references it.

### `CreateContainerConfigError`

The Deployment references something that doesn't exist yet. Check `kubectl describe pod <pod-name>`. If the events show `Error: secret "rails-secrets" not found`, the master key secret hasn't been created. Create it, then restart the pods:

```sh
kubectl get secret rails-secrets   # confirm it's missing (NotFound)

kubectl create secret generic rails-secrets \
  --from-file=RAILS_MASTER_KEY=config/master.key

kubectl rollout restart deployment kubernetes-rails-example-deployment
kubectl rollout status deployment kubernetes-rails-example-deployment --timeout=180s
```

The first create prints `secret/rails-secrets created`, and the rollout finishes with `successfully rolled out`. Then `kubectl get pods` should show only new pods at `1/1 Running`.

- Creating a secret doesn't restart pods. Without `rollout restart`, pods can stay stuck in back-off for a while before retrying.
- `my-docker-secret` (registry credentials) and `rails-secrets` (master key) are two different secrets. Pods need both if the repository is private.

### Old and new pods at the same time

After changing a Deployment, you may see two groups of pods with different hashes in their names. For example, `...-57bb485d44-...` might be in `Error` while `...-54cbc99c5d-...` is in `CreateContainerConfigError`. The old pods come from the previous version of the Deployment. Kubernetes keeps them until the new pods become healthy, so fix the new pods and the old ones are removed automatically.

### `port-forward` fails with `connect: connection refused`

```
error forwarding port 80 to pod ...: failed to connect to localhost:80 inside namespace ...: connect: connection refused
```

The port-forward itself works, but nothing in the pod is listening on port 80. Usually the app isn't running: `port-forward` to a Service picks one pod, which may be a crashing one. Run `kubectl get pods` and fix whatever pods aren't `1/1 Running` (see the sections above), then forward again:

```sh
kubectl port-forward svc/kubernetes-rails-example-load-balancer 3000:80
# open http://localhost:3000
```

If every pod is `Running` and you still get this error, check the ports in the next section.

### Pods are `Running` but the app isn't reachable

The ports don't match. The container listens on **80** (Thruster), so `containerPort` and the Service's `targetPort` must both be `80`, not `3000`. See [kubernetes-ports-explained.md](kubernetes-ports-explained.md) for how the ports fit together.

### Working manifests

`config/kube/deployment.yml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-rails-example-deployment
spec:
  replicas: 4
  selector:
    matchLabels:
      app: rails-app
  template:
    metadata:
      labels:
        app: rails-app
    spec:
      imagePullSecrets:
      - name: my-docker-secret       # only needed for a private Docker Hub repo
      containers:
      - name: rails-app
        image: nista24/kubernetes-rails-example:latest
        imagePullPolicy: IfNotPresent # use an image loaded with `minikube image load` if present
        ports:
        - containerPort: 80
        env:
        - name: RAILS_MASTER_KEY
          valueFrom:
            secretKeyRef:
              name: rails-secrets
              key: RAILS_MASTER_KEY
```

`config/kube/load_balancer.yml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-rails-example-load-balancer
spec:
  type: LoadBalancer
  selector:
    app: rails-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      name: http
```

After changing secrets or manifests, re-apply and restart the pods:

```sh
kubectl apply -f config/kube
kubectl rollout restart deployment kubernetes-rails-example-deployment
```

## Differences from the article

| Article (DigitalOcean) | Local (minikube) |
|---|---|
| Create cluster in the DO control panel | `minikube start` |
| Download kubeconfig, `export KUBECONFIG=...` | Done automatically; context is `minikube` |
| `LoadBalancer` gets a public IP | `minikube tunnel`, `minikube service`, or `kubectl port-forward` |
| Domain name + DNS records | Use `localhost`, or an `/etc/hosts` entry pointing to `$(minikube ip)` |
| Ingress controller installed separately | `minikube addons enable ingress` |
| Let's Encrypt / TLS | Skip it locally |

## Useful commands

```sh
minikube dashboard        # web UI for the cluster
minikube stop             # stop the cluster (keeps its state)
minikube delete           # delete the cluster completely
kubectl get pods          # check that pods are running
kubectl logs <pod-name>   # see app logs (e.g. the secret_key_base error)
```

## Note on the database

The app uses SQLite, so each pod keeps its own database file inside the container. That data is lost whenever a pod restarts, and replicas won't share it. That's fine for learning, but use a PersistentVolume or Postgres for anything real.
