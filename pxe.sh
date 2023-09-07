#!/bin/bash

# Get the current boot order
boot_order="$(efibootmgr -v | grep BootOrder | cut -d' ' -f2-)"

# Get first boot option hex number
first_boot_nr_hex="$(echo "${boot_order}" | cut -c1-4)"

# Get first boot option
first_boot_option="$(efibootmgr -v | grep "Boot${first_boot_nr_hex}")"
os_boot="$(efibootmgr -v | grep "Boot${first_boot_nr_hex}" | cut -c5-8)"

# Check if the first boot option is PXE boot
if echo "$first_boot_option" | grep -q "PXE IPv4"; then
    echo "PXE boot is already the first option in the boot order"
else
    # Get PXE boot option
    pxe_boot="$(efibootmgr -v | grep -E "^Boot[0-9]{4}" | grep "PXE IPv4" | cut -c5-8)"
    
    # Set the boot order to PXE boot followed by the other options
    new_boot_order="$(echo "$pxe_boot"),$(echo "$os_boot")"
    efibootmgr -o "$new_boot_order"
    echo "PXE boot is now the first option in the boot order"
fi