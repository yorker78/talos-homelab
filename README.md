# talos-homelab

A Talos Linux Kubernetes cluster on Proxmox VE, built entirely with Terraform and applied by CI.

- **bpg/proxmox** downloads the Talos nocloud image from the Image Factory and creates the VMs, with static IPs set through cloud-init.
- **siderolabs/talos** generates the cluster secrets, applies each node's machine config, bootstraps etcd and produces the kubeconfig.
- **Forgejo Actions** runs `terraform plan` on every pull request and `terraform apply` on merge to `main`. State stays on the runner and never enters git.

| Node    | Role          | IP           |
|---------|---------------|--------------|
| talos-1 | control plane | 192.168.1.20 |
| talos-2 | worker        | 192.168.1.21 |
| talos-3 | worker        | 192.168.1.22 |

Next: Flux for GitOps, MetalLB for LoadBalancer services, local-path storage.
