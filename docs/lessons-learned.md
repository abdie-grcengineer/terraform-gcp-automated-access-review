# Lessons Learned (from the AWS build)

Carried forward to avoid repeating on GCP. Each entry: what bit us, why it happened, what to do differently.

---

## 1. CI hangs forever when a required variable has no default

**What bit us (AWS):** `recipient_email` had no default in `variables.tf`. Locally the value came from `terraform.tfvars`, but `*.tfvars` is gitignored, so CI checked out without any value. `terraform plan` defaulted to interactive prompt; runner has no TTY; plan hung for 20+ minutes per attempt.

**Apply on GCP:**
- Add `-input=false` to **every** `terraform plan` call in CI from day one. Forces a clean fail instead of a silent hang.
- Pass required variables via `TF_VAR_<name>` env vars sourced from GitHub secrets.
- Add a `RECIPIENT_EMAIL` secret to the GCP repo before the first CI run.

---

## 2. Workflow does not auto-trigger on the commit that introduces it

**What bit us (AWS):** When path filters are present in `on: push:`, GitHub Actions sometimes does not run the workflow on the commit that adds the workflow file. We had to push a follow-up commit to trigger the first run.

**Apply on GCP:**
- Include `workflow_dispatch:` in the `on:` block from the start so you can always trigger manually.
- Include `.github/workflows/terraform.yml` in the path filter so workflow file edits do trigger the workflow.

---

## 3. State lock contention from concurrent or cancelled runs

**What bit us (AWS):** Two parallel runs raced for the same state lock. One was cancelled mid-flight and left a stale `terraform.tfstate.tflock` in S3. Every subsequent run failed with `Error acquiring the state lock`.

**Apply on GCP:**
- GCS backend uses object generation numbers for locking; the equivalent is a stale lock object that needs deletion.
- If a run hangs, cancel cleanly first, then clear the lock object before triggering another. Do not let two CI runs race.
- For the demo, only trigger one workflow at a time.

---

## 4. Markdown auto-linking corrupts pasted code

**What bit us (AWS):** When the user copy-pasted from rendered markdown, anything that looked like a domain got auto-linked. `data.aws` became `[data.aws](http://data.aws)` and broke the .tf file. Same for `s3.tf`, `function.zip`, etc.

**Apply on GCP:**
- For any non-trivial file content, write it directly to disk using the file-writing tool. Don't ask the user to copy-paste from a code block in chat.
- For tiny snippets (a single line edit), pasting is fine.

---

## 5. Required service permissions take time to propagate

**What bit us (AWS):** Lambda creation can sit at "Still creating..." for 1-3 minutes after the IAM role is created, because the role's assumability flag is propagating across AWS's IAM plane.

**Apply on GCP:**
- Cloud Functions 2nd gen + Cloud Run + Cloud Build interactions can take similar time on first deploy.
- Service account binding propagation can take up to a few minutes.
- Don't ctrl-C a deploy that's "just sitting there" within the first 5 minutes. Wait it out.

---

## 6. API enablement is asynchronous even after the command returns

**Net new for GCP:**
- `gcloud services enable` returns when the request is accepted, not when the API is actually live.
- First `terraform apply` can occasionally fail with "API not enabled" errors because of this. Solution: wait 60 seconds after the enable command completes, or retry once.

---

## 7. Bucket-not-empty blocks bucket deletion

**What bit us (AWS):** Tearing down the CFN stack failed because the report bucket had reports in it. CFN does not auto-empty buckets.

**Apply on GCP:**
- GCS has the same behavior: `terraform destroy` fails on a non-empty bucket unless `force_destroy = true` is set on the resource.
- For a lab/demo, set `force_destroy = true` on the report bucket so cleanup works without manual intervention.
- For production, leave it false so accidental destroy doesn't delete audit evidence.

---

## 8. Resource name collisions between old and new deploys

**What bit us (AWS):** First Terraform deploy failed because the Lambda name `aws-access-review-access-review` already existed from the prior CloudFormation deploy. Forced a manual CFN stack delete first.

**Apply on GCP:**
- This project is greenfield in GCP, so no collision.
- But: every resource name in the Terraform should include the `name_prefix` variable so future redeploys to the same project can be parameterized to avoid collisions.

---

## 9. Files end up empty when pasted via heredoc with bad input

**What bit us (AWS):** `main.tf` and `terraform.tfvars.example` ended up as empty 0-byte files because the heredoc paste went wrong somewhere. Plan failed with "data resource not declared."

**Apply on GCP:**
- Always run `ls -la` after creating files via heredoc to verify file size.
- Better: write files directly using the file-writing tool. No heredoc round-trip.

---

## 10. fmt -check is silent on success but breaks shell chains on no-match

**Minor but caused confusion:** `grep -c "—" file` returns exit code 1 when count is 0. Chaining with `&&` then made the next command fail to run.

**Apply on GCP:**
- When chaining commands, be aware which commands return non-zero on "no match" (grep, find with no results) and use `|| true` or restructure the chain.

---

## 11. Cancelling a run mid-create leaves orphaned state

**What bit us (AWS):** A 22-minute hang during Lambda creation in CI. We cancelled. State sometimes ends up with a half-created resource entry that has to be `terraform state rm` removed before the next apply.

**Apply on GCP:**
- Don't cancel within the first 5 minutes of an apply.
- If you do, run `terraform state list` and look for resources you don't expect. Clean up with `terraform state rm` if needed.

---

## 12. Em dashes in written content

**Standing rule:** No em dashes anywhere in user-facing prose. Use commas, parens, or sentence breaks. (This is a personal style preference, not a project rule.)

---

## 13. Project number vs project ID confusion

**Net new for GCP:**
- Project ID (`gcp-access-review-1777695270`) and project number (`857439867682`) are both used.
- WIF resource names use **project number**.
- Most other commands use **project ID**.
- Easy to mix up; capture both as variables and use the correct one for each context.

---

## 14. Gmail API send quotas

**Net new for GCP:**
- Free Gmail accounts cap at 500 sends/day. Workspace accounts at 2000.
- Sandbox-equivalent issues in SES don't apply, but rate limits do.
- For a monthly access review, we are nowhere near the limit. Worth knowing for if the schedule got cranked up to daily.

---

## 15. Vertex AI region availability

**Net new for GCP:**
- Gemini 2.0 Flash is available in `us-central1`, `us-east5`, `europe-west1`, others. Not every region.
- Default to `us-central1` unless there's a specific reason otherwise.

---

## 16. Cloud Functions 2nd gen needs Eventarc API enabled

**Bit us on first deploy:** `terraform apply` failed creating the function with `Eventarc API has not been used`. The Pub/Sub trigger for Cloud Functions 2nd gen is implemented as an Eventarc trigger under the hood, and Eventarc needs its own API enabled.

**Fix added to `bootstrap_gcp.sh`:** added `eventarc.googleapis.com` to the API enablement list. Anyone running the bootstrap from scratch now gets it.

**Lesson:** Cloud Functions 2nd gen is built on Cloud Run + Eventarc + Cloud Build. Enable all three families of APIs even if you "only need" Cloud Functions.

---

## 17. Secret Manager secret resources need at least one version before a Cloud Function that mounts them can deploy

**Bit us on first deploy:** the function has `secret_environment_variables` referencing `version = "latest"`. Cloud Run validates the secret reference exists at deploy time, but the resource we created has no versions yet (we planned to populate it via `gmail_oauth_setup.sh` after deploy).

**Fix:** seed a placeholder version before the function is created. We did this manually with `gcloud secrets versions add ... --data-file=-` and a JSON placeholder value. The function then deploys cleanly. The OAuth setup script overwrites the placeholder with the real refresh token JSON.

**Lesson:** `secret_environment_variables` validates at deploy time, not at runtime. Either create the version before the function (in a bootstrap step), or create the secret + version together in Terraform with a sentinel value, or move the secret read to runtime via the Secret Manager SDK.

---

(Append new lessons here as they come up during the build.)
