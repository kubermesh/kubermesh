#!/bin/bash

for domain in `virsh list --all --name | grep kubermesh`; do
  virsh destroy $domain
  virsh undefine $domain
done

for network in `virsh net-list --all --name | grep kubermesh`; do
  virsh net-destroy $network
  virsh net-undefine $network
done

rm -rf libvirt/kubermesh*
