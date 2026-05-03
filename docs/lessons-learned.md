# Lessons Learned

Gotchas hit during the build, plus the patterns we adopted to prevent repeats. Each entry: what bit us, why it happened, what to do differently.

---

## 1. CI hangs forever when a required variable has no default

`recipient_email` had no default in `variables.tf`. Locally the value came from `terraform.tfvars`, but `*.tfvars` is gitignored, so CI checks out without any value. `terraform plan` defaulted to interactive prompt; runner has no TTY; plan would hang for 20+ minutes per attempt.

**Fix:**
- `-input=false` on every `terraform plan` call in CI. Forces a clean fail instead of a silent hang.
- Pass required variables via `TF_VAR_<name>` env vars sourced from GitHub secrets.
- Add a `RECIPIENT_EMAIL` and `GCP_PROJECT_ID` secret before the first CI run.

---

## 2. Workflow does not auto-trigger on the commit that introduces it

When path filters are present in `on: push:`, GitHub Actions sometimes does not run the workflow on the commit that adds the workflow file. Worth knowing for greenfield repos.

**Fix:**
- Include `workflow_dispatch:` in the `on:` block from the start so manual triggers are always available.
- Include `.github/workflows/terraform.yml` in the path filter so workflow file edits trigger the workflow.

---

## 3. State lock contention from concurrent or cancelled runs

If a CI run is cancelled mid-flight, GCS backend locking can leave a stale lock that blocks subsequent runs.

**Fix:**
- Don't trigger overlapping runs.
- If a run hangs, cancel cleanly first, then verify no stale lock remains before retrying.
- For the demo, only trigger one workflow at a time.

---

## 4. Markdown auto-linking corrupts pasted code

When copy-pasting from rendered markdown, anything that looks like a domain gets auto-linked. Patterns like `function.zip` can become `[function.zip](http://function.zip)` and break files.

**Fix:**
- For any non-trivial file content, write directly to disk via the file-writing tool. Don't ask the user to copy-paste from a code block in chat.
- For tiny snippets (a single line edit), pasting is fine.

---

## 5. Service account permissions take time to propagate

Cloud Functions 2nd gen + Cloud Run + Cloud Build interactions can take 1-3 minutes on first deploy. Service account binding propagation can take up to a few minutes.

**Fix:**
- Don't ctrl-C a deploy that's "just sitting there" within the first 5 minutes. Wait it out.

---

## 6. API enablement is asynchronous even after the command returns

`gcloud services enable` returns when the request is accepted, not when the API is actually live. First `terraform apply` can occasionally fail with "API not enabled" errors because of this.

**Fix:**
- Wait 60 seconds after the enable command completes, or retry once.

---

## 7. Bucket-not-empty blocks bucket deletion

GCS does not auto-empty buckets on `terraform destroy` unless the resource has `force_destroy = true`.

**Fix:**
- For a lab/demo, set `force_destroy = true` on the report bucket so cleanup works without manual intervention.
- For production, leave it false so accidental destroys do not delete audit evidence.

---

## 8. Files end up empty when pasted via heredoc with bad input

Heredoc paste can produce 0-byte files if any input goes wrong. Plan then fails with mysterious "data resource not declared" type errors.

**Fix:**
- Always run `ls -la` after creating files via heredoc to verify file size.
- Better: write files directly via the file-writing tool. No heredoc round-trip.

---

## 9. fmt -check is silent on success but breaks shell chains on no-match

`grep -c "—" file` returns exit code 1 when count is 0. Chaining with `&&` then makes the next command fail to run.

**Fix:**
- When chaining commands, be aware which commands return non-zero on "no match" (grep, find with no results) and use `|| true` or restructure the chain.

---

## 10. Cancelling a run mid-create leaves orphaned state

A 22-minute hang during Cloud Function creation in CI. After cancellation, state can end up with a half-created resource entry that has to be `terraform state rm` removed before the next apply.

**Fix:**
- Don't cancel within the first 5 minutes of an apply.
- If you do, run `terraform state list` and look for resources you don't expect. Clean up with `terraform state rm` if needed.

---

## 11. Em dashes in written content

**Standing rule:** No em dashes anywhere in user-facing prose. Use commas, parens, or sentence breaks.

---

## 12. Project number vs project ID confusion

Project ID (`gcp-access-review-1777695270`) and project number (`857439867682`) are both used.
- WIF resource names use **project number**.
- Most other commands use **project ID**.
- Easy to mix up; capture both as variables and use the correct one for each context.

---

## 13. Gmail API send quotas

Free Gmail accounts cap at 500 sends/day. Workspace accounts at 2000.
For a monthly access review, we are nowhere near the limit. Worth knowing if the schedule got cranked up to daily.

---

## 14. Vertex AI region availability

Gemini 1.5 Flash and 2.0 Flash are available in `us-central1`, `us-east5`, `europe-west1`, others. Not every region.
Default to `us-central1` unless there's a specific reason otherwise.

---

## 15. Cloud Functions 2nd gen needs Eventarc API enabled

First `terraform apply` failed creating the function with "Eventarc API has not been used." The Pub/Sub trigger for Cloud Functions 2nd gen is implemented as an Eventarc trigger under the hood, and Eventarc needs its own API enabled.

**Fix added to `bootstrap_gcp.sh`:** added `eventarc.googleapis.com` to the API enablement list.

**Lesson:** Cloud Functions 2nd gen is built on Cloud Run + Eventarc + Cloud Build. Enable all three families of APIs even if you "only need" Cloud Functions.

---

## 16. Secret Manager secret resources need at least one version before a Cloud Function that mounts them can deploy

The function has `secret_environment_variables` referencing `version = "latest"`. Cloud Run validates the secret reference exists at deploy time, but the resource we created had no versions yet (the OAuth setup script populates it after deploy).

**Fix:** seed a placeholder version before the function is created. The OAuth setup script overwrites the placeholder with the real refresh token JSON later.

**Lesson:** `secret_environment_variables` validates at deploy time, not at runtime. Either create the version before the function, or create the secret + version together in Terraform with a sentinel value, or move the secret read to runtime via the Secret Manager SDK.

---

## 17. Gemini 2.0 needs explicit access in fresh projects

First test invocation logged "Publisher Model `gemini-2.0-flash-001` was not found or your project does not have access." Newer Gemini 2.0 models require approval via Vertex Model Garden in fresh projects.

**Fix:** use `gemini-1.5-flash-002` which is GA and accessible by default. The fallback summary kicked in so the email still sent; just no AI narrative until the model swap.

**Lesson:** newer Vertex AI models often require Model Garden activation. Stick with GA models for default deploys.

---

## 18. Python package import paths can be confusing

The `google-cloud-iam` package does not expose `google.iam.admin_v1` the way some examples suggest. Service account key listing is not in the stable public Python client.

**Fix:** skip the SA key age check or implement via REST API. Don't trust autocomplete; verify against the package's actual `__init__.py` before depending on a module path.

---

## 19. Security Command Center is org-level by default

Project-level SCC requires the Premium tier. Free-tier projects fail SCC findings calls.

**Fix:** the function catches the 404 non-fatally and continues; the report still ships with IAM and audit log findings. For org-wide SCC, deploy the function with org-level service account permissions.

---

## 20. OAuth "Access blocked: Desktop did not complete verification"

External OAuth apps in "Testing" status only let listed test users authorize. Without your email on the test user list, you get this error during consent.

**Fix:** add the email to the OAuth consent screen's test user list before running the OAuth flow.

---

## 21. OAuth localhost redirect "refused to connect" is expected behavior

The redirect URI `http://localhost:8080` has nothing listening; the browser shows an error. The auth code is in the address bar and is what matters.

**Fix:** copy the URL from the address bar, not the page contents. The script then extracts the `code` parameter and exchanges it for tokens.

---

(Append new lessons here as they come up.)
