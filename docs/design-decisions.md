# Design Decisions Log

Running list of key architectural choices for the GCP version of Automated Access Review. Each entry: what we picked, what we considered, why.

Use this file as the source of truth when generating study materials. Every "why didn't you do X?" interview question should have an answer here.

---

## AI service for narrative summary: Gemini 2.0 Flash

**Picked:** Gemini 2.0 Flash via Vertex AI

**Considered:**
- Claude Haiku 4.5 on Vertex AI (continuity with the AWS version which used Bedrock + Haiku)
- Gemini 2.0 Pro
- Larger Claude models (Sonnet, Opus) on Vertex

**Why Gemini Flash:**
- GCP-native, no model access request needed (Claude on Vertex requires manual Anthropic approval)
- Cheapest option for summarization workload (the task is summarize a CSV of findings into a paragraph)
- Right-sized: Flash is purpose-built for fast, cheap, high-volume inference. Pro and Opus would be overkill for summarization.
- Removes external dependency (the Anthropic approval queue could delay deployment)

**Interview talking point:**
"I picked Gemini Flash for the summary workload deliberately. The task is summarization, which is Flash's design center. Using a larger model would be 10x the cost for marginal quality lift on a paragraph of findings. Right-sizing the model to the workload is a cost-and-performance discipline, same way I picked Haiku on Bedrock for the AWS version."

**Tradeoff acknowledged:**
Loses cross-cloud model continuity. If the goal were to demonstrate the same Claude prompts working on both clouds, sticking with Claude on Vertex would be the answer. But the project's outcome is GRC reports, not LLM portability, so Gemini Flash is correct.

---

## Compute service: Cloud Functions 2nd gen

**Picked:** Cloud Functions 2nd gen

**Considered:**
- Cloud Run (more flexibility, container-based)
- Cloud Functions 1st gen (deprecated)
- App Engine (legacy)

**Why Cloud Functions 2nd gen:**
- Direct equivalent to AWS Lambda (upload code, GCP runs it, pay-per-invocation)
- 2nd gen is built on Cloud Run under the hood, so it inherits Cloud Run's better defaults (longer timeouts, more memory)
- No container management overhead; just upload Python
- 1st gen is being deprecated; new projects should default to 2nd gen

**Interview talking point:**
"Cloud Functions 2nd gen is the GCP equivalent of Lambda. It's built on Cloud Run, so it gets Cloud Run's runtime characteristics, but presents the same upload-code-and-run model. For a periodic batch workload like this access review, that's the right fit. Cloud Run would be needed if I had long-running services or container-specific dependencies."

---

## Email delivery: Gmail API

**Picked:** Gmail API

**Considered:**
- SendGrid (third-party SaaS, cheapest setup)
- Mailgun (similar to SendGrid)
- Skip email and write only to GCS

**Why Gmail API:**
- Uses your existing Gmail account; no third-party signup
- Free for personal use within Gmail send limits
- Native Google ecosystem integration

**Tradeoff:**
- Setup is more involved than SendGrid (OAuth 2.0 dance, refresh token storage in Secret Manager)
- Sender is your personal Gmail; not ideal for a real client deployment
- For the demo and learning, fine. For production, switch to a transactional email service.

---

## Authentication: Workload Identity Federation (WIF)

**Picked:** WIF, no service account keys

**Considered:**
- Service account JSON keys stored in GitHub Secrets (the equivalent of long-lived AWS access keys)

**Why WIF:**
- No long-lived credentials anywhere
- Tokens are short-lived, scoped per workflow run
- Same security model as AWS OIDC: GitHub OIDC token presented to GCP STS, exchanged for impersonation credentials
- Maps to NIST 800-53 IA-2(8) for replay-resistant authentication

**Two-layer security:**
1. WIF Provider has `attribute_condition` restricting tokens to assertions where `repository_owner == 'abdie-grcengineer'`. Even forks of the repo get rejected at the provider level.
2. Service account IAM binding restricts impersonation to the specific repo path `abdie-grcengineer/terraform-gcp-automated-access-review`. Defense in depth.

---

## State backend: GCS with versioning

**Picked:** Google Cloud Storage backend, versioning enabled

**Considered:**
- Terraform Cloud (managed)
- Local state (insecure for team use)

**Why GCS:**
- Native GCP, no third-party dependency
- Versioning provides rollback for state corruption
- Encryption is automatic with Google-managed keys (default behavior)
- Built-in locking via object generation numbers; no separate lock table needed (similar to S3 `use_lockfile` but Terraform's GCS backend has had native locking since the beginning)

**AWS comparison:** S3 backend in the AWS version uses `use_lockfile = true` (Terraform 1.10+) for native locking. GCS backend doesn't need an explicit flag; native locking is the default behavior.

---

## Identity bindings vs inline policies

**Pattern:** GCP IAM uses role bindings; AWS IAM uses inline policies. Different mental model.

In AWS, a role has a trust policy and one or more permissions policies attached directly to the role.

In GCP, you bind a principal (user, service account, group) to a predefined or custom role at a resource scope (project, folder, org). The "policy" is the union of all bindings at all relevant scopes.

**Implication for OPA policies:** the Rego policies need to target `google_project_iam_member`, `google_storage_bucket_iam_binding`, etc., not `aws_iam_role_policy`. Same conceptual checks, different resource type names.

---

## OPA policies (planned, not yet built)

Policies will mirror the AWS version's coverage but adapted to GCP resource types:

| AWS policy | GCP equivalent |
|---|---|
| `iam_no_wildcard.rego` (no `*:*`) | `iam_no_owner.rego` (no `roles/owner` bindings on principals other than the project owner) |
| `s3_public_access.rego` | `gcs_uniform_access.rego` (UBLA must be enabled) |
| `s3_encryption.rego` | `gcs_encryption.rego` (CMEK or default Google-managed keys) |

Same NIST 800-53 mappings: AC-3, AC-6, SC-7, SC-28.

---

(Append new decisions here as we make them.)
