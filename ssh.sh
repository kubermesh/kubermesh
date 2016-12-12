#!/bin/bash

exec ssh -A -o PreferredAuthentications=publickey -o UserKnownHostsFile=/dev/null -o stricthostkeychecking=no core@2001:db8:a001::2 $@
