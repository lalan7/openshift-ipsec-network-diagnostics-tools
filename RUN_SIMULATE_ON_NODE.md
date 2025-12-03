# Running simulate-ipsec-failure.sh on OpenShift Node

## ⚠️ WARNING

**This documentation has NOT been tested and may not work on all OpenShift clusters.**

- Use this document as a **reference guide only**
- Methods described here are theoretical and may require adaptation for your specific cluster
- Results may vary depending on:
  - OpenShift version
  - Node operating system (RHCOS version)
  - Network configuration (OVN, SDN, etc.)
  - Available tools and permissions
- **Test in a non-production environment first**
- **Use at your own risk**

## Overview

The `simulate-ipsec-failure.sh` script requires root privileges and direct access to network interfaces. On OpenShift nodes, you need to use `oc debug node` to access the host filesystem.

## Prerequisites

- `oc` CLI installed and authenticated
- Cluster admin permissions (for `oc debug node`)
- The script file available locally or on the node

## Method 1: Copy Script to Node and Run (Recommended)

### Step 1: Copy script to the node

```bash
# Set your node name
NODE_NAME="worker1.example.com"

# Copy script to node
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "
cat > /tmp/simulate-ipsec-failure.sh << 'SCRIPT_EOF'
$(cat simulate-ipsec-failure.sh)
SCRIPT_EOF
chmod +x /tmp/simulate-ipsec-failure.sh
"
```

### Step 2: Run the script interactively

```bash
# Start interactive debug session
oc debug node/"$NODE_NAME" --to-namespace=default

# Once in the debug pod, run:
chroot /host

# Now run the script
/tmp/simulate-ipsec-failure.sh br-ex 10.75.126.30 0.01
```

### Step 3: Monitor and cleanup

- Press `Ctrl+C` to stop the script (it will cleanup automatically)
- Or manually cleanup if needed:
  ```bash
  oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "tc qdisc del dev br-ex root 2>/dev/null || true"
  ```

## Method 2: Run Script Directly via oc debug (Non-Interactive)

**Note**: This method runs the script but you won't see real-time output easily.

```bash
NODE_NAME="worker1.example.com"
INTERFACE="br-ex"
TARGET_HOST="10.75.126.30"
CORRUPTION_RATE="0.01"

# Base64 encode the script
SCRIPT_B64=$(cat simulate-ipsec-failure.sh | base64 -w 0)

# Run on node
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "
echo '$SCRIPT_B64' | base64 -d > /tmp/simulate.sh
chmod +x /tmp/simulate.sh
/tmp/simulate.sh $INTERFACE $TARGET_HOST $CORRUPTION_RATE
"
```

**Warning**: This runs the script but you won't be able to easily stop it with Ctrl+C. You'll need to manually cleanup.

## Method 3: Run in Background with Cleanup Script

Create a wrapper script that handles cleanup:

```bash
#!/bin/bash
# run-simulate-on-node.sh

NODE_NAME="${1:-worker1.example.com}"
INTERFACE="${2:-br-ex}"
TARGET_HOST="${3:-10.75.126.30}"
CORRUPTION_RATE="${4:-0.01}"

echo "Deploying simulate-ipsec-failure.sh to $NODE_NAME..."

# Copy script to node
SCRIPT_B64=$(cat simulate-ipsec-failure.sh | base64 -w 0)
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "
echo '$SCRIPT_B64' | base64 -d > /tmp/simulate-ipsec-failure.sh
chmod +x /tmp/simulate-ipsec-failure.sh
"

echo "Script deployed. Starting interactive session..."
echo "Run: /tmp/simulate-ipsec-failure.sh $INTERFACE $TARGET_HOST $CORRUPTION_RATE"
echo "Press Ctrl+C in the debug session to stop and cleanup"
echo ""

# Start interactive debug session
oc debug node/"$NODE_NAME" --to-namespace=default
```

## Important Notes

### 1. Root Access
- The script checks for root (`EUID -ne 0`)
- When using `chroot /host`, you have root access to the host
- The script should work correctly

### 2. Network Interface Access
- Use `chroot /host` to access host network interfaces
- Common interfaces: `br-ex`, `ens3`, `eth0`
- List interfaces: `ip link show` or `ifconfig`

### 3. Traffic Control (tc) Tool
- RHCOS nodes should have `tc` available
- If missing, you may need to install: `rpm-ostree install iproute-tc`
- Check availability: `which tc` or `tc -V`

### 4. Cleanup
- The script has a cleanup trap that runs on exit
- If script is killed unexpectedly, manually cleanup:
  ```bash
  oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "tc qdisc del dev <interface> root 2>/dev/null || true"
  ```

### 5. Monitoring
- Watch kernel logs for ICV failures:
  ```bash
  oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "journalctl -k -f | grep -i 'icv\|xfrm'"
  ```

## Example: Complete Workflow

```bash
# 1. Set variables
NODE_NAME="worker1.example.com"
INTERFACE="br-ex"
TARGET_HOST="10.75.126.30"

# 2. Copy script to node
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "
cat > /tmp/simulate-ipsec-failure.sh << 'EOF'
$(cat simulate-ipsec-failure.sh)
EOF
chmod +x /tmp/simulate-ipsec-failure.sh
"

# 3. Start interactive session
oc debug node/"$NODE_NAME" --to-namespace=default

# 4. In the debug pod:
chroot /host
/tmp/simulate-ipsec-failure.sh "$INTERFACE" "$TARGET_HOST" 0.01

# 5. In another terminal, monitor for ICV failures:
oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "journalctl -k -f | grep -i icv"

# 6. Stop script with Ctrl+C (cleanup happens automatically)
```

## Troubleshooting

### Script says "must be run as root"
- Make sure you're using `chroot /host` before running the script
- Verify: `whoami` should show `root` after chroot

### "tc not found" error
- Install iproute-tc: `rpm-ostree install iproute-tc`
- Or check if tc is available: `which tc`

### Can't access network interface
- List available interfaces: `ip link show`
- Make sure you're using `chroot /host`
- Verify interface name matches your cluster (usually `br-ex` for OVN)

### Script doesn't stop
- Press Ctrl+C in the debug session
- If that doesn't work, manually cleanup:
  ```bash
  oc debug node/"$NODE_NAME" --to-namespace=default -- chroot /host bash -c "tc qdisc del dev <interface> root"
  ```

## Security Warning

⚠️ **This script modifies network packets and should ONLY be used in test environments!**

- Do not run on production clusters
- Packet corruption can affect cluster communication
- Always cleanup traffic control rules after testing

