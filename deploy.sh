#!/bin/bash -e

usage() {
        echo "Usage: $0 %number_of_kubermesh_nodes%"
}

if [ "$1" == "" ]; then
        usage
        exit 1
fi

if ! [[ $1 =~ ^[0-9]+$ ]]; then
        echo "'$1' is not a number"
        usage
        exit 1
fi

LIBVIRT_PATH=`pwd`/libvirt
ASSET_DIR=`pwd`/cluster
NETWORK_DIR=`pwd`/networks
VM_CONFIGS=`pwd`/machines
USER_DATA_TEMPLATE=${VM_CONFIGS}/gateway/user-data
GATEWAY_IP=2001:db8:a001::2
CHANNEL=stable
# systemd 227-229 is affected by https://github.com/systemd/systemd/issues/2004, we need at least v231
# As that's not available in any coreos release, we go back to this older version
RELEASE=1010.6.0
RAM=1024
CPUs=1
IMG_NAME="coreos_${CHANNEL}_${RELEASE}_qemu_image.img"

if [ ! -d $LIBVIRT_PATH ]; then
        mkdir -p $LIBVIRT_PATH || (echo "Can not create $LIBVIRT_PATH directory" && exit 1)
fi

if [ ! -f $USER_DATA_TEMPLATE ]; then
        echo "$USER_DATA_TEMPLATE template doesn't exist"
        exit 1
fi

echo "Creating networks..."
for network in `ls -1 ${NETWORK_DIR}`; do
  if ! virsh net-info ${network} >/dev/null 2>/dev/null; then
    virsh net-define --file ${NETWORK_DIR}/${network}
    virsh net-autostart ${network}
    virsh net-start ${network}
  fi
done

if [ ! -d "cluster" ]; then
  echo "Generating kubernetes assets..."
  docker run --name kubermesh-bootkube quay.io/coreos/bootkube:v0.1.2 /bootkube render --asset-dir=cluster --api-servers=https://[fd65:7b9c:569:680:98eb:c508:eb8c:1b80]:443 --etcd-servers=http://[fd65:7b9c:569:680:98eb:c508:ea6b:b0b2]:2379
  docker cp kubermesh-bootkube:cluster ${ASSET_DIR}
  docker rm kubermesh-bootkube
fi

echo "Copying manifests..."
curl -s https://raw.githubusercontent.com/kubermesh/quagga/master/manifests/quagga-daemonset.yaml -o cluster/manifests/quagga-daemonset.yaml
cp -r manifests/* cluster/manifests/

if [ ! -f $LIBVIRT_PATH/$IMG_NAME ]; then
        wget https://${CHANNEL}.release.core-os.net/amd64-usr/${RELEASE}/coreos_production_qemu_image.img.bz2 -O - | bzcat > $LIBVIRT_PATH/$IMG_NAME || (rm -f $LIBVIRT_PATH/$IMG_NAME && echo "Failed to download image" && exit 1)
fi

# Seed node configuration

HOSTNAME="kubermesh-gateway"
echo "Configuring seed node ${HOSTNAME}..."

if [ ! -d $LIBVIRT_PATH/$HOSTNAME/openstack/latest ]; then
        mkdir -p $LIBVIRT_PATH/$HOSTNAME/openstack/latest || (echo "Can not create $LIBVIRT_PATH/$HOSTNAME/openstack/latest directory" && exit 1)
fi

if [ ! -f $LIBVIRT_PATH/$HOSTNAME.qcow2 ]; then
        qemu-img create -q -f qcow2 -b $LIBVIRT_PATH/$IMG_NAME $LIBVIRT_PATH/$HOSTNAME.qcow2
fi

cp $USER_DATA_TEMPLATE $LIBVIRT_PATH/$HOSTNAME/openstack/latest/user_data
sed 's/^/      /' ${ASSET_DIR}/auth/kubeconfig >> $LIBVIRT_PATH/$HOSTNAME/openstack/latest/user_data

virt-install --connect qemu:///system \
             --import \
             --name ${HOSTNAME} \
             --ram 512 \
             --vcpus 1 \
             --os-type=linux \
             --os-variant=virtio26 \
             --serial pty \
             --disk path=${LIBVIRT_PATH}/${HOSTNAME}.qcow2,format=qcow2,bus=virtio \
             --filesystem ${LIBVIRT_PATH}/${HOSTNAME}/,config-2,type=mount,mode=squash \
             --network network=kubermesh-internet \
             --network network=kubermesh-gateway-1 \
             --vnc \
             --noautoconsole

# Blank node configuration

for SEQ in $(seq 1 $1); do
        HOSTNAME="kubermesh$SEQ"
        echo "Configuring blank node ${HOSTNAME}..."

        if [ ! -f $LIBVIRT_PATH/$HOSTNAME.qcow2 ]; then
                qemu-img create -q -f qcow2 $LIBVIRT_PATH/$HOSTNAME.qcow2 8.5G
        fi

        virt-install --connect qemu:///system \
                     --name $HOSTNAME \
                     --ram $RAM \
                     --vcpus $CPUs \
                     --os-type=linux \
                     --os-variant=virtio26 \
                     --serial pty \
                     --disk path=$LIBVIRT_PATH/$HOSTNAME.qcow2,format=qcow2,bus=virtio \
                     `cat ${VM_CONFIGS}/${HOSTNAME}/virt-args` \
                     --vnc \
                     --boot hd,network \
                     --print-xml > ${LIBVIRT_PATH}/${HOSTNAME}.xml
        sed -i -e 's#</os>#<bios useserial="yes" rebootTimeout="10000"/></os>#' ${LIBVIRT_PATH}/${HOSTNAME}.xml
        virsh define ${LIBVIRT_PATH}/${HOSTNAME}.xml
        virsh start ${HOSTNAME}
done

echo -n 'Waiting for gateway'
while ! ping6 -c 1 -w 1 ${GATEWAY_IP} >/dev/null 2>/dev/null; do
  sleep 1
  echo -n .
done
echo
echo "Gateway available at: $GATEWAY_IP (or use ./ssh.sh)"

echo 'Setting flannel network config...'
./ssh.sh -q "/usr/bin/etcdctl set /coreos.com/network/config '{ \"Network\": \"172.31.0.0/16\", \"Backend\": {\"Type\": \"alloc\"} }'"

echo 'Forcing initial anycast addresses up'
./ssh.sh -q 'sudo ip addr add fd65:7b9c:569:680:98eb:c508:eb8c:1b80 dev eth1'


echo -n 'Waiting for dnsmasq container'
while ! ./ssh.sh -q docker inspect dnsmasq >/dev/null 2>/dev/null; do
  sleep 1
  echo -n .
done
echo

echo -n 'Waiting for bootcfg container'
while ! ./ssh.sh -q docker inspect bootcfg >/dev/null 2>/dev/null; do
  sleep 1
  echo -n .
done
echo

echo -n 'Waiting for kubermesh1 to be available'
while ! ./ssh.sh 'ssh -q -o UserKnownHostsFile=/dev/null -o stricthostkeychecking=no `ip neigh show dev eth1 | grep 2001 | awk "{print \\$1}"` true'; do
  sleep 1
  echo -n .
done
echo

echo -n 'Waiting for kubermesh1 kubelet'
while ! ./ssh.sh 'ssh -q -o UserKnownHostsFile=/dev/null -o stricthostkeychecking=no `ip neigh show dev eth1 | grep 2001 | awk "{print \\$1}"` rkt list | grep -q kube'; do
  sleep 1
  echo -n .
done
echo

echo 'Starting bootkube...'
scp -q -o stricthostkeychecking=no -r ${ASSET_DIR} core@[${GATEWAY_IP}]:/home/core/cluster
./ssh.sh -q 'docker run --net=host --rm -v /home/core/cluster:/home/core/cluster --name kubermesh-bootkube quay.io/coreos/bootkube:v0.1.2 /bootkube start --asset-dir=/home/core/cluster --etcd-server=http://127.0.0.1:2379'

echo 'Removing anycast address'
./ssh.sh -q 'sudo ip addr del fd65:7b9c:569:680:98eb:c508:eb8c:1b80 dev eth1'

echo
echo "Bootstrap complete. Access your kubernetes cluster using:"
echo "kubectl --kubeconfig=${PWD}/cluster/auth/kubeconfig get nodes"
echo
