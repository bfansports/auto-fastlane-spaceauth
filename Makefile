all: build

build:
	@echo "Building..."
	@sam build

sync:
	@echo "Syncing..."
	@echo y | sam sync --watch

deploy:
	@echo "Deploying..."
	@sam deploy --resolve-s3 --region "${$AWS_REGION}" --role-arn "arn:aws:iam::${AWS_ACCOUNT}:role/CloudFormationDeployRole"

delete:
	@echo "Deleting..."
	@sam delete --no-prompts --region "${AWS_REGION}"