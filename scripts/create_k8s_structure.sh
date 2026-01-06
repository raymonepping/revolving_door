#!/bin/bash

echo "Creating Kubernetes directory structure..."

# 1. Create the directory tree
mkdir -p k8s/10-backend
mkdir -p k8s/20-frontend
mkdir -p k8s/30-ingress
mkdir -p k8s/40-door-operator

# 2. Create Backend files
touch k8s/10-backend/00-serviceaccount.yaml
touch k8s/10-backend/10-configmap-app.yaml
touch k8s/10-backend/20-deployment.yaml
touch k8s/10-backend/30-service.yaml

# 3. Create Frontend files
touch k8s/20-frontend/10-configmap-index.yaml
touch k8s/20-frontend/20-deployment.yaml
touch k8s/20-frontend/30-service.yaml

# 4. Create Ingress files
touch k8s/30-ingress/10-ingress-demo.yaml

# 5. Create Door Operator files
touch k8s/40-door-operator/00-rbac.yaml
touch k8s/40-door-operator/10-cronjob-door-open.yaml
touch k8s/40-door-operator/20-cronjob-door-close.yaml

echo "Done! Structure created in ./k8s"
