#!/bin/bash
SCRIPT_PATH="/usr/local/sbin/fix-boot-order.sh"
SERVICE_PATH="/etc/systemd/system/fix-boot-order.service"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/boot-order-fix.log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo "[ERROR] $1" >> "${LOG_FILE}"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $1" >> "${LOG_FILE}"
}

log "Starting PXE boot order enforcement setup v4.1..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    error "This script must be run as root"
    exit 1
fi

# Check if system is EFI
if [ ! -d /sys/firmware/efi ]; then
    warn "This system is not using EFI/UEFI boot. Skipping boot order setup."
    exit 0
fi

# Install efibootmgr if not present
if ! command -v efibootmgr &> /dev/null; then
    log "Installing efibootmgr..."
    if command -v dnf &> /dev/null; then
        dnf install -y efibootmgr
    elif command -v yum &> /dev/null; then
        yum install -y efibootmgr
    else
        error "Cannot install efibootmgr - no package manager found"
        exit 1
    fi
fi

# Test efibootmgr - but don't fail if it doesn't work during post-install
log "Testing efibootmgr..."
if efibootmgr &>/dev/null; then
    log "efibootmgr is working"
    EFI_ACCESSIBLE=true
else
    warn "efibootmgr not accessible during installation (this is normal)"
    warn "EFI variables will be accessible after first boot"
    EFI_ACCESSIBLE=false
fi

log "Creating boot order fix script at ${SCRIPT_PATH}..."

# Create the main script
cat > "${SCRIPT_PATH}" << 'EOFSCRIPT'
#!/bin/bash
##############################################################################
# Boot Order Fix Script v4.1
# Ensures PXE/Network boot entries are first, OS boot entry is second
##############################################################################

LOGFILE="/var/log/boot-order-fix.log"
MAX_RETRIES=3
RETRY_DELAY=2

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
    logger -t boot-order-fix "$1"
}

# Wait for efivarfs to be ready
wait_for_efi() {
    local retries=0
    while [ $retries -lt 10 ]; do
        if [ -d /sys/firmware/efi/efivars ] && efibootmgr &>/dev/null; then
            return 0
        fi
        retries=$((retries + 1))
        sleep 1
    done
    return 1
}

log_message "=== Starting boot order fix ==="

# Wait for EFI variables to be available
if ! wait_for_efi; then
    log_message "ERROR: EFI variables not accessible after 10 seconds"
    exit 1
fi

# Get all EFI data
EFI_DATA=$(efibootmgr 2>/dev/null)
if [ -z "$EFI_DATA" ]; then
    log_message "ERROR: Could not retrieve EFI boot data"
    exit 1
fi

# Save full output for debugging
log_message "Full efibootmgr output:"
echo "$EFI_DATA" >> "$LOGFILE"

# Get BootCurrent (the OS we're currently running)
BOOT_CURRENT=$(echo "$EFI_DATA" | grep "^BootCurrent:" | awk '{print $2}' | tr -d '\r\n')
log_message "BootCurrent (current OS): $BOOT_CURRENT"

# Get current boot order
CURRENT_ORDER=$(echo "$EFI_DATA" | grep "^BootOrder:" | cut -d: -f2 | tr -d ' \r\n')
log_message "Current BootOrder: $CURRENT_ORDER"

if [ -z "$CURRENT_ORDER" ]; then
    log_message "ERROR: Could not determine current boot order"
    exit 1
fi

# Find ALL PXE/Network boot entries - Match exactly 4 hex digits to avoid matching BootCurrent
PXE_ENTRIES=$(echo "$EFI_DATA" | grep "^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]" | grep -i 'pxe' | grep -vi 'http' | cut -c5-8)

log_message "Found PXE entries: $PXE_ENTRIES"

if [ -z "$PXE_ENTRIES" ]; then
    log_message "ERROR: No PXE boot entries found"
    log_message "Available boot entries:"
    echo "$EFI_DATA" | grep "^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]" >> "$LOGFILE"
    exit 1
fi

# Get first entry in current boot order
FIRST_IN_ORDER=$(echo "$CURRENT_ORDER" | cut -d, -f1)
SECOND_IN_ORDER=$(echo "$CURRENT_ORDER" | cut -d, -f2)

# Check if any PXE entry is already first
PXE_IS_FIRST=false
for pxe in $PXE_ENTRIES; do
    if [ "$FIRST_IN_ORDER" == "$pxe" ]; then
        PXE_IS_FIRST=true
        break
    fi
done

# Check if boot order is already correct
if [ "$PXE_IS_FIRST" = true ]; then
    if [ -n "$BOOT_CURRENT" ] && [ "$SECOND_IN_ORDER" == "$BOOT_CURRENT" ]; then
        log_message "SUCCESS: Boot order already optimal (PXE first, OS second)"
        exit 0
    fi
    
    # Check if second is another PXE entry
    for pxe in $PXE_ENTRIES; do
        if [ "$SECOND_IN_ORDER" == "$pxe" ]; then
            THIRD_IN_ORDER=$(echo "$CURRENT_ORDER" | cut -d, -f3)
            if [ -n "$BOOT_CURRENT" ] && [ "$THIRD_IN_ORDER" == "$BOOT_CURRENT" ]; then
                log_message "SUCCESS: Boot order already optimal"
                exit 0
            fi
            break
        fi
    done
fi

log_message "Boot order needs adjustment"

# Build new boot order - Start fresh
NEW_ORDER=""

# Sort PXE entries: IPv4 first, then IPv6
PXE_IPV4=""
PXE_IPV6=""
PXE_OTHER=""

for pxe in $PXE_ENTRIES; do
    ENTRY_INFO=$(echo "$EFI_DATA" | grep "^Boot${pxe}")
    if echo "$ENTRY_INFO" | grep -qi "ipv4\|ip4"; then
        if [ -z "$PXE_IPV4" ]; then
            PXE_IPV4="$pxe"
        else
            PXE_IPV4="$PXE_IPV4 $pxe"
        fi
    elif echo "$ENTRY_INFO" | grep -qi "ipv6\|ip6"; then
        if [ -z "$PXE_IPV6" ]; then
            PXE_IPV6="$pxe"
        else
            PXE_IPV6="$PXE_IPV6 $pxe"
        fi
    else
        if [ -z "$PXE_OTHER" ]; then
            PXE_OTHER="$pxe"
        else
            PXE_OTHER="$PXE_OTHER $pxe"
        fi
    fi
done

# Add IPv4 PXE entries first
for pxe in $PXE_IPV4; do
    if [ -z "$NEW_ORDER" ]; then
        NEW_ORDER="$pxe"
    else
        NEW_ORDER="$NEW_ORDER,$pxe"
    fi
done

# Then IPv6 PXE entries
for pxe in $PXE_IPV6; do
    if [ -z "$NEW_ORDER" ]; then
        NEW_ORDER="$pxe"
    else
        NEW_ORDER="$NEW_ORDER,$pxe"
    fi
done

# Then other PXE entries
for pxe in $PXE_OTHER; do
    if [ -z "$NEW_ORDER" ]; then
        NEW_ORDER="$pxe"
    else
        NEW_ORDER="$NEW_ORDER,$pxe"
    fi
done

log_message "PXE entries in new order: $NEW_ORDER"

# Add current OS entry next (if we know it and it's not a PXE entry)
if [ -n "$BOOT_CURRENT" ]; then
    IS_PXE=false
    for pxe in $PXE_ENTRIES; do
        if [ "$BOOT_CURRENT" == "$pxe" ]; then
            IS_PXE=true
            break
        fi
    done
    
    if [ "$IS_PXE" = false ]; then
        NEW_ORDER="$NEW_ORDER,$BOOT_CURRENT"
        log_message "Added current OS ($BOOT_CURRENT) after PXE entries"
    fi
fi

# Add all other entries (excluding PXE entries, current OS, and Hard Drive entries)
# Match exactly 4 hex digits to avoid matching BootCurrent
ALL_ENTRIES=$(echo "$EFI_DATA" | grep "^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]" | cut -c5-8)
for entry in $ALL_ENTRIES; do
    # Skip if already in NEW_ORDER
    if echo ",$NEW_ORDER," | grep -q ",$entry,"; then
        continue
    fi
    
    # Skip "Hard Drive" entries
    ENTRY_INFO=$(echo "$EFI_DATA" | grep "^Boot${entry}")
    if echo "$ENTRY_INFO" | grep -qi "hard drive"; then
        log_message "Skipping 'Hard Drive' entry: $entry"
        continue
    fi
    
    NEW_ORDER="$NEW_ORDER,$entry"
done

log_message "Final new boot order: $NEW_ORDER"

# Apply the new boot order with retry logic
retries=0
success=false

while [ $retries -lt $MAX_RETRIES ]; do
    log_message "Attempt $((retries + 1))/$MAX_RETRIES: Setting boot order to: $NEW_ORDER"
    
    if efibootmgr -o "$NEW_ORDER" >> "$LOGFILE" 2>&1; then
        success=true
        log_message "Boot order command executed successfully"
        break
    else
        log_message "efibootmgr command failed, check output above"
    fi
    
    retries=$((retries + 1))
    if [ $retries -lt $MAX_RETRIES ]; then
        log_message "Failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    fi
done

if [ "$success" = false ]; then
    log_message "ERROR: Failed to set boot order after $MAX_RETRIES attempts"
    exit 1
fi

# Verify the change
sleep 2
VERIFY_DATA=$(efibootmgr 2>/dev/null)
VERIFY_ORDER=$(echo "$VERIFY_DATA" | grep "^BootOrder:" | cut -d: -f2 | tr -d ' \r\n')
VERIFY_FIRST=$(echo "$VERIFY_ORDER" | cut -d, -f1)

log_message "Verification - New boot order: $VERIFY_ORDER"

# Check if any PXE entry is now first
PXE_VERIFIED=false
for pxe in $PXE_ENTRIES; do
    if [ "$VERIFY_FIRST" == "$pxe" ]; then
        PXE_VERIFIED=true
        log_message "VERIFIED: PXE entry $pxe is now first"
        break
    fi
done

if [ "$PXE_VERIFIED" = true ]; then
    log_message "SUCCESS: Boot order has been corrected"
    exit 0
else
    log_message "WARNING: Could not verify PXE is first (got: $VERIFY_FIRST)"
    exit 1
fi
EOFSCRIPT

chmod +x "${SCRIPT_PATH}"
log "Main script created and made executable"

# Create the systemd service
log "Creating systemd service..."

cat > "${SERVICE_PATH}" << 'EOFSERVICE'
[Unit]
Description=Enforce PXE Boot Order on Startup
Documentation=https://documentation.tenantos.com
After=local-fs.target systemd-remount-fs.service
Before=network-pre.target
DefaultDependencies=no
ConditionPathExists=/sys/firmware/efi

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fix-boot-order.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutStartSec=60

[Install]
WantedBy=sysinit.target
EOFSERVICE

log "Systemd service created"

# Reload systemd
systemctl daemon-reload

# Enable the service
log "Enabling service..."
systemctl enable fix-boot-order.service

# Create verification script
VERIFY_SCRIPT="/usr/local/sbin/verify-boot-order.sh"
log "Creating verification script..."

cat > "${VERIFY_SCRIPT}" << 'EOFVERIFY'
#!/bin/bash
echo "=== Boot Order Verification ==="
echo ""

if [ ! -d /sys/firmware/efi ]; then
    echo "This is not an EFI system"
    exit 0
fi

EFI_DATA=$(efibootmgr 2>/dev/null)
if [ -z "$EFI_DATA" ]; then
    echo "ERROR: Could not read EFI boot data"
    exit 1
fi

echo "Service Status:"
systemctl is-enabled fix-boot-order.service 2>/dev/null && echo "  Enabled: YES" || echo "  Enabled: NO"
systemctl is-active fix-boot-order.service 2>/dev/null && echo "  Active: YES" || echo "  Active: NO (normal for oneshot)"
echo ""

BOOT_CURRENT=$(echo "$EFI_DATA" | grep "^BootCurrent:" | awk '{print $2}')
echo "Currently Booted OS Entry: $BOOT_CURRENT"

PXE_ENTRIES=$(echo "$EFI_DATA" | grep "^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]" | grep -iE 'pxe' | grep -viE 'http' | cut -c5-8 | tr '\n' ' ')
echo "PXE Entries Found: $PXE_ENTRIES"

BOOT_ORDER=$(echo "$EFI_DATA" | grep "^BootOrder:" | cut -d: -f2 | tr -d ' ')
FIRST_ENTRY=$(echo "$BOOT_ORDER" | cut -d, -f1)
SECOND_ENTRY=$(echo "$BOOT_ORDER" | cut -d, -f2)

echo "First Boot Entry: $FIRST_ENTRY"
echo "Second Boot Entry: $SECOND_ENTRY"
echo ""

PXE_IS_FIRST=false
for pxe in $PXE_ENTRIES; do
    if [ "$FIRST_ENTRY" == "$pxe" ]; then
        PXE_IS_FIRST=true
        break
    fi
done

if [ "$PXE_IS_FIRST" = true ]; then
    echo "✓ SUCCESS: PXE entry is first in boot order"
    if [ -n "$BOOT_CURRENT" ] && [ "$SECOND_ENTRY" == "$BOOT_CURRENT" ]; then
        echo "✓ SUCCESS: Current OS is second in boot order"
    else
        echo "⚠ INFO: Second entry ($SECOND_ENTRY) is not current OS ($BOOT_CURRENT)"
    fi
else
    echo "✗ WARNING: PXE is NOT first in boot order"
fi
echo ""

echo "Complete Boot Order:"
echo "$EFI_DATA" | grep "^BootOrder:"
echo ""

echo "All Boot Entries:"
echo "$EFI_DATA" | grep "^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]"
echo ""

if [ -f /var/log/boot-order-fix.log ]; then
    echo "Recent Log Entries:"
    tail -20 /var/log/boot-order-fix.log
fi

echo ""
echo "=== Verification Complete ==="
EOFVERIFY

chmod +x "${VERIFY_SCRIPT}"
log "Verification script created"

# Create log file
touch "${LOG_FILE}"
chmod 644 "${LOG_FILE}"

log ""
log "================================================================"
log "  Installation Complete - PXE Boot Order Fix v4.1"
log "================================================================"
log ""

# Try to run initial fix if EFI is accessible
if [ "$EFI_ACCESSIBLE" = true ]; then
    log "Running initial boot order fix..."
    if "${SCRIPT_PATH}"; then
        log "✓ Boot order fixed successfully"
    else
        warn "Initial fix reported issues (will work after reboot)"
    fi
else
    log "EFI variables not accessible during installation"
    log "Boot order will be fixed automatically on first boot"
fi

log ""
log "Files created:"
log "  - Main script: ${SCRIPT_PATH}"
log "  - Service: ${SERVICE_PATH} (enabled)"
log "  - Verification: ${VERIFY_SCRIPT}"
log "  - Logs: ${LOG_FILE}"
log ""
log "Testing commands:"
log "  - Verify: ${VERIFY_SCRIPT}"
log "  - Manual run: systemctl start fix-boot-order.service"
log "  - Check logs: tail -f ${LOG_FILE}"
log ""
log "Next steps:"
log "  1. Reboot to test automatic boot-time execution"
log "  2. After reboot, verify with: ${VERIFY_SCRIPT}"
log "  3. Expected order: PXE IPv4, PXE IPv6, OS, others"
log "================================================================"
log ""

exit 0
