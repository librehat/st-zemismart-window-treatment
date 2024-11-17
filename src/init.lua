-- Zemismart Window Treatment ver 0.0.1
-- Copyright 2024 Simeon Huang (librehat)
--
-- This edge driver is based on a more generic one from iquix's ST-Edge-Driver and code
-- from https://github.com/Koenkk/zigbee-herdsman-converters
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local window_preset_defaults = require "st.zigbee.defaults.windowShadePreset_defaults"
local log = require "log"

---------- Constant Definitions ----------

local CLUSTER_TUYA = 0xEF00
local SET_DATA = 0x00
local DP_TYPE_BOOL = "\x01"
local DP_TYPE_VALUE = "\x02"
local DP_TYPE_ENUM = "\x04"

local packet_id = 0

----------Tuya Utility Functions-----------

local function send_tuya_command(device, dp, dp_type, fncmd) 
  local header_args = {
    cmd = data_types.ZCLCommandId(SET_DATA)
  }
  local zclh = zcl_messages.ZclHeader(header_args)
  zclh.frame_ctrl:set_cluster_specific()
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_TUYA),
    zb_const.HA_PROFILE_ID,
    CLUSTER_TUYA
  )
  packet_id = (packet_id + 1) % 65536
  local fncmd_len = string.len(fncmd)
  local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id) .. dp .. dp_type .. string.pack(">I2", fncmd_len) .. fncmd)
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = payload_body
  })
  local send_message = messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  })
  device:send(send_message)
end

------------Capabilities Handlers-----------

local function get_current_level(device)
  return device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
end

local function get_current_battery(device)
  return device:get_latest_state("main", capabilities.battery.ID, capabilities.battery.battery.NAME)
end

local function level_event_moving(device, level)
  local current_level = get_current_level(device)
  if current_level == nil or current_level == level then
    log.info("Ignore invalid reports")
    return false
  end

  if current_level < level then
    device:emit_event(capabilities.windowShade.windowShade.opening())
  elseif current_level > level then
    device:emit_event(capabilities.windowShade.windowShade.closing())
  end
  return true
end

local function level_event_arrived(device, level)
  if type(level) ~= "number" or (level < 0 or level > 100) then
    log.error("Invalid level", level)
    device:emit_event(capabilities.windowShade.windowShade.unknown())
    return
  end

  local window_shade_val
  if level == 0 then
    window_shade_val = "closed"
  elseif level == 100 then 
    window_shade_val = "open"
  else
    window_shade_val = "partially open"
  end
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  device:emit_event(capabilities.windowShade.windowShade(window_shade_val))
end

local function window_shade_open_handler(driver, device)
  send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x00")
end

local function window_shade_pause_handler(driver, device)
  send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x01")
end

local function window_shade_close_handler(driver, device)
  send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x02")
end

local function window_shade_level_set_shade_level_handler(driver, device, command)
  send_tuya_command(device, "\x02", DP_TYPE_VALUE, string.pack(">I4", command.args.shadeLevel))
end

local function window_shade_preset_preset_position_handler(driver, device)
  local preset_level = device.preferences.presetPosition or device:get_field(window_preset_defaults.PRESET_LEVEL_KEY) or window_preset_defaults.PRESET_LEVEL
  window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = preset_level }})
end

------------Preferences Handlers------------

local function set_limit(device, is_set, direction)
  if (direction == "up" and device.preferences.reverse ~= true) or (direction == "down" and device.preferences.reverse == true) then
    -- set upper border/limit (upper becomes lower if 'reverse' is switched on)
    send_tuya_command(device, "\10", DP_TYPE_BOOL, is_set and "\x00" or "\x02")
  else
    send_tuya_command(device, "\10", DP_TYPE_BOOL, is_set and "\x01" or "\x03")
  end
end

------------Lifecycle Handlers--------------

local function device_init(driver, device)
  log.info("current level", get_current_level(device))
  log.info("current battery", get_current_battery(device))
end

local function device_info_changed(driver, device, event, args)
  if args.old_st_store.preferences.reverse ~= device.preferences.reverse then
    send_tuya_command(device, "\x05", DP_TYPE_ENUM, device.preferences.reverse and "\x01" or "\x00")
  end
  if args.old_st_store.preferences.limitUp ~= device.preferences.limitUp then
    set_limit(device, device.preferences.limitUp, "up")
  end
  if args.old_st_store.preferences.limitDown ~= device.preferences.limitDown then
    set_limit(device, device.preferences.limitDown, "down")
  end

  local current_level = get_current_level(device)
  if current_level ~= nil then
    level_event_arrived(device, 100 - current_level)
  end
end

-----------Tuya Cluster Functions-----------

local function tuya_cluster_handler(driver, device, zb_rx)
  local rx = zb_rx.body.zcl_body.body_bytes
  local dp = string.byte(rx:sub(3,3))
  local fncmd_len = string.unpack(">I2", rx:sub(5,6))
  local fncmd = string.unpack(">I"..fncmd_len, rx:sub(7))
  log.debug(string.format("dp=%d, fncmd=%d", dp, fncmd))
  if dp == 1 then -- 0x01: Control -- open / pause / close
    -- fncmd: 0: open, 1: pause, 2: close
    if fncmd == 1 then
      device:emit_event(capabilities.windowShade.windowShade.paused())
    elseif fncmd == 0 then -- 100% in ST means fully open
      level_event_moving(device, 100)
    elseif fncmd == 2 then -- 0% in ST means fully closed
      level_event_moving(device, 0)
    end
  elseif dp == 2 then -- 0x02: Percent control -- Started moving to position (triggered from Zigbee)
    level_event_moving(device, fncmd)
  elseif dp == 3 then -- 0x03: Percent state -- Arrived at position
    level_event_arrived(device, fncmd)
  elseif dp == 5 then -- 0x05: Direction state
    log.info("direction state of the motor is "..(fncmd and "reverse" or "forward"))
  elseif dp == 12 then -- 0x0c: Motor fault
    log.error("motor fault, not implemented yet") -- TODO
  elseif dp == 13 then -- 0x0d: Battery level
    device:emit_event(capabilities.battery.battery(fncmd))
  elseif dp == 20 then -- click control (single motor steps)
    log.debug("click control received, not implemented yet") -- TODO
  else
    log.warn(string.format("unhandled dp=%d", dp))
  end
end

--------------Driver Main-------------------

local zemismart_window_treatment_driver = {
  supported_capabilities = {
    capabilities.windowShade,
    capabilities.windowShadeLevel,
    capabilities.windowShadePreset,
    capabilities.battery,
  },
  zigbee_handlers = {
    cluster = {
      [CLUSTER_TUYA] = {
        [0x01] = tuya_cluster_handler,
        [0x02] = tuya_cluster_handler,
      }
    }
  },
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = window_shade_open_handler,
      [capabilities.windowShade.commands.pause.NAME] = window_shade_pause_handler,
      [capabilities.windowShade.commands.close.NAME] = window_shade_close_handler
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_set_shade_level_handler
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_preset_position_handler
    }
  },
  lifecycle_handlers = {
    init = device_init,
    infoChanged = device_info_changed
  }
}

local zigbee_driver = ZigbeeDriver("zemismart-window-treatment", zemismart_window_treatment_driver)
zigbee_driver:run()
