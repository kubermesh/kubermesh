# kubermesh

## Goal

1. Deploy to one machine. Say, boot off a USB hard drive.
2. Plug other machines into the first one. Watch them boot and join the cluster.
3. Keep going till you run out of machines.

No need for a traditional network with switches.

Easy replacement, just drop new machines in. And the same goes for adding capacity

This repo is a prototype trying to achieve the above concepts. For more about the project, see [the blog post](http://ocadotechnology.com/blog/creating-a-distributed-data-centre-architecture-using-kubernetes-and-containers/)

## Local dev prerequisites
`sudo apt-get install qemu-kvm libvirt-bin docker virtinst`

## Getting started

`./deploy libvirt 4`

This will set up 4 nodes using libvirt, and run the bootstrap process

Usernames/Passwords are currently hardcoded to `core/core`

## Useful commands

`virt-viewer kubermesh1` - to get a graphical console
`virsh console kubermesh1` - to get a serial console

## Cleaning up

`./teardown`

## Current address allocations

Anycast addresses:
- apiserver: fd65:7b9c:569:680:98eb:c508:eb8c:1b80
- etcd: fd65:7b9c:569:680:98eb:c508:ea6b:b0b2
- docker hub mirror: [fd65:7b9c:569:680:98e8:1762:7b6e:83f6]:5000
- gcr.io mirror: [fd65:7b9c:569:680:98e8:1762:7b6e:61d3]:5002
- quay.io mirror: [fd65:7b9c:569:680:98e8:1762:7abd:e0b7]:5001

libvirt networking:
- host <-> gateway: 172.30.0.1/30
- host <-> gateway: 2001:db8:a001::1/64
- gateway <-> kubermesh1: 172.30.0.9/29
- gateway <-> kubermesh1: 2001:db8:a002::10/126
- gateway docker: 172.30.1.1/24
- flannel ipv4: 172.31.0.0/16
- custom ipv4 allocation: 172.30.2.0/24
- custom ipv6 allocation: 2001:db8::/71

Installation networking:
- ??::0/119
- host: ::0/123
- host vip: ::0/128
- mesh interfaces: ::10/123
- mesh interface 1: ::10/126
- mesh interface 2: ::14/126
- mesh interface 3: ::18/126
- mesh interface 4: ::1c/126
- pods: ::100/120

## Hardware specific
### NUCs
* Disable legacy network boot in the bios, so it will use EFI boot over ipv6
  * Enter the BIOS
  * Select Advanced under `Boot Order`
  * Under `Legacy Boot Priority` disable `Legacy Boot`
  * Under `Boot Configuration` select `Boot Network Devices Last`
  * Under `Boot Configuration` select `Unlimited Boot to Network Attempts`
  * Under `Boot Configuration` check `Network Boot` is set to `UEFI PXE & iSCSI`
  * F10
### USB Devices for the gateway bootstrapping physical hardware
* Plug USB3 ones into a USB2 port, so qemu can use it without Speed Mismatch errors
* Might need to add `/run/udev/data/** r,` to `/etc/apparmor.d/abstractions/libvirt-qemu` until qemu fixes that bug
