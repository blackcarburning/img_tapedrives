#!/usr/bin/env bash
#===============================================================================
#
#  IBM Storage Protect — Spectra Logic Tape Library Configuration Wizard
#  (PRINT-ONLY MODE — does not execute any commands)
#
#  Purpose:   Walk through every step of configuring a Spectra Logic tape
#             library with dual-pathed IBM LTO drives on RHEL for
#             IBM Storage Protect 8.1.x. Prints all commands for the
#             operator to run manually.
#
#  Usage:     bash sp_tape_library_setup.sh
#
#  Platform:  Red Hat Enterprise Linux 8.x / 9.x
#
#===============================================================================

set -euo pipefail

#---------------------------------------
# GLOBALS (collected interactively)
#---------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/sp_tape_setup_output"
SYMLINK_BASE="/dev/tsmtape"

SP_SERVER=""
SP_ADMIN_USER=""
SP_LIBRARY_NAME=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

banner() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

pause() {
    echo ""
    read -rp "    Press ENTER to continue to the next phase (Ctrl-C to quit)... "
    echo ""
}

# Print a block of commands the operator should run.
print_commands() {
    echo ""
    echo -e "${DIM}┌─── COMMANDS TO RUN ──────────────────────────────────────────┐${NC}"
    while IFS= read -r line; do
        echo -e "  ${GREEN}${line}${NC}"
    done
    echo -e "${DIM}└──────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# Write a file to the output directory
write_file() {
    local filename="$1"
    local filepath="${OUTPUT_DIR}/${filename}"
    cat > "$filepath"
    chmod +x "$filepath" 2>/dev/null || true
    success "Written: ${filepath}"
}

#===============================================================================
# PHASE 0 — INFORMATION GATHERING
#===============================================================================

phase0_gather() {
    banner "PHASE 0 — INFORMATION GATHERING"

    info "I need a few details about your environment."
    info "These are used to generate commands and scripts — nothing is executed."
    echo ""

    read -rp "    SP server name (as registered in SP):  " SP_SERVER
    SP_SERVER="${SP_SERVER:-YOURSERVERNAME}";

    read -rp "    SP admin user ID:                      " SP_ADMIN_USER
    SP_ADMIN_USER="${SP_ADMIN_USER:-admin}";

    read -rp "    Library name to use in SP [SPECTRALIB]: " SP_LIBRARY_NAME
    SP_LIBRARY_NAME="${SP_LIBRARY_NAME:-SPECTRALIB}";

    read -rp "    Number of physical tape drives:         " NUM_DRIVES
    NUM_DRIVES="${NUM_DRIVES:-2}";

    declare -g -a DRIVE_ELEMENTS=()
    declare -g -a DRIVE_SERIALS_INPUT=()
    for (( d=1; d<=NUM_DRIVES; d++ )); do
        local padded
        padded=$(printf "%02d" "$d")
        local default_elem=$(( 255 + d ))
        read -rp "    Drive ${padded} element address [${default_elem}]: " elem
        DRIVE_ELEMENTS+=("${elem:-$default_elem}")
        read -rp "    Drive ${padded} serial number [SERIAL${padded}]:  " ser
        DRIVE_SERIALS_INPUT+=("${ser:-SERIAL${padded}}")
    done

    read -rp "    Library changer serial [LIBSERIAL001]:  " LIB_CHANGER_SERIAL
    LIB_CHANGER_SERIAL="${LIB_CHANGER_SERIAL:-LIBSERIAL001}";

    echo ""
    success "All inputs collected. No commands have been run."
    info "The following phases will print commands for you to execute."

    pause;
}

#===============================================================================
# PHASE 1 — LIN_TAPE DRIVER
#===============================================================================

phase1_lin_tape() {
    banner "PHASE 1 — IBM lin_tape DRIVER INSTALLATION"

    info "The lin_tape driver provides /dev/IBMtape* and /dev/IBMchanger* device nodes."
    info "Download the RPM from IBM Fix Central:"
    info "  https://www.ibm.com/support/fixcentral"
    info "  Product Group : System Storage"
    info "  Product       : Tape drivers and software > Tape device drivers"
    info "  Platform      : Linux"
    info "  Select the pre-built RPM matching your RHEL version."
    echo ""
    info "If a pre-built RPM is not available for your kernel (e.g., you are"
    info "running a custom or cloud-tuned kernel), you will need the source"
    info "tarball and the kernel-devel package to compile the module."
    echo ""

    info "Step 1a: Install the lin_tape RPM"
    print_commands <<'EOF'
# If using the pre-built RPM (typical case):
sudo rpm -ivh lin_tape-*.rpm

# If building from source tarball (only if no pre-built RPM exists for your kernel):
# sudo yum install -y kernel-devel-$(uname -r) gcc make
# tar -xzf lin_tape-*.tar.gz
# cd lin_tape-*
# make
# sudo make install
EOF

    info "Step 1b: Blacklist generic SCSI tape drivers"
    info "This prevents the 'st' and 'sg' drivers from claiming your tape devices."   
    print_commands <<'EOF'
sudo tee /etc/modprobe.d/blacklist-tape-generic.conf <<'CONF'
# Prevent generic SCSI tape/generic drivers from loading before lin_tape
blacklist st
blacklist sg
CONF
EOF

    info "Step 1c: Ensure lin_tape loads at boot"
    print_commands <<'EOF'
echo "lin_tape" | sudo tee /etc/modules-load.d/lin_tape.conf
EOF

    info "Step 1d: Unload generic drivers (if loaded) and load lin_tape"
    print_commands <<'EOF'
sudo rmmod st 2>/dev/null; true
sudo rmmod sg 2>/dev/null; true
sudo modprobe lin_tape
EOF

    info "Step 1e: Rebuild initramfs so blacklist persists across reboots"
    print_commands <<'EOF'
sudo dracut --force
EOF

    info "Step 1f: Verify"
    print_commands <<'EOF'
lsmod | grep lin_tape
ls -la /dev/IBMtape*
ls -la /dev/IBMchanger*
EOF

    # Generate test script
    write_file "test_01_lin_tape.sh" <<'TESTSCRIPT'
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
check "/dev/IBMtape* devices present"         ls /dev/IBMtape*
check "/dev/IBMchanger* devices present"      ls /dev/IBMchanger*

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
echo "--- Recent dmesg (tape related) ---"
dmesg | grep -i -E "tape|IBMtape|lin_tape|changer" | tail -20
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
[[ $FAIL -eq 0 ]] && echo "All lin_tape checks PASSED." || echo "Some checks FAILED."
exit $FAIL
TESTSCRIPT

    pause;
}

#===============================================================================
# PHASE 2 — DEVICE DISCOVERY
#===============================================================================

phase2_discovery() {
    banner "PHASE 2 — DEVICE DISCOVERY"

    info "After lin_tape is loaded, run these commands to discover your devices"
    info "and gather the attributes needed for persistent udev rules."
    echo ""

    info "Step 2a: List tape and changer device nodes"
    print_commands <<'EOF'
ls -la /dev/IBMtape*
ls -la /dev/IBMchanger*
EOF

    info "Step 2b: Use lsscsi to see SCSI device mapping"
    print_commands <<'EOF'
lsscsi -g
EOF

    info "Step 2c: Dump udev attributes for each device"
    info "Run this for EVERY /dev/IBMtape* and /dev/IBMchanger* device."
    info "The output tells you which attributes (serial, path, etc.) to match in udev rules."
    print_commands <<'EOF'
# Repeat for each device — e.g. /dev/IBMtape0, /dev/IBMtape1, etc.
udevadm info --query=all --name=/dev/IBMtape0
udevadm info --query=all --name=/dev/IBMtape1
udevadm info --query=all --name=/dev/IBMchanger0

# For a deeper sysfs attribute walk (useful for building ATTRS{} matches):
udevadm info --attribute-walk --name=/dev/IBMtape0
EOF

    info "Step 2d: Identify FC HBA ports and their WWPNs"
    print_commands <<'EOF'
for host_dir in /sys/class/fc_host/host*; do
    host=$(basename "$host_dir")
    wwpn=$(cat "${host_dir}/port_name" 2>/dev/null);
    state=$(cat "$host_dir/port_state" 2>/dev/null);
echo "  ${host}: WWPN=${wwpn}  State=${state}"
done
EOF

    info "Step 2e: Check /proc/scsi/IBMtape (if available)"
    print_commands <<'EOF'
cat /proc/scsi/IBMtape 2>/dev/null || echo "Not available"
EOF

    info "KEY INFORMATION TO RECORD:"
    info "  • Serial number of each tape device (from udevadm: ID_SCSI_SERIAL or ATTRS{serial})"
    info "  • Which /dev/IBMtape* nodes map to which physical drive"
    info "  • Which HBA path each device node uses (from udevadm: ID_PATH)"
    info "  • With dual pathing, each physical drive will appear as TWO /dev/IBMtape* nodes"
    info "  • Serial number of the changer device"

    # Generate test script
    write_file "test_02_discovery.sh" <<'TESTSCRIPT'
#!/usr/bin/env bash
#===============================================================================
# TEST 02 — Device Discovery & Attribute Dump
#===============================================================================
echo "============================================="
echo " TEST 02 — DEVICE DISCOVERY"
echo "============================================="
echo ""
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

echo "--- FC HBA ports ---"
for host_dir in /sys/class/fc_host/host*; do
    [[ -d "$host_dir" ]] || continue
    host=$(basename "$host_dir")
    wwpn=$(cat "${host_dir}/port_name" 2>/dev/null);
    state=$(cat "${host_dir}/port_state" 2>/dev/null);
echo "  ${host}: WWPN=${wwpn}  State=${state}"
done

echo ""
echo "--- /proc/scsi/IBMtape ---"
cat /proc/scsi/IBMtape 2>/dev/null || echo "(not available)"
echo ""
echo "Discovery complete."
TESTSCRIPT

    pause;
}

#===============================================================================
# PHASE 3 — PERSISTENT DEVICE BINDING (udev RULES)
#===============================================================================

phase3_persistence() {
    banner "PHASE 3 — PERSISTENT DEVICE BINDING (udev RULES)"

    info "Device nodes like /dev/IBMtape0 are assigned dynamically. They can"
    info "shift across reboots if hardware changes. We create udev rules that"
    info "give each drive path a stable symlink under ${SYMLINK_BASE}/."
    echo ""

    # Build the rules content from gathered info
    local rules_content=""
    rules_content+="#===============================================================================\n"
    rules_content+="# IBM Storage Protect — Persistent tape device symlinks\n"
    rules_content+="# Generated: $(date '+%F %T')\n"
    rules_content+="# Library: Spectra Logic with IBM LTO drives (dual-pathed)\n"
    rules_content+="#\n"
    rules_content+="# IMPORTANT: The match attributes below (ATTRS{serial}, ENV{ID_PATH}) must be\n"
    rules_content+="# verified against your actual udevadm output from Phase 2. Adjust as needed.\n"
    rules_content+="#\n"
    rules_content+="# Useful udevadm commands to find the right attributes:\n"
    rules_content+="#   udevadm info --query=all --name=/dev/IBMtape0\n"
    rules_content+="#   udevadm info --attribute-walk --name=/dev/IBMtape0\n"
    rules_content+="#===============================================================================\n\n"

    # Library changer
    rules_content+="# --- Medium Changer (Library) ---\n"
    rules_content+="KERNEL==\"IBMchanger[0-9]*\", ATTRS{serial}==\"${LIB_CHANGER_SERIAL}\", SYMLINK+=\"tsmtape/library0\"\n\n"

    # Drives
    for (( d=1; d<=NUM_DRIVES; d++ )); do
        local padded
        padded=$(printf "%02d" "$d")
        local serial="${DRIVE_SERIALS_INPUT[$((d-1))]}"

        rules_content+="# --- Drive ${padded} (serial: ${serial}) ---\n"
        rules_content+="# Path 0 (HBA A) — adjust ENV{ID_PATH} pattern to match your first HBA\n"
        rules_content+="KERNEL==\"IBMtape[0-9]*\", ATTRS{serial}==\"${serial}\", ENV{ID_PATH}==\"*pci-0000:XX:00.0*\", SYMLINK+=\"tsmtape/drive${padded}_path0\"\n"
        rules_content+="# Path 1 (HBA B) — adjust ENV{ID_PATH} pattern to match your second HBA\n"
        rules_content+="KERNEL==\"IBMtape[0-9]*\", ATTRS{serial}==\"${serial}\", ENV{ID_PATH}==\"*pci-0000:YY:00.0*\", SYMLINK+=\"tsmtape/drive${padded}_path1\"\n\n"
    done

    info "Here is the generated udev rules file."
    info "Review it and adjust the ENV{ID_PATH} patterns based on your Phase 2 discovery."
    echo ""
    echo -e "${DIM}┌─── /etc/udev/rules.d/99-ibm-tape-persist.rules ─────────────┐${NC}"
    echo -e "$rules_content"
    echo -e "${DIM}└──────────────────────────────────────────────────────────────┘${NC}"

    # Save to output dir
    echo -e "$rules_content" | write_file "99-ibm-tape-persist.rules"

    echo ""
    info "Step 3a: Review and install the udev rules"
    print_commands <<EOF
# Review the generated rules file:
cat ${OUTPUT_DIR}/99-ibm-tape-persist.rules

# After editing/verifying, copy into place:
sudo cp ${OUTPUT_DIR}/99-ibm-tape-persist.rules /etc/udev/rules.d/99-ibm-tape-persist.rules
EOF

    info "Step 3b: Create the symlink directory and reload udev"
    print_commands <<EOF
sudo mkdir -p ${SYMLINK_BASE}
sudo udevadm control --reload-rules
sudo udevadm trigger
sleep 2
EOF

    info "Step 3c: Verify symlinks"
    print_commands <<EOF
ls -la ${SYMLINK_BASE}/
# Expected:
#   drive01_path0 -> ../IBMtape0
#   drive01_path1 -> ../IBMtape1
#   drive02_path0 -> ../IBMtape2
#   drive02_path1 -> ../IBMtape3
#   library0      -> ../IBMchanger0
EOF

    # Generate test script
    cat <<TESTSCRIPT | write_file "test_03_persistence.sh"
#!/usr/bin/env bash
#===============================================================================
# TEST 03 — Persistent Device Binding Verification
#===============================================================================
echo "============================================="
echo " TEST 03 — PERSISTENT DEVICE BINDING"
echo "============================================="

PASS=0; FAIL=0;
SYMLINK_DIR="${SYMLINK_BASE}"

check() {
    local desc="\$1"; shift
    if "\$@" &>/dev/null; then
        echo "[PASS] \${desc}"
        ((PASS++));
    else
        echo "[FAIL] \${desc}"
        ((FAIL++));
    fi
}

check "udev rules file exists"        test -f /etc/udev/rules.d/99-ibm-tape-persist.rules;
check "Symlink directory exists"       test -d "\$SYMLINK_DIR";

echo ""
echo "--- Symlinks in \${SYMLINK_DIR}/ ---";
if ls -la "\$SYMLINK_DIR/" 2>/dev/null; then
    for link in "\$SYMLINK_DIR"/*; do
        [[ -L "\$link" ]] || continue;
        target=\$(readlink -f "\$link");
        if [[ -e "\$target" ]]; then
            echo "[PASS] \${link} -> \${target}";
            ((PASS++));
        else
            echo "[FAIL] \${link} -> \${target} (BROKEN SYMLINK)";
            ((FAIL++));
        fi
    done;
else
    echo "[FAIL] No symlinks found in \${SYMLINK_DIR}/";
    ((FAIL++));
fi

echo ""
echo "Reboot test: reboot the server, then re-run this script.";
echo "Symlinks must survive reboot to be considered persistent.";
echo ""
echo "Results: \${PASS} passed, \${FAIL} failed.";
[[ \$FAIL -eq 0 ]] && echo "All checks PASSED." || echo "Some checks FAILED.";
exit \$FAIL;
TESTSCRIPT

    pause;
}

#===============================================================================
# PHASE 4 — SP LIBRARY / DRIVE / PATH CONFIGURATION
#===============================================================================

phase4_sp_config() {
    banner "PHASE 4 — IBM STORAGE PROTECT CONFIGURATION"

    info "Below are the dsmadmc commands to define the library, drives,"
    info "paths, device class, and storage pool."
    info "Run these in a dsmadmc session or pipe them into dsmadmc."
    echo ""

    # Build the full SP script
    local sp_script=""
    sp_script+="/* ============================================================\n"
    sp_script+=" * STEP 1: Define the library\n"
    sp_script+=" * ============================================================ */\n"
    sp_script+="DEFINE LIBRARY ${SP_LIBRARY_NAME} LIBTYPE=SCSI\n\n"

    sp_script+="/* ============================================================\n"
    sp_script+=" * STEP 2: Define the path from the server to the library changer\n"
    sp_script+=" * ============================================================ */\n"
    sp_script+="DEFINE PATH ${SP_SERVER} ${SP_LIBRARY_NAME} SRCTYPE=SERVER DESTTYPE=LIBRARY DEVICE=${SYMLINK_BASE}/library0 ONLINE=YES\n\n"

    for (( d=1; d<=NUM_DRIVES; d++ )); do
        local padded;
        padded=$(printf "%02d" "$d");
        sp_script+="/* ============================================================\n"
        sp_script+=" * STEP 3.${d}: Drive ${padded}  (element ${DRIVE_ELEMENTS[$((d-1))]})\n"
        sp_script+=" * ============================================================ */\n"
        sp_script+="DEFINE DRIVE ${SP_LIBRARY_NAME} DRIVE${padded} ELEMENT=${DRIVE_ELEMENTS[$((d-1))]} CLEANFREQUENCY=ASNEEDED\n\n"
        sp_script+="/* Primary path (HBA A) */\n"
        sp_script+="DEFINE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path0 ONLINE=YES\n\n"
        sp_script+="/* Secondary path (HBA B) */\n"
        sp_script+="DEFINE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path1 ONLINE=YES\n\n"
    done

    sp_script+="/* ============================================================\n"
    sp_script+=" * STEP 4: Audit the library\n"
    sp_script+=" * ============================================================ */\n"
    sp_script+="AUDIT LIBRARY ${SP_LIBRARY_NAME} CHECKLABEL=BARCODE\n\n"

    sp_script+="/* ============================================================\n"
    sp_script+=" * STEP 5: Define device class\n"
    sp_script+=" * ============================================================ */\n"
    sp_script+="DEFINE DEVCLASS LTO_DC DEVTYPE=LTO LIBRARY=${SP_LIBRARY_NAME} FORMAT=DRIVE MOUNTRETENTION=60 MOUNTWAIT=60 MOUNTLIMIT=DRIVES\n\n"

    sp_script+="/* ============================================================\n"
    sp_script+=" * STEP 6: Define storage pool\n"
    sp_script+=" * ============================================================ */\n"
    sp_script+="DEFINE STGPOOL LTO_POOL LTO_DC MAXSCRATCH=500 COLLOCATE=FILESPACE REUSEDELAY=1\n\n"

    sp_script+="/* ============================================================\n"
    sp_script+=" * STEP 7: Label and check in scratch tapes\n"
    sp_script+=" * ============================================================ */\n"
    sp_script+="LABEL LIBVOLUME ${SP_LIBRARY_NAME} SEARCH=YES LABELSOURCE=BARCODE CHECKIN=SCRATCH OVERWRITE=NO\n"

    echo -e "${DIM}┌─── dsmadmc commands ────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${sp_script}${NC}"
    echo -e "${DIM}└──────────────────────────────────────────────────────────────┘${NC}"

    # Save to file — strip C-style block comment lines so dsmadmc gets clean commands
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*/\* ]] && continue
        [[ "$line" =~ ^[[:space:]]*\*/ ]] && continue
        [[ "$line" =~ ^[[:space:]]*\* ]] && continue
        echo "$line"
    done <<< "$(echo -e "$sp_script")" | write_file "sp_configure_library.dsmadmc"

    echo ""
    info "How to run these commands:"
    print_commands <<EOF
# Option A: Run interactively — open dsmadmc and paste each command:
dsmadmc -id=${SP_ADMIN_USER}

# Option B: Pipe the whole script in:
dsmadmc -id=${SP_ADMIN_USER} < ${OUTPUT_DIR}/sp_configure_library.dsmadmc
EOF

    info "After running, verify with:"
    print_commands <<EOF
dsmadmc -id=${SP_ADMIN_USER} << 'VERIFY'
QUERY LIBRARY ${SP_LIBRARY_NAME} FORMAT=DETAILED
QUERY PATH FORMAT=DETAILED
QUERY DRIVE ${SP_LIBRARY_NAME} FORMAT=DETAILED
QUERY LIBVOLUME ${SP_LIBRARY_NAME}
QUERY DEVCLASS LTO_DC FORMAT=DETAILED
QUERY STGPOOL LTO_POOL FORMAT=DETAILED
VERIFY
EOF

    # Generate test script
    cat <<TESTSCRIPT | write_file "test_04_sp_config.sh"
#!/usr/bin/env bash
#===============================================================================
# TEST 04 — IBM Storage Protect Configuration Verification
#===============================================================================
echo "============================================="
echo " TEST 04 — SP LIBRARY CONFIGURATION"
echo "============================================="

SP_USER="${SP_ADMIN_USER}"
LIB_NAME="${SP_LIBRARY_NAME}"

DSMADMC="dsmadmc -id=\${SP_USER} -displ=list -dataonly=yes"
PASS=0; FAIL=0

run_check() {
    local desc="\$1"
    local cmd="\$2"
    local output;
    output=\$(\$DSMADMC "\$cmd" 2>&1);
    if [[ \$? -eq 0 ]] && [[ -n "\$output" ]]; then
        echo "[PASS] \${desc}"
        echo "       \$(echo "\$output" | head -3)";
        ((PASS++));
    else
        echo "[FAIL] \${desc}"
        ((FAIL++));
    fi
    echo "";
}

run_check "Library \${LIB_NAME} exists"     "QUERY LIBRARY \${LIB_NAME}"
run_check "Library path exists"             "QUERY PATH ${SP_SERVER} \${LIB_NAME} SRCTYPE=SERVER DESTTYPE=LIBRARY"
run_check "Drives defined"                  "QUERY DRIVE \${LIB_NAME}"
run_check "Drive paths defined"             "QUERY PATH FORMAT=DETAILED"
run_check "Device class LTO_DC"             "QUERY DEVCLASS LTO_DC"
run_check "Storage pool LTO_POOL"           "QUERY STGPOOL LTO_POOL"

echo ""
echo "Results: \${PASS} passed, \${FAIL} failed."
[[ \$FAIL -eq 0 ]] && echo "All SP config checks PASSED." || echo "Some checks FAILED."
exit \$FAIL;
TESTSCRIPT

    pause;
}

#===============================================================================
# PHASE 5 — DUAL-PATH FAILOVER TEST
#===============================================================================

phase5_failover() {
    banner "PHASE 5 — DUAL-PATH FAILOVER TESTING"

    info "These commands test failover by taking one path offline at a time."
    warn "Run these during a MAINTENANCE WINDOW only."
    echo ""

    for (( d=1; d<=NUM_DRIVES; d++ )); do
        local padded;
        padded=$(printf "%02d" "$d");

        echo -e "${BOLD}── Drive ${padded} ──${NC}"
        echo ""

        info "Test A: Disable path0, verify path1 is used"
        print_commands <<EOF
dsmadmc -id=${SP_ADMIN_USER} "UPDATE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path0 ONLINE=NO"
sleep 2
dsmadmc -id=${SP_ADMIN_USER} "QUERY PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE"
dsmadmc -id=${SP_ADMIN_USER} "QUERY DRIVE ${SP_LIBRARY_NAME} DRIVE${padded} FORMAT=DETAILED"
EOF

        info "Restore path0"
        print_commands <<EOF
dsmadmc -id=${SP_ADMIN_USER} "UPDATE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path0 ONLINE=YES"
sleep 2
EOF

        info "Test B: Disable path1, verify path0 is used"
        print_commands <<EOF
dsmadmc -id=${SP_ADMIN_USER} "UPDATE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path1 ONLINE=NO"
sleep 2
dsmadmc -id=${SP_ADMIN_USER} "QUERY PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE"
dsmadmc -id=${SP_ADMIN_USER} "QUERY DRIVE ${SP_LIBRARY_NAME} DRIVE${padded} FORMAT=DETAILED"
EOF

        info "Restore path1"
        print_commands <<EOF
dsmadmc -id=${SP_ADMIN_USER} "UPDATE PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=${SP_LIBRARY_NAME} DEVICE=${SYMLINK_BASE}/drive${padded}_path1 ONLINE=YES"
sleep 2
EOF

        info "Verify both paths restored for DRIVE${padded}"
        print_commands <<EOF
dsmadmc -id=${SP_ADMIN_USER} "QUERY PATH ${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE"
EOF
        echo "";
    done

    # Generate combined failover test script
    {
        echo '#!/usr/bin/env bash'
        echo '#===============================================================================';
        echo '# TEST 05 — Dual-Path Failover';
        echo '# WARNING: Takes paths offline temporarily. Run in maintenance window!';
        echo '#===============================================================================';
        echo 'echo "============================================="';
        echo 'echo " TEST 05 — DUAL-PATH FAILOVER"';
        echo 'echo "============================================="';
        echo ''; 
        echo "SP_USER=\"${SP_ADMIN_USER}\"";
        echo "LIB_NAME=\"${SP_LIBRARY_NAME}\"";
        echo "SP_SERVER=\"${SP_SERVER}\"";
        echo "SYMLINK_DIR=\"${SYMLINK_BASE}\"";
        echo ''; 
        echo 'DSMADMC="dsmadmc -id=\${SP_USER} -displ=list"';
        echo ''; 
        echo 'echo ""';
        echo 'echo "Verifying all paths are ONLINE before starting ..."';
        echo '\$DSMADMC "QUERY PATH FORMAT=DETAILED" | grep -E "Source Name|Destination Name|Device|Online"';
        echo 'echo ""';
        echo 'read -rp "All paths online? Press ENTER to begin failover test (Ctrl-C to abort)... "';
        echo ''; 
        for (( d=1; d<=NUM_DRIVES; d++ )); do
            local padded;
            padded=$(printf "%02d" "$d");
            echo "echo ''";
            echo "echo '━━━━ DRIVE${padded}: Take path0 offline ━━━━'";
            echo "\$DSMADMC \"UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path0 ONLINE=NO\"";
            echo "sleep 2";
            echo "\$DSMADMC \"QUERY PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE\" | grep -E 'Device|Online'";
            echo "\$DSMADMC \"QUERY DRIVE \${LIB_NAME} DRIVE${padded} FORMAT=DETAILED\" | grep -E 'Drive Name|State|Online'";
            echo "echo '━━━━ DRIVE${padded}: Restore path0 ━━━━'";
            echo "\$DSMADMC \"UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path0 ONLINE=YES\"";
            echo "sleep 2";
            echo "";
            echo "echo '━━━━ DRIVE${padded}: Take path1 offline ━━━━'";
            echo "\$DSMADMC \"UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path1 ONLINE=NO\"";
            echo "sleep 2";
            echo "\$DSMADMC \"QUERY PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE\" | grep -E 'Device|Online'";
            echo "\$DSMADMC \"QUERY DRIVE \${LIB_NAME} DRIVE${padded} FORMAT=DETAILED\" | grep -E 'Drive Name|State|Online'";
            echo "echo '━━━━ DRIVE${padded}: Restore path1 ━━━━'";
            echo "\$DSMADMC \"UPDATE PATH \${SP_SERVER} DRIVE${padded} SRCTYPE=SERVER DESTTYPE=DRIVE LIBRARY=\${LIB_NAME} DEVICE=\${SYMLINK_DIR}/drive${padded}_path1 ONLINE=YES\"";
            echo "sleep 2";
            echo "";
        done
        echo 'echo ""';
        echo 'echo "Failover testing complete. Verify all paths are back online:"';
        echo '\$DSMADMC "QUERY PATH FORMAT=DETAILED" | grep -E "Source Name|Destination Name|Device|Online"';
    } | write_file "test_05_failover.sh";

    pause;
}

#===============================================================================
# PHASE 6 — END-TO-END TEST
#===============================================================================

phase6_e2e() {
    banner "PHASE 6 — END-TO-END INTEGRATION TEST"

    info "This generates a comprehensive test script that validates the full stack."
    echo "";

    cat <<TESTSCRIPT | write_file "test_06_end_to_end.sh"
#!/usr/bin/env bash
#===============================================================================
# TEST 06 — End-to-End Integration Test
#===============================================================================
set -uo pipefail

echo "============================================="
echo " TEST 06 — END-TO-END INTEGRATION"
echo "============================================="

SP_USER="\${SP_ADMIN_USER}"
SP_SERVER="\${SP_SERVER}"
LIB_NAME="\${SP_LIBRARY_NAME}"
SYMLINK_DIR="\${SYMLINK_BASE}"

DSMADMC="dsmadmc -id=\${SP_USER} -displ=list -dataonly=yes"
PASS=0; FAIL=0; WARN=0

check() {
    local desc="\$1"; shift;
    if "\$@" &>/dev/null; then
        echo "[PASS] \${desc}"
        ((PASS++));
    else
        echo "[FAIL] \${desc}"
        ((FAIL++));
    fi
}

section() {
    echo ""
    echo "──────────────────────────────────────────"
    echo " \$1"
    echo "──────────────────────────────────────────"
}

# ── Section 1: OS / Driver ────────────────────────────────────
section "1. OS & DRIVER"
check "lin_tape loaded"                       lsmod | grep -q lin_tape;
check "st NOT loaded"                         bash -c '! lsmod | grep -q "^st "';
check "/dev/IBMtape* present"                 ls /dev/IBMtape*;
check "/dev/IBMchanger* present"              ls /dev/IBMchanger*;
check "Blacklist file"                        test -f /etc/modprobe.d/blacklist-tape-generic.conf;
check "modules-load.d"                        test -f /etc/modules-load.d/lin_tape.conf;

# ── Section 2: Persistence ────────────────────────────────────
section "2. PERSISTENT SYMLINKS"
check "udev rules file"                       test -f /etc/udev/rules.d/99-ibm-tape-persist.rules;
check "Symlink directory"                     test -d "\${SYMLINK_DIR}";
check "Library symlink"                       test -L "\${SYMLINK_DIR}/library0";

for link in "\${SYMLINK_DIR}"/drive*; do
    [[ -L "\$link" ]] || continue;
    target=\$(readlink -f "\$link");
    check "Symlink \$(basename \$link) resolves" test -e "\$target";
done;

# ── Section 3: SP Configuration ──────────────────────────────
section "3. STORAGE PROTECT"
sp_check() {
    local desc="\$1" cmd="\$2";
    local output;
    output=\$(\$DSMADMC "\$cmd" 2>&1);
    if [[ \$? -eq 0 ]] && [[ -n "\$output" ]]; then
        echo "[PASS] \${desc}"
        ((PASS++));
    else
        echo "[FAIL] \${desc}"
        ((FAIL++));
    fi
}

sp_check "Library \${LIB_NAME}"               "QUERY LIBRARY \${LIB_NAME}";
sp_check "Library path"                       "QUERY PATH \${SP_SERVER} \${LIB_NAME} SRCTYPE=SERVER DESTTYPE=LIBRARY";
sp_check "Drives"                             "QUERY DRIVE \${LIB_NAME}";
sp_check "Device class LTO_DC"                "QUERY DEVCLASS LTO_DC";
sp_check "Storage pool LTO_POOL"              "QUERY STGPOOL LTO_POOL";

path_count=\$(\$DSMADMC "QUERY PATH" 2>/dev/null | grep -c "DRIVE" || echo 0);
echo "[INFO] Drive paths found: \${path_count}";
if [[ \$path_count -ge $(( NUM_DRIVES * 2 )) ]]; then
    echo "[PASS] Expected $((NUM_DRIVES * 2)) drive paths for ${NUM_DRIVES} dual-pathed drives";
    ((PASS++));
else
    echo "[WARN] Expected $((NUM_DRIVES * 2)) paths, found \${path_count}";
    ((WARN++));
fi

# ── Section 4: Operational ────────────────────────────────────
section "4. OPERATIONAL"

vol_output=\$(\$DSMADMC "QUERY LIBVOLUME \${LIB_NAME}" 2>&1);
if [[ \$? -eq 0 ]] && [[ -n "\$vol_output" ]]; then
    echo "[PASS] Library inventory query succeeded";
    echo "       \$(echo "\$vol_output" | head -5)";
    ((PASS++));
else
    echo "[WARN] Library inventory empty (check in scratch tapes)";
    ((WARN++));
fi

# ── Summary ──────────────────────────────────────────────────
echo "";
echo "=============================================";
echo " SUMMARY";
echo "=============================================";
echo " Passed  : \${PASS}";
echo " Failed  : \${FAIL}";
echo " Warnings: \${WARN}";
echo "=============================================";
[[ \$FAIL -eq 0 ]] && echo "✅ ALL TEST SUITES PASSED." || echo "❌ SOME FAILURES.";
exit \$FAIL;
TESTSCRIPT

    pause;
}

#===============================================================================
# PHASE 7 — MASTER TEST RUNNER
#===============================================================================

phase7_master() {
    banner "PHASE 7 — MASTER TEST RUNNER"

    cat <<'TESTSCRIPT' | write_file "run_all_tests.sh"
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
echo "║  \$(date '+%F %T')                                   ║"
echo "╚═══════════════════════════════════════════════════════════╝";
echo "";

run_test() {
    local test_script="$1";
    local test_name;
    test_name=$(basename "$test_script" .sh);

    echo "";
echo "┌───────────────────────────────────────────────────────────┐";
echo "│ Running: ${test_name}";
echo "└───────────────────────────────────────────────────────────┘";

    if [[ ! -x "$test_script" ]]; then
        echo "[SKIP] ${test_script} not found or not executable.";
        return;
    fi

    local rc=0;
    bash "$test_script" || rc=$?;

    if [[ $rc -eq 0 ]]; then
        echo ">>> ${test_name}: ALL PASSED";
        ((TOTAL_PASS++));
    else
        echo ">>> ${test_name}: FAILURES (exit code ${rc})";
        ((TOTAL_FAIL++));
    fi
}

run_test "${SCRIPT_DIR}/test_01_lin_tape.sh";
run_test "${SCRIPT_DIR}/test_02_discovery.sh";
run_test "${SCRIPT_DIR}/test_03_persistence.sh";
run_test "${SCRIPT_DIR}/test_04_sp_config.sh";
# Uncomment the next line ONLY during a maintenance window:
# run_test "${SCRIPT_DIR}/test_05_failover.sh";
run_test "${SCRIPT_DIR}/test_06_end_to_end.sh";

echo "";
echo "╔═══════════════════════════════════════════════════════════╗";
echo "║  FINAL SUMMARY                                          ║";
echo "╠═══════════════════════════════════════════════════════════╣";
printf "║  Test suites passed : %-3s                               ║\n" "$TOTAL_PASS";
printf "║  Test suites failed : %-3s                               ║\n" "$TOTAL_FAIL";
echo "╚═══════════════════════════════════════════════════════════╝";

[[ $TOTAL_FAIL -eq 0 ]] && echo "✅ ALL TEST SUITES PASSED." || echo "❌ SOME FAILURES.";
exit $TOTAL_FAIL;
TESTSCRIPT
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    clear;
    echo "";
    echo "╔═══════════════════════════════════════════════════════════════════╗";
    echo "║                                                                 ║";
    echo "║   IBM Storage Protect — Spectra Logic Library Setup Wizard      ║";
    echo "║   Dual-Pathed IBM LTO Drives on RHEL                           ║";
    echo "║                                                                 ║";
    echo "║   MODE: PRINT-ONLY (no commands are executed by this script)    ║";
    echo "║                                                                 ║";
    echo "║   This wizard will:                                             ║";
    echo "║     • Ask for your environment details                          ║";
    echo "║     • Print all commands for you to copy/paste and run          ║";
    echo "║     • Generate test scripts to verify each phase                ║";
    echo "║                                                                 ║";
    echo "║   Phases:                                                       ║";
    echo "║     0 — Gather information                                      ║";
    echo "║     1 — lin_tape driver installation commands                   ║";
    echo "║     2 — Device discovery commands                               ║";
    echo "║     3 — Persistent device binding (udev rules)                  ║";
    echo "║     4 — SP library / drive / path definition                    ║";
    echo "║     5 — Dual-path failover test scripts                         ║";
    echo "║     6 — End-to-end integration test                             ║";
    echo "║     7 — Master test runner                                      ║";
    echo "║                                                                 ║";
    echo "╚═══════════════════════════════════════════════════════════════════╝";
    echo "";

    mkdir -p "$OUTPUT_DIR";

    pause;

    phase0_gather;
    phase1_lin_tape;
    phase2_discovery;
    phase3_persistence;
    phase4_sp_config;
    phase5_failover;
    phase6_e2e;
    phase7_master;

    banner "WIZARD COMPLETE";

    echo "";
    info "All generated files are in:";
    info "  ${OUTPUT_DIR}/";
    echo "";
    echo "  Files generated:";
    echo "  ────────────────────────────────────────────────────";
    ls -1 "${OUTPUT_DIR}/" | while read -r f; do
        echo "    ${f}";
    done;
    echo "  ────────────────────────────────────────────────────";
    echo "";
    info "To run all verification tests:";
    echo "";
    print_commands <<EOF
sudo bash ${OUTPUT_DIR}/run_all_tests.sh
EOF
    info "Or run individual tests:";
    echo "";
    print_commands <<EOF
sudo bash ${OUTPUT_DIR}/test_01_lin_tape.sh
sudo bash ${OUTPUT_DIR}/test_02_discovery.sh
sudo bash ${OUTPUT_DIR}/test_03_persistence.sh
sudo bash ${OUTPUT_DIR}/test_04_sp_config.sh
sudo bash ${OUTPUT_DIR}/test_05_failover.sh      # maintenance window only!
sudo bash ${OUTPUT_DIR}/test_06_end_to_end.sh
EOF

    success "Done. Copy/paste the commands from each phase into your terminal. 🎉";
}

main "$@";
