#!/bin/sh
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh
DEFINE_string 'device' '' "device name" 'd'
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'dev_i2c_path' '' "device i2c path" 'p'

FW_LINK_BASE="emright_firmware.bin"
EMRIGHTUPDATE="/usr/sbin/EMRight_FWupdate"
GET_BOARD_SPECIFIC_HWID="/opt/google/touch/scripts/get_board_specific_emright_hwid.sh"
# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

minijail_tool() {
  local policy="/opt/google/touch/policies/emrightupdate.update.policy"
  minijail0 -u goodixfwupdate -g goodixfwupdate \
            -v -P /mnt/empty -b / -b /proc -t -b /dev,,1 -b /sys \
            --uts -e -l -p -N -G -n -S "${policy}" "${EMRIGHTUPDATE}" "$@"
}

update_firmware() {
  local i=""
  local ret=""
  local fw_path="$2"
  local cmd_log=""
  local dev_path="$1"

  for i in $(seq 3); do
    cmd_log="$(minijail_tool "${dev_path}" "3" "${fw_path}")"
    ret=$?
    if [ ${ret} -eq "0" ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed... retrying."
  done
  die "Error updating emr firmware. ${ret}"
}

get_active_firmware_version() {
  local emr_log=""
  local dev_path="$1"
  emr_log="$(minijail_tool "${dev_path}" "1")"

  echo "${emr_log}"
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local active_product_id=""
  local active_fw_version=""
  local update_type=""
  local product_id=""
  local fw_link_path=""
  local fw_path=""
  local fw_name=""
  local hardware_id=""
  local update_needed="${FLAGS_FALSE}"

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  if [ -x "${GET_BOARD_SPECIFIC_HWID}" ]; then
    hardware_id="$("${GET_BOARD_SPECIFIC_HWID}")"
  fi

  # Find the device path if it exists "/dev/hidrawX".
  touch_device_path="$(find_i2c_hid_device "${touch_device_name##*-}")"
  log_msg "touch_dev_path:${touch_device_path}"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi

  chown goodixfwupdate "${touch_device_path}"
  # Find the active fw version and the product ID currently in use.
  active_product_id="${touch_device_name##*_}"
  active_fw_version="$(get_active_firmware_version "${touch_device_path}")"

  fw_link_path="$(find_fw_link_path "${FW_LINK_BASE}" "${hardware_id}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink -f "${fw_link_path}")"

  if [ -z "${fw_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device} found."
  fi

  fw_name="$(basename "${fw_path}" ".bin")"
  product_id=${fw_name##*_}
  fw_version=${fw_name%_*}
  fw_version=${fw_version##*_}

  # Check to make sure we found the device we're expecting. If the product
  # IDs don't match, abort immediately to avoid flashing the wrong device.

  if [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Compare the two versions, and see if an update is needed.
  log_msg "Product ID: ${active_product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  #If active_fw_version is "1001" always update to cover programming mode
  #Programming mode version is "1001"
  if [ "${active_fw_version}" = "1001" ]; then
    update_needed="${FLAGS_TRUE}"
  else
    update_type="$(compare_multipart_version "${active_fw_version}" \
                "${fw_version}")"
    log_update_type "${update_type}"
    update_needed="$(is_update_needed "${update_type}")"
  fi

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name}"
    run_cmd_and_block_powerd update_firmware "${touch_device_path}" "${fw_path}"

    rebind_driver "${FLAGS_dev_i2c_path}"

    # Check if update was successful
    chown goodixfwupdate "${touch_device_path}"
    active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
    update_type="$(compare_multipart_version "${active_fw_version}" \
                "${fw_version}")"
    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
  fi

  exit 0
}

main "$@"