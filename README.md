# kubermesh

Anycast addresses:
- apiserver: fd65:7b9c:569:680:98eb:c508:eb8c:1b80
- etcd: fd65:7b9c:569:680:98eb:c508:ea6b:b0b2

libvirt networking:
- host <-> gateway: 172.30.0.1/30
- host <-> gateway: 2001:db8:a001::1/64
- gateway <-> kubermesh1: 172.30.0.9/29
- gateway <-> kubermesh1: 2001:db8:a002::1/64
- gateway docker: 172.30.1.1/24
- flannel ipv4: 172.31.0.0/16
- custom ipv4 allocation: 172.30.1.0/24
- custom ipv6 allocation: 2001:db8::/71
