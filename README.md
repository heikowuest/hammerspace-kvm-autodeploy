Hammerspace Autodeployment Script for KVM-based cluster deployment

Overview
This script automates the deployment of a full Hammerspace cluster on a KVM host.
It validates environment configuration, prepares per-node data, and launches all VMs.

Requirments: 
installer.yaml definition of the Hammerspace Cluster which is setting up the Hammerspace Appliance after the VM was started
hammerspace qcow2 image, exact naming and other additional options are configured as variables in the deploy.sh script

Key Features:
- Works with Rocky 9 / RHEL 9 and Ubuntu 22.04 or later
- Automatic detection of KVM bridges and STP configuration
- Snap-based yq auto-detection and fix for Ubuntu
- Interactive or fully automatic (--force) modes
- cleanup-only mode (--cleanup)

Command Line Options
--help Displays usage instructions and exits.
--force Skips all interactive prompts and runs in non-interactive mode. Useful for automated environments or CI/CD usage.
--cleanup Removes previously deployed Hammerspace VMs and directories only.No new deployment is performed.

Deployment Workflow

1. KVM & Bridge Validation
- Checks KVM kernel modules, virt-install availability, and bridge setup.

2. STP / Edge-Port Check
- Warns if STP is enabled on bridge (delays VM networking).

3. Firewall Overview
- Displays current firewall configuration and VNC port reminder.

4. yq Installation / Snap Fix
- Ensures yq is installed and usable even in snap sandbox.

5. Cleanup (optional)
- Removes existing Hammerspace VMs and related directories.

6. Configuration & Deployment
- Creates per-node YAMLs, config drives, and runs virt-install for each VM.

7. Summary & VNC Ports
- Displays VM list and their active VNC ports.
