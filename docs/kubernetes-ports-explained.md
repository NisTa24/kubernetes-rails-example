# Kubernetes ports explained: why everything is port 80

In `config/kube/deployment.yml` and `config/kube/load_balancer.yml`, `containerPort`, `targetPort` and `port` are all `80`. They're three different ports that happen to share a number. Each one belongs to a different "place" with its own network address, so they don't clash.

```
your Mac                Service (cluster IP)        Pod (own IP)
localhost:3000  ──►  port: 80  ──►  targetPort: 80 = containerPort: 80
(port-forward)       (load_balancer.yml)            Thruster ──► Puma on 3000
                                                    (inside the container)
```

## 1. `containerPort: 80` (deployment.yml)

```yaml
ports:
- containerPort: 80
```

This is the port the app listens on **inside the container**.

The `Dockerfile` starts the app with:

```dockerfile
CMD ["./bin/thrust", "./bin/rails", "server"]
```

[Thruster](https://github.com/basecamp/thruster) is a small proxy that listens on **port 80** by default and passes requests to Rails (Puma) on **port 3000** inside the same container. From outside the container, only port 80 is reachable. That's why a `containerPort` or `targetPort` of `3000` doesn't work.

`containerPort` is mostly documentation. It doesn't open or change anything; it just records which port the app uses.

## 2. `targetPort: 80` (load_balancer.yml)

```yaml
ports:
  - port: 80
    targetPort: 80
```

This is the port **on each pod** where the Service sends traffic. It must match the port the app actually listens on, which is `80`.

## 3. `port: 80` (load_balancer.yml)

This is the port the **Service itself** listens on, at its own cluster IP (and its external IP when `minikube tunnel` is running).

You can choose any number here. With `port: 8080`, you'd run `kubectl port-forward svc/kubernetes-rails-example-load-balancer 3000:8080`, and traffic would still reach pod port 80. Port 80 is just the standard HTTP port, so browsers don't need a port number in the URL.

## Why four replicas can all use port 80

Each pod gets **its own IP address**:

| Pod | Address |
|---|---|
| Pod A | `10.244.0.11:80` |
| Pod B | `10.244.0.12:80` |
| ... | ... |

Two programs can't share a port on the same address, but different addresses each have their own port 80. The Service has another address again and spreads requests across the pods.

## The port-forward command

```sh
kubectl port-forward svc/kubernetes-rails-example-load-balancer 3000:80
```

`3000:80` means "local port 3000 on my Mac → port 80 on the Service". The `3000` here is just a port on your Mac. It has nothing to do with Puma's port 3000 inside the container.

## Summary

| Setting | Where | Meaning | Can it change? |
|---|---|---|---|
| `containerPort` | deployment.yml | Port the app listens on in the container | Only if the app's listening port changes |
| `targetPort` | load_balancer.yml | Port on the pod that the Service sends traffic to | Must match `containerPort` |
| `port` | load_balancer.yml | Port the Service listens on | Any number you like |
| `3000` in `3000:80` | port-forward command | Port on your Mac | Any free local port |

The one number that can't change on its own is `targetPort`, because it has to match where the app listens (`containerPort`). The Service `port` and the local port-forward port are your choice.
