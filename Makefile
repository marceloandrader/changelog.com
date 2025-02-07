SHELL := bash# we want bash behaviour in all shell invocations
PLATFORM := $(shell uname)
platform = $(shell echo $(PLATFORM) | tr A-Z a-z)
MAKEFILE := $(firstword $(MAKEFILE_LIST))

# https://linux.101hacks.com/ps1-examples/prompt-color-using-tput/
RED := $(shell tput setaf 1)
GREEN := $(shell tput setaf 2)
YELLOW := $(shell tput setaf 3)
BOLD := $(shell tput bold)
NORMAL := $(shell tput sgr0)

ifneq (4,$(firstword $(sort $(MAKE_VERSION) 4)))
  $(warning $(BOLD)$(RED)GNU Make v4 or newer is required$(NORMAL))
  $(info On macOS it can be installed with $(BOLD)brew install make$(NORMAL) and run as $(BOLD)gmake$(NORMAL))
  $(error Please run with GNU Make v4 or newer)
endif



### VARS ###
#
# https://tools.ietf.org/html/rfc3339 format - s/:/./g so that Docker tag is valid
export BUILD_VERSION := $(shell date -u +'%Y-%m-%dT%H.%M.%SZ')

DOMAIN ?= changelog.com
DOCKER_STACK ?= 201910
DOCKER_STACK_FILE ?= docker/$(DOCKER_STACK).stack.yml

HOST ?= $(DOCKER_STACK)i.$(DOMAIN)
HOST_SSH_USER ?= core

HOSTNAME := $(DOCKER_STACK).$(DOMAIN)
HOSTNAME_LOCAL := changelog.localhost

GIT_REPOSITORY ?= https://github.com/thechangelog/changelog.com
GIT_BRANCH ?= master

LOCAL_BIN := $(CURDIR)/bin
PATH := $(LOCAL_BIN):$(PATH)
export PATH

export FQDN IPv4

ifeq ($(PLATFORM),Darwin)
OPEN := open
else
OPEN := xdg-open
endif

XDG_CONFIG_HOME := $(CURDIR)/.config
export XDG_CONFIG_HOME



### DEPS ###
#
ifeq ($(PLATFORM),Darwin)
DOCKER ?= /usr/local/bin/docker
COMPOSE ?= $(DOCKER)-compose
$(DOCKER) $(COMPOSE):
	brew cask install docker \
	&& open -a Docker
endif
ifeq ($(PLATFORM),Linux)
DOCKER ?= /usr/bin/docker
$(DOCKER): $(CURL)
	@sudo apt-get update && \
	sudo apt-get install apt-transport-https gnupg-agent && \
	$(CURL) -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add - && \
	APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=true apt-key finger | \
	  grep --quiet "9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88" && \
	echo "deb https://download.docker.com/linux/ubuntu $$(lsb_release -c -s) stable" | \
	  sudo tee /etc/apt/sources.list.d/docker.list && \
	sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io && \
	sudo adduser $$USER docker && newgrp docker && sudo service restart docker
COMPOSE ?= /usr/local/bin/docker-compose
$(COMPOSE):
	@sudo curl -L "https://github.com/docker/compose/releases/download/1.24.0/docker-compose-$$(uname -s)-$$(uname -m)" -o /usr/local/bin/docker-compose && \
	sudo chmod a+x /usr/local/bin/docker-compose
endif

CURL ?= /usr/bin/curl
ifeq ($(PLATFORM),Linux)
$(CURL):
	@sudo apt-get update && sudo apt-get install curl
endif

ifeq ($(PLATFORM),Darwin)
JQ := /usr/local/bin/jq
$(JQ):
	@brew install jq
endif
ifeq ($(PLATFORM),Linux)
JQ ?= /snap/bin/jq
$(JQ):
	@sudo snap install jq
endif

ifeq ($(PLATFORM),Darwin)
LPASS := /usr/local/bin/lpass
$(LPASS):
	@brew install lastpass-cli
endif
ifeq ($(PLATFORM),Linux)
LPASS := /usr/bin/lpass
$(LPASS):
	@sudo apt-get update && sudo apt-get install lastpass-cli
endif

TERRAFORM := /usr/local/bin/terraform
$(TERRAFORM):
ifeq ($(PLATFORM),Darwin)
	@brew install terraform
endif
ifeq ($(PLATFORM),Linux)
	$(error $(RED)Please install $(BOLD)terraform v0.12$(NORMAL) in $(TERRAFORM): https://www.terraform.io/downloads.html)
endif

ifeq ($(PLATFORM),Darwin)
WATCH := /usr/local/bin/watch
$(WATCH):
	@brew install watch
endif
ifeq ($(PLATFORM),Linux)
WATCH := /usr/bin/watch
endif
WATCH_MAKE_TARGET = $(WATCH) --color $(MAKE) --makefile $(MAKEFILE) --no-print-directory

BATS := /usr/local/bin/bats
$(BATS):
ifeq ($(PLATFORM),Darwin)
	@brew install bats-core
endif
ifeq ($(PLATFORM),Linux)
	$(error $(RED)Please install $(BOLD)bats-core$(NORMAL) in $(BATS): https://github.com/bats-core/bats-core#installation)
endif

SECRETS := mkdir -p $(XDG_CONFIG_HOME)/.config && $(LPASS) ls "Shared-changelog/secrets"

TF := cd terraform && $(TERRAFORM)
TF_VAR := export TF_VAR_ssl_key="$$(lpass show --notes 8995604957212378446)" && export TF_VAR_ssl_cert="$$(lpass show --notes 7865439845556655715 && cat terraform/dhparams.pem)"

# Enable Terraform debugging if make runs in debug mode
ifneq (,$(findstring d,$(MFLAGS)))
  TF_LOG ?= debug
  export TF_LOG
endif



### TARGETS ###
#
.DEFAULT_GOAL := help

include $(CURDIR)/mk/inspect.mk
include $(CURDIR)/mk/images.mk
include $(CURDIR)/mk/ssl.mk

MIGRATE_FROM := core@2019i.changelog.com
include $(CURDIR)/mk/migrate.mk

include $(CURDIR)/mk/lke.mk

colours:
	@echo "$(BOLD)BOLD $(RED)RED $(GREEN)GREEN $(YELLOW)YELLOW $(NORMAL)"

define MAKE_TARGETS
  awk -F: '/^[^\.%\t][a-zA-Z\._\-]*:+.*$$/ { printf "%s\n", $$1 }' $(MAKEFILE_LIST)
endef
define BASH_AUTOCOMPLETE
  complete -W \"$$($(MAKE_TARGETS) | sort | uniq)\" make gmake m
endef
.PHONY: autocomplete
autocomplete: ## ac  | Configure shell autocomplete - eval "$(make autocomplete)"
	@echo "$(BASH_AUTOCOMPLETE)"
.PHONY: ac
ac: autocomplete
# Continuous Feedback for the ac target - run in a split window while iterating on it
.PHONY: CFac
CFac: $(WATCH)
	@$(WATCH_MAKE_TARGET) ac

.PHONY: $(HOST)
$(HOST): iaas create-docker-secrets bootstrap-docker

define BOOTSTRAP_CONTAINER
docker pull thechangelog/bootstrap:$(DOCKER_STACK) && \
docker run --rm --interactive --tty --name bootstrap \
  --env HOSTNAME=\$$HOSTNAME \
  --volume /var/run/docker.sock:/var/run/docker.sock:ro \
  --volume changelog.com:/app:rw \
  $(BOOTSTRAP_RUN)
endef
BOOTSTRAP_RUN ?= thechangelog/bootstrap:$(DOCKER_STACK)
define DISABLE_APP_UPDATER
docker service scale $(DOCKER_STACK)_app_updater=0
endef
.PHONY: bootstrap-docker
bootstrap-docker:
	@ssh -t $(HOST_SSH_USER)@$(HOST) "$(DISABLE_APP_UPDATER) ; $(BOOTSTRAP_CONTAINER)"
.PHONY: bd
bd: bootstrap-docker

.PHONY: interactive-bootstrap
interactive-bootstrap: BOOTSTRAP_RUN = --entrypoint /bin/bash thechangelog/bootstrap:$(DOCKER_STACK) --login
interactive-bootstrap:
	@ssh -t $(HOST_SSH_USER)@$(HOST) "$(BOOTSTRAP_CONTAINER)"
.PHONY: ib
ib: interactive-bootstrap

.PHONY: add-secret
add-secret: $(LPASS) ## as  | Add secret to LastPass
ifndef SECRET
	@echo "$(RED)SECRET$(NORMAL) environment variable must be set to the name of the secret that will be added" && \
	echo "This value must be in upper-case, e.g. $(BOLD)SOME_SECRET$(NORMAL)" && \
	echo "This value must not match any of the existing secrets:" && \
	$(SECRETS) && \
	exit 1
endif
	@$(LPASS) add --notes "Shared-changelog/secrets/$(SECRET)"
.PHONY: as
as: add-secret

DONE := $(YELLOW)(press any key when done)$(NORMAL)

.PHONY: howto-rotate-secret
howto-rotate-secret:
	@printf "$(BOLD)$(GREEN)All commands must be run in this directory. I propose a new side-by-side split to these instructions.$(NORMAL)\n\n"
	@printf " 1/10. Add new secret to our vault by running e.g. $(BOLD)make add-secret SECRET=ALGOLIA_API_KEY_2$(NORMAL)\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 2/10. Update secret reference in $(BOLD)Makefile$(NORMAL) (search for e.g. ALGOLIA_API_KEY) and ensure that it works by running e.g. $(BOLD)make algolia$(NORMAL)\n       If last comamnd fails, manually sync vault state by running $(BOLD)make sync-secrets$(NORMAL) and repeat\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 3/10. Add new secret to production by running $(BOLD)make create-docker-secrets$(NORMAL)\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 4/10. Add new secret reference to $(BOLD)docker/$(DOCKER_STACK).stack.yml$(NORMAL) as a new entry under $(BOLD)secrets:$(NORMAL) as well as $(BOLD)services: > app: > secrets:$(NORMAL)\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 5/10. Maybe repeat the previous step for $(BOLD)docker/local.stack.yml$(NORMAL)\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 6/10. Commit & push all changes to GitHub\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 7/10. Apply the stack modifications by running $(BOLD)make bootstrap-docker$(NORMAL)\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 8/10. After the previous command succeeds, ensure the new secret is available in the $(BOLD)$(DOCKER_STACK)_app$(NORMAL) service\n       Run $(BOLD)make ctop > select running $(DOCKER_STACK)_app instance & ENTER > exec shell$(NORMAL), then run e.g. $(BOLD)cat /var/run/secrets/ALGOLIA_API_KEY_2$(NORMAL) inside the container\n" ; read -rp " $(DONE)" -n 1
	@printf "\n 9/10. Modify app to use new secret reference in either $(BOLD)config/config.exs$(NORMAL) or $(BOLD)config/prod.exs$(NORMAL)\n" ; read -rp " $(DONE)" -n 1
	@printf "\n10/10. Commit & push to GitHub\n" ; read -rp " $(DONE)" -n 1
	@printf "\n$(BOLD)$(GREEN)I know, that was really long & convoluted... BUT YOU DID IT!\nWhen the new app instance starts, it will use the new secret 🙌🏻 $(NORMAL)\n"
	@printf "To double-check, search for e.g. $(BOLD)ALGOLIA_API_KEY_2$(NORMAL) in the app's logs in Papertrail\n"

.PHONY: create-dirs-mounted-as-volumes
create-dirs-mounted-as-volumes:
	@mkdir -p $(CURDIR)/priv/{uploads,db}

.PHONY: help
help:
	@awk -F"[:#]" '/^[^\.][a-zA-Z\._\-]+:+.+##.+$$/ { printf "\033[36m%-24s\033[0m %s\n", $$1, $$4 }' $(MAKEFILE_LIST) \
	| sort
# Continuous Feedback for the help target - run in a split window while iterating on it
.PHONY: CFhelp
CFhelp: $(WATCH)
	@$(WATCH_MAKE_TARGET) help

.PHONY: clean-docker
clean-docker: $(DOCKER) $(COMPOSE) ## cd  | Remove all changelog containers, images & volumes
	@$(COMPOSE) stop && \
	$(DOCKER) stack rm $(DOCKER_STACK) && \
	$(DOCKER) system prune && \
	$(DOCKER) volume prune && \
	$(DOCKER) volume ls | awk '/changelog|$(DOCKER_STACK)/ { system("$(DOCKER) volume rm " $$2) }' ; \
	$(DOCKER) image ls | awk '/changelog|$(DOCKER_STACK)/ { system("$(DOCKER) image rm " $$1 ":" $$2) }' ; \
	$(DOCKER) config ls | awk '/changelog|$(DOCKER_STACK)/ { system("$(DOCKER) config rm " $$2) }'
.PHONY: cd
cd: clean-docker

CIRCLE_CI_ADD_ENV_VAR_URL = https://circleci.com/api/v1.1/project/github/thechangelog/changelog.com/envvar?circle-token=$(CIRCLE_TOKEN)
.PHONY: configure-ci-secrets
configure-ci-secrets: configure-ci-docker-secret configure-ci-coveralls-secret ## ccs | Configure CircleCI secrets
.PHONY: ccs
ccs: configure-ci-secrets

.PHONY: configure-ci-docker-secret
configure-ci-docker-secret: $(LPASS) $(JQ) $(CURL) circle-token
	@DOCKER_CREDENTIALS=$$($(LPASS) show --json 2219952586317097429) && \
	DOCKER_USER="$$($(JQ) --compact-output '.[] | {name: "DOCKER_USER", value: .username}' <<< $$DOCKER_CREDENTIALS)" && \
	DOCKER_PASS="$$($(JQ) --compact-output '.[] | {name: "DOCKER_PASS", value: .password}' <<< $$DOCKER_CREDENTIALS)" && \
	$(CURL) --silent --fail --request POST --header "Content-Type: application/json" -d "$$DOCKER_USER" "$(CIRCLE_CI_ADD_ENV_VAR_URL)" && \
	$(CURL) --silent --fail --request POST --header "Content-Type: application/json" -d "$$DOCKER_PASS" "$(CIRCLE_CI_ADD_ENV_VAR_URL)"
.PHONY: ccds
ccds: configure-ci-docker-secret

.PHONY: configure-ci-coveralls-secret
configure-ci-coveralls-secret: $(LPASS) $(JQ) $(CURL) circle-token
	@COVERALLS_TOKEN='{"name":"COVERALLS_REPO_TOKEN", "value":"'$$($(LPASS) show --notes 8654919576068551356)'"}' && \
	$(CURL) --silent --fail --request POST --header "Content-Type: application/json" -d "$$COVERALLS_TOKEN" "$(CIRCLE_CI_ADD_ENV_VAR_URL)"
.PHONY: cccs
.PHONY: cccs
cccs: configure-ci-coveralls-secret

.PHONY: contrib
contrib: $(COMPOSE) create-dirs-mounted-as-volumes ## c   | Contribute to changelog.com by running a local copy
	@bash -c "trap '$(COMPOSE) down' INT ; \
	  $(COMPOSE) up ; \
	  [[ $$? =~ 0|2 ]] || \
	    ( echo 'You might want to run $(BOLD)make clean contrib$(NORMAL) if app dependencies have changed' && exit 1 )"
.PHONY: c
c: contrib

.PHONY: clean
clean:
	@rm -fr deps _build assets/node_modules

.PHONY: create-docker-secrets
create-docker-secrets: $(LPASS) ## cds | Create Docker secrets
	@$(SECRETS) | \
	awk '! /secrets\/? / { print($$1) }' | \
	while read -r secret ; do \
	  export secret_key="$$($(LPASS) show --name $$secret)" ; \
	  export secret_value="$$($(LPASS) show --notes $$secret)" ; \
	  echo "Creating $(BOLD)$(YELLOW)$$secret_key$(NORMAL) secret on $(HOST)..." ; \
	  echo "Prevent ssh from hijacking stdin: https://github.com/koalaman/shellcheck/wiki/SC2095" > /dev/null ; \
	  if [ $(HOST) = localhost ] ; then \
	    echo $$secret_value | docker secret create $$secret_key - || true ; \
	  else \
	    ssh $(HOST_SSH_USER)@$(HOST) "echo $$secret_value | docker secret create $$secret_key - || true" < /dev/null || exit 1 ; \
	  fi \
	done && \
	echo "$(BOLD)$(GREEN)All secrets are now setup as Docker secrets$(NORMAL)" && \
	echo "A Docker secret cannot be modified - it can only be removed and created again, with a different value" && \
	echo "A Docker secret can only be removed if it is not bound to a Docker service" && \
	echo "It might be easier to define a new secret, e.g. $(BOLD)ALGOLIA_API_KEY2$(NORMAL)"
.PHONY: cds
cds: create-docker-secrets

define VERSION_CHECK
VERSION="$$($(CURL) --silent --location \
  --write-out '$(NORMAL)HTTP/%{http_version} %{http_code} in %{time_total}s' \
  http://$(HOSTNAME)/version.txt)" && \
echo $(BOLD)$(GIT_COMMIT)$$VERSION @ $$(date)
endef
.PHONY: check-deployed-version
check-deployed-version: GIT_COMMIT = $(GIT_REPOSITORY)/commit/
check-deployed-version: $(CURL) ## cdv | Check the currently deployed git sha
	@$(VERSION_CHECK)
.PHONY: cdv
cdv: check-deployed-version

.PHONY: check-deployed-version-local
check-deployed-version-local: HOSTNAME = $(HOSTNAME_LOCAL)
check-deployed-version-local: $(CURL)
	@$(VERSION_CHECK)
.PHONY: cdvl
cdvl: check-deployed-version-local

.PHONY: remove-docker-secrets
remove-docker-secrets: $(LPASS)
	@if [ $(HOST) = localhost ] ; then \
	  docker secret ls | awk '/ago/ { system("docker secret rm " $$1) }' ; \
	else \
	  ssh $(HOST_SSH_USER)@$(HOST) "docker secret ls | awk '/ago/ { system(\"docker secret rm \" \$$1) }'" ; \
	fi
.PHONY: rds
rds: remove-docker-secrets

.PHONY: deploy-docker-stack
deploy-docker-stack: $(DOCKER) ## dds | Deploy the changelog.com Docker Stack
	@export HOSTNAME ; \
	$(DOCKER) service scale $(DOCKER_STACK)_app_updater=0 ; \
	$(DOCKER) stack deploy --compose-file $(DOCKER_STACK_FILE) --prune $(DOCKER_STACK)
.PHONY: dds
dds: deploy-docker-stack

priv/db:
	@mkdir -p priv/db

.PHONY: deploy-docker-stack-local
deploy-docker-stack-local: DOCKER_STACK_FILE = docker/local.stack.yml
deploy-docker-stack-local: deploy-docker-stack priv/db
.PHONY: ddsl
ddsl: deploy-docker-stack-local

.PHONY: update-app-service-local
update-app-service-local: $(DOCKER)
	@$(DOCKER) service update --force --image thechangelog/changelog.com:local --update-monitor 10s $(DOCKER_STACK)_app
.PHONY: uasl
uasl: update-app-service-local

.PHONY: env-secrets
env-secrets: postgres campaignmonitor github hackernews aws backups_aws twitter app slack rollbar buffer coveralls algolia plusplus ## es  | Print secrets stored in LastPass as env vars
.PHONY: es
es: env-secrets

.PHONY: iaas
iaas: linode-token dnsimple-creds terraform/dhparams.pem init validate apply ## i   | Provision IaaS infrastructure
.PHONY: i
i: iaas

.PHONY: init
init: $(TERRAFORM)
	@$(TF) init

.PHONY: validate
validate: $(TERRAFORM)
	@$(TF_VAR) && $(TF) validate

.PHONY: plan
plan: $(TERRAFORM)
	@$(TF_VAR) && $(TF) plan

.PHONY: apply
apply: $(TERRAFORM)
	@$(TF_VAR) && $(TF) apply

.PHONY: legacy-assets
legacy-assets: $(DOCKER)
	@echo "$(YELLOW)This is a secret target that is only meant to be executed if legacy assets are present locally$(NORMAL)" && \
	echo "$(YELLOW)If this runs with an incorrect $(BOLD)./nginx/www/wp-content$(NORMAL)$(YELLOW), the resulting Docker image will miss relevant files$(NORMAL)" && \
	read -rp "Are you sure that you want to continue? (y|n) " -n 1 && ([[ $$REPLY =~ ^[Yy]$$ ]] || exit) && \
	cd nginx && $(DOCKER) build --tag thechangelog/legacy_assets --file Dockerfile.legacy_assets . && \
	$(DOCKER) push thechangelog/legacy_assets

CHANGELOG_SERVICES_SEPARATOR := ----------------------------------------------------------------------------------------
define CHANGELOG_SERVICES

                                                                        $(BOLD)$(RED)Private$(NORMAL)   $(BOLD)$(GREEN)Public$(NORMAL)
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(RED)Papertrail$(NORMAL)               | https://papertrailapp.com/dashboard                       |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(RED)Fastly$(NORMAL)                   | https://manage.fastly.com/services/all                    |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(RED)Linode$(NORMAL)                   | https://cloud.linode.com/dashboard                        |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(RED)Pivotal Tracker$(NORMAL)          | https://www.pivotaltracker.com/n/projects/1650121         |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(RED)Rollbar Dashboard$(NORMAL)        | https://rollbar.com/changelogmedia/changelog.com/         |
| $(BOLD)$(RED)Rollbar Deploys$(NORMAL)          | https://rollbar.com/changelogmedia/changelog.com/deploys/ |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(RED)Pingdom Uptime$(NORMAL)           | https://my.pingdom.com/reports/uptime                     |
| $(BOLD)$(RED)Pingdom Page Speed$(NORMAL)       | https://my.pingdom.com/reports/rbc                        |
| $(BOLD)$(RED)Pingdom Visitor Insights$(NORMAL) | https://my.pingdom.com/3/visitor-insights                 |
| $(BOLD)$(GREEN)Pingdom Status$(NORMAL)           | http://status.changelog.com/                              |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(GREEN)Netdata$(NORMAL)                  | http://netdata.changelog.com                              |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(GREEN)DockerHub$(NORMAL)                | https://hub.docker.com/u/thechangelog                     |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(GREEN)CircleCI$(NORMAL)                 | https://circleci.com/gh/thechangelog/changelog.com        |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(GREEN)GitHub$(NORMAL)                   | https://github.com/thechangelog/changelog.com             |
$(CHANGELOG_SERVICES_SEPARATOR)
| $(BOLD)$(GREEN)Slack$(NORMAL)                    | https://changelog.slack.com/                              |
$(CHANGELOG_SERVICES_SEPARATOR)

endef
export CHANGELOG_SERVICES
.PHONY: list-services
list-services: ## ls  | List of all services used by changelog.com
	@echo "$$CHANGELOG_SERVICES"
.PHONY: ls
ls: list-services

.PHONY: preview-readme
preview-readme: $(DOCKER) ## pre | Preview README & live reload on edit
	@$(DOCKER) run --interactive --tty --rm --name changelog_md \
	  --volume $(CURDIR):/data \
	  --volume $(HOME)/.grip:/.grip \
	  --expose 5000 --publish 5000:5000 \
	  mbentley/grip --context=. 0.0.0.0:5000
.PHONY: pre
pre: preview-readme

.PHONY: e2e
e2e: $(BATS) $(CURL)

.PHONY: proxy-test
proxy-test: FQDN = $(DOMAIN)
proxy-test: IPv4 = 69.164.223.133
proxy-test: e2e
	@cd test/e2e && \
	$(BATS) proxy.bats proxy.prod.bats
.PHONY: pt
pt: proxy-test

.PHONY: proxy-test-local
proxy-test-local: FQDN = $(HOSTNAME_LOCAL)
proxy-test-local: IPv4 = 127.0.0.1
proxy-test-local: e2e
	@cd test/e2e && \
	$(BATS) proxy.bats proxy.local.bats
.PHONY: ptl
ptl: proxy-test-local

.PHONY: report-deploy
report-deploy: report-deploy-slack report-deploy-rollbar

.PHONY: report-deploy-rollbar
report-deploy-rollbar: $(CURL)
	@ROLLBAR_ACCESS_TOKEN="$$(cat /run/secrets/ROLLBAR_ACCESS_TOKEN)" && export ROLLBAR_ACCESS_TOKEN && \
	COMMIT_USER="$$(cat ./COMMIT_USER)" && export COMMIT_USER && \
	COMMIT_SHA="$$(cat ./COMMIT_SHA)" && export COMMIT_SHA && \
	$(CURL) --silent --fail --output /dev/null --request POST --url https://api.rollbar.com/api/1/deploy/ \
	  --data '{"access_token":"'$$ROLLBAR_ACCESS_TOKEN'","environment":"'$$ROLLBAR_ENVIRONMENT'","rollbar_username":"'$$COMMIT_USER'","revision":"'$$COMMIT_SHA'","comment":"Running in container '$$HOSTNAME' on host '$$NODE'"}'

.PHONY: report-deploy-slack
report-deploy-slack: $(CURL)
	@SLACK_DEPLOY_WEBHOOK="$$(cat /run/secrets/SLACK_DEPLOY_WEBHOOK)" && export SLACK_DEPLOY_WEBHOOK && \
	COMMIT_USER="$$(cat ./COMMIT_USER)" && export COMMIT_USER && \
	COMMIT_SHA="$$(cat ./COMMIT_SHA)" && export COMMIT_SHA && \
	$(CURL) --silent --fail --output /dev/null --request POST --url $$SLACK_DEPLOY_WEBHOOK \
	  --header 'Content-type: application/json' \
	  --data '{"text":"<$(GIT_REPOSITORY)/commit/'$$COMMIT_SHA'|'$${COMMIT_SHA:0:7}'> by <$(GIT_REPOSITORY)/commits?author='$$COMMIT_USER'|'$$COMMIT_USER'> just started, it will be promoted to live when healthy. <$(GIT_REPOSITORY)/blob/master/docker/$(DOCKER_STACK).stack.yml|$(DOCKER_STACK).stack>"}'

.PHONY: rsync-image-uploads-to-local
rsync-image-uploads-to-local: create-dirs-mounted-as-volumes
	@rsync --archive --delete --update --inplace --verbose --progress --human-readable \
	  "$(HOST_SSH_USER)@$(HOST):/uploads/{avatars,covers,icons,logos}" $(CURDIR)/priv/uploads/

.PHONY: rsync-all-uploads-to-local
rsync-all-uploads-local: create-dirs-mounted-as-volumes
	@rsync --archive --delete --update --inplace --verbose --progress --human-readable \
	  "$(HOST_SSH_USER)@$(HOST):/uploads/" $(CURDIR)/priv/uploads/

.PHONY: secrets
secrets: $(LPASS) ## s   | List all LastPass secrets
	@$(SECRETS)
.PHONY: s
s: secrets

.PHONY: test
test: $(COMPOSE) ## t   | Run tests as they run on CircleCI
	@$(COMPOSE) run --rm -e MIX_ENV=test -e DB_NAME=changelog_test app mix test
.PHONY: t
t: test

test_flakes:
	@mkdir -p test_flakes

TEST_RUNS ?= 10
.PHONY: find-flaky-tests
find-flaky-tests: test_flakes
	@for TEST_RUN_NO in {1..$(TEST_RUNS)}; do \
	  echo "RUNNING TEST $$TEST_RUN_NO ... " ; \
	  ($(MAKE) --no-print-directory test >> test_flakes/$$TEST_RUN_NO && \
	    rm test_flakes/$$TEST_RUN_NO && \
	    echo -e "$(GREEN)PASS$(NORMAL)\n") || \
	  echo -e "$(RED)FAIL$(NORMAL)\n"; \
	done

define UPDATE_NETDATA
docker pull netdata/netdata && \
docker service update --force --image netdata/netdata $(DOCKER_STACK)_netdata
endef
.PHONY: update_netdata
update_netdata:
	@ssh -t $(HOST_SSH_USER)@$(HOST) "$(UPDATE_NETDATA)"

define DIRENV

We like $(BOLD)https://direnv.net/$(NORMAL) to manage environment variables.
This is an $(BOLD).envrc$(NORMAL) template that you can use as a starting point:

    PATH_add script
    PATH_add bin
    PATH_add ~/.krew/bin

    export XDG_CONFIG_HOME=$$(expand_path .config)

    export CIRCLE_TOKEN=
    export TF_VAR_linode_token=
    export LINODE_CLI_TOKEN=
    export DNSIMPLE_ACCOUNT=
    export DNSIMPLE_TOKEN=

endef
export DIRENV
.PHONY: circle-token
circle-token:
ifndef CIRCLE_TOKEN
	@echo "$(RED)CIRCLE_TOKEN$(NORMAL) environment variable must be set\n" && \
	echo "Learn more about CircleCI API tokens $(BOLD)https://circleci.com/docs/2.0/managing-api-tokens/$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: linode-token
linode-token:
ifndef TF_VAR_linode_token
	@echo "$(RED)TF_VAR_linode_token$(NORMAL) environment variable must be set" && \
	echo "Learn more about Linode API tokens $(BOLD)https://cloud.linode.com/profile/tokens$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: linode-cli-token
linode-cli-token:
ifndef LINODE_CLI_TOKEN
	@echo "$(RED)LINODE_CLI_TOKEN$(NORMAL) environment variable must be set" && \
	echo "Learn more about Linode API tokens $(BOLD)https://cloud.linode.com/profile/tokens$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: dnsimple-creds
dnsimple-creds:
ifndef DNSIMPLE_ACCOUNT
	@echo "$(RED)DNSIMPLE_ACCOUNT$(NORMAL) environment variable must be set" && \
	echo "This will be the account's numerical ID, e.g. $(BOLD)00000$(NORMAL)" && \
	echo "$$DIRENV" && \
	exit 1
endif
ifndef DNSIMPLE_TOKEN
	@echo "$(RED)DNSIMPLE_TOKEN$(NORMAL) environment variable must be set" && \
	echo "Get a DNSimple user access token $(BOLD)https://dnsimple.com/user?account_id=$(DNSIMPLE_ACCOUNT)$(NORMAL) " && \
	echo "$$DIRENV" && \
	exit 1
endif

.PHONY: sync-secrets
sync-secrets: $(LPASS)
	@$(LPASS) sync

.PHONY: postgres
postgres: $(LPASS)
	@echo "export PG_DOTCOM_PASS=$$($(LPASS) show --notes 7298637973371173308)"

.PHONY: campaignmonitor
CM_SMTP_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/CM_SMTP_TOKEN)"
CM_API_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/CM_API_TOKEN_2)"
campaignmonitor: $(LPASS)
	@echo "export CM_SMTP_TOKEN=$(CM_SMTP_TOKEN)" && \
	echo "export CM_API_TOKEN=$(CM_API_TOKEN)"
.PHONY: campaignmonitor-lke-secret
campaignmonitor-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic campaignmonitor \
	  --from-literal=smtp_token=$(CM_SMTP_TOKEN) \
	  --from-literal=api_token=$(CM_API_TOKEN) \
	| $(KUBECTL) apply --filename -

GITHUB_CLIENT_ID := "$$($(LPASS) show --notes Shared-changelog/secrets/GITHUB_CLIENT_ID)"
GITHUB_CLIENT_SECRET := "$$($(LPASS) show --notes Shared-changelog/secrets/GITHUB_CLIENT_SECRET)"
GITHUB_API_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/GITHUB_API_TOKEN2)"
.PHONY: github
github: $(LPASS)
	@echo "export GITHUB_CLIENT_ID=$(GITHUB_CLIENT_ID)" && \
	echo "export GITHUB_CLIENT_SECRET=$(GITHUB_CLIENT_SECRET)" && \
	echo "export GITHUB_API_TOKEN=$(GITHUB_API_TOKEN)"
.PHONY: github-lke-secret
github-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic github \
	  --from-literal=client_id=$(GITHUB_CLIENT_ID) \
	  --from-literal=client_secret=$(GITHUB_CLIENT_SECRET) \
	  --from-literal=api_token=$(GITHUB_API_TOKEN) \
	| $(KUBECTL) apply --filename -

HACKERNEWS_USER := "$$($(LPASS) show --notes Shared-changelog/secrets/HN_USER_1)"
HACKERNEWS_PASS := "$$($(LPASS) show --notes Shared-changelog/secrets/HN_PASS_1)"
.PHONY: hackernews
hackernews: $(LPASS)
	@echo "export HN_USER=$(HACKERNEWS_USER)" && \
	echo "export HN_PASS=$(HACKERNEWS_PASS)"
.PHONY: hackernews-lke-secret
hackernews-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic hackernews \
	  --from-literal=user=$(HACKERNEWS_USER) \
	  --from-literal=pass=$(HACKERNEWS_PASS) \
	| $(KUBECTL) apply --filename -

AWS_ACCESS_KEY_ID := "$$($(LPASS) show --notes Shared-changelog/secrets/AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY := "$$($(LPASS) show --notes Shared-changelog/secrets/AWS_SECRET_ACCESS_KEY)"
.PHONY: aws
aws: $(LPASS)
	@echo "export AWS_ACCESS_KEY_ID=$(AWS_ACCESS_KEY_ID)" && \
	echo "export AWS_SECRET_ACCESS_KEY=$(AWS_SECRET_ACCESS_KEY)"
.PHONY: aws-lke-secret
aws-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic aws \
	  --from-literal=access_key_id=$(AWS_ACCESS_KEY_ID) \
	  --from-literal=secret_access_key=$(AWS_SECRET_ACCESS_KEY) \
	| $(KUBECTL) apply --filename -

BACKUPS_AWS_ACCESS_KEY := "$$($(LPASS) show --notes Shared-changelog/secrets/BACKUPS_AWS_ACCESS_KEY)"
BACKUPS_AWS_SECRET_KEY := "$$($(LPASS) show --notes Shared-changelog/secrets/BACKUPS_AWS_SECRET_KEY)"
.PHONY: backups_aws
backups_aws: $(LPASS)
	@echo "export BACKUPS_AWS_ACCESS_KEY=$(BACKUPS_AWS_ACCESS_KEY)" && \
	echo "export BACKUPS_AWS_SECRET_KEY=$(BACKUPS_AWS_SECRET_KEY)"
.PHONY: backups-aws-lke-secret
backups-aws-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic backups-aws \
	  --from-literal=access_key_id=$(BACKUPS_AWS_ACCESS_KEY) \
	  --from-literal=secret_access_key=$(BACKUPS_AWS_SECRET_KEY) \
	| $(KUBECTL) apply --filename -

TWITTER_CONSUMER_KEY := "$$($(LPASS) show --notes Shared-changelog/secrets/TWITTER_CONSUMER_KEY)"
TWITTER_CONSUMER_SECRET := "$$($(LPASS) show --notes Shared-changelog/secrets/TWITTER_CONSUMER_SECRET)"
.PHONY: twitter
twitter: $(LPASS)
	@echo "export TWITTER_CONSUMER_KEY=$(TWITTER_CONSUMER_KEY)" && \
	echo "export TWITTER_CONSUMER_SECRET=$(TWITTER_CONSUMER_SECRET)"
.PHONY: twitter-lke-secret
twitter-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic twitter \
	  --from-literal=consumer_key=$(TWITTER_CONSUMER_KEY) \
	  --from-literal=consumer_secret=$(TWITTER_CONSUMER_SECRET) \
	| $(KUBECTL) apply --filename -

SECRET_KEY_BASE := "$$($(LPASS) show --notes Shared-changelog/secrets/SECRET_KEY_BASE)"
SIGNING_SALT := "$$($(LPASS) show --notes Shared-changelog/secrets/SIGNING_SALT)"
.PHONY: app
app: $(LPASS)
	@echo "export SECRET_KEY_BASE=$(SECRET_KEY_BASE)" && \
	echo "export SIGNING_SALT=$(SIGNING_SALT)"
.PHONY: app-lke-secret
app-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic app \
	  --from-literal=secret_key_base=$(SECRET_KEY_BASE) \
	  --from-literal=signing_salt=$(SIGNING_SALT) \
	| $(KUBECTL) apply --filename -

SLACK_INVITE_API_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/SLACK_INVITE_API_TOKEN)"
SLACK_APP_API_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/SLACK_APP_API_TOKEN)"
SLACK_DEPLOY_WEBHOOK := "$$($(LPASS) show --notes Shared-changelog/secrets/SLACK_DEPLOY_WEBHOOK)"
.PHONY: slack
slack: $(LPASS)
	@echo "export SLACK_INVITE_API_TOKEN=$(SLACK_INVITE_API_TOKEN)" && \
	echo "export SLACK_APP_API_TOKEN=$(SLACK_APP_API_TOKEN)"
.PHONY: slack-lke-secret
slack-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic slack \
	  --from-literal=app_api_token=$(SLACK_APP_API_TOKEN) \
	  --from-literal=deploy_webhook=$(SLACK_DEPLOY_WEBHOOK) \
	  --from-literal=invite_api_token=$(SLACK_INVITE_API_TOKEN) \
	| $(KUBECTL) apply --filename -

ROLLBAR_ACCESS_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/ROLLBAR_ACCESS_TOKEN)"
.PHONY: rollbar
rollbar: $(LPASS)
	@echo "export ROLLBAR_ACCESS_TOKEN=$(ROLLBAR_ACCESS_TOKEN)"
.PHONY: rollbar-lke-secret
rollbar-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic rollbar \
	  --from-literal=access_token=$(ROLLBAR_ACCESS_TOKEN) \
	| $(KUBECTL) apply --filename -

BUFFER_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/BUFFER_TOKEN_3)"
.PHONY: buffer
buffer: $(LPASS)
	@echo "export BUFFER_TOKEN=$(BUFFER_TOKEN)"
.PHONY: buffer-lke-secret
buffer-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic buffer \
	  --from-literal=token=$(BUFFER_TOKEN) \
	| $(KUBECTL) apply --filename -

COVERALLS_REPO_TOKEN := "$$($(LPASS) show --notes Shared-changelog/secrets/COVERALLS_REPO_TOKEN)"
.PHONY: coveralls
coveralls: $(LPASS)
	@echo "export COVERALLS_REPO_TOKEN=$(COVERALLS_REPO_TOKEN)"
.PHONY: coveralls-lke-secret
coveralls-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic coveralls \
	  --from-literal=repo_token=$(COVERALLS_REPO_TOKEN) \
	| $(KUBECTL) apply --filename -

ALGOLIA_APPLICATION_ID := "$$($(LPASS) show --notes Shared-changelog/secrets/ALGOLIA_APPLICATION_ID)"
ALGOLIA_API_KEY := "$$($(LPASS) show --notes Shared-changelog/secrets/ALGOLIA_API_KEY2)"
.PHONY: algolia
algolia: $(LPASS)
	@echo "export ALGOLIA_APPLICATION_ID=$(ALGOLIA_APPLICATION_ID)" && \
	echo "export ALGOLIA_API_KEY=$(ALGOLIA_API_KEY)"
.PHONY: algolia-lke-secret
algolia-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic algolia \
	  --from-literal=application_id=$(ALGOLIA_APPLICATION_ID) \
	  --from-literal=api_key=$(ALGOLIA_API_KEY) \
	| $(KUBECTL) apply --filename -

PLUSPLUS_SLUG := "$$($(LPASS) show --notes Shared-changelog/secrets/PLUSPLUS_SLUG_1)"
.PHONY: plusplus
plusplus: $(LPASS)
	@echo "export PLUSPLUS_SLUG_1=$(PLUSPLUS_SLUG)"
.PHONY: plusplus-lke-secret
plusplus-lke-secret: | lke-ctx $(LPASS)
	@$(KUBECTL) --namespace $(CHANGELOG_NAMESPACE) --dry-run=client --output=yaml \
	  create secret generic plusplus \
	  --from-literal=slug=$(PLUSPLUS_SLUG) \
	| $(KUBECTL) apply --filename -
