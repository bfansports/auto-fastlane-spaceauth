# Security Audit: auto-fastlane-spaceauth

**Date:** 2026-02-17
**Auditor:** AI DevOps Agent (bFAN Sports)
**Scope:** Session token security, Apple ID credentials, 2FA automation risks, token rotation, secrets storage
**Repo:** bfansports/auto-fastlane-spaceauth (branch: main)

---

## Critical

### C1. Apple ID Password Exposed in Lambda Environment Variables

**File:** `template.yaml` lines 162-166
**Risk:** Credential theft via Lambda console, API, or memory dump

The `FASTLANE_PASSWORD` is passed as a CloudFormation parameter (`NoEcho: true`) but then set as a **plaintext Lambda environment variable**:

```yaml
Environment:
  Variables:
    FASTLANE_PASSWORD: !Ref FastlanePassword
```

Anyone with `lambda:GetFunctionConfiguration` permission can read it. CloudFormation `NoEcho` only hides the value in CloudFormation console/API outputs — it does not encrypt the value at rest in the Lambda service. The password is also visible in the Lambda console's Configuration tab.

**Recommendation:**
- Store the Apple ID password in Secrets Manager (same secret or separate).
- Modify `app.rb` to fetch the password at runtime from Secrets Manager instead of reading `ENV["FASTLANE_PASSWORD"]`.
- Remove the `FastlanePassword` parameter and the `FASTLANE_PASSWORD` environment variable entirely.
- The Lambda already has Secrets Manager read permissions, so no IAM changes are needed.

### C2. FASTLANE_SESSION Returned in Lambda Response Body

**File:** `app.rb` lines 116-118
**Risk:** Session token leakage via CloudWatch logs, cross-account callers, or API responses

```ruby
return {
    FASTLANE_SESSION: new_fastlane_session,
}
```

The Lambda returns the full session token in its response. This means:
- Cross-account invocations (dev, QA, prod accounts all have `lambda:InvokeFunction`) receive the raw session token in the response payload.
- If CloudWatch logging is enabled for Lambda responses (or if the caller logs the response), the session cookie is written to logs.
- Any principal with invoke permission gets the session — no Secrets Manager access needed, bypassing KMS encryption entirely.

**Recommendation:**
- Return only a status message (`{ status: "updated" }` or `{ status: "unchanged" }`).
- Callers that need the session should read it from Secrets Manager, which enforces KMS decryption and IAM policies.
- This also respects the principle of least privilege — invoke permission should not grant secret access.

---

## High

### H1. SQS Queue VisibilityTimeout = 0 Allows Duplicate 2FA Code Processing

**File:** `template.yaml` line 58
**Risk:** Race condition, session corruption, Apple rate limiting

```yaml
VisibilityTimeout: 0
```

With `VisibilityTimeout: 0`, any message received by one `receive_message` call is immediately visible to another concurrent invocation. Since the Lambda runs every 15 minutes AND can be invoked cross-account on demand, two concurrent invocations could both process the same 2FA code. This can cause:
- Apple rate-limiting ("Too many verification codes have been sent")
- Double-write to Secrets Manager with potentially different session states

**Recommendation:**
- Set `VisibilityTimeout` to at least the Lambda timeout (150 seconds).
- This ensures a message is hidden while being processed by one invocation.

### H2. Broad Cross-Account Lambda Invoke Permissions

**File:** `template.yaml` lines 272-293
**Risk:** Any role/user in the dev/QA/prod accounts can invoke the Lambda

```yaml
FastlaneSpaceauthFunctionCrossAccountPermissionDev:
  Type: AWS::Lambda::Permission
  Properties:
    Action: lambda:InvokeFunction
    FunctionName: !Ref FastlaneSpaceauthFunction
    Principal: !Ref DevAccountId
```

This grants `lambda:InvokeFunction` to the **entire AWS account** (all principals in that account). Combined with C2 (session in response), any IAM entity in any of the three accounts can extract the session token.

**Recommendation:**
- Restrict the `Principal` to specific IAM roles (e.g., the CI/CD role ARN in each account).
- Use `Condition` keys with `aws:PrincipalArn` to scope down further.
- At minimum, document which roles in each account are intended callers.

### H3. No Gem Version Pinning — Supply Chain Risk

**File:** `auto-fastlane-spaceauth/Gemfile` lines 1-7
**Risk:** Dependency confusion, malicious gem injection

```ruby
gem "fastlane"
gem "aws-sdk-sqs"
gem "aws-sdk-secretsmanager"
```

No version constraints. No `Gemfile.lock` committed. Every `sam build` (which uses `use_container: true`) resolves the latest versions from rubygems.org. A compromised or yanked gem version would be silently pulled in.

**Recommendation:**
- Pin gem versions: `gem "fastlane", "~> 2.225"` (or exact: `"= 2.225.0"`).
- Commit `Gemfile.lock` to the repository.
- Consider using `bundle audit` in CI/CD to detect known vulnerabilities.

### H4. 2FA Code and SMS Body Logged to CloudWatch in Plaintext

**File:** `app.rb` lines 33, 42
**Risk:** 2FA codes visible in CloudWatch logs

```ruby
puts message_body   # Prints full SMS text including 2FA code
puts code           # Prints extracted 6-digit code
```

The `Fastlane2FaSmsLogger` Lambda (template.yaml line 236) also logs the full event (`print(event)`). Both Lambdas write 2FA codes to CloudWatch in cleartext with 7-day retention.

**Recommendation:**
- Remove or redact `puts message_body` and `puts code` from production code.
- If logging is needed for debugging, log only a masked version: `puts "Received 2FA code: ***#{code[-2..]}"`.
- The SMS logger Lambda should also redact the code portion of the message body.

---

## Medium

### M1. No Gemfile.lock — Non-Reproducible Builds

**File:** `auto-fastlane-spaceauth/Gemfile`
**Risk:** Build inconsistency, regression from upstream changes

Without `Gemfile.lock`, each build resolves dependencies from scratch. A breaking change in `fastlane`, `spaceship`, or any transitive dependency can silently break the Lambda.

**Recommendation:**
- Run `bundle install` locally and commit the resulting `Gemfile.lock`.
- SAM's container build will respect the lockfile.

### M2. Hardcoded AWS Account IDs and Resource ARNs in Template

**File:** `template.yaml` lines 14, 26, 30, 32-40
**Risk:** Information disclosure, accidental deployment to wrong environment

Default parameter values contain real account IDs, KMS key ARN, and secret ARN:

```yaml
Default: "arn:aws:secretsmanager:eu-west-1:501431420968:secret:IOSEnvironment-eotAA1"
Default: "arn:aws:kms:eu-west-1:501431420968:key/64b87c32-49f8-48e2-864a-2da94059448c"
Default: "501431420968"  # ProdAccountId
Default: "441276146445"  # DevAccountId
Default: "644562626802"  # QaAccountId
```

These are committed to a public-facing template (the repo has a LICENCE.md suggesting it may be public or shared).

**Recommendation:**
- Replace defaults with placeholder values (`"REPLACE_ME"` or empty strings).
- Use `samconfig.toml` parameter overrides or environment-specific config files.
- If the repo is public, consider rotating the KMS key ID (exposure of key ARN alone is low risk but combined with account ID enables targeted attacks).

### M3. Apple ID Email Hardcoded in Template

**File:** `template.yaml` line 18
**Risk:** Targeted phishing, credential stuffing

```yaml
Default: "dev-ios@bfansports.com"
```

The Apple ID email is committed in plaintext. While less sensitive than the password, it provides an attacker with:
- A known valid Apple ID for targeted phishing
- A target for credential stuffing attacks
- Social engineering leverage

**Recommendation:**
- Move to `samconfig.toml` parameter override or Secrets Manager.
- Replace the default with a placeholder.

### M4. Pinpoint Phone Number Hardcoded in Template

**File:** `template.yaml` line 10
**Risk:** Targeted SMS spam, phone number abuse

```yaml
Default: "+1 (787) 493-0633"
```

The Pinpoint long code number is committed. An attacker could:
- Send spoofed SMS to this number to inject fake 2FA codes into the SQS queue
- Use the number for social engineering against Apple support

**Recommendation:**
- Move to `samconfig.toml` parameter override.
- Replace the default with a placeholder.

### M5. 15-Minute Schedule May Trigger Apple Rate Limiting

**File:** `template.yaml` lines 170-175
**Risk:** Account lockout, "Too many verification codes" errors

```yaml
Schedule: rate(15 minutes)
```

The Lambda runs every 15 minutes. If the session is already valid, `fastlane spaceauth` with a valid `FASTLANE_SESSION` env var should not trigger 2FA. However, if the session becomes invalid, every 15-minute invocation will:
1. Attempt login with invalid session
2. Trigger a new 2FA SMS
3. Process the 2FA code from SQS

Apple limits verification code requests. The existing CloudWatch alarm (`FastlaneTooManyVerificationCodesSentErrorAlarm`) detects this, but there is no circuit breaker — the Lambda will keep trying every 15 minutes.

**Recommendation:**
- Implement a circuit breaker: after detecting "Too many verification codes", write a flag to Secrets Manager or a DynamoDB item, and skip processing for a cooldown period (e.g., 1 hour).
- Consider increasing the schedule to `rate(30 minutes)` or `rate(1 hour)` — sessions last much longer than 15 minutes.

### M6. No Error Handling for Secrets Manager Failures

**File:** `app.rb` lines 71-95
**Risk:** Lambda crash with unhandled exception, no retry logic

Neither `get_previously_saved_session()` nor `save_session()` have error handling. If Secrets Manager is throttled, the secret is deleted, or KMS is unavailable, the Lambda crashes with an unhandled exception.

**Recommendation:**
- Wrap Secrets Manager calls in begin/rescue blocks.
- Log specific error types (throttling vs. not found vs. KMS errors).
- Return meaningful error status instead of crashing.

### M7. SQS Message Retention of Only 120 Seconds

**File:** `template.yaml` line 56
**Risk:** Lost 2FA codes if Lambda doesn't poll within 2 minutes

```yaml
MessageRetentionPeriod: 120
```

If the Lambda is slow to start (cold start on ARM64 with Ruby + Fastlane gems can be significant) or if the EventBridge trigger and the 2FA SMS are not perfectly synchronized, the 2FA code message may expire before it is consumed.

**Recommendation:**
- Increase to at least 300 seconds (5 minutes) to account for Lambda cold starts and timing misalignment.
- The Lambda's `wait_time_seconds: 20` (long polling) helps, but doesn't protect against messages that arrive before the Lambda starts polling.

---

## Low

### L1. Typo in Log Message

**File:** `app.rb` line 19
**Risk:** None (cosmetic)

```ruby
puts "Retriveing the 2FA code from the SQS queue"
```

Should be "Retrieving".

### L2. CLAUDE.md Lists Python Runtime — Actual Runtime is Ruby

**File:** `CLAUDE.md` lines 8, 58-59
**Risk:** Misleading documentation for developers and AI agents

The CLAUDE.md states:
- Tech Stack: `Runtime: Python (AWS Lambda)`
- Dependencies: `fastlane spaceship (Ruby gem called from Python)`

The actual Lambda runtime is `ruby3.3` (template.yaml line 157). The function code is Ruby (`app.rb`). There is no Python except the inline SMS logger Lambda.

### L3. `/tmp` Directory Permissions Set to 1777

**File:** `app.rb` lines 101-104
**Risk:** Minor — other processes in the Lambda execution environment could read/write to this directory

```ruby
File.chmod(1777, temp_dir)
```

This is a workaround for a Ruby 3.3 issue on Lambda. The sticky bit (1777) is the standard for shared temp directories, but since Lambda is single-tenant, 0700 would be more restrictive.

**Recommendation:**
- Use `File.chmod(0700, temp_dir)` instead, since no other users need access in a Lambda context.

### L4. No CloudWatch Log Encryption

**Files:** `template.yaml` lines 177-182, 248-252
**Risk:** Logs containing 2FA codes and session debug info are stored unencrypted

The log groups do not specify a KMS key for encryption at rest. Combined with H4 (2FA codes in logs), this means sensitive authentication data is stored in plaintext.

**Recommendation:**
- Add `KmsKeyId` property to both `AWS::Logs::LogGroup` resources.
- This requires the KMS key policy to allow `logs.amazonaws.com` as a principal.

### L5. SNS Permission for Logger Lambda is Overly Broad

**File:** `template.yaml` lines 255-259
**Risk:** Any SNS topic can invoke the logger Lambda

```yaml
SnsPermissionForFastlane2FaSmsLoggerFunction:
  Type: AWS::Lambda::Permission
  Properties:
    Action: lambda:InvokeFunction
    FunctionName: !Ref Fastlane2FaSmsLoggerFunction
    Principal: sns.amazonaws.com
```

No `SourceArn` condition. Any SNS topic in any account could invoke this Lambda.

**Recommendation:**
- Add `SourceArn: !Ref SnsTopicArn` to restrict invocation to the specific Pinpoint SMS topic.

---

## Agent Skill Improvements

### S1. CLAUDE.md Runtime Mismatch

The CLAUDE.md incorrectly identifies the runtime as Python. This should be corrected to Ruby 3.3 to avoid confusing future AI agents and developers. (Addressed in the improved CLAUDE.md delivered with this audit.)

### S2. Missing Auth Flow Documentation

No documentation describes the end-to-end authentication flow: schedule trigger -> check session -> login -> 2FA -> SQS poll -> save session. This makes it hard for agents to reason about the system. (Addressed in the improved CLAUDE.md.)

### S3. Missing Deployment Parameter Documentation

The `make deploy` command requires `AWS_REGION`, `AWS_ACCOUNT`, and `FASTLANE_PASSWORD` environment variables, but this is not documented in the CLAUDE.md or README in a consolidated way.

---

## Positive Observations

### P1. KMS Encryption for Secrets Manager
The session token in Secrets Manager is encrypted with a customer-managed KMS key, providing an additional layer of access control beyond IAM.

### P2. SQS Managed SSE
The SQS queue has `SqsManagedSseEnabled: true`, ensuring 2FA codes are encrypted at rest in the queue.

### P3. Least-Privilege IAM (Mostly)
The Lambda IAM roles are scoped to specific resources (specific log group, specific SQS queue, specific secret ARN, specific KMS key). This is good practice.

### P4. CloudWatch Alarm for Rate Limiting
The `FastlaneTooManyVerificationCodesSentErrorAlarm` detects Apple's rate limit error and sends notifications. This is proactive monitoring.

### P5. SMS Logger for Disaster Recovery
The `Fastlane2FaSmsLoggerFunction` preserves all incoming 2FA SMS in CloudWatch, enabling manual recovery if the automation breaks or Apple blocks the phone number.

### P6. Log Retention Limits
Both log groups have `RetentionInDays: 7`, limiting the exposure window for sensitive log data.

### P7. Container-Based Builds
`samconfig.toml` uses `use_container = true`, ensuring consistent builds regardless of the developer's local environment.

### P8. Cross-Account Architecture
The cross-account invoke pattern is well-structured with conditions to avoid unnecessary self-referencing permissions, and a managed policy is provided for CI/CD roles.
