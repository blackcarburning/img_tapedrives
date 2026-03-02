#!/usr/bin/env bash
#===============================================================================
#
#  IBM Storage Protect — Spectra Logic Tape Library Configuration Wizard
#
#  Purpose:   Walk through every step of configuring a Spectra Logic tape
#             library with dual-pathed IBM LTO drives on RHEL for
#             IBM Storage Protect 8.1.x.
#
#  Usage:     sudo bash sp_tape_library_setup.sh
#
#  Author:    Generated for blackcarburning — 2026-03-02
#  Platform:  Red Hat Enterprise Linux 8.x / 9.x
#  Requires:  root / sudo privileges
#
#===============================================================================

set -euo pipefail

#---------------------------------------
# GLOBALS
#---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/sp_tape_setup_output"
LOG_FILE="${OUTPUT_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
UDEV_RULES_FILE="/etc/udev/rules.d/99-ibm-tape-persist.rules"
MODPROBE_BLACKLIST="/etc/modprobe.d/blacklist-tape-generic.conf"
MODULES_LOAD_CONF="/etc/modules-load.d/lin_tape.conf"
SYMLINK_BASE="/dev/tsmtape"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# SP connection defaults (overridden interactively)
SP_SERVER=""
SP_ADMIN_USER=""
SP_ADMIN_PASS=""
SP_LIBRARY_NAME=""
DSMADMC_CMD=""

# Drive / library discovery results
declare -a TAPE_DEVICES=()
declare -a CHANGER_DEVICES=()
declare -a DRIVE_SERIALS=()
declare -a DRIVE_PATHS=()

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

log()       { echo -e "$(date '+%F %T') | $*" | tee -a "$LOG_FILE"; }
info()      { echo -e "${CYAN}[INFO]${NC}  $*"  | tee -a "$LOG_FILE"; }
success()   { echo -e "${GREEN}[OK]${NC}    $*"  | tee -a "$LOG_FILE"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
fail()      { echo -e "${RED}[FAIL]${NC}  $*"    | tee -a "$LOG_FILE"; }
banner()    {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

pause() {
    echo ""
    read -rp "    Press ENTER to continue (or Ctrl-C to abort)... "
    echo ""
}

confirm() {
    local prompt="${1:-Continue?}"
    local reply
    read -rp "    ${prompt} [y/N]: " reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

write_test_script() {
    local script_name="$1"
    local script_path="${OUTPUT_DIR}/${script_name}"
    # Content is written by the caller via heredoc redirect
    chmod +x "$script_path"
    success "Test script written: ${script_path}"
}

run_dsmadmc() {
    # Execute a dsmadmc command, capturing output
    local cmd="$1"
    if [[ -z "$DSMADMC_CMD" ]]; then
        fail "dsmadmc connection not configured."
        return 1
    fi
    echo "$cmd" | tee -a "$LOG_FILE"
    $DSMADMC_CMD -dataonly=yes -comma "$cmd" 2>&1 | tee -a "$LOG_FILE"
}

#===============================================================================
# PHASE 0 — INITIALISATION
#===============================================================================

phase0_init() {
    banner "PHASE 0 — INITIALISATION"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        fail "This script must be run as root (or with sudo)."
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"
    : > "$LOG_FILE"

    info "Output directory : ${OUTPUT_DIR}"
    info "Log file         : ${LOG_FILE}"

    # Detect OS
    if [[ -f /etc/redhat-release ]]; then
        local os_release
        os_release=$(cat /etc/redhat-release)
        info "Detected OS      : ${os_release}"
    else
        warn "This script is designed for RHEL. Detected a non-RHEL system."
        confirm "Continue anyway?" || exit 0
    fi

    # Detect kernel
    info "Running kernel   : $(uname -r)"

    # Check for kernel-devel
    if rpm -q "kernel-devel-$(uname -r)" &>/dev/null; then
        success "kernel-devel package is installed for running kernel."
    else
        warn "kernel-devel-$(uname -r) not found. Required to build lin_tape."
        if confirm "Install kernel-devel now?"; then
            yum install -y "kernel-devel-$(uname -r)" gcc make | tee -a "$LOG_FILE"
        fi
    fi

    # Generate Phase 0 test script
    cat > "${OUTPUT_DIR}/test_00_prerequisites.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# TEST 00 — Prerequisite Checks
#===============================================================================
echo "============================================="
echo " TEST 00 — PREREQUISITE CHECKS"
echo "============================================="

PASS=0; FAIL=0

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        echo "[PASS] ${desc}"
        ((PASS++))
    else
        echo "[FAIL] ${desc}"
        ((FAIL++))
    fi
}

check "Running as root"               test "$(id -u)" -eq 0
check "RHEL detected"                 test -f /etc/redhat-release
check "kernel-devel installed"        rpm -q "kernel-devel-$(uname -r)"
check "gcc installed"                 command -v gcc
check "make installed"                command -v make
check "lsscsi installed"             command -v lsscsi
check "udevadm available"            command -v udevadm

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ $FAIL -eq 0 ]] && echo "All prerequisite checks PASSED." || echo "Some checks FAILED — review above."
exit $FAIL
TESTSCRIPT
    write_test_script "test_00_prerequisites.sh"

    pause
}

#===============================================================================
# PHASE 1 — LIN_TAPE DRIVER
#===============================================================================

phase1_lin_tape() {
    banner "PHASE 1 — IBM lin_tape DRIVER INSTALLATION"

    # Check if lin_tape is already loaded
    if lsmod | grep -q lin_tape; then
        success "lin_tape module is already loaded."
        modinfo lin_tape 2>/dev/null | head -5 | tee -a "$LOG_FILE"
    else
        warn "lin_tape module is NOT currently loaded."
    fi

    # Check if the RPM is installed
    if rpm -qa | grep -qi lin_tape; then
        success "lin_tape RPM detected: $(rpm -qa | grep -i lin_tape)"
    else
        warn "No lin_tape RPM found."
        echo ""
        info "You need to download the lin_tape driver from IBM Fix Central:"
        info "  https://www.ibm.com/support/fixcentral"
        info "  Product Group : System Storage"
        info "  Product       : Tape drivers and software > Tape device drivers"
        info "  Platform      : Linux"
        info "  Select the RPM or tarball matching your kernel."
        echo ""
        if confirm "Do you have the lin_tape RPM ready to install now?"; then
            read -rp "    Enter full path to lin_tape RPM: " rpm_path
            if [[ -f "$rpm_path" ]]; then
                info "Installing ${rpm_path} ..."
                rpm -ivh "$rpm_path" 2>&1 | tee -a "$LOG_FILE"
            else
                fail "File not found: ${rpm_path}"
            fi
        fi
    fi

    # Blacklist generic drivers
    info "Configuring blacklist for generic st / sg drivers ..."
    cat > "$MODPROBE_BLACKLIST" <<'EOF'
# Blacklist generic SCSI tape/generic drivers to prevent them from
# claiming IBM tape devices before lin_tape loads.
blacklist st
blacklist sg
EOF
    success "Created ${MODPROBE_BLACKLIST}"

    # Ensure lin_tape loads at boot
    echo "lin_tape" > "$MODULES_LOAD_CONF"
    success "Created ${MODULES_LOAD_CONF}"

    # Load the module now if not loaded
    if ! lsmod | grep -q lin_tape; then
        # Unload generic drivers if loaded
        rmmod st  2>/dev/null || true
        rmmod sg  2>/dev/null || true
        modprobe lin_tape 2>&1 | tee -a "$LOG_FILE" && \
            success "lin_tape module loaded." || \
            fail "Failed to load lin_tape — check dmesg."
    fi

    # Rebuild initramfs
    if confirm "Rebuild initramfs with dracut (recommended)?"; then
        info "Running dracut --force ..."
        dracut --force 2>&1 | tee -a "$LOG_FILE"
        success "initramfs rebuilt."
    fi

    # Generate Phase 1 test script
    cat > "${OUTPUT_DIR}/test_01_lin_tape.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# TEST 01 — lin_tape Driver Verification
#===============================================================================
echo "============================================="
echo " TEST 01 — LIN_TAPE DRIVER"
echo "============================================="

PASS=0; FAIL=0

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        echo "[PASS] ${desc}"
        ((PASS++))
    else
        echo "[FAIL] ${desc}"
        ((FAIL++))
    fi
}

check "lin_tape module loaded"                lsmod | grep -q lin_tape
check "lin_tape RPM installed"                rpm -qa | grep -qi lin_tape
check "st driver is NOT loaded"               bash -c '! lsmod | grep -q "^st "'
check "sg driver is NOT loaded"               bash -c '! lsmod | grep -q "^sg "'
check "Blacklist file exists"                 test -f /etc/modprobe.d/blacklist-tape-generic.conf
check "modules-load.d entry exists"           test -f /etc/modules-load.d/lin_tape.conf
check "/dev/IBMtape* devices present"         ls /dev/IBMtape* 2>/dev/null
check "/dev/IBMchanger* devices present"      ls /dev/IBMchanger* 2>/dev/null

echo ""
echo "--- lin_tape module info ---"
modinfo lin_tape 2>/dev/null | head -10
echo ""
echo "--- /dev/IBMtape* ---"
ls -la /dev/IBMtape*  2>/dev/null || echo "(none found)"
echo ""
echo "--- /dev/IBMchanger* ---"
ls -la /dev/IBMchanger*  2>/dev/null || echo "(none found)"
echo ""

# Show kernel messages related to tape
echo "--- Recent dmesg (tape related) ---"
dmesg | grep -i -E "tape|IBMtape|lin_tape|changer" | tail -20

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ $FAIL -eq 0 ]] && echo "All lin_tape checks PASSED." || echo "Some checks FAILED."
exit $FAIL
TESTSCRIPT
    write_test_script "test_01_lin_tape.sh"

    pause
}

#===============================================================================
# PHASE 2 — DEVICE DISCOVERY
#===============================================================================

phase2_discovery() {
    banner "PHASE 2 — DEVICE DISCOVERY"

    info "Scanning for IBM tape devices and changers ..."
    echo ""

    # Discover tape devices
    TAPE_DEVICES=()
    if compgen -G "/dev/IBMtape[0-9]*" > /dev/null 2>&1; then
        # Collect only the base (non 'n' suffix) devices
        while IFS= read -r dev; do
            # Skip the non-rewind 'n' variants for enumeration
            if [[ "$dev" =~ IBMtape[0-9]+$ ]]; then
                TAPE_DEVICES+=("$dev")
            fi
        done < <(ls -1 /dev/IBMtape* 2>/dev/null | sort -V)
    fi

    # Discover changer devices
    CHANGER_DEVICES=()
    if compgen -G "/dev/IBMchanger[0-9]*" > /dev/null 2>&1; then
        while IFS= read -r dev; do
            CHANGER_DEVICES+=("$dev")
        done < <(ls -1 /dev/IBMchanger* 2>/dev/null | sort -V)
    fi

    info "Found ${#TAPE_DEVICES[@]} tape device node(s):"
    for d in "${TAPE_DEVICES[@]}"; do
        echo "    $d" | tee -a "$LOG_FILE"
    done

    info "Found ${#CHANGER_DEVICES[@]} changer device node(s):"
    for d in "${CHANGER_DEVICES[@]}"; do
        echo "    $d" | tee -a "$LOG_FILE"
    done

    if [[ ${#TAPE_DEVICES[@]} -eq 0 ]]; then
        fail "No tape devices found. Check FC zoning, HBA, and lin_tape."
        warn "Continuing in dry-run / informational mode."
    fi

    # Gather detailed attributes for each tape device
    echo ""
    info "Gathering udev attributes for each device ..."
    local detail_file="${OUTPUT_DIR}/device_discovery.txt"
    : > "$detail_file"

    for dev in "${TAPE_DEVICES[@]}" "${CHANGER_DEVICES[@]}"; do
        {
            echo "========================================"
            echo "DEVICE: ${dev}"
            echo "========================================"
            udevadm info --query=all --name="$dev" 2>/dev/null || echo "(udevadm failed for $dev)"
            echo ""
        } >> "$detail_file"
    done
    success "Full device attributes saved to: ${detail_file}"

    # Attempt to extract serial numbers
    DRIVE_SERIALS=()
    DRIVE_PATHS=()
    for dev in "${TAPE_DEVICES[@]}"; do
        local serial
        serial=$(udevadm info --query=property --name="$dev" 2>/dev/null \
                 | grep -E '^ID_SCSI_SERIAL=|^ID_SERIAL_SHORT=' \
                 | head -1 | cut -d= -f2)
        serial="${serial:-UNKNOWN}"
        DRIVE_SERIALS+=("$serial")
        DRIVE_PATHS+=("$dev")
        info "  ${dev} => serial: ${serial}"
    done

    # Generate Phase 2 test script
    cat > "${OUTPUT_DIR}/test_02_discovery.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# TEST 02 — Device Discovery & Attribute Dump
#===============================================================================
echo "============================================="
echo " TEST 02 — DEVICE DISCOVERY"
echo "============================================="

echo "--- Tape Devices ---"
ls -la /dev/IBMtape*  2>/dev/null || echo "(none)"
echo ""
echo "--- Changer Devices ---"
ls -la /dev/IBMchanger* 2>/dev/null || echo "(none)"
echo ""
echo "--- lsscsi ---"
lsscsi -g 2>/dev/null || echo "(lsscsi not available)"
echo ""

echo "--- Detailed udev attributes per device ---"
for dev in /dev/IBMtape[0-9]* /dev/IBMchanger[0-9]*; do
    [[ -e "$dev" ]] || continue
    echo "========================================"
    echo "DEVICE: $dev"
    echo "========================================"
    udevadm info --query=all --name="$dev" 2>/dev/null
    echo ""
done

echo "--- /proc/scsi/IBMtape (if available) ---"
cat /proc/scsi/IBMtape 2>/dev/null || echo "(not available)"

echo ""
echo "--- FC HBA ports ---"
for host_dir in /sys/class/fc_host/host*; do
    [[ -d "$host_dir" ]] || continue
    host=$(basename "$host_dir")
    wwpn=$(cat "${host_dir}/port_name" 2>/dev/null)
    state=$(cat "${host_dir}/port_state" 2>/dev/null)
    echo "  ${host}: WWPN=${wwpn}  State=${state}"
done

echo ""
echo "Discovery complete."
TESTSCRIPT
    write_test_script "test_02_discovery.sh"

    pause
}

#===============================================================================
# PHASE 3 — PERSISTENT DEVICE BINDING (udev)
#===============================================================================

phase3_persistence() {
    banner "PHASE 3 — PERSISTENT DEVICE BINDING (udev RULES)"

    info "We will create udev rules to give each drive path and the library"
    info "changer a stable symlink under ${SYMLINK_BASE}/."
    echo ""

    # Ask how many physical drives
    local num_drives
    read -rp "    How many PHYSICAL tape drives are in the library? " num_drives
    num_drives="${num_drives:-0}"

    if ! [[ "$num_drives" =~ ^[0-9]+$ ]] || [[ "$num_drives" -lt 1 ]]; then
        warn "Invalid number. Generating a template with 2 drives."
        num_drives=2
    fi

    # Start building the rules file content
    local rules_content=""
    rules_content+="#===============================================================================\n"
    rules_content+="# IBM Storage Protect — Persistent tape device symlinks\n"
    rules_content+="# Generated: $(date '+%F %T')\n"
    rules_content+="# Library: Spectra Logic with IBM LTO drives (dual-pathed)\n"
    rules_content+="#===============================================================================\n\n"

    # Library changer
    local changer_serial="CHANGE_ME_LIBRARY_SERIAL"
    if [[ ${#CHANGER_DEVICES[@]} -gt 0 ]]; then
        changer_serial=$(udevadm info --query=property --name="${CHANGER_DEVICES[0]}" 2>/dev/null \
                         | grep -E '^ID_SCSI_SERIAL=|^ID_SERIAL_SHORT=' \
                         | head -1 | cut -d= -f2)
        changer_serial="${changer_serial:-CHANGE_ME_LIBRARY_SERIAL}"
    fi
    rules_content+="# --- Medium Changer (Library) ---\n"
    rules_content+="KERNEL==\"IBMchanger[0-9]*\", ATTRS{serial}==\"${changer_serial}\", SYMLINK+=\"tsmtape/library0\"\n\n"

    # Drives
    # We need to figure out which discovered tape devices map to which physical drives.
    # With dual-pathing, each physical drive has 2 device nodes.
    info "For each physical drive, we need the serial number and two device paths."
    info "Detected device nodes & serials:"
    for i in "${!DRIVE_PATHS[@]}"; do
        info "  [${i}] ${DRIVE_PATHS[$i]} — serial: ${DRIVE_SERIALS[$i]}"
    done
    echo ""

    for (( d=1; d<=num_drives; d++ )); do
        local padded
        padded=$(printf "%02d" "$d")
        local serial="CHANGE_ME_DRIVE${padded}_SERIAL"

        echo ""
        info "--- Physical Drive ${d} ---"

        # Try to auto-detect from discovery
        local idx0=$(( (d - 1) * 2 ))
        local idx1=$(( idx0 + 1 ))
        if [[ $idx0 -lt ${#DRIVE_SERIALS[@]} ]]; then
            serial="${DRIVE_SERIALS[$idx0]}"
            info "  Auto-detected serial: ${serial}"
        fi

        read -rp "    Drive ${d} serial [${serial}]: " user_serial
        serial="${user_serial:-$serial}"

        rules_content+="# --- Drive ${padded} (serial: ${serial}) ---\n"

        # Path 0
        local match_attr_p0="ATTRS{serial}==\"${serial}\""
        local dev_hint_p0=""
        if [[ $idx0 -lt ${#DRIVE_PATHS[@]} ]]; then
            dev_hint_p0="  # discovered as ${DRIVE_PATHS[$idx0]}"
        fi
        rules_content+="KERNEL==\"IBMtape[0-9]*\", ${match_attr_p0}, ENV{ID_PATH}==\"*-lun-0\", SYMLINK+=\"tsmtape/drive${padded}_path0\"${dev_hint_p0}\n"

        # Path 1
        local dev_hint_p1=""
        if [[ $idx1 -lt ${#DRIVE_PATHS[@]} ]]; then
            dev_hint_p1="  # discovered as ${DRIVE_PATHS[$idx1]}"
        fi
        rules_content+="KERNEL==\"IBMtape[0-9]*\", ${match_attr_p0}, ENV{ID_PATH}==\"*-lun-1\", SYMLINK+=\"tsmtape/drive${padded}_path1\"${dev_hint_p1}\n"
        rules_content+="\n"
    done

    # Display the generated rules
    echo ""
    info "Generated udev rules:"
    echo "────────────────────────────────────────"
    echo -e "$rules_content"
    echo "────────────────────────────────────────"

    # Write the rules file
    if confirm "Write these rules to ${UDEV_RULES_FILE}?"; then
        echo -e "$rules_content" > "$UDEV_RULES_FILE"
        success "udev rules written to ${UDEV_RULES_FILE}"

        # Also save a backup
        cp "$UDEV_RULES_FILE" "${OUTPUT_DIR}/99-ibm-tape-persist.rules.bak"

        # Create the symlink directory
        mkdir -p "$SYMLINK_BASE"

        # Reload udev
        info "Reloading udev rules ..."
        udevadm control --reload-rules
        udevadm trigger
        sleep 2
        success "udev rules reloaded."
    else
        # Save to output dir only
        echo -e "$rules_content" > "${OUTPUT_DIR}/99-ibm-tape-persist.rules.draft"
        info "Rules saved as draft to ${OUTPUT_DIR}/99-ibm-tape-persist.rules.draft"
        info "You can review and install them manually."
    fi

    # Generate comprehensive udev debugging help
    cat > "${OUTPUT_DIR}/udev_debug_helper.sh" <<'DEBUGSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# UDEV DEBUG HELPER
# Use this to inspect attributes available for udev rule matching.
#===============================================================================
echo "============================================="
echo " UDEV ATTRIBUTE INSPECTOR"
echo "============================================="

for dev in /dev/IBMtape[0-9]* /dev/IBMchanger[0-9]*; do
    [[ -e "$dev" ]] || continue
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " $dev"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "--- Properties (ENV) ---"
    udevadm info --query=property --name="$dev" 2>/dev/null
    echo ""
    echo "--- Sysfs attribute walk (first 60 lines) ---"
    udevadm info --attribute-walk --name="$dev" 2>/dev/null | head -60
    echo ""
done

echo ""
echo "TIP: Use the attributes above to refine your udev rules."
echo "     Common useful attributes for matching:"
echo "       ATTRS{serial}      — drive serial number"
echo "       ATTRS{vendor}      — e.g. 'IBM'"
echo "       ATTRS{model}       — e.g. 'ULT3580-HH9' (LTO-9)"
echo "       ENV{ID_PATH}       — HBA path identifier"
echo "       ENV{ID_SCSI_SERIAL}"
echo "       ENV{ID_SERIAL_SHORT}"
DEBUGSCRIPT
    write_test_script "udev_debug_helper.sh"

    # Generate Phase 3 test script
    cat > "${OUTPUT_DIR}/test_03_persistence.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# TEST 03 — Persistent Device Binding Verification
#===============================================================================
echo "============================================="
echo " TEST 03 — PERSISTENT DEVICE BINDING"
echo "============================================="

PASS=0; FAIL=0
SYMLINK_DIR="/dev/tsmtape"

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        echo "[PASS] ${desc}"
        ((PASS++))
    else
        echo "[FAIL] ${desc}"
        ((FAIL++))
    fi
}

check "udev rules file exists"        test -f /etc/udev/rules.d/99-ibm-tape-persist.rules
check "Symlink directory exists"       test -d "$SYMLINK_DIR"

echo ""
echo "--- Symlinks in ${SYMLINK_DIR}/ ---"
if ls -la "$SYMLINK_DIR/" 2>/dev/null; then
    echo ""
    # Check each symlink resolves
    for link in "$SYMLINK_DIR"/*; do
        [[ -L "$link" ]] || continue
        target=$(readlink -f "$link")
        if [[ -e "$target" ]]; then
            echo "[PASS] ${link} -> ${target} (exists)"
            ((PASS++))
        else
            echo "[FAIL] ${link} -> ${target} (BROKEN)"
            ((FAIL++))
        fi
    done
else
    echo "[FAIL] No symlinks found in ${SYMLINK_DIR}/"
    ((FAIL++))
fi

echo ""
echo "--- Reboot persistence test ---"
echo "To fully verify persistence, reboot the server and re-run this test."
echo "After reboot, the symlinks should still point to the correct devices."

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ $FAIL -eq 0 ]] && echo "All persistence checks PASSED." || echo "Some checks FAILED."
exit $FAIL
TESTSCRIPT
    write_test_script "test_03_persistence.sh"

    pause
}

#===============================================================================
# PHASE 4 — IBM STORAGE PROTECT CONFIGURATION
#===============================================================================

phase4_sp_config() {
    banner "PHASE 4 — IBM STORAGE PROTECT LIBRARY CONFIGURATION"

    # Gather SP connection details
    info "We need to connect to your IBM Storage Protect server via dsmadmc."
    echo ""

    read -rp "    SP server name (as defined in SP): " SP_SERVER
    SP_SERVER="${SP_SERVER:-YOURSERVERNAME}"

    read -rp "    SP admin user: " SP_ADMIN_USER
    SP_ADMIN_USER="${SP_ADMIN_USER:-admin}"

    read -rsp "    SP admin password: " SP_ADMIN_PASS
    echo ""
    SP_ADMIN_PASS="${SP_ADMIN_PASS:-password}"

    read -rp "    Library name to use in SP [SPECTRALIB]: " SP_LIBRARY_NAME
    SP_LIBRARY_NAME="${SP_LIBRARY_NAME:-SPECTRALIB}"

    # Determine dsmadmc path
    local dsmadmc_path
    dsmadmc_path=$(command -v dsmadmc 2>/dev/null || echo "")
    if [[ -z "$dsmadmc_path" ]]; then
        # Common paths
        for p in /opt/tivoli/tsm/client/ba/bin/dsmadmc \
                 /opt/tivoli/tsm/server/bin/dsmadmc \
                 /usr/bin/dsmadmc; do
            if [[ -x "$p" ]]; then
                dsmadmc_path="$p"
                break
            fi
        done
    fi

    if [[ -z "$dsmadmc_path" ]]; then
        warn "dsmadmc not found in PATH. SP commands will be saved as scripts only."
        DSMADMC_CMD=""
    else
        DSMADMC_CMD="${dsmadmc_path} -id=${SP_ADMIN_USER} -pa=${SP_ADMIN_PASS} -displ=list"
        success "dsmadmc found: ${dsmadmc_path}"
    fi

    # Gather drive details
    local num_drives
    read -rp "    Number of physical drives: " num_drives
    num_drives="${num_drives:-2}"

    local -a element_addrs=()
    for (( d=1; d<=num_drives; d++ )); do
        local default_elem=$(( 255 + d ))
        read -rp "    Element address for Drive ${d} [${default_elem}]: " elem
        element_addrs+=("${elem:-$default_elem}")
    done

    # Build the SP configuration script
    local sp_script="${OUTPUT_DIR}/sp_configure_library.dsmadmc"
    cat > "$sp_script" <<SPEOF
/******************************************************************************
 * IBM Storage Protect — Library Configuration Script
 * Generated: $(date '+%F %T')
 * Server:    ${SP_SERVER}
 * Library:   ${SP_LIBRARY_NAME}
 * Drives:    ${num_drives} (dual-pathed)
 ******************************************************************************/

/* ============================================================
 * STEP 1: Define the library
 * ============================================================ */
DEFINE LIBRARY ${SP_LIBRARY_NAME} LIBTYPE=SCSI

/* ============================================================
 * STEP 2: Define the path to the library (medium changer)
 * ============================================================ */
DEFINE PATH ${SP_SERVER} ${SP_LIBRARY_NAME} SRCTYPE=SERVER DESTTYPE=LIBRARY DEVICE=${SYMLINK_BASE}/library0 ONLINE=YES

SPEOF

    for (( d=1; d<=num_drives; d++ )); do
        local padded
        padded=$(printf "%02d" "$d")
        cat >> "$sp_script" <<SPEOF

/* ============================================================
 * STEP 3.${d}: Define Drive ${padded} and its dual paths
 * ============================================================ */
DEFINE DRIVE ${SP_LIBRARY_NAME} DRIVE${padded} ELEMENT=${element_addrs[$((d-1))]} CLEANFREQUENCY=ASNEEDED

/* Primary path (HBA A) */
DEFINE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path0 ONLINE=YES

/* Secondary path (HBA B) */
DEFINE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path1 ONLINE=YES
SPEOF
    done

    cat >> "$sp_script" <<SPEOF

/* ============================================================
 * STEP 4: Audit the library
 * ============================================================ */
AUDIT LIBRARY ${SP_LIBRARY_NAME} CHECKLABEL=BARCODE

/* ============================================================
 * STEP 5: Define device class
 * ============================================================ */
DEFINE DEVCLASS LTO_DC DEVTYPE=LTO LIBRARY=${SP_LIBRARY_NAME} FORMAT=DRIVE MOUNTRETENTION=60 MOUNTWAIT=60 MOUNTLIMIT=DRIVES

/* ============================================================
 * STEP 6: Define storage pool
 * ============================================================ */
DEFINE STGPOOL LTO_POOL LTO_DC MAXSCRATCH=500 COLLOCATE=FILESPACE REUSEDELAY=1

/* ============================================================
 * STEP 7: Label and check in tapes
 * ============================================================ */
LABEL LIBVOLUME ${SP_LIBRARY_NAME} SEARCH=YES LABELSOURCE=BARCODE CHECKIN=SCRATCH OVERWRITE=NO
SPEOF

    success "SP configuration script written: ${sp_script}"
    echo ""

    # Display it
    info "Generated SP configuration commands:"
    echo "────────────────────────────────────────"
    cat "$sp_script"
    echo "────────────────────────────────────────"
    echo ""

    # Optionally execute
    if [[ -n "$DSMADMC_CMD" ]]; then
        if confirm "Execute these commands against the SP server now?"; then
            warn "Executing SP commands — errors will be logged."
            while IFS= read -r line; do
                # Skip comments and blank lines
                [[ "$line" =~ ^[[:space:]]*/\* ]] && continue
                [[ "$line" =~ ^\*/ ]] && continue
                [[ "$line" =~ ^[[:space:]]*$ ]] && continue
                [[ "$line" =~ ^[[:space:]]*\* ]] && continue
                run_dsmadmc "$line"
            done < "$sp_script"
            success "SP commands executed."
        fi
    else
        info "dsmadmc not available. Run the commands manually:"
        info "  dsmadmc -id=${SP_ADMIN_USER} -pa=****** < ${sp_script}"
    fi

    # Generate Phase 4 test script
    cat > "${OUTPUT_DIR}/test_04_sp_config.sh" <<TESTSCRIPT
#!/usr/bin/env bash
#===============================================================================
# TEST 04 — IBM Storage Protect Configuration Verification
#===============================================================================
echo "============================================="
echo " TEST 04 — SP LIBRARY CONFIGURATION"
echo "============================================="

# Update these connection details as needed
SP_USER="${SP_ADMIN_USER}"
SP_PASS="${SP_ADMIN_PASS}"
SP_SERVER="${SP_SERVER}"
LIB_NAME="${SP_LIBRARY_NAME}"

DSMADMC="dsmadmc -id=\${SP_USER} -pa=\${SP_PASS} -displ=list -dataonly=yes"

PASS=0; FAIL=0

run_check() {
    local desc="\$1"
    local cmd="\$2"
    local output
    output=\$(\$DSMADMC "\$cmd" 2>&1)
    if [[ \$? -eq 0 ]] && [[ -n "\$output" ]]; then
        echo "[PASS] \${desc}"
        echo "       \${output}" | head -5
        ((PASS++))
    else
        echo "[FAIL] \${desc}"
        echo "       \${output}" | head -3
        ((FAIL++))
    fi
    echo ""
}

echo "--- Library ---"
run_check "Library \${LIB_NAME} exists"           "QUERY LIBRARY \${LIB_NAME} FORMAT=DETAILED"

echo "--- Library Path ---"
run_check "Library path exists"                   "QUERY PATH \${SP_SERVER} \${LIB_NAME} SRCTYPE=SERVER DESTTYPE=LIBRARY"

echo "--- Drives ---"
run_check "Drives defined"                        "QUERY DRIVE \${LIB_NAME}"

echo "--- Drive Paths (all) ---"
run_check "Drive paths defined"                   "QUERY PATH FORMAT=DETAILED"

echo "--- Device Class ---"
run_check "Device class LTO_DC"                   "QUERY DEVCLASS LTO_DC FORMAT=DETAILED"

echo "--- Storage Pool ---"
run_check "Storage pool LTO_POOL"                 "QUERY STGPOOL LTO_POOL FORMAT=DETAILED"

echo "--- Library Inventory ---"
run_check "Library volumes"                       "QUERY LIBVOLUME \${LIB_NAME}"

echo ""
echo "Results: \${PASS} passed, \${FAIL} failed."
[[ \$FAIL -eq 0 ]] && echo "All SP config checks PASSED." || echo "Some checks FAILED."
exit \$FAIL
TESTSCRIPT
    write_test_script "test_04_sp_config.sh"

    pause
}

#===============================================================================
# PHASE 5 — DUAL PATH FAILOVER TESTING
#===============================================================================

phase5_failover() {
    banner "PHASE 5 — DUAL-PATH FAILOVER TESTING"

    info "This phase generates a test script that validates dual-path failover."
    info "It will:"
    info "  1. Verify all paths are ONLINE"
    info "  2. Take path0 OFFLINE for each drive"
    info "  3. Attempt a mount (or query) to prove path1 is used"
    info "  4. Bring path0 back ONLINE"
    info "  5. Repeat in reverse (take path1 offline)"
    echo ""

    local num_drives
    read -rp "    Number of drives to test failover for [2]: " num_drives
    num_drives="${num_drives:-2}"

    cat > "${OUTPUT_DIR}/test_05_failover.sh" <<TESTSCRIPT
#!/usr/bin/env bash
#===============================================================================
# TEST 05 — Dual-Path Failover Verification
#
# WARNING: This test temporarily takes drive paths offline.
#          Run during a maintenance window!
#===============================================================================
echo "============================================="
echo " TEST 05 — DUAL-PATH FAILOVER"
echo "============================================="

SP_USER="${SP_ADMIN_USER}"
SP_PASS="${SP_ADMIN_PASS}"
SP_SERVER="${SP_SERVER}"
LIB_NAME="${SP_LIBRARY_NAME}"
SYMLINK_DIR="${SYMLINK_BASE}"

DSMADMC="dsmadmc -id=\${SP_USER} -pa=\${SP_PASS} -displ=list"

echo ""
echo "Step 1: Verify all paths are ONLINE"
echo "──────────────────────────────────────"
\$DSMADMC "QUERY PATH FORMAT=DETAILED" | grep -E "Source Name|Destination Name|Device|Online"
echo ""

TESTSCRIPT

    for (( d=1; d<=num_drives; d++ )); do
        local padded
        padded=$(printf "%02d" "$d")
        cat >> "${OUTPUT_DIR}/test_05_failover.sh" <<TESTSCRIPT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FAILOVER TEST — DRIVE${padded}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Step 2a: Take path0 OFFLINE for DRIVE${padded}"
\$DSMADMC "UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path0 ONLINE=NO"
sleep 2

echo ""
echo "Step 2b: Verify path0 is offline, path1 is online"
\$DSMADMC "QUERY PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE" | grep -E "Device|Online"

echo ""
echo "Step 2c: Query drive status (SP should use path1)"
\$DSMADMC "QUERY DRIVE \${LIB_NAME} DRIVE${padded} FORMAT=DETAILED"

echo ""
echo "Step 2d: Restore path0 ONLINE"
\$DSMADMC "UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path0 ONLINE=YES"
sleep 2

echo ""
echo "Step 3a: Take path1 OFFLINE for DRIVE${padded}"
\$DSMADMC "UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path1 ONLINE=NO"
sleep 2

echo ""
echo "Step 3b: Verify path1 is offline, path0 is online"
\$DSMADMC "QUERY PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE" | grep -E "Device|Online"

echo ""
echo "Step 3c: Query drive status (SP should use path0)"
\$DSMADMC "QUERY DRIVE \${LIB_NAME} DRIVE${padded} FORMAT=DETAILED"

echo ""
echo "Step 3d: Restore path1 ONLINE"
\$DSMADMC "UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path1 ONLINE=YES"
sleep 2

echo ""
echo "Step 4: Verify both paths restored for DRIVE${padded}"
\$DSMADMC "QUERY PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE" | grep -E "Device|Online"
echo ""
TESTSCRIPT
    done

    cat >> "${OUTPUT_DIR}/test_05_failover.sh" <<'TESTSCRIPT'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FAILOVER TESTING COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Review the output above. For each drive:"
echo "  - When path0 was offline, SP should have used path1 (and vice versa)."
echo "  - Both paths should now be back ONLINE."
echo ""
echo "For a comprehensive test, initiate a backup while one path is offline"
echo "and verify data flows through the alternate path."
TESTSCRIPT
    write_test_script "test_05_failover.sh"

    pause
}

#===============================================================================
# PHASE 6 — COMPREHENSIVE END-TO-END TEST
#===============================================================================

phase6_e2e_test() {
    banner "PHASE 6 — END-TO-END INTEGRATION TEST"

    cat > "${OUTPUT_DIR}/test_06_end_to_end.sh" <<TESTSCRIPT
#!/usr/bin/env bash
#===============================================================================
# TEST 06 — End-to-End Integration Test
#
# This script performs a full stack verification:
#   1. OS-level driver and device checks
#   2. Persistent symlink checks
#   3. SP library, drive, path, and pool checks
#   4. Operational test: mount a scratch tape and write a test file
#===============================================================================
set -uo pipefail

echo "============================================="
echo " TEST 06 — END-TO-END INTEGRATION"
echo "============================================="

SP_USER="${SP_ADMIN_USER}"
SP_PASS="${SP_ADMIN_PASS}"
SP_SERVER="${SP_SERVER}"
LIB_NAME="${SP_LIBRARY_NAME}"
SYMLINK_DIR="${SYMLINK_BASE}"

DSMADMC="dsmadmc -id=\${SP_USER} -pa=\${SP_PASS} -displ=list -dataonly=yes"
PASS=0; FAIL=0; WARN=0

check() {
    local desc="\$1"; shift
    if "\$@" &>/dev/null; then
        echo "[PASS] \${desc}"
        ((PASS++))
    else
        echo "[FAIL] \${desc}"
        ((FAIL++))
    fi
}

section() {
    echo ""
    echo "──────────────────────────────────────────"
    echo " \$1"
    echo "──────────────────────────────────────────"
}

# ── Section 1: OS / Driver ────────────────────────────────────────
section "1. OS & DRIVER"
check "lin_tape module loaded"                lsmod | grep -q lin_tape
check "st driver NOT loaded"                  bash -c '! lsmod | grep -q "^st "'
check "/dev/IBMtape* present"                 ls /dev/IBMtape*
check "/dev/IBMchanger* present"              ls /dev/IBMchanger*
check "Blacklist conf exists"                 test -f /etc/modprobe.d/blacklist-tape-generic.conf
check "modules-load.d entry"                  test -f /etc/modules-load.d/lin_tape.conf

# ── Section 2: Persistence ────────────────────────────────────────
section "2. PERSISTENT SYMLINKS"
check "udev rules file exists"               test -f /etc/udev/rules.d/99-ibm-tape-persist.rules
check "Symlink directory exists"              test -d "\${SYMLINK_DIR}"
check "Library symlink exists"                test -L "\${SYMLINK_DIR}/library0"

for link in "\${SYMLINK_DIR}"/drive*; do
    [[ -L "\$link" ]] || continue
    target=\$(readlink -f "\$link")
    check "Symlink \$(basename \$link) -> \${target}" test -e "\$target"
done

# ── Section 3: SP Configuration ──────────────────────────────────
section "3. STORAGE PROTECT CONFIG"

check "Library \${LIB_NAME} defined"         \$DSMADMC "QUERY LIBRARY \${LIB_NAME}"
check "Library path defined"                 \$DSMADMC "QUERY PATH \${SP_SERVER} \${LIB_NAME} SRCTYPE=SERVER DESTTYPE=LIBRARY"
check "At least one drive defined"           \$DSMADMC "QUERY DRIVE \${LIB_NAME}"
check "Device class LTO_DC"                  \$DSMADMC "QUERY DEVCLASS LTO_DC"
check "Storage pool LTO_POOL"                \$DSMADMC "QUERY STGPOOL LTO_POOL"

# Count paths
path_count=\$(\$DSMADMC "QUERY PATH" 2>/dev/null | grep -c "DRIVE" || echo 0)
echo "[INFO] Total drive paths found: \${path_count}"
if [[ \$path_count -ge 2 ]]; then
    echo "[PASS] Multiple drive paths detected (dual-path expected)"
    ((PASS++))
else
    echo "[WARN] Fewer than 2 drive paths detected — verify dual-pathing"
    ((WARN++))
fi

# ── Section 4: Operational Test ──────────────────────────────────
section "4. OPERATIONAL TEST"

echo "[INFO] Attempting to query library inventory ..."
vol_output=\$(\$DSMADMC "QUERY LIBVOLUME \${LIB_NAME}" 2>&1)
if [[ \$? -eq 0 ]] && [[ -n "\$vol_output" ]]; then
    echo "[PASS] Library inventory query succeeded."
    echo "\$vol_output" | head -10
    ((PASS++))
else
    echo "[WARN] Library inventory query returned no results (library may be empty)."
    ((WARN++))
fi

echo ""
echo "[INFO] Checking drive status ..."
\$DSMADMC "SELECT drive_name, online, drive_state FROM drives WHERE library_name='\${LIB_NAME}'" 2>/dev/null | head -20 || \
    \$DSMADMC "QUERY DRIVE \${LIB_NAME} FORMAT=DETAILED" 2>/dev/null | head -30

echo ""
echo "[INFO] To test a full write operation, run a backup to the LTO_POOL"
echo "       storage pool and verify data is written to tape."
echo "       Example:"
echo "         dsmc archive /tmp/testfile -se=\${SP_SERVER}"
echo "       Then verify:"
echo "         \$DSMADMC \"QUERY VOLUME * STGPOOL=LTO_POOL\""

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "============================================="
echo " SUMMARY"
echo "============================================="
echo " Passed  : \${PASS}"
echo " Failed  : \${FAIL}"
echo " Warnings: \${WARN}"
echo "============================================="
[[ \$FAIL -eq 0 ]] && echo "All critical checks PASSED." || echo "Some checks FAILED — review output above."
exit \$FAIL
TESTSCRIPT
    write_test_script "test_06_end_to_end.sh"

    pause
}

#===============================================================================
# PHASE 7 — GENERATE MASTER RUNNER
#===============================================================================

phase7_master_runner() {
    banner "PHASE 7 — MASTER TEST RUNNER"

    cat > "${OUTPUT_DIR}/run_all_tests.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# MASTER TEST RUNNER
# Runs all test scripts in sequence and produces a summary.
#===============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  IBM Storage Protect — Tape Library Test Suite           ║"
echo "║  $(date '+%F %T')                                   ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

run_test() {
    local test_script="$1"
    local test_name
    test_name=$(basename "$test_script" .sh)

    echo ""
    echo "┌───────────────────────────────────────────────────────────┐"
    echo "│ Running: ${test_name}"
    echo "└───────────────────────────────────────────────────────────┘"

    if [[ ! -x "$test_script" ]]; then
        echo "[SKIP] ${test_script} not found or not executable."
        return
    fi

    local rc=0
    bash "$test_script" || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo ">>> ${test_name}: ALL PASSED"
        ((TOTAL_PASS++))
    else
        echo ">>> ${test_name}: SOME FAILURES (exit code ${rc})"
        ((TOTAL_FAIL++))
    fi
}

# Run tests in order
run_test "${SCRIPT_DIR}/test_00_prerequisites.sh"
run_test "${SCRIPT_DIR}/test_01_lin_tape.sh"
run_test "${SCRIPT_DIR}/test_02_discovery.sh"
run_test "${SCRIPT_DIR}/test_03_persistence.sh"
run_test "${SCRIPT_DIR}/test_04_sp_config.sh"
run_test "${SCRIPT_DIR}/test_05_failover.sh"
run_test "${SCRIPT_DIR}/test_06_end_to_end.sh"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  FINAL SUMMARY                                          ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Test suites passed : ${TOTAL_PASS}                              ║"
echo "║  Test suites failed : ${TOTAL_FAIL}                              ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

[[ $TOTAL_FAIL -eq 0 ]] && echo "✅ ALL TEST SUITES PASSED." || echo "❌ SOME TEST SUITES HAD FAILURES."
exit $TOTAL_FAIL
TESTSCRIPT
    write_test_script "run_all_tests.sh"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    clear
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                 ║"
    echo "║   IBM Storage Protect — Spectra Logic Library Setup Wizard      ║"
    echo "║   Dual-Pathed IBM LTO Drives on RHEL                           ║"
    echo "║                                                                 ║"
    echo "║   This script will walk you through:                            ║"
    echo "║     Phase 0 — Prerequisite checks                               ║"
    echo "║     Phase 1 — lin_tape driver installation                      ║"
    echo "║     Phase 2 — Device discovery                                  ║"
    echo "║     Phase 3 — Persistent device binding (udev)                  ║"
    echo "║     Phase 4 — SP library / drive / path configuration           ║"
    echo "║     Phase 5 — Dual-path failover test generation                ║"
    echo "║     Phase 6 — End-to-end integration test generation            ║"
    echo "║     Phase 7 — Master test runner generation                     ║"
    echo "║                                                                 ║"
    echo "║   All output and test scripts are saved to:                     ║"
    echo "║     ${OUTPUT_DIR}                              ║"
    echo "║                                                                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""

    pause

    phase0_init
    phase1_lin_tape
    phase2_discovery
    phase3_persistence
    phase4_sp_config
    phase5_failover
    phase6_e2e_test
    phase7_master_runner

    banner "SETUP COMPLETE"

    echo ""
    info "All configuration and test scripts have been saved to:"
    info "  ${OUTPUT_DIR}/"
    echo ""
    echo "  Generated files:"
    echo "  ────────────────────────────────────────────────────"
    ls -1 "${OUTPUT_DIR}/" | while read -r f; do
        echo "    ${f}"
    done
    echo "  ────────────────────────────────────────────────────"
    echo ""
    info "To run ALL tests:"
    info "  sudo bash ${OUTPUT_DIR}/run_all_tests.sh"
    echo ""
    info "To run individual tests:"
    info "  sudo bash ${OUTPUT_DIR}/test_00_prerequisites.sh"
    info "  sudo bash ${OUTPUT_DIR}/test_01_lin_tape.sh"
    info "  sudo bash ${OUTPUT_DIR}/test_02_discovery.sh"
    info "  sudo bash ${OUTPUT_DIR}/test_03_persistence.sh"
    info "  sudo bash ${OUTPUT_DIR}/test_04_sp_config.sh"
    info "  sudo bash ${OUTPUT_DIR}/test_05_failover.sh    # ⚠ maintenance window"
    info "  sudo bash ${OUTPUT_DIR}/test_06_end_to_end.sh"
    echo ""
    info "Logs: ${LOG_FILE}"
    echo ""
    success "Done. Good luck with your tape library! 🎉"
}

main "$@"
