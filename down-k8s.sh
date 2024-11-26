set -e

# Set verbosity
if [ "${DEBUG}" = 1 ]; then
    set -x
    KUBEADM_VERBOSE="-v=8"
else
    KUBEADM_VERBOSE="-v=3"
fi

BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
SERVICE_DIR="/etc/systemd/system"
COMMAND=$1

# Define global compatibility matrix
declare -A versions=(
    ["containerd"]="v1.7.22"
    ["runc"]="v1.1.14"
    ["cni"]="v1.5.1"
    ["crictl"]="v1.31.1"
    ["nerdctl"]="v1.7.7"
    ["kubernetes"]="v1.31.1"
)

# Log functions
info()  { echo "[INFO] $@"; }
warn()  { echo "[WARN] $@" >&2; }
fatal() { echo "[ERROR] $@" >&2; exit 1; }

# Setup architecture
setup_arch() {
    # case ${ARCH:=$(uname -m)} in
    #     amd64|x86_64) ARCH=amd64 ;;
    #     arm64|aarch64) ARCH=arm64 ;;
    #     *) fatal "unsupported architecture ${ARCH}" ;;
    # esac
    ARCH=amd64
    SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
    mkdir -p ./${ARCH}
    cd ./${ARCH}
}

get_version() {
    local component=$1
    echo "${versions[$component]}"
}

setup_env() {
    # Check if running as root
    # [ "$(id -u)" -eq 0 ] || fatal "You need to be root to perform this install"
    # Set default values
    KUBERNETES_VERSION=${KUBERNETES_VERSION:-$(get_version "kubernetes")}
    CONTAINERD_VERSION=${CONTAINERD_VERSION:-$(get_version "containerd")}
    RUNC_VERSION=${RUNC_VERSION:-$(get_version "runc")}
    CNI_VERSION=${CNI_VERSION:-$(get_version "cni")}
    CRICTL_VERSION=${CRICTL_VERSION:-$(get_version "crictl")}
    NERDCTL_VERSION=${NERDCTL_VERSION:-$(get_version "nerdctl")}
    ADVERTISE_ADDRESS=${ADVERTISE_ADDRESS:-0.0.0.0}
    BIND_PORT=${BIND_PORT:-6443}
}

# Install containerd
download_containerd() {
    info "download containerd"
    FILE=containerd-${CONTAINERD_VERSION#?}-linux-${ARCH}.tar.gz
    if [ ! -f $FILE ] ; then
        curl -LO https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION#?}-linux-${ARCH}.tar.gz
        curl -LO https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
    fi
    

    info "download runc"
    FILE=runc.${ARCH}
    if [ ! -f $FILE ] ; then
        curl -LO https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}
    fi

    info "download CNI plugins"
    FILE=cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz
    if [ ! -f $FILE ] ; then
        curl -LO https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz
    fi

}

download_crictl() {
    info "download crictl"
    FILE=crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz
    if [ ! -f $FILE ] ; then
        curl -LO https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz
    fi
}

download_nerdctl() {
    info "download nerdctl"
    FILE=nerdctl-${NERDCTL_VERSION#*v}-linux-${ARCH}.tar.gz
    if [ ! -f $FILE ] ; then
        curl -LO https://github.com/containerd/nerdctl/releases/download/${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION#*v}-linux-${ARCH}.tar.gz
    fi
}


download_kube_binaries() {
    # download kubeadm, kubelet
    info "download kubeadm and kubelet"
    FILE=kubeadm
    if [ ! -f $FILE ] ; then
        curl -LO https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubeadm
    fi
    FILE=kubelet
    if [ ! -f $FILE ] ; then
        curl -LO https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubelet
    fi


    # download kubelet service
    local VERSION="v0.16.2"
    FILE=kubelet.service
    if [ ! -f $FILE ] ; then
        curl -LO https://raw.githubusercontent.com/kubernetes/release/${VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service
    fi
    FILE=10-kubeadm.conf
    if [ ! -f $FILE ] ; then
        curl -LO https://raw.githubusercontent.com/kubernetes/release/${VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf
    fi

    # download kubectl
    info "download kubectl"
    FILE=kubectl
    if [ ! -f $FILE ] ; then
        curl -LO https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubectl
    fi
}

setup_arch
setup_env

download_containerd
download_crictl
download_nerdctl
download_kube_binaries