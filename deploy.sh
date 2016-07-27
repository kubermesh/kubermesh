#!/bin/bash -e

usage() {
        echo "Usage: $0 %number_of_kubermesh_nodes%"
}

if [ "$1" == "" ]; then
        echo "Cluster size is empty"
        usage
        exit 1
fi

if ! [[ $1 =~ ^[0-9]+$ ]]; then
        echo "'$1' is not a number"
        usage
        exit 1
fi

LIBVIRT_PATH=`pwd`/libvirt
USER_DATA_TEMPLATE=`pwd`/user-data
ASSET_DIR=`pwd`/cluster
ETCD_DISCOVERY=$(curl -s "https://discovery.etcd.io/new?size=1")
CHANNEL=stable
RELEASE=current
RAM=512
CPUs=1
IMG_NAME="coreos_${CHANNEL}_${RELEASE}_qemu_image.img"

if [ ! -d $LIBVIRT_PATH ]; then
        mkdir -p $LIBVIRT_PATH || (echo "Can not create $LIBVIRT_PATH directory" && exit 1)
fi

if [ ! -f $USER_DATA_TEMPLATE ]; then
        echo "$USER_DATA_TEMPLATE template doesn't exist"
        exit 1
fi

if [ ! -d "cluster" ]; then
  docker run --name kubermesh-bootkube quay.io/coreos/bootkube:v0.1.2 /bootkube render --asset-dir=cluster --api-servers=https://127.0.0.1:443 --etcd-servers=http://127.0.0.1:2379
  docker cp kubermesh-bootkube:cluster ${ASSET_DIR}
  docker rm kubermesh-bootkube
fi

if [ ! -f $LIBVIRT_PATH/$IMG_NAME ]; then
        wget https://${CHANNEL}.release.core-os.net/amd64-usr/${RELEASE}/coreos_production_qemu_image.img.bz2 -O - | bzcat > $LIBVIRT_PATH/$IMG_NAME || (rm -f $LIBVIRT_PATH/$IMG_NAME && echo "Failed to download image" && exit 1)
fi

# Seed node configuration

HOSTNAME="kubermesh1"
echo "Configuring seed node ${HOSTNAME}..."

if [ ! -d $LIBVIRT_PATH/$HOSTNAME/openstack/latest ]; then
        mkdir -p $LIBVIRT_PATH/$HOSTNAME/openstack/latest || (echo "Can not create $LIBVIRT_PATH/$HOSTNAME/openstack/latest directory" && exit 1)
fi

if [ ! -f $LIBVIRT_PATH/$HOSTNAME.qcow2 ]; then
        qemu-img create -f qcow2 -b $LIBVIRT_PATH/$IMG_NAME $LIBVIRT_PATH/$HOSTNAME.qcow2
fi

sed "s#%HOSTNAME%#$HOSTNAME#g;s#%DISCOVERY%#$ETCD_DISCOVERY#g" $USER_DATA_TEMPLATE > $LIBVIRT_PATH/$HOSTNAME/openstack/latest/user_data
sed 's/^/      /' ${ASSET_DIR}/auth/kubeconfig >> $LIBVIRT_PATH/$HOSTNAME/openstack/latest/user_data

virt-install --connect qemu:///system \
             --import \
             --name $HOSTNAME \
             --ram $RAM \
             --vcpus $CPUs \
             --os-type=linux \
             --os-variant=virtio26 \
             --disk path=$LIBVIRT_PATH/$HOSTNAME.qcow2,format=qcow2,bus=virtio \
             --filesystem $LIBVIRT_PATH/$HOSTNAME/,config-2,type=mount,mode=squash \
             --vnc \
             --noautoconsole

# Blank node configuration

for SEQ in $(seq 2 $1); do
        HOSTNAME="kubermesh$SEQ"
        echo "Configuring blank node ${HOSTNAME}..."

        if [ ! -f $LIBVIRT_PATH/$HOSTNAME.qcow2 ]; then
                qemu-img create -f qcow2 $LIBVIRT_PATH/$HOSTNAME.qcow2 8.5G
        fi

        virt-install --connect qemu:///system \
                     --name $HOSTNAME \
                     --ram $RAM \
                     --vcpus $CPUs \
                     --os-type=linux \
                     --os-variant=virtio26 \
                     --disk path=$LIBVIRT_PATH/$HOSTNAME.qcow2,format=qcow2,bus=virtio \
                     --filesystem $LIBVIRT_PATH/$HOSTNAME/,config-2,type=mount,mode=squash \
                     --vnc \
                     --pxe \
                     #--noautoconsole
done

echo -n 'Waiting for seed IP'
while [ -z "${SEED_IP}" ]; do
  sleep 1
  echo -n .
  SEED_IP=$(virsh domifaddr kubermesh1 --full --interface vnet0 | grep vnet0 | awk '{print $4}' | cut -d / -f 1)
done
echo
echo "Seed node available at: $SEED_IP"

sleep 5

echo 'Starting bootkube...'
scp -q -o stricthostkeychecking=no -r ${ASSET_DIR} core@${SEED_IP}:/home/core/cluster
ssh -q -o stricthostkeychecking=no core@${SEED_IP} 'docker run --net=host --rm -v /home/core/cluster:/home/core/cluster --name kubermesh-bootkube quay.io/coreos/bootkube:v0.1.2 /bootkube start --asset-dir=/home/core/cluster --etcd-server=http://127.0.0.1:2379'


echo
echo "Bootstrap complete. Access your kubernetes cluster using:"
echo "kubectl --kubeconfig=cluster/auth/kubeconfig get nodes"
echo
