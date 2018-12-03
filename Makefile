SHELL=/bin/bash
ELASTIC_REGISTRY ?= docker.elastic.co

export PATH := ./bin:./venv/bin:$(PATH)

# Determine the version to build. Override by setting ELASTIC_VERSION env var.
ELASTIC_VERSION := $(shell ./bin/elastic-version)

ifdef STAGING_BUILD_NUM
  VERSION_TAG := $(ELASTIC_VERSION)-$(STAGING_BUILD_NUM)
else
  VERSION_TAG := $(ELASTIC_VERSION)
endif

IMAGE_FLAVORS ?= oss
DEFAULT_IMAGE_FLAVOR ?= oss

IMAGE_TAG := $(ELASTIC_REGISTRY)/logstash/logstash
HTTPD ?= logstash-docker-artifact-server

FIGLET := pyfiglet -w 160 -f puffy

all: build

test: lint docker-compose
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  $(FIGLET) "test: $(FLAVOR)"; \
	  ./bin/pytest tests --image-flavor=$(FLAVOR); \
	)

test-snapshot:
	ELASTIC_VERSION=$(ELASTIC_VERSION)-SNAPSHOT make test

lint: venv
	flake8 tests

build: dockerfile docker-compose env2yaml
	docker pull centos:7
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  docker build -t $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) \
	  -f build/logstash/Dockerfile-$(FLAVOR) build/logstash; \
	  if [[ $(FLAVOR) == $(DEFAULT_IMAGE_FLAVOR) ]]; then \
	    docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) $(IMAGE_TAG):$(VERSION_TAG); \
	  fi; \
	)

release-manager-snapshot: clean
	ARTIFACTS_DIR=$(ARTIFACTS_DIR) ELASTIC_VERSION=$(ELASTIC_VERSION)-SNAPSHOT make build-from-local-artifacts

release-manager-release: clean
	ARTIFACTS_DIR=$(ARTIFACTS_DIR) ELASTIC_VERSION=$(ELASTIC_VERSION) make build-from-local-artifacts

# Build from artifacts on the local filesystem, using an http server (running
# in a container) to provide the artifacts to the Dockerfile.
build-from-local-artifacts: venv dockerfile docker-compose env2yaml
	docker run --rm -d --name=$(HTTPD) \
	           --network=host -v $(ARTIFACTS_DIR):/mnt \
	           python:3 bash -c 'cd /mnt && python3 -m http.server'
	timeout 120 bash -c 'until curl -s localhost:8000 > /dev/null; do sleep 1; done'
	-$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  pyfiglet -f puffy -w 160 "Building: $(FLAVOR)"; \
	  docker build --network=host -t $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) -f build/logstash/Dockerfile-$(FLAVOR) build/logstash || \
	    (docker kill $(HTTPD); false); \
	  if [[ $(FLAVOR) == $(DEFAULT_IMAGE_FLAVOR) ]]; then \
	    docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) $(IMAGE_TAG):$(VERSION_TAG); \
	  fi; \
	)
	-docker kill $(HTTPD)

# Build images from the latest snapshots on snapshots.elastic.co
from-snapshot:
	rm -rf snapshots/
	mkdir -p snapshots/logstash/build/
	(cd snapshots/logstash/build/ && \
	  wget https://snapshots.elastic.co/downloads/logstash/logstash-$(ELASTIC_VERSION)-SNAPSHOT.tar.gz && \
	  wget https://snapshots.elastic.co/downloads/logstash/logstash-oss-$(ELASTIC_VERSION)-SNAPSHOT.tar.gz)
	ARTIFACTS_DIR=$$PWD/snapshots make release-manager-snapshot

demo: docker-compose clean-demo
	docker-compose up

# Push the image to the dedicated push endpoint at "push.docker.elastic.co"
push: test
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) viki/logstash-$(FLAVOR):$(VERSION_TAG); \
	  docker push viki/logstash-$(FLAVOR):$(VERSION_TAG); \
	  docker rmi viki/logstash-$(FLAVOR):$(VERSION_TAG); \
	)

# The tests are written in Python. Make a virtualenv to handle the dependencies.
venv: requirements.txt
	@if [ -z $$PYTHON3 ]; then\
	    PY3_MINOR_VER=`python3 --version 2>&1 | cut -d " " -f 2 | cut -d "." -f 2`;\
	    if (( $$PY3_MINOR_VER < 5 )); then\
		echo "Couldn't find python3 in \$PATH that is >=3.5";\
		echo "Please install python3.5 or later or explicity define the python3 executable name with \$PYTHON3";\
		echo "Exiting here";\
		exit 1;\
	    else\
		export PYTHON3="python3.$$PY3_MINOR_VER";\
	   fi;\
	fi;\
	test -d venv || virtualenv --python=$$PYTHON3 venv;\
	pip install -r requirements.txt;\
	touch venv;\

# Make a Golang container that can compile our env2yaml tool.
golang:
	docker build -t golang:env2yaml build/golang

# Compile "env2yaml", the helper for configuring logstash.yml via environment
# variables.
env2yaml: golang
	docker run --rm -i \
	  -v ${PWD}/build/logstash/env2yaml:/usr/local/src/env2yaml:Z \
	  golang:env2yaml

# Generate the Dockerfiles from Jinja2 templates.
dockerfile: venv templates/Dockerfile.j2
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  jinja2 \
	    -D elastic_version='$(ELASTIC_VERSION)' \
	    -D staging_build_num='$(STAGING_BUILD_NUM)' \
	    -D version_tag='$(VERSION_TAG)' \
	    -D image_flavor='$(FLAVOR)' \
	    -D artifacts_dir='$(ARTIFACTS_DIR)' \
	    templates/Dockerfile.j2 > build/logstash/Dockerfile-$(FLAVOR); \
	)


# Generate docker-compose files from Jinja2 templates.
docker-compose: venv
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  jinja2 \
	    -D version_tag='$(VERSION_TAG)' \
	    -D image_flavor='$(FLAVOR)' \
	    templates/docker-compose.yml.j2 > docker-compose-$(FLAVOR).yml; \
	)
	ln -sf docker-compose-$(DEFAULT_IMAGE_FLAVOR).yml docker-compose.yml

clean: clean-demo
	rm -f build/logstash/env2yaml/env2yaml build/logstash/Dockerfile
	rm -rf venv

clean-demo: docker-compose
	docker-compose down
	docker-compose rm --force

.PHONY: build clean clean-demo demo push test
