#!/bin/bash

for domain in `virsh list --all --name | grep kubermesh`; do
  virsh destroy $domain
  virsh undefine $domain
done

rm -rf libvirt/kubermesh*
