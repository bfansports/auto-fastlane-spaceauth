# auto-fastlane-spaceauth

## What This Is

Automated Fastlane spaceauth session management for App Store Connect CI/CD. AWS SAM-based serverless stack that automatically runs `fastlane spaceauth` including 2FA SMS verification, stores session cookies in AWS Secrets Manager, and provides `FASTLANE_SESSION` tokens for Bitrise CI/CD and other build pipelines. Eliminates manual session refresh by handling 2FA SMS via AWS Pinpoint.

## Tech Stack

- **Framework**: AWS Serverless Application Model (SAM)
- **Runtime**: Python (AWS Lambda)
- **Services**: AWS Pinpoint (SMS), AWS Secrets Manager, AWS SNS, AWS KMS
- **Automation**: Fastlane Spaceship
- **CI/CD Integration**: Bitrise, GitHub Actions (via FASTLANE_SESSION env var)

## Quick Start

```bash
# Test locally (x86_64 recommended for faster builds)
make test

# Deploy to AWS
make deploy

# Delete stack
make delete
```

<!-- Ask: What Lambda function runtime/version is used? Python 3.9? 3.11? -->
<!-- Ask: How often does the Lambda run? EventBridge schedule? On-demand? -->
<!-- Ask: What triggers the session refresh? Expiry detection? Fixed schedule? -->

## Project Structure

```
auto-fastlane-spaceauth/
├── template.yaml            # SAM template (Lambda, Pinpoint, Secrets Manager)
├── samconfig.toml           # SAM deployment config
├── Makefile                 # Test/deploy/delete commands
├── auto-fastlane-spaceauth/ # Lambda function source code
│   └── ...                  # Python handler, 2FA SMS parsing
└── README.md
```

## Dependencies

**AWS Resources:**
- Secrets Manager — stores `FASTLANE_SESSION` cookie
- KMS — encrypts Secrets Manager secret
- Pinpoint — receives 2FA SMS from Apple
- SNS — Pinpoint → Lambda event delivery
- Lambda — automation logic
- IAM roles — Lambda permissions

**External Services:**
- App Store Connect — Fastlane authentication target
- Apple 2FA SMS — sent to Pinpoint phone number

**Python Libraries:**
- fastlane spaceship (Ruby gem called from Python)
- boto3 (AWS SDK)

<!-- Ask: Is there a requirements.txt or layer for Python/Ruby dependencies? -->

## API / Interface

**For CI/CD Pipelines:**
1. Read `FASTLANE_SESSION` from AWS Secrets Manager
2. Set as environment variable
3. Run Fastlane commands (upload to TestFlight, etc.)

**Example (Bitrise/GitHub Actions):**
```bash
export FASTLANE_SESSION=$(aws secretsmanager get-secret-value \
  --secret-id <secret-arn> \
  --query SecretString --output text)
fastlane beta  # Upload to TestFlight
```

## Key Patterns

- **Serverless Automation**: No manual intervention for App Store Connect session refresh
- **2FA via SMS**: Pinpoint long code receives Apple 2FA SMS → SNS → Lambda
- **Session Storage**: Encrypted session token in Secrets Manager
- **CI/CD Integration**: Pipelines fetch session from Secrets Manager on-demand
- **Cost Optimization**: Lambda ARM64 for production, x86_64 for local dev (build speed)

## Environment

**AWS Secrets Manager:**
- Secret ARN configured in template.yaml
- KMS key ARN for encryption

**AWS Pinpoint:**
- Long code phone number (Puerto Rico or other country with 2-way SMS)
- SNS topic for incoming SMS delivery
- Apple 2FA SMS sent to this number

**Template Parameters (customize in template.yaml):**
- `SecretsManagerSecretId` — ARN of secret to store `FASTLANE_SESSION`
- `KmsKeyIdForSecretsManager` — KMS key ARN
- `Spaceship2FaSmsDefaultPhoneNumber` — Pinpoint long code
- `SnsTopicArn` — SNS topic for SMS delivery

<!-- Ask: What are the Apple ID credentials? Stored in same Secrets Manager secret? -->

## Deployment

**Prerequisites:**
1. Create Secrets Manager secret for `FASTLANE_SESSION`
2. Buy AWS Pinpoint long code with 2-way SMS (use cheapest country script)
3. Enable 2-way SMS → SNS topic
4. Update template.yaml parameters with ARNs

**Deploy:**
```bash
make deploy
```

**Stack Resources:**
- Lambda function (Fastlane automation)
- SNS subscription (Pinpoint SMS → Lambda)
- IAM roles (Lambda → Secrets Manager, KMS, SNS)

<!-- Ask: Is there a scheduled refresh? Or triggered manually? -->
<!-- Ask: How does the Lambda know when to refresh (session expiry detection)? -->

## Testing

**Local Testing:**
```bash
make test
```

**Test Workflow:**
1. Lambda receives SNS event (simulated)
2. Parses 2FA SMS code
3. Runs fastlane spaceauth with code
4. Stores session in Secrets Manager

**Manual Trigger:**
<!-- Ask: Can you manually invoke the Lambda to force refresh? -->

## Gotchas

- **ARM64 vs x86_64**: Lambda ARM64 is cheaper but slower builds locally; switch to x86_64 for dev
- **Pinpoint Phone Number Availability**: Not all countries support 2-way SMS; use PR (Puerto Rico) if needed
- **SMS Costs**: Pay per incoming SMS; monitor Pinpoint usage
- **Session Expiry**: Apple sessions expire unpredictably; Lambda must detect and refresh
- **KMS Encryption**: If not using KMS, remove KMS permissions from template
- **Security Admin Role**: Google Cloud credentials need `Security Admin` for cross-project access
- **Fastlane Spaceship**: Requires Ruby environment in Lambda (use Lambda Layer or container)
- **SNS Topic Permissions**: Lambda must have permission to subscribe to SNS topic
- **Secret ARN Format**: Must match exact format in template.yaml
- **2FA Code Parsing**: SMS format changes may break code extraction logic
- **Bitrise Integration**: Bitrise must have IAM credentials to read from Secrets Manager