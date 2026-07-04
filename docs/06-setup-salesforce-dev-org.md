# Salesforce Developer Org — setup guide

## Short answers
- **Is it free?** Yes. A **Salesforce Developer Edition** org is free forever,
  no credit card, instant signup.
- **Do I install anything on macOS?** **No.** A Developer org is a *cloud* org —
  you use it entirely in the browser. There is nothing to install to get a
  working org with Cases and an API. (A local `sf` CLI is optional and only a
  convenience — see the bottom of this doc.)
- **Alternative if I don't want Salesforce?** You could mock the Case→Owner
  lookup with a DynamoDB table, but the plan deliberately avoids that: a real
  CCaaS-replacement demo audience won't be convinced by a fake Salesforce.
  Since the real one is free and takes ~10 minutes, use the real one.

---

## Step 1 — Create the free Developer org
1. Go to **https://developer.salesforce.com/signup**
2. Fill in name / email / a made-up company; pick a unique username (it must
   look like an email but does **not** need to be a real address, e.g.
   `you@evolvity-poc.dev`). Save this username — it's your login.
3. Check your email, click the activation link, set a password.
4. You're now in **Lightning Experience** in the browser. That's the whole org —
   nothing to install.

## Step 2 — Note your login URL
For a Developer Edition org the OAuth login URL is:
> `https://login.salesforce.com`
(*not* `test.salesforce.com` — that's only for sandboxes.)

## Step 3 — Create an External Client App (for API access via Client Credentials)
The Lambda authenticates with the **Client Credentials OAuth flow** (no user
interaction), so it needs an app with a `client_id` / `client_secret`.

> **Note on app type:** newer Salesforce orgs have removed classic "Connected
> App" creation from App Manager — you'll only see **New Lightning App** and
> **New External Client App**. Use **External Client Apps (ECA)**, the modern
> replacement; it fully supports the Client Credentials flow. (If your org still
> shows **New Connected App**, that path also works — the field names are nearly
> identical.)

> **Naming:** keep the app name **generic/company-neutral** (e.g.
> `Email Case Router`). Reserve "PCNA" for demo email copy and agent prompts
> only, so the demo re-skins easily for other prospects.

### 3a. Create the app
1. **Setup** (gear icon) → Quick Find → **External Client App Manager** →
   **New External Client App**.
2. **Basic Information:**
   - **External Client App Name:** `Email Case Router`
   - **API Name:** auto-fills — leave it.
   - **Contact Email:** your email.
   - **Distribution State:** **Local** (used only inside this org).

### 3b. Enable OAuth (API settings)
Expand **API (Enable OAuth Settings)**:
1. Check **☑ Enable OAuth**.
2. **Callback URL:** `https://login.salesforce.com/services/oauth2/callback`
   (required placeholder; Client Credentials never uses it).
3. **Selected OAuth Scopes:** move to the right list:
   - **Manage user data via APIs (api)** — required
   - *(optional)* **Perform requests at any time (refresh_token, offline_access)**
4. Leave the **PKCE** / "require secret for Web Server Flow" options at their
   defaults — they don't affect Client Credentials.
5. **Create** the app.

### 3c. Enable the Client Credentials Flow + set the Run As user
This is the mandatory part for Client Credentials, and in an ECA it lives under
**Policies** (not the create form):
1. Open the app → **Policies** tab → **Edit**.
2. Expand **OAuth Policies** → **App Authorization** (or **Flow Enablement**).
3. Check **☑ Enable Client Credentials Flow**.
4. Set **Run As** to a user with API access that can **read Case** records — your
   admin user is fine for a POC.
5. **Save.** Allow ~2–10 minutes to propagate.

### 3d. Get the credentials (client_id / client_secret)
1. Open the app → **Settings** tab → **OAuth Settings** section.
2. Under **Consumer Key and Secret**, click **Reveal** / **Consumer Details**
   (you may need to confirm via an emailed verification code).
3. Copy the **Consumer Key** → this is your **`client_id`**.
4. Copy the **Consumer Secret** → this is your **`client_secret`**.

You'll put these into AWS Secrets Manager after deploy (`login_url` = your My
Domain host — see Step 5):
```bash
aws secretsmanager put-secret-value \
  --secret-id "<InstanceAlias>-salesforce-credentials" \
  --secret-string '{"client_id":"<consumer_key>","client_secret":"<consumer_secret>","login_url":"https://orgfarm-ad53113bc6-dev-ed.develop.my.salesforce.com"}' \
  --region us-west-2
```

## Step 4 — Create sample Case records for the demo
1. In the app launcher (grid icon) open **Service** (or **Cases**).
2. Create 2–3 **Cases**. Salesforce auto-assigns each a **Case Number** like
   `00001001`. Set an **Owner** (assign different owners to show routing).
3. **Write the Case Numbers down** — you'll put them in test email subjects,
   e.g. `RE: Case #00001001 - order question`.

## Step 5 — (Optional) Sanity-check the API from your Mac
You can confirm the Client Credentials flow works before wiring the Lambda.

> **Token endpoint — use your My Domain URL, not `login.salesforce.com`.**
> Modern orgs (and ECAs) require the Client Credentials token request to go to
> the org's My Domain host. For this org that is:
> `https://orgfarm-ad53113bc6-dev-ed.develop.my.salesforce.com`
> Set the same value as `login_url` in the AWS secret below. (If a call returns
> `invalid_client_id` / `unsupported_grant_type`, you're almost certainly hitting
> the wrong host.)

```bash
MYDOMAIN="https://orgfarm-ad53113bc6-dev-ed.develop.my.salesforce.com"

# Get a token
curl -s "$MYDOMAIN/services/oauth2/token" \
  -d grant_type=client_credentials \
  -d client_id='<consumer_key>' \
  -d client_secret='<consumer_secret>'
# -> JSON with access_token and instance_url

# Query a case (use the instance_url + access_token from above)
curl -s "<instance_url>/services/data/v60.0/query?q=SELECT+Id,CaseNumber,OwnerId,Owner.Name+FROM+Case+WHERE+CaseNumber='00001001'" \
  -H "Authorization: Bearer <access_token>"
```
If that returns your case with `Owner.Name`, the Lambda will work.

---

## Optional: Salesforce CLI on macOS (only if you like CLI workflows)
Not required for this POC, but handy for scripting/data loading:
```bash
brew install --cask sf   # Salesforce CLI ("sf")
sf org login web         # opens browser to authorize your dev org
```
This does **not** replace anything above — the org itself is still cloud-based.
