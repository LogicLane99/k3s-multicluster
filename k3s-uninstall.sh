#!/bin/bash
# =============================================================================
# K3s Multi-Node Cluster Uninstall / Cleanup Script (RHEL10 Air-Gap)
# Removes: k3s server, Podman agent containers, images, network, RPMs, configs
# =============================================================================

set -uo pipefail   # no -e so cleanup continues even if individual steps fail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ── Config ────────────────────────────────────────────────────────────────────
AGENT1_NAME="k3s-agent-1"
AGENT2_NAME="k3s-agent-2"
AGENT_IMAGE="k3s-agent-base:latest"

# ── Must run as root ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERROR]${NC} Must run as root (use sudo)"; exit 1; }

echo -e "${RED}"
echo "  ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗ "
echo "  ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝ "
echo "  ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗"
echo "  ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║"
echo "  ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝"
echo "   ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝ "
echo -e "${NC}"
echo -e "${YELLOW}  This will COMPLETELY remove the K3s cluster and all related data.${NC}"
echo ""
read -rp "  Are you sure you want to continue? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Step 1: Stop & remove Podman agent containers ─────────────────────────────
section "STEP 1 — Remove Agent Containers"

for AGENT in "$AGENT1_NAME" "$AGENT2_NAME"; do
    if podman ps -a --format '{{.Names}}' | grep -q "^${AGENT}$"; then
        log "Stopping container: $AGENT"
        podman stop "$AGENT" 2>/dev/null || warn "Could not stop $AGENT"
        log "Removing container: $AGENT"
        podman rm -f "$AGENT" 2>/dev/null || warn "Could not remove $AGENT"
        ok "Container $AGENT removed"
    else
        warn "Container $AGENT not found — skipping"
    fi
done

# ── Step 2: Remove Podman agent base image ─────────────────────────────────────
section "STEP 2 — Remove Agent Podman Image"

if podman images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${AGENT_IMAGE}$"; then
    log "Removing image: $AGENT_IMAGE"
    podman rmi -f "$AGENT_IMAGE" 2>/dev/null || warn "Could not remove image"
    ok "Image $AGENT_IMAGE removed"
else
    warn "Image $AGENT_IMAGE not found — skipping"
fi

# Clean up any dangling images
log "Cleaning dangling Podman images"
podman image prune -f 2>/dev/null || true

# ── Step 3: Uninstall K3s server ──────────────────────────────────────────────
section "STEP 3 — Uninstall K3s Server"

if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
    log "Running k3s-uninstall.sh"
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || warn "k3s-uninstall.sh encountered errors"
    ok "k3s-uninstall.sh completed"
else
    warn "k3s-uninstall.sh not found — cleaning manually"
    log "Stopping k3s service"
    systemctl stop k3s 2>/dev/null || true
    systemctl disable k3s 2>/dev/null || true
    rm -f /etc/systemd/system/k3s.service
    rm -f /etc/systemd/system/k3s.service.env
    systemctl daemon-reload
    ok "k3s service removed manually"
fi

# Also kill any lingering k3s processes
log "Killing any remaining k3s processes"
pkill -9 -f "k3s " 2>/dev/null || true
pkill -9 -f "k3s-server" 2>/dev/null || true
pkill -9 -f "k3s-agent" 2>/dev/null || true

# ── Step 4: Remove K3s data & config directories ─────────────────────────────
section "STEP 4 — Remove K3s Data & Config Directories"

DIRS=(
    "/var/lib/rancher/k3s"
    "/etc/rancher/k3s"
    "/var/log/k3s"
    "/run/k3s"
    "/run/flannel"
    "/var/lib/kubelet"
    "/root/k3s-cluster.env"
)

for D in "${DIRS[@]}"; do
    if [[ -e "$D" ]]; then
        log "Removing: $D"
        rm -rf "$D"
        ok "Removed $D"
    else
        warn "$D not found — skipping"
    fi
done

# ── Step 5: Remove K3s binaries & helper scripts ─────────────────────────────
section "STEP 5 — Remove K3s Binaries"

BINS=(
    /usr/local/bin/k3s
    /usr/local/bin/k3s-uninstall.sh
    /usr/local/bin/k3s-agent-uninstall.sh
    /usr/local/bin/kubectl
    /usr/local/bin/crictl
    /usr/local/bin/ctr
)

for B in "${BINS[@]}"; do
    if [[ -f "$B" ]]; then
        log "Removing binary: $B"
        rm -f "$B"
        ok "Removed $B"
    fi
done

# ── Step 6: Remove network interfaces ─────────────────────────────────────────
section "STEP 6 — Clean Up Network Interfaces"

IFACES=(flannel.1 cni0 kube-ipvs0 flannel-whl)
for IFACE in "${IFACES[@]}"; do
    if ip link show "$IFACE" &>/dev/null; then
        log "Deleting interface: $IFACE"
        ip link delete "$IFACE" 2>/dev/null || warn "Could not delete $IFACE"
        ok "Deleted $IFACE"
    else
        warn "Interface $IFACE not found — skipping"
    fi
done

# ── Step 7: Flush iptables rules ──────────────────────────────────────────────
section "STEP 7 — Flush iptables Rules"

log "Flushing iptables"
iptables -F          2>/dev/null || warn "iptables -F failed"
iptables -t nat -F   2>/dev/null || warn "iptables nat flush failed"
iptables -t mangle -F 2>/dev/null || warn "iptables mangle flush failed"
iptables -X          2>/dev/null || warn "iptables -X failed"
ok "iptables flushed"

# ── Step 8: Remove CNI config & plugins ───────────────────────────────────────
section "STEP 8 — Remove CNI Config & Plugins"

for D in /etc/cni/net.d /opt/cni/bin; do
    if [[ -d "$D" ]]; then
        log "Removing: $D"
        rm -rf "$D"
        ok "Removed $D"
    fi
done

# ── Step 9: Remove installed RPMs ─────────────────────────────────────────────
section "STEP 9 — Remove K3s RPMs"

INSTALLED_RPMS=$(rpm -qa | grep -i k3s || true)
if [[ -n "$INSTALLED_RPMS" ]]; then
    echo "$INSTALLED_RPMS" | while read -r pkg; do
        log "Removing RPM: $pkg"
        rpm -e --nodeps "$pkg" 2>/dev/null || warn "Could not remove $pkg"
    done
    ok "K3s RPMs removed"
else
    warn "No k3s RPMs found — skipping"
fi

# ── Step 10: Revert sysctl & kernel module config ─────────────────────────────
section "STEP 10 — Revert sysctl & Kernel Modules"

if [[ -f /etc/sysctl.d/k3s.conf ]]; then
    log "Removing /etc/sysctl.d/k3s.conf"
    rm -f /etc/sysctl.d/k3s.conf
    sysctl --system -q
    ok "sysctl config removed"
fi

if [[ -f /etc/modules-load.d/k3s.conf ]]; then
    log "Removing /etc/modules-load.d/k3s.conf"
    rm -f /etc/modules-load.d/k3s.conf
    ok "Module autoload config removed"
fi

log "Unloading kernel modules (non-critical)"
modprobe -r br_netfilter 2>/dev/null || true

# ── Step 11: Clean KUBECONFIG from shell rc ───────────────────────────────────
section "STEP 11 — Clean Shell Environment"

for RC in ~/.bashrc ~/.bash_profile /root/.bashrc /root/.bash_profile; do
    if [[ -f "$RC" ]]; then
        if grep -q 'KUBECONFIG' "$RC" 2>/dev/null; then
            log "Removing KUBECONFIG from $RC"
            sed -i '/KUBECONFIG/d' "$RC"
            ok "Cleaned $RC"
        fi
    fi
done
unset KUBECONFIG 2>/dev/null || true

# ── Final verification ────────────────────────────────────────────────────────
section "FINAL — Verification"

echo ""
log "Checking for leftover k3s processes..."
PROCS=$(ps aux | grep '[k]3s' || true)
[[ -z "$PROCS" ]] && ok "No k3s processes running" || { warn "Leftover processes:"; echo "$PROCS"; }

log "Checking for leftover k3s services..."
SVCS=$(systemctl list-units 2>/dev/null | grep k3s || true)
[[ -z "$SVCS" ]] && ok "No k3s services found" || { warn "Leftover services:"; echo "$SVCS"; }

log "Checking for leftover containers..."
CTRS=$(podman ps -a 2>/dev/null | grep k3s || true)
[[ -z "$CTRS" ]] && ok "No k3s containers found" || { warn "Leftover containers:"; echo "$CTRS"; }

log "Checking for leftover data dirs..."
[[ ! -d /var/lib/rancher ]] && ok "/var/lib/rancher — gone" || warn "/var/lib/rancher still exists"
[[ ! -d /etc/rancher    ]] && ok "/etc/rancher — gone"     || warn "/etc/rancher still exists"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✔  K3s cluster fully removed!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
