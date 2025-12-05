# OpenShift IPsec Network Diagnostics Tools

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Tools for troubleshooting IPsec integrity failures (SA-icv-failure / ICV failures) on OpenShift clusters.

## What are ICV Failures?

ICV (Integrity Check Value) failures occur when IPsec encrypted packets fail integrity verification on the receiving end. This typically indicates:
- Data corruption in transit (network hardware, drivers)
- Packet modification between sender and receiver
- Crypto/key synchronization issues

These tools help capture synchronized packet data from both sides to identify where corruption occurs.

## Scripts

| Script | Purpose |
|--------|---------|
| `run-ipsec-diagnostics.sh` | **Full ICV failure diagnostics: xfrm + tcpdump + retis** (recommended) |
| `run-dual-capture.sh` | ESP packet capture on two nodes |
| `run-retis-capture.sh` | Retis dropped packet capture |
| `xfrm-dump.sh` | Dump XFRM state and policy (local Linux only) |
| `capture-config.env` | Configuration for all scripts |
| `simulate-ipsec-failure.sh` | Simulate packet corruption for testing |
| `ipsec-capture-commands.sh` | Generate manual capture commands (fallback) |

## Quick Start

### Full Diagnostics (Recommended)

Run all 3 tools in one command with ICV failure tracking:

```bash
# Clone and run
git clone https://github.com/lalan7/openshift-ipsec-network-diagnostics-tools.git
cd openshift-ipsec-network-diagnostics-tools

# Basic run with ICV monitoring
./run-ipsec-diagnostics.sh --monitor-icv --duration 60

# Full options for ICV failure investigation
./run-ipsec-diagnostics.sh \
    --node1 worker1.example.com \
    --node2 worker2.example.com \
    --retis-node worker2.example.com \
    --monitor-icv \
    --icv-threshold 3 \
    --duration 120 \
    --no-packet-limit

# Skip Retis (faster, tcpdump + xfrm only)
./run-ipsec-diagnostics.sh --duration 30 --skip-retis

# Simple ESP filter (capture all ESP traffic)
./run-ipsec-diagnostics.sh --filter "esp" --duration 30
```

**Output:**
```
~/ipsec-captures/diag-YYYYMMDD-HHMMSS/
├── xfrm-<node1>-start.txt         # XFRM state/policy BEFORE capture
├── xfrm-<node1>-end.txt           # XFRM state/policy AFTER capture
├── xfrm-<node2>-start.txt
├── xfrm-<node2>-end.txt
├── node1-esp.pcap                 # tcpdump ESP from sender
├── node1-timing.txt               # Capture timing info
├── node2-esp.pcap                 # tcpdump ESP from receiver
├── node2-timing.txt
├── retis_icv.data                 # ICV failure tracking data
├── retis-timing.txt
├── retis-output.log
└── sync-time.txt                  # Capture start timestamp
```

### Run from RHEL9 Bastion

Tested and working on RHEL 9.6:

```bash
# SSH to bastion host
ssh user@bastion.example.com

# Clone repo (or copy scripts)
git clone https://github.com/lalan7/openshift-ipsec-network-diagnostics-tools.git
cd openshift-ipsec-network-diagnostics-tools

# Run diagnostics
./run-ipsec-diagnostics.sh --duration 30
```

## Individual Scripts

### 1. Capture ESP Traffic Only

```bash
# Use defaults from capture-config.env
./run-dual-capture.sh

# Override via CLI
./run-dual-capture.sh --node1 worker1.example.com --node2 worker2.example.com --duration 60

# With custom filter
./run-dual-capture.sh --filter "esp" --duration 30
```

### 2. Capture Dropped Packets Only (Retis)

```bash
# Use defaults from capture-config.env
./run-retis-capture.sh

# Override via CLI
./run-retis-capture.sh --node worker1.example.com --duration 60

# With filter
./run-retis-capture.sh --filter "src host 10.0.0.1"
```

### 3. Dump XFRM State/Policy Only

```bash
# Local Linux only
./xfrm-dump.sh /tmp/xfrm-output

# On OpenShift node (via oc debug)
oc debug node/worker1.example.com -- chroot /host bash -c "ip xfrm state show; ip xfrm policy show"
```

## Configuration

All parameters can be set via:
1. **Config file** (`capture-config.env`) - default values
2. **Environment variables** - override config file
3. **CLI arguments** - highest priority

### capture-config.env

```bash
# Node names (set to your actual OpenShift worker nodes)
NODE1_NAME="worker1.example.com"
NODE2_NAME="worker2.example.com"

# Network interface
INTERFACE="br-ex"

# Capture settings
DURATION="30"
PACKET_COUNT="1000"              # Max packets (ignored with --no-packet-limit)
LOCAL_OUTPUT="${HOME}/ipsec-captures"

# tcpdump filter (use {NODE1_IP} and {NODE2_IP} as placeholders)
FILTER="host {NODE1_IP} and host {NODE2_IP} and esp"
TCPDUMP_EXTRA=""

# Retis settings
RETIS_IMAGE="quay.io/retis/retis"
RETIS_FILTER=""
```

### CLI Options

```bash
./run-ipsec-diagnostics.sh --help

Options:
  --node1            First node - sender (default: from config)
  --node2            Second node - receiver (default: from config)
  --interface        Network interface (default: br-ex)
  --duration         Capture duration in seconds (default: 30)
  --output           Local output directory (default: ~/ipsec-captures)
  --filter           tcpdump filter (default: ESP between nodes)
  --skip-retis       Skip Retis capture
  --retis-node       Node where Retis runs (dropping side, default: node2)
  --monitor-icv      Monitor for ICV failures and auto-stop
  --icv-threshold    Number of ICV failures before stopping (default: 3)
  --no-packet-limit  Run tcpdump for full duration (ignore packet count)

By default, tcpdump stops after 1000 packets OR duration, whichever first.
Use --no-packet-limit to capture for the full duration regardless of packet count.

Captures include:
  - XFRM state/policy at START and END (for comparison)
  - tcpdump ESP packets on both nodes (synchronized, full packet -s0)
  - Retis with xfrm_audit_state_icvfail/stack probe on dropping node
```

## Analyzing Captures

### XFRM State/Policy

```bash
# Compare XFRM state before and after capture
diff ~/ipsec-captures/diag-*/xfrm-*-start.txt ~/ipsec-captures/diag-*/xfrm-*-end.txt

# View IPsec Security Associations at start
cat ~/ipsec-captures/diag-*/xfrm-*-start.txt

# Look for:
# - src/dst IPs
# - ESP SPI values
# - aead rfc4106(gcm(aes)) encryption
# - replay-window settings
```

### tcpdump / pcap files

```bash
# Basic read
tcpdump -r ~/ipsec-captures/diag-*/node1-esp.pcap -nn
tcpdump -r ~/ipsec-captures/diag-*/node2-esp.pcap -nn

# Show ESP details
tcpdump -r ~/ipsec-captures/diag-*/node1-esp.pcap -nn -v esp

# Count packets on both nodes (should match for synchronized captures)
echo "Node1: $(tcpdump -r ~/ipsec-captures/diag-*/node1-esp.pcap -nn esp 2>/dev/null | wc -l)"
echo "Node2: $(tcpdump -r ~/ipsec-captures/diag-*/node2-esp.pcap -nn esp 2>/dev/null | wc -l)"
```

### tshark (Wireshark CLI)

```bash
# Full decode
tshark -r ~/ipsec-captures/diag-*/node1-esp.pcap -V -Y "esp"

# Show ESP SPIs and sequence numbers (critical for ICV failure correlation)
tshark -r ~/ipsec-captures/diag-*/node1-esp.pcap -Y "esp" -T fields \
    -e frame.time -e ip.src -e ip.dst -e esp.spi -e esp.sequence

# Compare packets between nodes (find same ESP sequence in both captures)
tshark -r ~/ipsec-captures/diag-*/node2-esp.pcap -Y "esp" -T fields \
    -e frame.time -e ip.src -e ip.dst -e esp.spi -e esp.sequence

# Statistics
tshark -r ~/ipsec-captures/diag-*/node1-esp.pcap -q -z io,stat,1
```

### Retis (ICV failure tracking)

```bash
# On Linux
retis print ~/ipsec-captures/diag-*/retis_icv.data
retis sort ~/ipsec-captures/diag-*/retis_icv.data

# On macOS (via Podman)
podman run --rm -v ~/ipsec-captures:/data:ro quay.io/retis/retis print /data/diag-*/retis_icv.data
podman run --rm -v ~/ipsec-captures:/data:ro quay.io/retis/retis sort /data/diag-*/retis_icv.data

# View Retis output log
cat ~/ipsec-captures/diag-*/retis-output.log
```

### ICV Failure Correlation Workflow

To find corrupted packets:

1. **Find dropped packet in Retis output** - Look for xfrm_audit_state_icvfail events
2. **Get ESP sequence number** from the dropped packet
3. **Search both pcap files** for the same sequence number
4. **Compare packet data** between sender and receiver to identify corruption

## Troubleshooting

### No packets captured?

1. **Check IPsec is enabled:**
   ```bash
   oc get pods -n openshift-ovn-kubernetes -l app=ovn-ipsec
   ```

2. **Generate traffic** - ping or run workloads between nodes during capture

3. **Try broader filter:**
   ```bash
   ./run-ipsec-diagnostics.sh --filter "esp" --duration 30
   ```

### Files are empty?

Check capture logs:
```bash
cat /tmp/capture-<nodename>.log
cat /tmp/tcpdump-<nodename>.log
```

### Filter syntax error?

Use simple filters:
```bash
# Good
--filter "esp"
--filter "host 10.0.0.1"

# Avoid complex filters with special chars
```

### Retis analysis fails on macOS?

Use home directory path (not `/tmp`) for Podman volume mounts:
```bash
# Wrong (won't work on macOS)
podman run -v /tmp/captures:/data ...

# Correct
podman run -v ~/ipsec-captures:/data ...
```

### tcpdump: can't parse filter?

The filter is passed to tcpdump. Common issues:
- Use `esp` not `proto esp`
- Ensure IPs are correct
- Check quoting in config file

## Requirements

| Requirement | Purpose |
|-------------|---------|
| `oc` CLI | Cluster access |
| Cluster admin | `oc debug node` permission |
| RHCOS nodes | `toolbox` with tcpdump |
| For analysis | `tcpdump`, `tshark`, or Podman |

## Platform Support

| Platform | Status |
|----------|--------|
| macOS | ✓ Tested |
| RHEL 9 | ✓ Tested |
| Linux | ✓ Should work |

## Example Output

```
╔════════════════════════════════════════════════════════════════╗
║        IPsec ICV Failure Diagnostics                          ║
╚════════════════════════════════════════════════════════════════╝

  Cluster: https://api.cluster.example.com:6443
  Node 1 (sender): worker1.example.com
  Node 2 (receiver): worker2.example.com
  Retis node (dropping side): worker2.example.com
  Interface: br-ex
  Duration: 120s
  Capture mode: duration-only (no packet limit)
  Monitor ICV: true (threshold: 3)
  Output: ~/ipsec-captures/diag-20251203-131212

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Phase 1: XFRM State & Policy Dump (START - before capture)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dumping XFRM from worker1 (start)...
  Saved: xfrm-worker1-start.txt
Dumping XFRM from worker2 (start)...
  Saved: xfrm-worker2-start.txt

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Phase 2: Synchronized Capture - tcpdump + Retis (120s)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

tcpdump filter: host 10.0.0.1 and host 10.0.0.2 and esp
Retis filter: src host 10.0.0.1 and dst host 10.0.0.2
Retis running on: worker2.example.com (dropping side)

Starting synchronized captures...

Capture start time: 2025-12-03T13:12:18-05:00
Starting tcpdump on worker1.example.com...
Starting tcpdump on worker2.example.com...
Starting Retis on worker2.example.com (ICV failure tracking)...

Waiting for captures to complete (120s)...
  Time remaining:  10 seconds | Running: 3 | ICV failures: 0
All captures completed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Phase 3: XFRM State & Policy Dump (END - after capture)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dumping XFRM from worker1 (end)...
  Saved: xfrm-worker1-end.txt
Dumping XFRM from worker2 (end)...
  Saved: xfrm-worker2-end.txt

╔════════════════════════════════════════════════════════════════╗
║                       Results Summary                          ║
╚════════════════════════════════════════════════════════════════╝

Output directory: ~/ipsec-captures/diag-20251203-131212

total 1.2M
-rw-r--r--. 1 user user 4.0K Dec  3 13:13 node1-esp.pcap
-rw-r--r--. 1 user user  512 Dec  3 13:13 node1-timing.txt
-rw-r--r--. 1 user user 811K Dec  3 13:13 node2-esp.pcap
-rw-r--r--. 1 user user  512 Dec  3 13:13 node2-timing.txt
-rw-r--r--. 1 user user  64K Dec  3 13:13 retis_icv.data
-rw-r--r--. 1 user user  256 Dec  3 13:13 retis-timing.txt
-rw-r--r--. 1 user user 2.0K Dec  3 13:13 retis-output.log
-rw-r--r--. 1 user user   32 Dec  3 13:12 sync-time.txt
-rw-r--r--. 1 user user 1.5K Dec  3 13:12 xfrm-worker1-start.txt
-rw-r--r--. 1 user user 1.5K Dec  3 13:13 xfrm-worker1-end.txt
-rw-r--r--. 1 user user  26K Dec  3 13:12 xfrm-worker2-start.txt
-rw-r--r--. 1 user user  26K Dec  3 13:13 xfrm-worker2-end.txt
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit your changes (`git commit -am 'Add new feature'`)
4. Push to the branch (`git push origin feature/improvement`)
5. Open a Pull Request

### Development Guidelines

This project follows **KISS** (Keep It Simple, Stupid) principles and **12-Factor App** methodology. All code contributions must adhere to security best practices and maintainability standards.

**Key Principles:**
- **Security**: Input validation, secure coding practices, no hardcoded secrets, proper error handling
- **KISS**: Simple, readable solutions over complex optimizations
- **12-Factor**: Environment-based configuration, stateless processes, proper logging

**For Cursor IDE users:** This repository includes `.cursorrules` that automatically enforce these standards. The rules cover:
- Input validation and sanitization
- Secure bash scripting (`set -euo pipefail`, proper quoting)
- Container security (Podman/Buildah only)
- Configuration via environment variables
- Structured logging without sensitive data exposure

**Code Requirements:**
- All bash scripts must use `set -euo pipefail` and quote all variables
- Never hardcode credentials or secrets (use environment variables)
- Validate all inputs and file paths
- Use Podman/Buildah for containers (never Docker)
- Follow 12-factor config management (env vars > config files > hardcoded values)

See [`.cursorrules`](.cursorrules) for complete development guidelines and security rules.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
