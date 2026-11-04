# ====================================================================================
# Setup Project

include ../../../build/makelib/common.mk

# ====================================================================================
#  Options

include ../../../build/makelib/imagelight.mk

# ====================================================================================
# Setup k8s tools

-include ../../../build/makelib/k8s_tools.mk

# ====================================================================================
# Setup xpkg

-include ../../../build/makelib/xpkg.mk

# ====================================================================================
# Targets

img.build:
	@$(INFO) Family base image to build: $(IMAGE)
	@$(INFO) Building image $(IMAGE); \
	# Buildx is required to cross-build linux/amd64 and linux/arm64. Export its
	# result as a Docker archive, then import it into Docker's image store for
	# xpkg batch. The classic builder silently produces the host architecture
	# for both tags on Apple Silicon.
	image_tar="$(IMAGE_TEMP_DIR)/image.tar"; \
	rm -f "$${image_tar}"; \
	$(MAKE) BUILD_ARGS="--output=type=docker,dest=$${image_tar} ${BUILD_ARGS}" IMAGE=$(IMAGE) XPKG_REG_ORGS=$(XPKG_REG_ORGS) img.build.shared && \
	{ docker image rm -f "$(IMAGE):latest" >/dev/null 2>&1 || true; } && \
	docker load -i "$${image_tar}" && \
	rm -f "$${image_tar}" && \
	actual_arch=$$(docker image inspect "$(IMAGE):latest" --format '{{.Architecture}}'); \
	if [ "$${actual_arch}" != "$(ARCH)" ]; then \
		echo "built $(IMAGE):latest with architecture $${actual_arch}, expected $(ARCH)" >&2; \
		exit 1; \
	fi && \
	if [[ "$${LOAD_PACKAGES}" == "true" ]]; then \
		$(MAKE) batch-process SUBPACKAGES="$(SUBPACKAGES)" XPKG_DIR=$(XPKG_DIR) XPKG_IGNORE=$(XPKG_IGNORE) BATCH_PLATFORMS=$(PLATFORM) BUILD_ONLY=true STORE_PACKAGES="$$(tr ' ' ',' <<< "$(SUBPACKAGES)")" && \
		for s in $(SUBPACKAGES); do \
			export t=$$(docker load -qi "$(XPKG_OUTPUT_DIR)/$(PLATFORM)/$(PROJECT_NAME)-$${s}-$(VERSION).xpkg") && \
			docker tag $${t##*:} $(BUILD_REGISTRY)/$(PROJECT_NAME)-$${s}-$(ARCH); \
		done; \
	fi || $(FAIL)
	@$(OK) docker build $${IMAGE}

img.build.shared:
	@cp Dockerfile $(IMAGE_TEMP_DIR) || $(FAIL)
	@# CA_BUNDLE_PATH is exported by the corporate shell profile. Supplying an
	@# alternate CORPORATE_CA_BUNDLE supports CI and nonstandard local setups.
	@if [ -n "$(CORPORATE_CA_BUNDLE)" ]; then \
		cp "$(CORPORATE_CA_BUNDLE)" $(IMAGE_TEMP_DIR)/corporate-ca.pem; \
	elif [ -n "$(CA_BUNDLE_PATH)" ]; then \
		cp "$(CA_BUNDLE_PATH)" $(IMAGE_TEMP_DIR)/corporate-ca.pem; \
	else \
		: > $(IMAGE_TEMP_DIR)/corporate-ca.pem; \
	fi || $(FAIL)
	@docker buildx build $(BUILD_ARGS) \
		--platform $(IMAGE_PLATFORMS) \
		--build-arg CROSSPLANE_PROVIDER_VERSION=$(VERSION) \
		-t $(IMAGE) \
		$(IMAGE_TEMP_DIR) || $(FAIL)

img.publish: batch-process

img.promote:
	@$(INFO) Skipping image promotion from $(FROM_IMAGE) to $(TO_IMAGE)
	@echo Promote is deferred to xpkg machinery
	@$(OK) Image promotion skipped for $(FROM_IMAGE) to $(TO_IMAGE)

CONCURRENCY ?= 30
DEP_CONSTRAINT := >= 0.0.0
ifeq (-,$(findstring -,$(VERSION)))
    DEP_CONSTRAINT = >= 0.0.0-0
endif
BUILD_ONLY ?= false
STORE_PACKAGES ?= ""
XPKG_CLEANUP_EXAMPLES_VERSION ?= v0.12.1
batch-process: $(CROSSPLANE_CLI)
	@rm -rf $(WORK_DIR)/xpkg-cleaned-examples
	@GOOS=$(HOSTOS) GOARCH=$(TARGETARCH) go run github.com/upbound/uptest/cmd/cleanupexamples@$(XPKG_CLEANUP_EXAMPLES_VERSION) $(ROOT_DIR)/examples $(WORK_DIR)/xpkg-cleaned-examples || $(FAIL)
	@$(INFO) Batch processing smaller provider packages for: "$(SUBPACKAGES)"
	@mkdir -p "$(XPKG_OUTPUT_DIR)/$(PLATFORM)" && \
	$(CROSSPLANE_CLI) xpkg batch --smaller-providers "$$(tr ' ' ',' <<< "$(SUBPACKAGES)")" \
		--family-base-image $(BUILD_REGISTRY)/$(PROJECT_NAME) \
		--platform $(BATCH_PLATFORMS) \
		--provider-name $(PROJECT_NAME) \
		--family-package-url-format $(XPKG_REG_ORGS)/%s:$(VERSION) \
		--package-repo-override monolith=$(PROJECT_NAME) --package-repo-override config=provider-family-$(PROVIDER_NAME) \
		--provider-bin-root $(OUTPUT_DIR)/bin \
		--output-dir $(XPKG_OUTPUT_DIR) \
		--store-packages "$(STORE_PACKAGES)" \
		--build-only=$(BUILD_ONLY) \
		--examples-root $(WORK_DIR)/xpkg-cleaned-examples \
		--examples-group-override monolith=* --examples-group-override config=providerconfig \
		--crd-root $(XPKG_DIR)/crds \
		--ignore $(XPKG_IGNORE) \
		--crd-group-override monolith=* --crd-group-override config=$(CONFIG_CRD_GROUP) \
		--package-metadata-template $(XPKG_DIR)/crossplane.yaml.tmpl \
		--template-var XpkgRegOrg=$(CONFIG_DEPENDENCY_REG_ORG) --template-var DepConstraint="$(DEP_CONSTRAINT)" --template-var ProviderName=$(PROVIDER_NAME) --template-var ProviderAuthGroup=$(PROVIDER_AUTH_GROUP) \
		--concurrency $(CONCURRENCY) \
		--push-retry 10 || $(FAIL)
	@$(OK) Done processing smaller provider packages for: "$(SUBPACKAGES)"
	@rm -rf $(WORK_DIR)/xpkg-cleaned-examples
