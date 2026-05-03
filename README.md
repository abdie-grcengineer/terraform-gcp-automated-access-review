# GCP Automated Access Review

Continuous GCP security posture assessment with policy-as-code guardrails. Built natively on Google Cloud Platform.

The system runs on a schedule, pulls findings from native GCP security services, summarizes them with Vertex AI Gemini, archives a CSV in Cloud Storage, and delivers the report by email via the Gmail API. Every infrastructure change is validated against NIST 800-53 / CMMC controls before it touches GCP.

## Why this is GRC engineering

The control IS the code. Infrastructure as code defines the system, policy as code enforces the rules, CI runs the gate on every change. Compliance ships in the same pipeline as the system.

## Architecture

```
                                  ┌─────────────────────────────────────────┐
                                  │  Native GCP Security Sources            │
                                  │   - Cloud IAM (bindings, SAs, keys)      │
                                  │   - Security Command Center             │
                                  │   - Cloud Audit Logs                    │
                                  │   - Recommender (IAM right-sizing)      │
                                  │   - Resource Manager (project/folder)   │
                                  └──────────────┬──────────────────────────┘
                                                 │ read-only
   ┌─────────────────────┐                       │
   │ Cloud Scheduler     │                       ▼
   │ (every 30 days)     │ publish      ┌──────────────────┐
   │                     ├─────────────►│ Pub/Sub topic    │
   └─────────────────────┘              └─────────┬────────┘
                                                  │
                                                  ▼
                                        ┌──────────────────┐
                                        │ Cloud Function   │
                                        │ 2nd gen (Python) │
                                        │ 512 MB, 9 min    │
                                        └────┬──┬─────┬────┘
                                             │  │     │
                       ┌─────────────────────┘  │     └────────────────────┐
                       ▼                        ▼                          ▼
            ┌─────────────────────┐  ┌────────────────────┐  ┌──────────────────────┐
            │ Vertex AI           │  │ GCS (encrypted,    │  │ Gmail API            │
            │ Gemini 2.0 Flash    │  │ versioned, 90-day  │  │ (OAuth refresh token │
            │ (narrative summary) │  │ lifecycle)         │  │ in Secret Manager)   │
            └─────────────────────┘  └────────────────────┘  └──────────────────────┘
```

## Compliance controls enforced

| Policy | NIST 800-53 / CMMC mapping |
| --- | --- |
| `policy/iam_no_owner.rego` | AC-6 Least Privilege / CMMC AC.L2-3.1.5 |
| `policy/gcs_uniform_access.rego` | AC-3 Access Enforcement / CMMC AC.L2-3.1.3 |
| `policy/gcs_encryption.rego` | SC-28 Protection at Rest / CMMC SC.L2-3.13.16 |

## Repository layout

```
.
├── terraform/                 IaC for GCS, IAM, Function, Scheduler, Pub/Sub
├── policy/                    OPA/Rego policies enforcing NIST/CMMC controls
├── scripts/                   bootstrap and operational wrappers
├── src/function/              Python Cloud Function 2nd gen implementation
├── docs/                      design decisions, lessons learned, study material
└── .github/workflows/         CI: WIF auth, fmt, tflint, plan, OPA gate, apply
```

## Tech stack

| Layer | Choice |
| --- | --- |
| Infrastructure as Code | Terraform >= 1.10 with `hashicorp/google` v5 provider |
| State management | Google Cloud Storage backend with native object-generation locking |
| Policy as Code | OPA / Conftest with Rego v1 |
| CI/CD | GitHub Actions |
| Cloud auth (CI) | Workload Identity Federation (no long-lived credentials in GitHub) |
| Compute | Cloud Functions 2nd gen (Python 3.12) |
| Scheduler | Cloud Scheduler + Pub/Sub |
| AI summary | Vertex AI Gemini 2.0 Flash |
| Storage | Cloud Storage with UBLA, versioning, 90-day lifecycle |
| Email | Gmail API via OAuth refresh token |
| Secret store | Secret Manager (Gmail OAuth refresh token) |

## Prerequisites

- GCP account with billing enabled
- gcloud CLI authenticated (`gcloud auth login` and `gcloud auth application-default login`)
- Terraform >= 1.10
- [Conftest](https://www.conftest.dev/) (`brew install conftest`)
- A Gmail account for OAuth send (or any Gmail Workspace account)
- Vertex AI Gemini access enabled in your project (automatic when Vertex API is enabled)

## One-time bootstrap (already done in this account)

The `scripts/bootstrap_gcp.sh` script provisions:
- A GCS bucket for Terraform state (versioned)
- A Workload Identity Pool and Provider trusted by GitHub
- A service account for GitHub Actions to impersonate

It is idempotent. Re-running on a fresh account creates everything; re-running on an existing setup is a no-op.

## Quick start

```bash
# 1. Configure your inputs
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set recipient_email, project_id

# 2. Initialize Terraform (connects to the GCS state backend)
terraform init

# 3. Deploy with the policy gate
cd ..
./scripts/tf_deploy.sh

# 4. Trigger an immediate report
./scripts/tf_run_report.sh
```

## CI/CD

The GitHub Actions workflow at `.github/workflows/terraform.yml` runs on every PR and every push to `main`:

1. Checkout
2. Authenticate to GCP via Workload Identity Federation (no stored credentials)
3. `terraform fmt -check`
4. `tflint`
5. `terraform plan -input=false`
6. Conftest evaluates all policies under `policy/`
7. Plan artifact uploaded for audit retention
8. Apply, only on push to main, only if all gates pass

## License

MIT
