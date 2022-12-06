# Auto Fastlane Spaceauth

This stack automatically runs `fastlane spaceauth` (including the 2FA SMS) and stores the session cookie in Secrets Manager for use in CI/CD.

We then use the `FASTLANE_SESSION` in Fastlane scripts and in Bitrise.

## Testing Locally 🧪

```bash
make test
```

*Note: I suggest you switch the lambda CPU architecture in the [template.yaml](template.yaml) to `x86_64` during development. This speeds the builds 10x.*

## Deploying 🚀

```bash
make deploy
```

## Deleting 🧨

```bash
make delete
```

## Setup ⚙️

This stack is created and used by [bFAN Sports](https://www.bfansports.com/). If you want to use this stack, you'll need to do a few things first.

### 1. AWS Secrets Manager

#### 1.1 Create a secret in Secrets Manager

You will be storing the `FASTLANE_SESSION` in Secrets Manager. So create a secret from the AWS dashboard.

Copy the ARN.

*Note: We chose to enable KMS encryption for the secret, so our template contains permissions to access the KMS key. Remove those permissions if you don't want to use KMS encryption.*

#### 1.2 Modify the template

In the [template.yaml](template.yaml), replace the `SecretsManagerSecretId` and `KmsKeyIdForSecretsManager` default parameter with your own value.

```yaml
  SecretsManagerSecretId:
    Type: String
    Description: AWS Secrets Manager secret ID to store the FASTLANE_SESSION
    Default: "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:SECRET_NAME-XXXXXXXX"
  KmsKeyIdForSecretsManager:
    Type: String
    Description: AWS KMS key ID for Secrets Manager
    Default: "arn:aws:kms:REGION:ACCOUNT_ID:key/KEY_ID"
```

### 2. AWS Pinpoint

#### 2.1 Buy an AWS Pinpoint long code phone number with 2-way SMS capability

You will be paying for every SMS received. You can find the cheapest phone number using [this script](https://gist.github.com/return-main/b1c833e6385dd73d9261388ff7976dd8).

Whatever country you chose, make sure it has [Two-way SMS capability](https://docs.aws.amazon.com/pinpoint/latest/userguide/channels-sms-countries.html).

The availability of phone numbers varies, so we used a phone number from Puerto Rico (PR).

Copy the long code phone number.

#### 2.2 Enable 2-way SMS for your phone number

Go to the long code's settings and enable two-way SMS. Send the incoming SMS to a new SNS topic.

Copy the SNS topic ARN.

#### 2.3 Modify the template

In the [template.yaml](template.yaml), replace the `Spaceship2FaSmsDefaultPhoneNumber` and `SnsTopicArn` default parameters with your own values.

```yaml
  Spaceship2FaSmsDefaultPhoneNumber:
    Type: String
    Description: Phone number to receive 2FA code (the AWS Pinpoint phone number)
    Default: "+1XXXXXXXXXX"
  SnsTopicArn:
    Type: String
    Description: AWS SNS topic ARN that receives 2FA SMS
    Default: "arn:aws:sns:REGION:ACCOUNT_ID:TOPIC_NAME"
```

### 3. Apple Developer Account

#### 3.1 Trusting the phone number

Go to your [Apple account](https://appleid.apple.com/) and add the trusted phone number you chose in step 2.1.

#### 3.2 Modify the template

In the [template.yaml](template.yaml), replace the `FastlaneUser` default parameters with your own Apple email.

```yaml
  FastlaneUser:
    Type: String
    Description: Apple ID for Fastlane
    Default: "APPLE_ACCOUNT@YOUR_WEBSITE.com"
```

#### 3.3 Export the Apple password

We don't want to store the Apple password in the template. Instead, we'll export it as an environment variable.

```bash
export FASTLANE_PASSWORD="your_password"
```

### 4. Deploying

Congratulations! You're ready to deploy.

[Install the SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html#install-sam-cli-instructions) and run:

```bash
make deploy
```
