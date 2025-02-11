CHANGELOG_DEPLOYMENT := app
CHANGELOG_NAMESPACE := prod-2020-07
CHANGELOG_TREE := $(KUBETREE) deployments $(CHANGELOG_DEPLOYMENT) --namespace $(CHANGELOG_NAMESPACE)
# Copy of https://changelog.com
.PHONY: lke-changelog
lke-changelog: | lke-ctx $(KUBETREE) $(YTT)
	$(YTT) \
	  --data-value app.name=$(CHANGELOG_DEPLOYMENT) \
	  --data-value namespace=$(CHANGELOG_NAMESPACE) \
	  --file $(CURDIR)/k8s/changelog > $(CURDIR)/k8s/changelog.yml \
	&& $(KUBECTL) apply --filename $(CURDIR)/k8s/changelog.yml \
	&& $(CHANGELOG_TREE)

.PHONY: lke-changelog-tree
lke-changelog-tree: | lke-ctx $(KUBETREE)
	$(CHANGELOG_TREE)

.PHONY: lke-changelog-db-restore
lke-changelog-db-restore: | lke-ctx
	$(KUBECTL) exec -it deployments/$(CHANGELOG_DEPLOYMENT) -c db-restore -- bash

.PHONY: lke-changelog-secrets
lke-changelog-secrets:: campaignmonitor-lke-secret
lke-changelog-secrets:: github-lke-secret
lke-changelog-secrets:: hackernews-lke-secret
lke-changelog-secrets:: aws-lke-secret
lke-changelog-secrets:: backups-aws-lke-secret
lke-changelog-secrets:: twitter-lke-secret
lke-changelog-secrets:: app-lke-secret
lke-changelog-secrets:: slack-lke-secret
lke-changelog-secrets:: rollbar-lke-secret
lke-changelog-secrets:: buffer-lke-secret
lke-changelog-secrets:: coveralls-lke-secret
lke-changelog-secrets:: algolia-lke-secret
lke-changelog-secrets:: plusplus-lke-secret
