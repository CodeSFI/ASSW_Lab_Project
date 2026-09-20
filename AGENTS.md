# AGENTS.md — Secure E-Commerce Infrastructure (OpenStack)

## Project Overview
5-VM OpenStack deployment with defense-in-depth networking:
- **DMZ** (10.10.10.0/24): `lb-proxy-cantabrico-01` — Nginx + ModSecurity WAF, public Floating IP
- **App** (10.10.20.0/24): `srv-ecommerce-app01/02` — Mock API nodes, no public access
- **Data** (10.10.30.0/24, **no gateway**): `srv-db-core01` — PostgreSQL, isolated
- **Mgmt** (10.10.99.0/24): `bastion-ops-cantabrico` — SSH jump host, public Floating IP (port 22)

Only LB and Bastion have Floating IPs. All internal SSH restricted to Mgmt subnet.

## Repository Structure
```
terraform/          # Infrastructure provisioning (IMPLEMENTED)
ansible/            # Configuration management (NOT YET IMPLEMENTED)
scripts/            # Deployment & validation scripts (NOT YET IMPLEMENTED)
docs/               # Documentation (NOT YET IMPLEMENTED)
```

## Developer Commands

### Terraform (Infrastructure)
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars  # Edit with real credentials
terraform init
terraform apply -auto-approve
terraform output  # Shows Floating IPs for LB and Bastion
```

### Ansible (Configuration) — Future
```bash
cd ansible
ansible-playbook -i inventory.ini site.yml --ask-vault-pass
```

## Key Conventions
- **Variables**: All secrets in `terraform.tfvars` (gitignored), Ansible Vault for runtime secrets
- **Naming**: Prefix `cantabrico-` on all resources (from `var.project_prefix`)
- **Security Groups**: 
  - `sg-lb`: HTTP/HTTPS from 0.0.0.0/0
  - `sg-bastion`: SSH from 0.0.0.0/0 (restrict in production)
  - `sg-internal`: SSH from mgmt-net only, HTTP 8080 from DMZ only, PostgreSQL 5432 from App only
- **Data subnet**: `no_gateway = true` — strict isolation, no Internet egress
- **Key pair**: `Lab_project` (must exist in OpenStack before `terraform apply`)

## Architecture Notes
- Router (`edge-router`) connects DMZ, Mgmt, App to external network via SNAT
- Data net **not connected to router** — completely isolated
- Bastion is the **only** SSH entry point; all Ansible runs via ProxyJump through Bastion
- App nodes use `count = 2` for HA demonstration
- Ubuntu 22.04 base image, flavor `ephym_small_2`

## Verification Steps (Post-Deploy)
1. Access `https://<LB_FLOATING_IP>/` — should serve via Nginx/WAF
2. SSH to Bastion Floating IP, then ProxyJump to internal nodes via Mgmt IPs
3. Verify DB unreachable from DMZ/App public interfaces
4. Run `scripts/test_security.sh` (when implemented) for WAF/isolation tests

## OpenStack Environment
- Auth URL: `http://156.35.95.9:5000/v3`
- Region: `RegionOne`
- External network: `public`
- Domain: `Default`