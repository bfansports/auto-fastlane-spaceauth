guard-%: GUARD
	@ if [ -z '${${*}}' ]; then echo 'Environment variable $* not set.' && exit 1; fi

.PHONY: GUARD
GUARD:

all: build

build:
	@echo "Building..."
	@sam build

sync:
	@echo "Syncing..."
	@echo y | sam sync --watch

deploy: guard-AWS_REGION guard-AWS_ACCOUNT guard-FASTLANE_PASSWORD build
	@echo "Deploying..."
	@sam deploy --resolve-s3 --region "${AWS_REGION}" --role-arn "arn:aws:iam::${AWS_ACCOUNT}:role/CloudFormationDeployRole" --parameter-overrides FastlanePassword="${FASTLANE_PASSWORD}"

delete: guard-AWS_REGION
	@echo "Deleting..."
	@sam delete --no-prompts --region "${AWS_REGION}"