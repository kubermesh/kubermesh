#!/bin/bash

exec ssh -o stricthostkeychecking=no core@`cat ./.ip-file` $@
