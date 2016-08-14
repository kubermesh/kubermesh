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
NETWORK_DIR=`pwd`/networks
VM_CONFIGS=`pwd`/vm-configs
IP_FILE=`pwd`/.ip-file
ETCD_DISCOVERY=$(curl -s "https://discovery.etcd.io/new?size=1")
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
  virsh net-define --file ${NETWORK_DIR}/${network}
  virsh net-autostart ${network}
  virsh net-start ${network}
done

if [ ! -d "cluster" ]; then
  echo "Generating kubernetes assets..."
  docker run --name kubermesh-bootkube quay.io/coreos/bootkube:v0.1.2 /bootkube render --asset-dir=cluster --api-servers=https://[fc4f:b597:4296:b8ca:13c8:9f17:dd30:811d]:443 --etcd-servers=http://127.0.0.1:2379
  docker cp kubermesh-bootkube:cluster ${ASSET_DIR}
  docker rm kubermesh-bootkube
fi

echo "Copying manifests..."
curl https://raw.githubusercontent.com/kubermesh/quagga/master/manifests/quagga-daemonset.yaml -o cluster/manifests/quagga-daemonset.yaml
cp -r manifests/* cluster/manifests/

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
             --network network=kubermesh-internet \
             --network network=kubermesh-1-2 \
             --network network=kubermesh-1-3 \
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
                     `cat ${VM_CONFIGS}/${SEQ}` \
                     --vnc \
                     --boot hd,network \
                     --print-xml > ${LIBVIRT_PATH}/${HOSTNAME}.xml
        sed -i -e 's#</os>#<bios useserial="yes" rebootTimeout="10000"/></os>#' ${LIBVIRT_PATH}/${HOSTNAME}.xml
        virsh define ${LIBVIRT_PATH}/${HOSTNAME}.xml
        virsh start ${HOSTNAME}
done

echo -n 'Waiting for seed IP'
while [ -z "${SEED_IP}" ]; do
  sleep 1
  echo -n .
  for ip in `virsh domifaddr kubermesh1 --full --interface vnet0 | grep vnet0 | awk '{print $4}' | cut -d / -f 1`; do
    if ping6 -c 1 -w 1 ${ip}; then
      SEED_IP=${ip}
    fi
  done
done
echo ${SEED_IP} > ${IP_FILE}
echo
echo "Seed node available at: $SEED_IP"

echo -n 'Waiting for host kubelet'
while ! ./ssh.sh -q rkt list | grep -q kube; do
  sleep 1
  echo -n .
done
echo

echo 'Forcing initial anycast address up'
ssh -q -o stricthostkeychecking=no core@${SEED_IP} 'sudo ip addr add fc4f:b597:4296:b8ca:13c8:9f17:dd30:811d dev dummy0'

echo 'Starting bootkube...'
scp -q -o stricthostkeychecking=no -r ${ASSET_DIR} core@[${SEED_IP}]:/home/core/cluster
ssh -q -o stricthostkeychecking=no core@${SEED_IP} 'docker run --net=host --rm -v /home/core/cluster:/home/core/cluster --name kubermesh-bootkube quay.io/coreos/bootkube:v0.1.2 /bootkube start --asset-dir=/home/core/cluster --etcd-server=http://127.0.0.1:2379'


echo
echo "Bootstrap complete. Access your kubernetes cluster using:"
echo "kubectl --kubeconfig=cluster/auth/kubeconfig get nodes"
echo
