# Copyright 2021 The Upbound Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ====================================================================================
# Options

ifeq ($(origin IMAGE_DIR),undefined)
IMAGE_DIR := $(ROOT_DIR)/cluster/images
endif

ifeq ($(origin IMAGE_OUTPUT_DIR),undefined)
IMAGE_OUTPUT_DIR := $(OUTPUT_DIR)/images/$(PLATFORM)
endif

ifeq ($(origin IMAGE_TEMP_DIR),undefined)
IMAGE_TEMP_DIR := $(shell mktemp -d)
endif

# we don't support darwin os images and instead strictly target linux
PLATFORM := $(subst darwin,linux,$(PLATFORM))

# shasum is not available on all systems. In that case, fall back to sha256sum.
ifneq ($(shell type shasum 2>/dev/null),)
SHA256SUM := shasum -a 256
else
SHA256SUM := sha256sum
endif

# a registry that is scoped to the current build tree on this host. this enables
# us to have isolation between concurrent builds on the same system, as in the case
# of multiple working directories or on a CI system with multiple executors. All images
# tagged with this build registry can safely be untagged/removed at the end of the build.
ifeq ($(origin BUILD_REGISTRY), undefined)
BUILD_REGISTRY := build-$(shell echo $(HOSTNAME)-$(ROOT_DIR) | $(SHA256SUM) | cut -c1-8)
endif

REGISTRY_ORGS ?= docker.io
IMAGE_ARCHS := $(subst linux_,,$(filter linux_%,$(PLATFORMS)))
ifndef MULTI_ARCH_BUILD
IMAGE_PLATFORMS := $(subst _,/,$(subst $(SPACE),$(COMMA),$(filter linux_%,$(PLATFORMS))))
endif
IMAGE_PLATFORMS_LIST := $(subst _,/,$(filter linux_%,$(PLATFORMS)))
IMAGE_PLATFORM := $(subst _,/,$(PLATFORM))

# if set to 1 docker image caching will not be used.
CACHEBUST ?= 0
ifeq ($(CACHEBUST),1)
BUILD_ARGS += --no-cache
endif

ifeq ($(HOSTOS),Linux)
SELF_CID := $(shell cat /proc/self/cgroup | grep docker | grep -o -E '[0-9a-f]{64}' | head -n 1)
endif

# =====================================================================================
# Image Targets

do.img.clean:
	@for i in $(CLEAN_IMAGES); do \
		if [ -n "$$(docker images -q $$i)" ]; then \
			for c in $$(docker ps -a -q --no-trunc --filter=ancestor=$$i); do \
				if [ "$$c" != "$(SELF_CID)" ]; then \
					echo stopping and removing container $${c} referencing image $$i; \
					docker stop $${c}; \
					docker rm $${c}; \
				fi; \
			done; \
			echo cleaning image $$i; \
			docker rmi $$i > /dev/null 2>&1 || true; \
		fi; \
	done

# this will clean everything for this build
img.clean:
	@$(INFO) cleaning images for $(BUILD_REGISTRY)
	@$(MAKE) do.img.clean CLEAN_IMAGES="$(shell docker images | grep -E '^$(BUILD_REGISTRY)/' | awk '{print $$1":"$$2}')"
	@$(OK) cleaning images for $(BUILD_REGISTRY)

img.done:
	@rm -fr $(IMAGE_TEMP_DIR)

# 1: registry 2: image
define repo.targets
img.release.publish.$(1).$(2):
	@$(MAKE) -C $(IMAGE_DIR)/$(2) IMAGE_PLATFORMS=$(IMAGE_PLATFORMS) IMAGE=$(1)/$(2):$(VERSION) img.publish
img.release.publish: img.release.publish.$(1).$(2)

img.release.promote.$(1).$(2):
	@$(MAKE) -C $(IMAGE_DIR)/$(2) TO_IMAGE=$(1)/$(2):$(CHANNEL) FROM_IMAGE=$(1)/$(2):$(VERSION) img.promote
	@[ "$(CHANNEL)" = "master" ] || $(MAKE) -C $(IMAGE_DIR)/$(2) TO_IMAGE=$(1)/$(2):$(VERSION)-$(CHANNEL) FROM_IMAGE=$(1)/$(2):$(VERSION) img.promote
img.release.promote: img.release.promote.$(1).$(2)

img.release.clean.$(1).$(2):
	@[ -z "$$$$(docker images -q $(1)/$(2):$(VERSION))" ] || docker rmi $(1)/$(2):$(VERSION)
	@[ -z "$$$$(docker images -q $(1)/$(2):$(VERSION)-$(CHANNEL))" ] || docker rmi $(1)/$(2):$(VERSION)-$(CHANNEL)
	@[ -z "$$$$(docker images -q $(1)/$(2):$(CHANNEL))" ] || docker rmi $(1)/$(2):$(CHANNEL)
img.release.clean: img.release.clean.$(1).$(2)
endef
$(foreach r,$(REGISTRY_ORGS), $(foreach i,$(IMAGES),$(eval $(call repo.targets,$(r),$(i)))))

# ====================================================================================
# Common Targets

ifdef MULTI_ARCH_BUILD
do.build.image.%:
	@$(MAKE) -C $(IMAGE_DIR)/$* IMAGE_PLATFORMS=$(IMAGE_PLATFORMS) IMAGE=$(BUILD_REGISTRY)/$* img.build
else
do.build.image.%:
	@$(MAKE) -C $(IMAGE_DIR)/$* IMAGE_PLATFORMS=$(IMAGE_PLATFORM) IMAGE=$(BUILD_REGISTRY)/$*-$(ARCH) img.build
endif

do.build.images: go.build $(foreach i,$(IMAGES), do.build.image.$(i))
do.skip.images:
	@$(OK) Skipping image build for unsupported platform $(IMAGE_PLATFORM)

ifdef MULTI_ARCH_BUILD
build.artifacts.platform: do.build.images
else
ifneq ($(filter $(IMAGE_PLATFORM),$(IMAGE_PLATFORMS_LIST)),)
build.artifacts.platform: do.build.images
else
build.artifacts.platform: do.skip.images
endif
endif

build.done: img.done
clean: img.clean img.release.clean

# Multi-arch publish targets
ifdef MULTI_ARCH_BUILD
do.publish.image.%:
	@$(MAKE) -C $(IMAGE_DIR)/$* IMAGE_PLATFORMS=$(IMAGE_PLATFORMS) IMAGE=$(BUILD_REGISTRY)/$* img.publish
do.publish.images: $(foreach i,$(IMAGES), do.publish.image.$(i))
endif

# only publish images for main / master and release branches by default
RELEASE_BRANCH_FILTER ?= main master release-%
ifneq ($(filter $(RELEASE_BRANCH_FILTER),$(BRANCH_NAME)),)
ifdef MULTI_ARCH_BUILD
publish.artifacts: do.publish.images
else
publish.artifacts: $(foreach r,$(REGISTRY_ORGS), $(foreach i,$(IMAGES),img.release.publish.$(r).$(i)))
endif
endif

promote.artifacts: $(foreach r,$(REGISTRY_ORGS), $(foreach i,$(IMAGES),img.release.promote.$(r).$(i)))
