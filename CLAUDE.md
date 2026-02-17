# auto-fastlane-spaceauth

## What This Is

Automated Fastlane spaceauth session management for App Store Connect CI/CD. AWS SAM-based serverless stack that automatically runs `fastlane spaceauth` including 2FA SMS verification, stores session cookies in AWS Secrets Manager, and provides `FASTLANE_SESSION` tokens for Bitrise CI/CD and other build pipelines. Eliminates manual session refresh by handling 2FA SMS via AWS Pinpoint.

## Tech Stack

- **Framework**: AWS Serverless Application Model (SAM)
- **Runtime**: Ruby 3.3 (main Lambda), Python 3.12 (SMS logger Lambda)
- **Language**: Ruby (`app.rb` — Fastlane Spaceship automation)
- **Services**: AWS Pinpoint (SMS), AWS Secrets Manager, AWS SNS, AWS SQS, AWS KMS, CloudWatch (metrics/alarms)
- **Automation**: Fastlane Spaceship (Ruby gem — monkey-patches `Spaceship::Client#ask_for_2fa_code`)
- **CI/CD Integration**: Bitrise, GitHub Actions (via `FASTLANE_SESSION` env var from Secrets Manager)

## Quick Start

```bash
# Required env vars for local testing
export SQS_QUEUE_URL="..."
export SPACESHIP_2FA_SMS_DEFAULT_PHONE_NUMBER="..."
export FASTLANE_USER="..."
export FASTLANE_PASSWORD="..."
export SECRETS_MANAGER_SECRET_ID="..."

# Test locally (switch to x86_64 in template.yaml for faster builds)
make test

# Deploy to AWS (requires AWS_REGION, AWS_ACCOUNT, FASTLANE_PASSWORD)
make deploy

# Delete stack
make delete
```

## Project Structure

```
auto-fastlane-spaceauth/
├── template.yaml            # SAM template (2 Lambdas, SQS, SNS, IAM, CloudWatch)
├── samconfig.toml           # SAM deployment config (container builds, stack name)
├── Makefile                 # Test/deploy/delete commands with env var guards
├── auto-fastlane-spaceauth/ # Main Lambda function source code
│   ├── app.rb               # Ruby handler: spaceauth + 2FA SQS polling + Secrets Manager
│   └── Gemfile              # Ruby dependencies (fastlane, aws-sdk-sqs, aws-sdk-secretsmanager)
├── README.md                # Setup guide (Secrets Manager, Pinpoint, Apple account)
└── LICENCE.md
```

## Authentication Flow

The end-to-end session refresh works as follows:

```
EventBridge (every 15 min)
    │
    ▼
FastlaneSpaceauth Lambda (Ruby 3.3)
    │
    ├─ 1. Fetch previous FASTLANE_SESSION from Secrets Manager
    │
    ├─ 2. Set FASTLANE_SESSION env var (so Spaceship can try the cached session)
    │
    ├─ 3. Run Spaceship::SpaceauthRunner
    │     │
    │     ├─ If cached session is valid → return same session (no 2FA needed)
    │     │
    │     └─ If session expired → login with Apple ID/password → Apple sends 2FA SMS
    │           │
    │           ▼
    │         Apple sends SMS to Pinpoint long code
    │           │
    │           ▼
    │         Pinpoint → SNS topic → SQS queue
    │           │                  └→ Fastlane2FaSmsLogger Lambda (logs SMS to CloudWatch)
    │           ▼
    │         Monkey-patched ask_for_2fa_code() polls SQS (20s long poll)
    │           │
    │           ▼
    │         Parse 6-digit code from SMS body via regex (/\d{6}/)
    │           │
    │           ▼
    │         Return code to Spaceship → completes 2FA → new session
    │
    ├─ 4. Compare new session with previous
    │     ├─ Different → save_session() to Secrets Manager
    │     └─ Same → skip write ("Session is still valid")
    │
    └─ 5. Return session in response (consumed by cross-account callers)
```

**Cross-account access:** Dev, QA, and Prod AWS accounts have `lambda:InvokeFunction` permission to force a session refresh on demand from CI/CD pipelines.

## Token Management

- **Storage**: `FASTLANE_SESSION` stored as a key in a JSON secret in AWS Secrets Manager
- **Encryption**: Customer-managed KMS key (`KmsKeyIdForSecretsManager`)
- **Refresh trigger**: EventBridge schedule (`rate(15 minutes)`) or cross-account Lambda invocation
- **Session validity**: Spaceship detects invalid sessions via `"Session loaded from environment variable is not valid"` log message (tracked by CloudWatch metric filter)
- **Rate limit protection**: CloudWatch alarm on `"Too many verification codes have been sent"` pattern, alerts via SNS email topic

**Secrets Manager secret structure** (JSON):
```json
{
  "FASTLANE_SESSION": "---\\n- !ruby/object:HTTP::Cookie\\n  ..."
}
```

## Dependencies

**AWS Resources (created by stack):**
- `FastlaneSpaceauthFunction` — Ruby 3.3 Lambda, ARM64, 150s timeout
- `Fastlane2FaSmsLoggerFunction` — Python 3.12 Lambda (inline code), ARM64, 3s timeout
- `SqsQueueForApple2FaSms` — SQS queue (SSE enabled, 120s retention)
- SNS subscriptions (SQS + Lambda)
- IAM roles with least-privilege policies
- CloudWatch log groups (7-day retention), metric filters, alarms

**AWS Resources (pre-existing, referenced by ARN):**
- Secrets Manager secret for `FASTLANE_SESSION`
- KMS key for Secrets Manager encryption
- Pinpoint long code phone number with 2-way SMS
- SNS topic for incoming Pinpoint SMS
- `EmailNotificationTopic` CloudFormation export (for alarm notifications)

**External Services:**
- Apple App Store Connect — authentication target
- Apple 2FA SMS delivery — sent to Pinpoint phone number

**Ruby Gems (Gemfile):**
- `fastlane` — Spaceship authentication library
- `aws-sdk-sqs` — SQS polling for 2FA codes
- `aws-sdk-secretsmanager` — session read/write

## API / Interface

**For CI/CD Pipelines (Bitrise, GitHub Actions):**
1. Read `FASTLANE_SESSION` from the Secrets Manager secret (parse JSON, extract `FASTLANE_SESSION` key)
2. Set as environment variable
3. Run Fastlane commands

```bash
# Extract FASTLANE_SESSION from JSON secret
export FASTLANE_SESSION=$(aws secretsmanager get-secret-value \
  --secret-id <secret-arn> \
  --query SecretString --output text | jq -r '.FASTLANE_SESSION')
fastlane beta
```

**Force refresh (cross-account):**
```bash
aws lambda invoke --function-name FastlaneSpaceauth /dev/stdout
```

## Deployment

**Prerequisites:**
1. Create Secrets Manager secret with KMS encryption (note ARN and KMS key ARN)
2. Buy AWS Pinpoint long code with 2-way SMS (Puerto Rico recommended — see [cost script](https://gist.github.com/return-main/b1c833e6385dd73d9261388ff7976dd8))
3. Enable 2-way SMS on the long code → create SNS topic (note ARN)
4. Add the Pinpoint phone number as a trusted number on the [Apple account](https://appleid.apple.com/)
5. Update `template.yaml` default parameters with your ARNs, phone number, and Apple ID email

**Deploy:**
```bash
export AWS_REGION="eu-west-1"
export AWS_ACCOUNT="501431420968"
export FASTLANE_PASSWORD="your_apple_password"
make deploy
```

**Stack name:** `auto-fastlane-spaceauth-stack` (from `samconfig.toml`)
**CloudFormation role:** `CloudFormationDeployRole` (IAM role in target account)
**Build:** Container-based (`use_container = true`), cached, parallel

## Testing

**Local testing (requires Docker for SAM container builds):**
```bash
# Set all required env vars first (see Quick Start)
make test
# Runs: sam build → sam local invoke FastlaneSpaceauthFunction
```

**What it does:** Invokes the Lambda locally. Requires a real SQS queue and Secrets Manager secret to be accessible (uses your AWS credentials).

**Manual Lambda invocation (deployed):**
```bash
aws lambda invoke --function-name FastlaneSpaceauth /dev/stdout
```

## Gotchas

- **ARM64 vs x86_64**: Lambda uses ARM64 in production (cheaper). Switch to x86_64 in `template.yaml` for local dev (10x faster SAM container builds on x86 machines)
- **Ruby 3.3 /tmp workaround**: Lambda's Ruby 3.3 runtime has a world-writable `/tmp` issue. The handler creates `/tmp/auto-fastlane-spaceauth` with 1777 permissions and overrides `TMPDIR`. See [Stack Overflow](https://stackoverflow.com/a/78886395/22189921)
- **Monkey-patching Spaceship**: `app.rb` overrides `Spaceship::Client#ask_for_2fa_code` to read from SQS instead of stdin. If Fastlane changes this interface, the override breaks silently
- **2FA code regex**: Parses 6-digit code via `/\d{6}/` — if Apple changes SMS format (e.g., adds other numbers), parsing may fail
- **SQS message retention**: Only 120 seconds — if Lambda cold start is slow or timing misaligns, the 2FA code may expire
- **15-minute schedule**: Every invocation with an expired session triggers a new 2FA SMS. Apple rate-limits verification codes. The alarm detects this but there is no circuit breaker
- **Pinpoint phone number**: Not all countries support 2-way SMS. Puerto Rico (PR) works. Number availability varies
- **Session expiry**: Apple sessions expire unpredictably (days to weeks). No way to check validity without attempting login
- **Cross-account invoke returns session**: The Lambda response body contains the raw `FASTLANE_SESSION` — anyone with invoke permission gets the session without needing Secrets Manager access
- **No Gemfile.lock**: Builds resolve latest gem versions from rubygems.org every time. Pin versions and commit lockfile
- **Hardcoded ARNs**: Real AWS account IDs, KMS key ARN, and phone number are in `template.yaml` defaults
- **Apple password in env var**: `FASTLANE_PASSWORD` is a Lambda environment variable (plaintext). Should be moved to Secrets Manager
- **`EmailNotificationTopic` import**: The CloudWatch alarm references a CloudFormation export `EmailNotificationTopic` — this must exist in the same region/account or the stack will fail to deploy

## Security Notes

- Session token encrypted at rest via KMS in Secrets Manager
- SQS queue uses managed SSE
- IAM roles scoped to specific resource ARNs
- Apple ID password passed via `NoEcho` CloudFormation parameter but stored as plaintext Lambda env var (see FINDINGS.md C1)
- 2FA codes logged to CloudWatch in plaintext (see FINDINGS.md H4)
- Cross-account permissions grant entire accounts invoke access (see FINDINGS.md H2)
- See `FINDINGS.md` for the full security audit with prioritized recommendations
