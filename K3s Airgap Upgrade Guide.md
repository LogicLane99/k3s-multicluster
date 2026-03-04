K3s Airgap Upgrade Guide — System Upgrade Controller
Architecture Overview
Nexus Repo (RPM + Images)
        │
        ▼
Each Node pulls RPM & images via internal repo
        │
        ▼
System Upgrade Controller executes Plans
        │
        ▼
Servers upgraded first → Agents upgraded after

Phase 1: Prepare Nexus Artifacts
Ensure the following are available in your Nexus:
ArtifactExampleK3s RPMk3s-selinux-*.rpm, k3s-*.rpmAirgap image tarballk3s-airgap-images-amd64.tar.gzSUC imagerancher/system-upgrade-controller:v0.13.xK3s upgrade imagerancher/k3s-upgrade:v1.x.x-k3s1

Phase 2: Pre-load Images on ALL Nodes
Do this before running any upgrade plan. Must be done on every server and agent node.
bash# On each node — pull from Nexus and import into k3s containerd

# 1. Pull the airgap image tarball from Nexus
curl -o /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.gz \
  http://<nexus-host>:<port>/repository/<repo-name>/k3s-airgap-images-amd64.tar.gz

# 2. Pull the k3s-upgrade image and save it
# On a machine with docker/podman access to Nexus:
podman pull <nexus-host>:<port>/rancher/k3s-upgrade:v1.XX.X-k3sX
podman save rancher/k3s-upgrade:v1.XX.X-k3sX \
  -o /tmp/k3s-upgrade-image.tar

# 3. Import into k3s containerd on each node
sudo k3s ctr images import /tmp/k3s-upgrade-image.tar

# 4. Also import the SUC image
podman pull <nexus-host>:<port>/rancher/system-upgrade-controller:v0.13.4
podman save rancher/system-upgrade-controller:v0.13.4 \
  -o /tmp/suc-image.tar

sudo k3s ctr images import /tmp/suc-image.tar

# Verify images are present
sudo k3s ctr images list | grep -E "k3s-upgrade|system-upgrade"

Phase 3: Configure Yum/DNF to Use Nexus RPM Repo
On every node, configure the repo file:
bash# /etc/yum.repos.d/k3s-nexus.repo
cat <<EOF | sudo tee /etc/yum.repos.d/k3s-nexus.repo
[k3s-nexus]
name=K3s Nexus Repo
baseurl=http://<nexus-host>:<port>/repository/<rpm-repo-name>/
enabled=1
gpgcheck=0
sslverify=0
EOF

# Test repo is reachable
sudo dnf repolist
sudo dnf info k3s  # confirm new version is visible

Phase 4: Deploy System Upgrade Controller
4.1 — Get the SUC manifest
bash# Download from Nexus or use a pre-staged copy
curl -o /tmp/system-upgrade-controller.yaml \
  http://<nexus-host>:<port>/repository/<raw-repo>/system-upgrade-controller.yaml

# Or apply directly if you have the YAML staged
kubectl apply -f /tmp/system-upgrade-controller.yaml
4.2 — Patch SUC to use your internal Nexus image
If the YAML references docker.io or ghcr.io, patch it:
bashkubectl -n system-upgrade set image deployment/system-upgrade-controller \
  system-upgrade-controller=<nexus-host>:<port>/rancher/system-upgrade-controller:v0.13.4
4.3 — Verify SUC is running
bashkubectl -n system-upgrade get pods
kubectl -n system-upgrade logs -l app=system-upgrade-controller

Phase 5: Label Your Nodes
SUC Plans use node label selectors to target servers vs agents.
bash# Label server nodes
kubectl label node <server-node-1> node-role.kubernetes.io/control-plane=true
kubectl label node <server-node-2> node-role.kubernetes.io/control-plane=true

# Agent nodes usually already have the worker label, verify:
kubectl get nodes --show-labels | grep -v control-plane

Phase 6: Create Upgrade Plans
Plan 1 — Server Upgrade
yaml# k3s-server-upgrade-plan.yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-server-upgrade
  namespace: system-upgrade
spec:
  concurrency: 1                        # Upgrade one server at a time
  cordon: true
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: "true"
  serviceAccountName: system-upgrade
  version: v1.XX.X+k3s1                # <<< Set your target version
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
    - effect: NoSchedule
      key: node-role.kubernetes.io/control-plane
      operator: Exists
  upgrade:
    image: <nexus-host>:<port>/rancher/k3s-upgrade  # Point to Nexus
    command:
      - sh
      - -c
    args:
      - |
        # Install new RPM from Nexus
        dnf install -y --repo=k3s-nexus k3s
        # The k3s-upgrade container handles the binary swap

Simpler approach — if your k3s-upgrade image handles everything via the standard entrypoint (it does by default), you can omit command/args and just set the image and version:

yaml# k3s-server-upgrade-plan.yaml (clean version)
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-server-upgrade
  namespace: system-upgrade
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: "true"
  serviceAccountName: system-upgrade
  version: v1.XX.X+k3s1
  tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/control-plane
      operator: Exists
  upgrade:
    image: <nexus-host>:<port>/rancher/k3s-upgrade
Plan 2 — Agent Upgrade (waits for server plan to complete)
yaml# k3s-agent-upgrade-plan.yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: k3s-agent-upgrade
  namespace: system-upgrade
spec:
  concurrency: 2                        # Can do 2 agents at a time
  cordon: true
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  serviceAccountName: system-upgrade
  version: v1.XX.X+k3s1
  prepare:                              # Wait for server plan to complete first
    image: <nexus-host>:<port>/rancher/k3s-upgrade
    args:
      - prepare
      - k3s-server-upgrade              # References the server plan name
  upgrade:
    image: <nexus-host>:<port>/rancher/k3s-upgrade
Apply both plans
bashkubectl apply -f k3s-server-upgrade-plan.yaml
kubectl apply -f k3s-agent-upgrade-plan.yaml

Phase 7: Monitor the Upgrade
bash# Watch plans
kubectl -n system-upgrade get plans -o wide
kubectl -n system-upgrade get jobs -o wide

# Watch upgrade pods as they spawn per node
kubectl -n system-upgrade get pods -w

# Watch nodes — they'll cordon, upgrade, then uncordon
kubectl get nodes -w

# Tail logs of an upgrade job pod
kubectl -n system-upgrade logs -f <upgrade-pod-name>

# Check events if something fails
kubectl -n system-upgrade describe plan k3s-server-upgrade
kubectl -n system-upgrade describe job <job-name>

Phase 8: Verify Upgrade
bash# Check all node versions match target
kubectl get nodes -o wide

# Verify on each node directly
k3s --version

# Check cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running

Rollback (if needed)
SUC doesn't auto-rollback. Manual steps:
bash# On affected node — reinstall previous RPM version from Nexus
sudo dnf downgrade k3s-<old-version> --repo=k3s-nexus

# Restart k3s
sudo systemctl restart k3s        # server
sudo systemctl restart k3s-agent  # agent

Common Pitfalls
IssueFixSUC pod can't pull imageEnsure image pre-imported via k3s ctr images importPlan stuck in Applied=falseCheck SUC logs, verify node labels match selectorAgent plan starts before servers doneMake sure prepare.args: [prepare, k3s-server-upgrade] is setRPM not foundVerify dnf repolist shows nexus repo and dnf info k3s shows new versionNodes not cordoningCheck SUC RBAC — serviceaccount needs proper cluster rolesVersion string mismatchUse exact version string: v1.28.8+k3s1 (use + not -)

Quick Reference — Key Commands Cheatsheet
bash# Import images
k3s ctr images import <tarball>

# Check imported images
k3s ctr images list

# Watch upgrade in real time
watch kubectl get nodes,plans,jobs -n system-upgrade

# Force delete a stuck upgrade pod
kubectl -n system-upgrade delete pod <pod> --force

# Check plan status
kubectl -n system-upgrade get plan k3s-server-upgrade -o yaml | grep -A10 status

The key flow is: pre-load images on all nodes → configure Nexus RPM repo → deploy SUC → apply server plan → agent plan auto-follows. The prepare stanza in the agent plan is what enforces the sequencing so agents never upgrade before all servers are done.
