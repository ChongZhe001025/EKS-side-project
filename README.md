EKS teardown script
-------------------

This repo includes a simple script to destroy the Terraform-provisioned EKS cluster and clean up local kubeconfig contexts.

Prerequisites:
- Terraform >= 1.5
- AWS CLI configured (AWS credentials and default region or provide --region)
- kubectl (optional, for kubeconfig cleanup)

Usage:
- Interactive confirmation:
	- ./scripts/destroy-eks.sh
- Non-interactive (CI-friendly):
	- ./scripts/destroy-eks.sh -y
- Specify infra dir or region if different:
	- ./scripts/destroy-eks.sh -y --infra-dir ./infra --region ap-southeast-2

Notes:
- The script auto-detects cluster_name and region from Terraform outputs or variables.tf.
- If destroy fails due to stuck cloud resources (e.g., load balancers), fix them in AWS Console and rerun.


EKS create script
-----------------

Automates Terraform apply, kubeconfig setup, and readiness checks.

Prerequisites:
- Terraform >= 1.5
- AWS CLI configured with credentials
- kubectl

Usage:
- Interactive:
	- ./scripts/create-eks.sh
- Non-interactive (CI):
	- ./scripts/create-eks.sh -y
- Specify region/cluster name:
	- ./scripts/create-eks.sh -y --region ap-southeast-2 --cluster-name sideproj-eks
- Also apply extra aws-auth mapping:
	- ./scripts/create-eks.sh -y --apply-aws-auth

Flags:
- --infra-dir DIR        Use a different Terraform directory (default: ./infra)
- --region REGION        Override AWS region
- --cluster-name NAME    Override cluster name
- --apply-aws-auth       kubectl apply -f infra/aws-auth.yaml after create
- --no-wait              Do not wait for nodes to be Ready

