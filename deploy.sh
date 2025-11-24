#!/usr/bin/env bash
set -euo pipefail

#############################################
#  Hammerspace Autodeployment Script        #
#  for KVM-based cluster deployment         #
#                                           #
#  Original concept: Heiko Wüst             #
#  AI-assisted automation: ChatGPT (OpenAI) #
#############################################

#############################################
#                 CONFIG
#############################################

INSTALLERSOURCE="./installer.yaml"
HSIMAGE="./hammerspace-5.1.40-449.qcow2"
CONFIG_DRIVE_IMAGE="config-drive.img"
MOUNT_POINT="/mnt/configdrive"

KVMBRIDGE="bridge"
LINUXBRIDGE="br0"

ANVIL_VM_VCPUS=8
ANVIL_VM_MEMORY=16384
ANVIL_VM_DISK_DATA_SIZE=100

DSX_VM_VCPUS=4
DSX_VM_MEMORY=8192
DSX_VM_DISK_DATA_SIZE=50

VM_OS_VARIANT="centos8"
VM_IMPORT="--import"
VM_GRAPHICS="vnc,listen=0.0.0.0"
VM_CONSOLE="pty,target_type=serial"
VM_VIDEO="virtio"

#############################################
#              LOGGING / ERROR
#############################################

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

log_cmd() {
    "$@" 2>&1 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log "$line"
    done
}

#############################################
#              CORE CHECKS
#############################################

show_help() {
    cat <<EOF
Usage: sudo ./deploy.sh [OPTIONS]

Options:
  --force             Skip all interactive prompts (non-interactive mode)
  --cleanup           Only remove existing Hammerspace VMs and directories
  --help              Show this help message and exit

EOF
    exit 0
}

check_kvm() {
    log "Checking KVM environment..."
    command -v virt-install >/dev/null 2>&1 || { err "virt-install not found"; exit 1; }
    grep -q '^kvm ' /proc/modules || { err "KVM module not loaded"; exit 1; }

    if lscpu | grep -iq 'GenuineIntel'; then
        grep -q '^kvm_intel ' /proc/modules || { err "kvm_intel not loaded"; exit 1; }
    elif lscpu | grep -iq 'AuthenticAMD'; then
	grep -q '^kvm_amd ' /proc/modules || { err "kvm_amd not loaded"; exit 1; }
    fi

    ip link show "$LINUXBRIDGE" >/dev/null 2>&1 || { err "Bridge '$LINUXBRIDGE' not found"; exit 1; }

    if virsh net-info "$KVMBRIDGE" >/dev/null 2>&1; then
        log "Found Bridge: $KVMBRIDGE"
        virsh net-info "$KVMBRIDGE" | while IFS= read -r l; do log "$l"; done
    else
        log "Creating KVM network '$KVMBRIDGE' linked to '$LINUXBRIDGE'..."
        TMP_XML=$(mktemp)
        cat >"$TMP_XML" <<EOF
<network>
  <name>$KVMBRIDGE</name>
  <forward mode='bridge'/>
  <bridge name='$LINUXBRIDGE'/>
</network>
EOF
        log_cmd virsh net-define "$TMP_XML"
        log_cmd virsh net-autostart "$KVMBRIDGE"
        log_cmd virsh net-start "$KVMBRIDGE"
        rm -f "$TMP_XML"
    fi
    log "KVM environment check passed"
}

check_stp_settings() {
    log "Checking STP settings on '$LINUXBRIDGE'..."
    local stp_status="unknown" port_type="unknown"
    if command -v nmcli >/dev/null 2>&1; then
        stp_status=$(nmcli -t -f bridge.stp connection show "$LINUXBRIDGE" 2>/dev/null | cut -d: -f2 || true)
        port_type=$(nmcli -t -f bridge.port-type connection show "$LINUXBRIDGE" 2>/dev/null | cut -d: -f2 || true)
    elif command -v netplan >/dev/null 2>&1; then
        stp_status=$(grep -E "stp:" /etc/netplan/* 2>/dev/null | awk '{print $2}' | tr -d '"')
        port_type="(netplan)"
    fi
    log "bridge.stp: ${stp_status:-unknown}, port-type: ${port_type:-unknown}"

    if [[ "$stp_status" =~ ^(yes|true)$ ]]; then
        warn "STP is enabled – may delay VM networking."
        if [[ "${FORCE:-false}" == "true" ]]; then
            log "Force mode active, continuing."
            return
        fi
        read -rp "[PROMPT] Continue anyway? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { err "Aborted due to STP setting"; exit 1; }
    fi
}

check_firewall() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        log "firewalld not installed."
        return
    fi
    if ! systemctl is-active --quiet firewalld; then
        log "firewalld inactive."
        return
    fi
    log "Host firewall configuration:"
    firewall-cmd --list-all | while IFS= read -r l; do log "$l"; done
}

#############################################
#             YQ / SNAP SUPPORT
#############################################

check_install_yq() {
    if command -v yq >/dev/null 2>&1; then
        log "yq already installed"
        return
    fi
    log "Installing yq..."
    if command -v apt >/dev/null 2>&1; then
        log_cmd sudo apt update -y
        log_cmd sudo apt install -y yq
    elif command -v dnf >/dev/null 2>&1; then
        log_cmd sudo dnf install -y yq
    elif command -v yum >/dev/null 2>&1; then
        log_cmd sudo yum install -y yq
    else
        err "No package manager found"
        exit 1
    fi
}

fix_yq_snap_access() {
    local yq_path
    yq_path=$(readlink -f "$(command -v yq)" 2>/dev/null || true)
    if [[ "$yq_path" == *"/snap/"* ]]; then
        warn "Snap-based yq detected – limited access outside /mnt and /media."
        local SNAP_LINK_DIR="/var/snap/yq-access"
        mkdir -p "$SNAP_LINK_DIR"
        local TARGET_LINK="$SNAP_LINK_DIR/installer.yaml"
        ln -sf "$(realpath "$INSTALLERSOURCE")" "$TARGET_LINK"
        log "Created symlink $TARGET_LINK -> $INSTALLERSOURCE"
        INSTALLERSOURCE="$TARGET_LINK"
    fi
}

#############################################
#                DEPLOYMENT
#############################################

cleanup_vms() {
    FORCE=${1:-false}
    mapfile -t NODE_IDS < <(yq '.nodes | keys | .[]' "$INSTALLERSOURCE")
    declare -a TARGET_VMS=()
    for nid in "${NODE_IDS[@]}"; do
        HOSTNAME=$(yq ".nodes.\"$nid\".hostname" "$INSTALLERSOURCE")
        [[ -n "$HOSTNAME" ]] && TARGET_VMS+=("$HOSTNAME")
    done
    [[ ${#TARGET_VMS[@]} -eq 0 ]] && { log "No VMs found."; return; }

    log "Checking existing VMs..."
    EXISTING=false
    for vm in "${TARGET_VMS[@]}"; do
        if virsh dominfo "$vm" >/dev/null 2>&1; then
            log "  Found VM: $vm"
            EXISTING=true
        fi
    done
    [[ "$EXISTING" == false ]] && { log "No existing VMs."; return; }

    if [[ "$FORCE" == "true" ]]; then CONFIRM="y"
    else read -rp "[PROMPT] Destroy and undefine these VMs? (y/N): " CONFIRM; fi

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        for vm in "${TARGET_VMS[@]}"; do
            if virsh dominfo "$vm" >/dev/null 2>&1; then
                STATE=$(virsh domstate "$vm" 2>/dev/null)
                if [[ "$STATE" == "running" ]]; then
                    log "Destroying $vm..."
                    log_cmd virsh destroy "$vm"
                fi
                log_cmd virsh undefine "$vm"
            fi
            [[ -d "./$vm" ]] && rm -rf "./$vm" && log "Removed directory ./$vm"
        done
    else
        err "Cleanup aborted."
        exit 1
    fi
}

deploy_configs() {
    [[ -f "$INSTALLERSOURCE" ]] || { err "installer.yaml missing"; exit 1; }
    mapfile -t NODE_IDS < <(yq '.nodes | keys | .[]' "$INSTALLERSOURCE")
    for nid in "${NODE_IDS[@]}"; do
        HOSTNAME=$(yq ".nodes.\"$nid\".hostname" "$INSTALLERSOURCE")
        mkdir -p "./$HOSTNAME"
        cp "$INSTALLERSOURCE" "./$HOSTNAME/installer.yaml"
        yq -i ".node_index = \"$nid\"" "./$HOSTNAME/installer.yaml"
        log "Prepared ./$HOSTNAME/installer.yaml"
    done
}

copy_hsimage() {
    [[ -f "$HSIMAGE" ]] || { err "HS image missing"; exit 1; }
    mapfile -t NODE_IDS < <(yq '.nodes | keys | .[]' "$INSTALLERSOURCE")
    for nid in "${NODE_IDS[@]}"; do
        HOSTNAME=$(yq ".nodes.\"$nid\".hostname" "$INSTALLERSOURCE")
        cp "$HSIMAGE" "./$HOSTNAME/"
        log "Copied HS image to ./$HOSTNAME/"
    done
}

deploy_config_drive() {
    [[ $EUID -eq 0 ]] || { err "Must run as root"; exit 1; }
    mapfile -t NODE_IDS < <(yq '.nodes | keys | .[]' "$INSTALLERSOURCE")
    for nid in "${NODE_IDS[@]}"; do
        HOSTNAME=$(yq ".nodes.\"$nid\".hostname" "$INSTALLERSOURCE")
        DIR="./$HOSTNAME"
        IMAGE_PATH="$DIR/$CONFIG_DRIVE_IMAGE"
        truncate -s 16M "$IMAGE_PATH"
        chmod 644 "$IMAGE_PATH"
        log_cmd mkfs.vfat -F 32 "$IMAGE_PATH"
        mkdir -p "$MOUNT_POINT"
        mount -o loop "$IMAGE_PATH" "$MOUNT_POINT"
        mkdir -p "$MOUNT_POINT/etc"
        touch "$MOUNT_POINT/COPY_TO_HAMMERSPACE"
        cp "$DIR/installer.yaml" "$MOUNT_POINT/etc/"
        umount "$MOUNT_POINT"
        log "Created config drive for $HOSTNAME"
    done
}

deploy_vms() {
    mapfile -t NODE_IDS < <(yq '.nodes | keys | .[]' "$INSTALLERSOURCE")
    for nid in "${NODE_IDS[@]}"; do
        HOSTNAME=$(yq ".nodes.\"$nid\".hostname" "$INSTALLERSOURCE")
	HA_MODE=$(yq -r ".nodes[\"$nid\"].ha_mode" "$INSTALLERSOURCE" 2>/dev/null || echo "null")

	if [[ "$HA_MODE" != "null" ]]; then
    		# ha_mode existiert und ist kein null -> ANVIL
    		VM_VCPUS=$ANVIL_VM_VCPUS
    		VM_MEMORY=$ANVIL_VM_MEMORY
    		VM_DISK_DATA_SIZE=$ANVIL_VM_DISK_DATA_SIZE
	else
    		# ha_mode fehlt oder ist explizit null -> DSX
    		VM_VCPUS=$DSX_VM_VCPUS
    		VM_MEMORY=$DSX_VM_MEMORY
    		VM_DISK_DATA_SIZE=$DSX_VM_DISK_DATA_SIZE
	fi

        DATA_DISK="./$HOSTNAME/data0.img"
        [[ -f "$DATA_DISK" ]] || log_cmd qemu-img create -f raw "$DATA_DISK" "${VM_DISK_DATA_SIZE}G"
        log "Deploying $HOSTNAME..."
        log_cmd virt-install \
            --name "$HOSTNAME" \
            --vcpus "$VM_VCPUS" \
            --memory "$VM_MEMORY" \
            --cpu host-model,+topoext \
            --os-variant "$VM_OS_VARIANT" \
            $VM_IMPORT \
            --disk path="./$HOSTNAME/$(basename "$HSIMAGE")",format=qcow2,bus=virtio \
            --disk path="./$HOSTNAME/$CONFIG_DRIVE_IMAGE",format=raw,bus=virtio\
            --disk path="$DATA_DISK",format=raw,bus=virtio \
            --network network="$KVMBRIDGE",model=virtio \
            --graphics "$VM_GRAPHICS" \
            --console "$VM_CONSOLE" \
            --video "$VM_VIDEO" \
            --noautoconsole
    done
}

show_vnc_ports() {
    log "Active VNC sessions:"
    mapfile -t RUNNING_VMS < <(virsh list --name | grep -v '^$' || true)
    for vm in "${RUNNING_VMS[@]}"; do
        DISPLAY=$(virsh vncdisplay "$vm" 2>/dev/null | tr -d '\r\n ')
        NUM=${DISPLAY#:}
        PORT=$((5900 + NUM))
        log "  $vm -> VNC port: $PORT (display $DISPLAY)"
    done
}

#############################################
#                   MAIN
#############################################

main() {
    [[ "${1:-}" == "--help" ]] && show_help
    FORCE=false
    CLEANUP_ONLY=false

    case "${1:-}" in
      --force) FORCE=true ;;
      --cleanup) CLEANUP_ONLY=true ;;
    esac

    check_install_yq
    fix_yq_snap_access

    if [[ "$CLEANUP_ONLY" == "true" ]]; then
        cleanup_vms "$FORCE"
        log "Cleanup completed (no deployment executed)."
        exit 0
    fi

    local start_time=$(date +%s)
    check_kvm
    check_stp_settings
    check_firewall
    cleanup_vms "$FORCE"
    deploy_configs
    copy_hsimage
    deploy_config_drive
    deploy_vms
    virsh list --all | while IFS= read -r l; do log "$l"; done
    show_vnc_ports
    local duration=$(( $(date +%s) - start_time ))
    log "Total deployment time: ${duration}s ($(printf "%dm %ds" $((duration/60)) $((duration%60))))"
}

main "$@"
exit 0

