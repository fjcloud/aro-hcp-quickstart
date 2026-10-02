ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
CONFIRM ?=

.DEFAULT_GOAL := help

.PHONY: help deploy delete status

help:
	@echo "make deploy          Create the two-node cluster, pull secret, and console login."
	@echo "make status          Show the cluster, node pool, and console URL."
	@echo "make delete CONFIRM=yes"
	@echo "                     Delete the cluster, its resource groups, and the Entra apps."

deploy:
	@"$(ROOT)scripts/deploy.sh"

status:
	@"$(ROOT)scripts/status.sh"

delete:
	@CONFIRM="$(CONFIRM)" "$(ROOT)scripts/delete.sh"
