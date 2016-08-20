#!/bin/bash

exec ssh -A -o UserKnownHostsFile=/dev/null -o stricthostkeychecking=no core@`cat ./.ip-file` $@
