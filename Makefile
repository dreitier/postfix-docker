IMAGE ?= dreitier/postfix
TAG ?= local

.PHONY: build e2e hooks lint pin-images

# local image only; releases are published by .github/workflows/release.yml
build:
	docker build -t $(IMAGE):$(TAG) .

# end-to-end test against Mailpit, as in CI (needs Docker and python3)
e2e: build
	.github/ci/e2e.sh $(IMAGE):$(TAG)

hooks:
	pre-commit install

lint:
	pre-commit run --all-files

# pins the base images to their current digests; Dependabot keeps tags and digests up to date afterwards
pin-images:
	.github/scripts/pin-images.py Dockerfile
