# Makefile - thin wrapper around lab/lab.sh.
#
#   make                       list all commands
#   make up                    build and start the lab, then check it
#   make check                 ssh, systemd, reachability and Postgres
#   make ssh ARGS='01'         ssh to a host as deploy (extra args run a command)
#   make push ARGS='01'        copy the project and temporal.env to ~/temporalScale
#   make psql                  psql as temporal inside tlab-pg
#   make stop | make start     power off / on (everything is kept)
#   make down                  remove containers, keep volumes (a fresh root disk)
#   make reset                 remove containers and volumes (empty Postgres)
#   make ui-up | make ui-down  the Web UI inside tlab-01's network

LAB := ./lab/lab.sh
ARGS ?=

.DEFAULT_GOAL := help
.PHONY: help up check ssh push psql stop start down reset ui-up ui-down

help:
	@$(LAB)

up check ssh push psql stop start down reset ui-up ui-down:
	@$(LAB) $@ $(ARGS)
