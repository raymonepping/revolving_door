# Kind on Podman: Multi-node Kubernetes cluster for this demo

This repo uses a local Kind cluster (running on Podman) to host the full demo stack.

## Cluster definition

The cluster is defined in `kind-podman-multinode.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: demo
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
  - role: worker
````

### What the port mapping does

* `hostPort: 8080` exposes port **8080** on your machine
* `containerPort: 30080` forwards that traffic into the **control-plane** node container
* This is typically used to reach an in-cluster Service via NodePort `30080` (or an ingress/controller listening on that NodePort)

## Prerequisites

You need:

* `podman`
* `kind`
* `kubectl`

Verify tools:

```bash
podman version
kind version
kubectl version --client=true
```

## Create the cluster

From the repo root:

```bash
kind create cluster --name demo --config kind-podman-multinode.yaml
```

Confirm it is reachable:

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

Expected output: 1 control-plane node and 4 workers.

## Delete the cluster

To tear down everything quickly:

```bash
kind delete cluster --name demo
```

## Notes

* The cluster name is `demo`. If you use multiple Kind clusters, keep that name consistent across scripts and docs.
* The host port mapping on `8080` is reserved by this cluster. If something else is already using 8080, cluster creation can fail. In that case, update `hostPort` in the YAML and re-create the cluster.
