ifndef VERBOSE
.SILENT:
endif

PACKAGE     := denver
DATE        := $(shell date +%s)
VERSION     := $(shell git --no-pager log --pretty=format:'%h' -n 1)
SHELL       := bash

BUILD_IMG   := golang:stretch

GO          := go
BASE        := $(shell pwd)

DIST := {linux,darwin,windows}

S3BUCKET    := s3.d3nver.io/app
RELEASE     := $(DATE)-v$(VERSION)
PROJECT_ID  := 181
S3PATH      := https://s3-eu-west-1.amazonaws.com/$(S3BUCKET)

V = 0
Q = $(if $(filter 1,$V),,@)
M = $(shell printf "\033[34;1m▶\033[0m")

########################################################
### Stages                                           ###
########################################################

help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

test: install-tools ; $(info $(M) Testing sources...) @  ## Test
	cd ./src && go test -race ./...

lint: install-tools ; $(info $(M) Linting sources...) @  ## Code lint
		$Q cd ./src && fgt golint ./...
		$Q cd ./src && fgt go vet ./...
		$Q cd ./src && fgt go fmt ./...
		$Q cd ./src && fgt goimports -w .
		$Q cd ./src && fgt errcheck -ignore Close  ./...

build-denver: ; $(info $(M) Building sources...) @  ## Build the sources inside Denver
		docker run --rm --interactive --tty --name $(PACKAGE)_builder --volume $$PWD:/go/src/$(PACKAGE) $(BUILD_IMG) bash -c "cd /go/src/$(PACKAGE); make lint test build-ci; chown -R 1000:1000 /go/src/$(PACKAGE)"

build-ci: ; $(info $(M) Building sources...) @  ## Build the sources for CI
		$Q cd ./src && \
			for dist in $(DIST); do \
				GOOS=$$dist GOARCH=amd64 $(GO) build \
					-tags release \
					-ldflags '-X $(PACKAGE)/cmd.Version=$(VERSION) -X $(PACKAGE)/cmd.BuildTs=$(DATE) -X $(PACKAGE)/cmd.WorkingDirectory=' \
					-o ../bin/$(PACKAGE)-$$dist; \
			done

pack: ; $(info $(M) Packing releases...) @  ## Packing the releases
		$Q rm -rf ./releases
		$Q mkdir -p ./releases/$(DIST)/$(DATE)/$(PACKAGE)/{conf,tools}
		$Q cd $(BASE) && \
			for dist in $(DIST); do \
				cp bin/$(PACKAGE)-$$dist releases/$$dist/$(DATE)/$(PACKAGE)/$(PACKAGE) ; \
				cp conf/config.yml.dist releases/$$dist/$(DATE)/$(PACKAGE)/conf/config.yml.dist ; \
				cp tools/alacritty-$$dist-* releases/$$dist/$(DATE)/$(PACKAGE)/tools/ ; \
				cp tools/alacritty.yml releases/$$dist/$(DATE)/$(PACKAGE)/tools/ ; \
			done
		$Q mv releases/windows/$(DATE)/$(PACKAGE)/$(PACKAGE) releases/windows/$(DATE)/$(PACKAGE)/$(PACKAGE).exe
		$Q cp tools/winpty-agent.exe releases/windows/$(DATE)/$(PACKAGE)/tools/
		$Q cp tools/iterm2.sh releases/darwin/$(DATE)/$(PACKAGE)/tools/
		$Q cd ./releases/linux && echo "{ \"filesize\": \"$$(du -s $(DATE)/$(PACKAGE) | cut -f 1)\", \"date\": \"$(DATE)\", \"release\": \"$(RELEASE)\", \"url\": \"$(S3PATH)/linux/$(DATE)/$(PACKAGE)-linux-$(RELEASE).tar.bz2\" }" > manifest.json
		$Q cd ./releases/linux/$(DATE) && tar -I lbzip2 -cf ./$(PACKAGE)-linux-$(RELEASE).tar.bz2 $(PACKAGE)
		$Q cd ./releases/darwin && echo "{ \"filesize\": \"$$(du -s $(DATE)/$(PACKAGE) | cut -f 1)\", \"date\": \"$(DATE)\", \"release\": \"$(RELEASE)\", \"url\": \"$(S3PATH)/darwin/$(DATE)/$(PACKAGE)-darwin-$(RELEASE).zip\" }" > manifest.json
		$Q cd ./releases/darwin/$(DATE) && zip -rq ./$(PACKAGE)-darwin-$(RELEASE).zip $(PACKAGE)
		$Q cd ./releases/windows && echo "{ \"filesize\": \"$$(du -s $(DATE)/$(PACKAGE) | cut -f 1)\", \"date\": \"$(DATE)\", \"release\": \"$(RELEASE)\", \"url\": \"$(S3PATH)/windows/$(DATE)/$(PACKAGE)-windows-$(RELEASE).zip\" }" > manifest.json
		$Q cd ./releases/windows/$(DATE) && zip -rq ./$(PACKAGE)-windows-$(RELEASE).zip $(PACKAGE)
		$Q for dist in $(DIST); do rm -rf ./releases/$$dist/$(DATE)/$(PACKAGE) ; done

push-release-to-s3: ; $(info $(M) Push release to S3) @  ## Push release to S3
		$Q aws s3 sync --acl public-read ./releases s3://$(S3BUCKET)

create-gitlab-release: _create_gitlab_json ; $(info $(M) Create Gitlab release) @  ## Create Gitlab release
		$Q curl \
		--header 'Content-Type: application/json' --header "Private-Token: $(TOKEN)" \
		--data "@release.json" \
		https://gitlab.werkspot.com/api/v4/projects/$(PROJECT_ID)/releases

_create_gitlab_json:
		$Q prev=$$(git rev-list -n 1 $$(git describe --abbrev=0 --tags)|git rev-list --max-parents=0 HEAD); \
		last=$$(git --no-pager log --pretty=format:'%H' -n 1); \
		description=$$(git --no-pager log --merges --pretty=tformat:"## %h - %aI - [%aN](mailto:%aE)%n\\\`\\\`\\\`%n%b%n\\\`\\\`\\\`" $$prev..); \
		echo "{ \"name\": \"$(RELEASE)\", \"tag_name\": \"$(RELEASE)\", \"ref\": \"$$last\", \"description\": \"$$description\", \"assets\": { \"links\": [{ \"name\": \"Linux\", \"url\": \"$(S3PATH)/linux/$(DATE)/$(PACKAGE)-linux-$(RELEASE).tar.bz2\" }, { \"name\": \"Mac\", \"url\": \"$(S3PATH)/darwin/$(DATE)/$(PACKAGE)-darwin-$(RELEASE).zip\" }, { \"name\": \"Windows\", \"url\": \"$(S3PATH)/windows/$(DATE)/$(PACKAGE)-windows-$(RELEASE).zip\" }] } }" \
		| awk '{printf "%s\\n", $$0}' 2>&1 \
		| sed 's/..$$//' > release.json

clean: ; $(info $(M) Removing useless data...) @  ## Cleanup the project folder
		$Q -cd ./src && $(GO) clean

mrproper: clean ; $(info $(M) Remove useless data and binaries...) @  ## Clean everything and free resources
		$Q -rm -f  ./bin/*
		$Q -rm -rf ./store
		$Q -rm -rf .ssh
		$Q -rm -rf ./releases

########################################################
### External tools                                   ###
########################################################

install-tools: ; $(info $(M) Installing all tools...) @
	$Q go get -u golang.org/x/lint/golint
	$Q go get -u golang.org/x/tools/cmd/goimports
	$Q go get -u github.com/GeertJohan/fgt
	$Q go get -u github.com/kisielk/errcheck
	$Q cd ./src && go mod download
