#/usr/bin/bash
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

DOWN_SVC=http://192.168.2.163:5000/

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


helper() {
    cat <<EOF
Usage:

  ENV=... yaki <setup|reset|help>

  You must be sudo to run this script.
EOF
}

# Setup architecture
setup_arch() {
    # case ${ARCH:=$(uname -m)} in
    #     amd64|x86_64) ARCH=amd64 ;;
    #     arm64|aarch64) ARCH=arm64 ;;
    #     *) fatal "unsupported architecture ${ARCH}" ;;
    # esac
    ARCH=amd64
    SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
    # mkdir -p ./${ARCH}
    # cd ./${ARCH}
}

get_version() {
    local component=$1
    echo "${versions[$component]}"
}

setup_env() {
    # Check if running as root
    [ "$(id -u)" -eq 0 ] || fatal "You need to be root to perform this install"
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

check_prerequisites() {
    info "Checking if prerequisites are installed"

    # List of required commands
    local required_commands=("conntrack" "socat" "ip" "iptables" "modprobe" "sysctl" "systemctl" "nsenter" "ebtables" "ethtool" "curl")

    for cmd in "${required_commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            info "$cmd is not installed. Please install it before proceeding."
            exit 1
        fi
    done
}

configure_system_settings() {
    info "Configure system settings: "
    info "  - disable swap"
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab

    info "  - enable required kernel modules"
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter

    info "  - forwarding IPv4 and letting iptables see bridged traffic"
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    info "  - apply sysctl settings"
    sysctl --system
}

# Install containerd
conf_containerd(){
    curl -L "${DOWN_SVC}/certs.tar.gz" | sudo tar -C "/etc/containerd" -xz
    chmod 755 `find /etc/containerd/certs.d -type d`
    sed -i 's/      config_path = ""/      config_path = "\/etc\/containerd\/certs.d"/' /etc/containerd/config.toml
}

install_containerd() {
    info "installing containerd"
    DEST="/usr/local"
    curl -L "${DOWN_SVC}/containerd-${CONTAINERD_VERSION#?}-linux-${ARCH}.tar.gz" | tar -C "$DEST" -xz

    mkdir -p /usr/local/lib/systemd/system/
    curl -L "${DOWN_SVC}/containerd.service" -o /usr/local/lib/systemd/system/containerd.service

    info "installing runc"
    curl -L "${DOWN_SVC}/runc.${ARCH}" -o ${SBIN_DIR}/runc
    chmod 755 ${SBIN_DIR}/runc

    info "installing CNI plugins"
    DEST="/opt/cni/bin"
    mkdir -p $DEST
    curl -L "${DOWN_SVC}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz" | tar -C "$DEST" -xz

    info "configuring systemd cgroup driver in containers"
    mkdir -p /etc/containerd
    containerd config default | sed -e "s#SystemdCgroup = false#SystemdCgroup = true#g" > /etc/containerd/config.toml
    conf_containerd
    sed -i '/\[Service\]/a EnvironmentFile='/etc/environment'' /usr/local/lib/systemd/system/containerd.service
    systemctl daemon-reload && systemctl enable --now containerd && systemctl restart containerd
}



# Install crictl
install_crictl() {
    info "installing crictl"
    curl -L "${DOWN_SVC}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" | tar -C $BIN_DIR -xz
    cat <<EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
EOF
}

# Install nerdctl
install_nerdctl() {
    info "installing nerdctl"
    
    # curl -L "http://192.168.2.163:5000/nerdctl-1.7.7-linux-amd64.tar.gz" | tar -C /usr/local/bin -xz
    # sudo nerdctl pull registry.k8s.io/coredns/coredns:v1.11.3
    curl -L "${DOWN_SVC}/nerdctl-${NERDCTL_VERSION#*v}-linux-${ARCH}.tar.gz" | tar -C $BIN_DIR -xz
}

# Install Kubernetes binaries
install_kube_binaries() {
    # Install kubeadm, kubelet, kubectl
    info "installing kubeadm and kubelet"
    cd $BIN_DIR
    curl -L  --remote-name-all ${DOWN_SVC}/{kubeadm,kubelet,kubectl}
    chmod +x {kubeadm,kubelet,kubectl}

    # Install kubelet service
    curl -L "${DOWN_SVC}/kubelet.service" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /etc/systemd/system/kubelet.service
    mkdir -p /etc/systemd/system/kubelet.service.d
    curl -L "${DOWN_SVC}/10-kubeadm.conf" | sed "s:/usr/bin:${BIN_DIR}:g" | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    systemctl daemon-reload && systemctl enable --now kubelet
}

# Main commands
do_kube_setup() {
    info "Prepare the machine for kubernetes"
    check_prerequisites
    configure_system_settings
    install_containerd
    install_crictl
    install_nerdctl
    install_kube_binaries
}

# Remove Kubernetes components
remove_kube() {
    info "removing kubernetes components"
    systemctl stop kubelet || true
    kubeadm reset -f || true
    rm -rf ${BIN_DIR}/{kubeadm,kubelet,kubectl} /etc/kubernetes /var/run/kubernetes /var/lib/kubelet /var/lib/etcd ${SERVICE_DIR}/kubelet.service ${SERVICE_DIR}/kubelet.service.d
    info "Kubernetes components removed"
}



# Remove containerd
remove_containerd() {
    info "removing containerd"
    systemctl stop containerd || true
    rm -rf ${BIN_DIR}/containerd* ${BIN_DIR}/ctr /etc/containerd/ /usr/local/lib/systemd/system/containerd.service
    rm -rf ${SBIN_DIR}/runc ${BIN_DIR}/crictl /etc/crictl.yaml
}

# Remove binaries and configuration files
remove_binaries() {
    info "removing side configuration files and binaries"
    rm -rf /etc/cni/net.d /opt/cni/bin /var/lib/cni /var/log/containers /var/log/pods
}

# Clean up iptables
clean_iptables() {
    info "cleaning up iptables"
    iptables -F
    iptables -t nat -F
    iptables -t mangle -F
    iptables -X
}

reset_cni(){
    ip link set dev cni0 down
    ip link set dev flannel.1 down

    ip link delete cni0
    ip link delete flannel.1

    rm -rf /var/lib/cni/
    rm -rf /etc/cni/net.d/*
}

do_uninstall() {
    info "Cleaning up"
    remove_kube
    remove_containerd
    remove_binaries
    reset_cni
    clean_iptables
}

do_reset(){
    info "reset kubernetes"
    kubeadm reset -f || true
    reset_cni
    clean_iptables
    systemctl restart containerd
    systemctl restart kubelet
    info "Kubernetes reset"
}

setup_arch
setup_env

case ${COMMAND} in
    # init)  do_kube_init && info "init completed successfully" ;;
    # join)  do_kube_join && info "join completed successfully" ;;
    setup) do_kube_setup && info "setup completed successfully" ;;
    reset) do_reset && info "reset completed successfully" ;;
    uninstall) do_uninstall && info "uninstall completed successfully" ;;
    help)  helper ;;
    *)     helper && fatal "use command: setup|reset|help" ;;
esac