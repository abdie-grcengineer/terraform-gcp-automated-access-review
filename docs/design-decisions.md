# Design Decisions Log

Running list of key architectural choices for the GCP Automated Access Review. Each entry: what we picked, what we considered, why.

Use this file as the source of truth for "why didn't you do X?" interview questions.

---

## AI service for narrative summary: Gemini 1.5 Flash

**Picked:** Vertex AI Gemini 1.5 Flash

**Considered:**
- Gemini 2.0 Flash (newest, requires Model Garden access approval in fresh projects)
- Gemini 1.5 Pro
- Anthropic Claude on Vertex AI

**Why Gemini 1.5 Flash:**
- GA in `us-central1` and accessible by default in any project with Vertex AI API enabled
- Gemini 2.0 Flash returned 404 in fresh projects until Model Garden access was granted
- Right-sized for summarization workload; the task is summarizing a CSV of findings into a paragraph
- Cheaper than Pro for marginal quality lift on summarization

**Interview talking point:**
"I picked Flash deliberately for the summary workload. The task is summarization, which is Flash's design center. Using a larger model would be 10x the cost for marginal quality lift on a paragraph of findings. Right-sizing the model to the workload is a cost-and-performance discipline."

**Tradeoff:**
For a project requiring more sophisticated reasoning over findings (e.g., correlating events across logs), Pro or Ultra would be the right choice. For an executive summary of a flat list of findings, Flash is correct.

---

## Compute service: Cloud Functions 2nd gen

**Picked:** Cloud Functions 2nd gen

**Considered:**
- Cloud Run (more flexibility, container-based)
- Cloud Functions 1st gen (deprecated)
- App Engine (legacy)

**Why Cloud Functions 2nd gen:**
- Direct serverless model (upload Python, GCP runs it, pay-per-invocation)
- Built on Cloud Run under the hood, inheriting Cloud Run's runtime characteristics (longer timeouts, more memory)
- No container management overhead; just upload Python source
- 1st gen is being deprecated; new projects should default to 2nd gen

**Interview talking point:**
"Cloud Functions 2nd gen for a periodic batch workload like this access review. Cloud Run would be needed if I had long-running services or container-specific dependencies. For schedule-triggered short-lived work, Functions is the right fit."

---

## Email delivery: Gmail API

**Picked:** Gmail API with OAuth refresh token

**Considered:**
- SendGrid (third-party SaaS, cheapest setup)
- Mailgun (similar to SendGrid)
- Skip email and write only to GCS

**Why Gmail API:**
- GCP has no native managed transactional email service
- Uses your existing Gmail account; no third-party signup
- Free for personal use within Gmail send limits
- Native Google ecosystem integration

**Tradeoff:**
- Setup is involved: OAuth 2.0 dance, refresh token storage in Secret Manager
- Sender is your personal Gmail; not ideal for a real client deployment
- For the demo and learning, fine. For production, switch to a transactional email service.

---

## Authentication: Workload Identity Federation (WIF)

**Picked:** WIF, no service account keys

**Considered:**
- Service account JSON keys stored in GitHub Secrets (long-lived credentials, audit risk)

**Why WIF:**
- No long-lived credentials anywhere
- Tokens are short-lived, scoped per workflow run
- GitHub Actions presents an OIDC token to GCP STS, which exchanges it for short-lived service account impersonation credentials
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
- Built-in locking via object generation numbers; no separate lock table needed

---

## Identity bindings (GCP IAM model)

**Pattern:** GCP IAM uses role bindings.

You bind a principal (user, service account, group) to a predefined or custom role at a resource scope (project, folder, org, individual resource). The "policy" on a resource is the union of all bindings at all relevant scopes.

**Use predefined roles** where possible. They are maintained by Google, audited, and named consistently. Custom roles are an option when finer-grained control is needed but introduce maintenance overhead.

**Implication for OPA policies:** the Rego policies target `google_project_iam_member` and `google_storage_bucket_iam_binding` for least-privilege checks.

---

## OPA policies

| Policy | Control mapping |
| --- | --- |
| `iam_no_owner.rego` | NIST 800-53 AC-6 / CMMC AC.L2-3.1.5 (no primitive role bindings) |
| `gcs_uniform_access.rego` | NIST 800-53 AC-3, SC-7 / CMMC AC.L2-3.1.3 (UBLA + public access prevention) |
| `gcs_encryption.rego` | NIST 800-53 SC-28 / CMMC SC.L2-3.13.16 (versioning enforced) |

The control documentation is the policy file. Each rule lives at `policy/*.rego` with a header comment naming the control it satisfies.

---

(Append new decisions here as we make them.)
