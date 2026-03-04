#!/bin/bash
# =============================================================================
# K3s Multi-Node Cluster Install Script (Air-Gap, Single RHEL10 VM)
# Architecture: 1 server (host) + 2 agents (Podman containers)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ── Config — edit these if needed ─────────────────────────────────────────────
K3S_RPM="k3s-1.32.3.rpm"
K3S_AIRGAP_RPM="k3s-airgap-images-1.32.3.rpm"
K3S_INSTALL_SCRIPT="k3s-install-script-1.32.3.rpm"
K3S_SELINUX_RPM="k3s-selinux-1.6.rpm"
AGENT1_NAME="k3s-agent-1"
AGENT2_NAME="k3s-agent-2"
IMAGES_DIR="/var/lib/rancher/k3s/agent/images"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
section "STEP 0 — Pre-flight Checks"

# Must run as root
[[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)"

# Check RPM files exist
for f in "$K3S_RPM" "$K3S_AIRGAP_RPM" "$K3S_INSTALL_SCRIPT" "$K3S_SELINUX_RPM"; do
    [[ -f "$f" ]] || error "Required file not found: $f — run this script from the directory containing your RPMs"
done

# Check podman
command -v podman &>/dev/null || error "podman not found — please install podman first"

log "All pre-flight checks passed"

# ── Step 1: Prepare host ───────────────────────────────────────────────────────
section "STEP 1 — Prepare Host"

log "Setting hostname to k3s-server"
hostnamectl set-hostname k3s-server

log "Disabling firewalld"
systemctl disable --now firewalld 2>/dev/null || warn "firewalld not running, skipping"

log "Disabling swap"
swapoff -a
sed -i '/swap/d' /etc/fstab

log "Enabling IP forwarding and bridge netfilter"
cat <<EOF > /etc/sysctl.d/k3s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system -q

log "Loading kernel modules"
modprobe br_netfilter
modprobe overlay
echo "br_netfilter" >> /etc/modules-load.d/k3s.conf
echo "overlay"      >> /etc/modules-load.d/k3s.conf

log "Host preparation complete"

# ── Step 2: Install RPMs ───────────────────────────────────────────────────────
section "STEP 2 — Install SELinux Policy & K3s Binary"

log "Installing SELinux policy"
rpm -ivh --nodeps "$K3S_SELINUX_RPM" || warn "SELinux RPM may already be installed"

log "Installing k3s binary RPM"
rpm -ivh --nodeps "$K3S_RPM" || warn "k3s RPM may already be installed"

# Verify binary
command -v k3s &>/dev/null || error "k3s binary not found after install"
log "k3s version: $(k3s --version | head -1)"

# ── Step 3: Stage air-gap images ──────────────────────────────────────────────
section "STEP 3 — Stage Air-Gap Images"

mkdir -p "$IMAGES_DIR"

log "Extracting air-gap images RPM"
TMPDIR=$(mktemp -d)
pushd "$TMPDIR" > /dev/null
  rpm2cpio "$(realpath - <<< "$OLDPWD/$K3S_AIRGAP_RPM")" | cpio -idmv 2>/dev/null || true
  # Copy any tar/zst/gz image archives found
  find . -name "*.tar*" -o -name "*.zst" | while read -r img; do
      log "Copying image archive: $img"
      cp "$img" "$IMAGES_DIR/"
  done
popd > /dev/null
rm -rf "$TMPDIR"

# Fallback: copy the RPM itself if no archives extracted
if [[ -z "$(ls -A "$IMAGES_DIR" 2>/dev/null)" ]]; then
    warn "No tar archives found — copying raw RPM to images dir as fallback"
    cp "$K3S_AIRGAP_RPM" "$IMAGES_DIR/"
fi

log "Images staged in $IMAGES_DIR:"
ls -lh "$IMAGES_DIR"

# ── Step 4: Install & start K3s server ────────────────────────────────────────
section "STEP 4 — Install & Start K3s Server"

log "Running k3s install script (air-gap mode)"
chmod +x "$K3S_INSTALL_SCRIPT"

INSTALL_K3S_SKIP_DOWNLOAD=true \
INSTALL_K3S_SELINUX_WARN=true \
bash "$K3S_INSTALL_SCRIPT" server \
    --cluster-init \
    --disable=traefik \
    --write-kubeconfig-mode=644 \
    --node-name k3s-server

log "Enabling and starting k3s service"
systemctl enable --now k3s

log "Waiting for k3s server to become ready (up to 60s)..."
for i in $(seq 1 12); do
    if k3s kubectl get nodes &>/dev/null 2>&1; then
        log "K3s server is ready"
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

systemctl is-active k3s &>/dev/null || error "k3s service failed to start — check: journalctl -u k3s"

# ── Step 5: Get token & host IP ────────────────────────────────────────────────
section "STEP 5 — Retrieve Token & Host IP"

NODE_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
HOST_IP=$(hostname -I | awk '{print $1}')

log "Server IP  : $HOST_IP"
log "Node Token : ${NODE_TOKEN:0:20}... (truncated for display)"

# Save for reference
cat <<EOF > /root/k3s-cluster.env
HOST_IP=$HOST_IP
NODE_TOKEN=$NODE_TOKEN
AGENT1_NAME=$AGENT1_NAME
AGENT2_NAME=$AGENT2_NAME
EOF
log "Saved cluster info to /root/k3s-cluster.env"

# ── Step 6: Build Podman agent base image ─────────────────────────────────────
section "STEP 6 — Build Podman Agent Base Image"

BUILDDIR=$(mktemp -d)
K3S_BIN=$(which k3s)

cat <<'EOF' > "$BUILDDIR/Containerfile"
FROM registry.access.redhat.com/ubi9/ubi:latest

RUN dnf install -y \
    iptables \
    iproute \
    iputils \
    conntrack-tools \
    socat \
    util-linux \
    && dnf clean all

RUN mkdir -p /var/lib/rancher/k3s/agent/images/

CMD ["/bin/bash"]
EOF

log "Building k3s-agent-base image (this may take a minute)..."
podman build -t k3s-agent-base:latest "$BUILDDIR" || error "Podman build failed"
rm -rf "$BUILDDIR"
log "Agent base image built successfully"

# ── Step 7: Start agent containers ────────────────────────────────────────────
section "STEP 7 — Start K3s Agent Containers"

for AGENT in "$AGENT1_NAME" "$AGENT2_NAME"; do
    log "Creating container: $AGENT"
    podman run -d \
        --name "$AGENT" \
        --privileged \
        --network=host \
        --pid=host \
        --cgroupns=host \
        -v /lib/modules:/lib/modules:ro \
        -v "$IMAGES_DIR:$IMAGES_DIR:ro" \
        -v "${K3S_BIN}:/usr/local/bin/k3s:ro" \
        -e K3S_URL="https://${HOST_IP}:6443" \
        -e K3S_TOKEN="${NODE_TOKEN}" \
        -e K3S_NODE_NAME="${AGENT}" \
        k3s-agent-base:latest \
        sleep infinity

    log "Starting k3s agent inside $AGENT"
    podman exec -d "$AGENT" \
        k3s agent \
            --server "https://${HOST_IP}:6443" \
            --token "${NODE_TOKEN}" \
            --node-name "${AGENT}"
done

# ── Step 8: Configure kubectl ──────────────────────────────────────────────────
section "STEP 8 — Configure kubectl"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
grep -q 'KUBECONFIG' ~/.bashrc || echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

# ── Step 9: Wait for all nodes ────────────────────────────────────────────────
section "STEP 9 — Waiting for All Nodes to Join"

log "Waiting for agents to register (up to 90s)..."
for i in $(seq 1 18); do
    READY=$(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
    if [[ "$READY" -ge 3 ]]; then
        log "All 3 nodes are Ready!"
        break
    fi
    echo -n "  Nodes ready: $READY/3 ..."
    sleep 5
done
echo ""

# ── Final status ──────────────────────────────────────────────────────────────
section "DONE — Cluster Status"

k3s kubectl get nodes -o wide
echo ""
k3s kubectl get pods -A
echo ""
echo -e "${GREEN}✔ K3s multi-node cluster is up!${NC}"
echo -e "${YELLOW}  Run: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml${NC}"
echo -e "${YELLOW}  Then: kubectl get nodes${NC}"
