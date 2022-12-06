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
