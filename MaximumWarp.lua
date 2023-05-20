----
-- Constants and data

local THROTTLE_THRESHOLD = 0.3
local LOG_TRACE = "TRACE"
local LOG_DEBUG = "DEBUG"
local LOG_INFO = "INFO"
local LOG_ERROR = "ERROR"
local LOG_LEVEL_TO_NUMBER = {
  [LOG_TRACE] = 5,
  [LOG_DEBUG] = 10,
  [LOG_INFO] = 100,
  [LOG_ERROR] = 1000,
}
local LOG_LEVEL_TO_COLOR = {
  [LOG_TRACE] = "89bcb5",
  [LOG_DEBUG] = "b294bb",
  [LOG_INFO] = "b5bd68",
  [LOG_ERROR] = "cc6666",
}

local SLOT_HANDS = "hands"
local SLOT_FEET = "feet"
local SLOT_TRINKET = "trinket"

local TRINKET_WHIP_ID = 32863
local TRINKET_CROP_ID = 25653
local TRINKET_CARROT_ID = 11122

local RIDING_TRINKET_IDS = { TRINKET_WHIP_ID, TRINKET_CROP_ID, TRINKET_CARROT_ID }

local TRINKET_TO_ICON = {
  [TRINKET_WHIP_ID] = "Interface\\Icons\\Inv_misc_crop_01",
  [TRINKET_CROP_ID] = "Interface\\Icons\\Inv_misc_crop_02",
  [TRINKET_CARROT_ID] = "Interface\\Icons\\Inv_misc_food_54",
}

local maximumWarpDBDefaults = {
  global = {
    enable = false,
    logLevel = LOG_ERROR,

    bgEnable = false,

    trinketSlot = 13,

    buttonEnable = true,

    ----
    -- Internals
    version = "1.0",
    [SLOT_HANDS .. "Normal"] = nil,
    [SLOT_FEET .. "Normal"] = nil,
    [SLOT_TRINKET .. "Normal"] = nil,
  }
}

local maximumWarpOptions = {
  type = "group",
  set = function (info, val) MaximumWarp:SetOption(info[#info], val) end,
  get = function (info) return MaximumWarp:GetOption(info[#info]) end,
  args = {
    enable = {
      name = "Enable",
      desc = "Enables / disables the addon",
      type = "toggle",
    },
    logLevel = {
      name = "Log level",
      desc = "Set the log level for the addon",
      type = "select",
      values = {
        [LOG_TRACE] = "The addon outputs information very verbosely and generously",
        [LOG_DEBUG] = "The addon outputs information useful for troubleshooting",
        [LOG_INFO] = "The addon outputs general information about its function",
        [LOG_ERROR] = "The addon outputs information only when encountering " ..
                      "issues that prevent its functioning"
      }
    },

    bgEnable = {
      name = "Enable in battlegrounds",
      desc = "Enables / disables the addon in battlegrounds",
      type = "toggle",
    },

    trinketSlot = {
      name = "Trinket slot",
      desc = "Which trinket slot to equip the carrot or crop in",
      type = "select",
      values = {
        [13] = "Top",
        [14] = "Bottom",
      },
    },

    buttonEnable = {
      name = "Enable button",
      desc = "Enable / disable UI button",
      type = "toggle",
    },
  }
}


----
-- State

local lastEquipTime = GetTime()
local lastEquippedItemId = {}

local feetMounted = nil
local handsMounted = nil
local trinketMounted = nil


----
-- Addon initialization

local Ace = LibStub("AceAddon-3.0")
MaximumWarp = Ace:NewAddon("MaximumWarp", "AceConsole-3.0", "AceEvent-3.0")
local AceConfig = LibStub("AceConfig-3.0")

MaximumWarpButton = CreateFrame("Button", "MaximumWarpButton", UIParent, "ActionButtonTemplate")
-- Trying to access `.icon` doesn't seem to work with ActionButtonTemplate in
-- 3.3.5, so let's get it from the globals instead.
local icon = _G[MaximumWarpButton:GetName() .. "Icon"]
icon:SetTexture("Interface\\Icons\\Inv_misc_crop_02")

local function log(level, message)
  local messageLogLevelNumber = LOG_LEVEL_TO_NUMBER[level]
  local currentLogLevel = MaximumWarp:GetOption("logLevel")
  local currentLogLevelNumber = LOG_LEVEL_TO_NUMBER[currentLogLevel]
  local messageColor = LOG_LEVEL_TO_COLOR[level]
  local color = "|cff" .. messageColor

  if (messageLogLevelNumber >= currentLogLevelNumber) then
    MaximumWarp:Print("[" .. color .. level .. "|r] " .. message)
  end
end

function MaximumWarp:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("MaximumWarpDB", maximumWarpDBDefaults)
  AceConfig:RegisterOptionsTable("MaximumWarp", maximumWarpOptions, {"maximumwarp", "mw"})
end

function MaximumWarp:OnEnable()
  MaximumWarp:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  MaximumWarp:RegisterEvent("PLAYER_REGEN_ENABLED", MaximumWarp.HandlePotentialEquipEvent)
  MaximumWarp:RegisterEvent("UNIT_AURA")

  icon:SetDesaturated(not MaximumWarp:GetOption("enable"))

  if MaximumWarp:GetOption("buttonEnable") then
    MaximumWarpButton:Show(MaximumWarpButton)
  else
    MaximumWarpButton:Hide(MaximumWarpButton)
  end
end


----
-- Event handlers

function MaximumWarp:UNIT_AURA(_, unitId)
  if (unitId ~= "player") then
    log(LOG_TRACE, "Unit aura changed but unitId ~= player.")
    return
  end

  MaximumWarp:HandlePotentialEquipEvent()
end

local function shouldBail(bailInNonPVPInstance)
  if (not MaximumWarp:GetOption("enable")) then
    log(LOG_DEBUG, "Bail - addon not enabled.")
    return true
  end

  if (InCombatLockdown() or UnitIsDeadOrGhost("player")) then
    log(LOG_DEBUG, "Bail - player in combat or dead.")
    return true
  end

  local isInInstance, instanceType = IsInInstance()

  if (isInInstance) then
    if (instanceType == "pvp") then
      if (not MaximumWarp:GetOption("bgEnable")) then
        log(LOG_DEBUG, "Bail, player in battleground and `not bgEnable`.")
        return true
      end
    else
      log(LOG_DEBUG, "Player in non-bg instance -> bail: " .. tostring(bailInNonPVPInstance))
      return bailInNonPVPInstance
    end
  end

  return false
end

function MaximumWarp:ZONE_CHANGED_NEW_AREA()
  log(LOG_TRACE, "Entered ZONE_CHANGED_NEW_AREA.")

  if shouldBail(false) then
    return
  end

  MaximumWarp:EquipNormalGear()
end

function MaximumWarp:HandlePotentialEquipEvent()
  log(LOG_TRACE, "Entered HandlePotentialEquipEvent.")

  if (shouldBail(true)) then
    return
  end

  local isMounted = IsMounted() and not UnitOnTaxi("player")
  if (isMounted) then
    log(LOG_DEBUG, "Player is mounted and riding gear should be equipped.")
    MaximumWarp:SearchInventory()
    MaximumWarp:SaveNormalGear()
    MaximumWarp:EquipMountedGear()
  else
    log(LOG_DEBUG, "Normal gear should be equipped.")
    MaximumWarp:EquipNormalGear()
  end
end


----
-- Helper functions

---Returns an item link by itemID, or nil if the itemID is nil.
---@param itemID number | nil
---@return string | nil
local function getItemLink(itemID)
  if (itemID == nil) then
    return "nil itemID"
  end

  local _, link = GetItemInfo(itemID)
  return link
end


----
-- Addon logic

function MaximumWarp:GetNormal(slot)
  if self.db ~= nil and self.db.global ~= nil then
    return self.db.global[slot .. "Normal"]
  end
end

function MaximumWarp:SetNormal(slot, item)
  if self.db ~= nil and self.db.global ~= nil then
    self.db.global[slot .. "Normal"] = item
    log(LOG_DEBUG, "Set normal " .. slot .. " to " .. getItemLink(item))
  end
end

function MaximumWarp:GetOption(option)
  if self.db ~= nil and self.db.global ~= nil then
    local value = self.db.global[option]
    return value
  else
    log(LOG_ERROR, "Can't read option [" .. option .. "] - using default.")
    return maximumWarpDBDefaults.global[option]
  end
end

function MaximumWarp:SetOption(option, value)
  log(LOG_TRACE, "Trying to set [" .. option .. "] to [" .. tostring(value) .. "]")
  if self.db ~= nil and self.db.global ~= nil then
    self.db.global[option] = value
    MaximumWarp:Print("[" .. option .. "] set to [" .. tostring(value) .. "]")
  else
    log(LOG_ERROR, "Options not ready - can not set option.")
  end
end

function MaximumWarp:SaveNormalGear()
  if (not MaximumWarp:GetOption("enable")) then
    return
  end

  local trinketSlot = MaximumWarp:GetOption("trinketSlot")
  local trinketEquipped = GetInventoryItemID("player", trinketSlot)

  if (trinketEquipped ~= trinketMounted) then
    MaximumWarp:SetNormal(SLOT_TRINKET, trinketEquipped)
  end

  if (trinketMounted == TRINKET_CARROT_ID) then
    local feetEquipped = GetInventoryItemID("player", 8)
    local handsEquipped = GetInventoryItemID("player", 10)

    if (feetEquipped ~= feetMounted) then
      MaximumWarp:SetNormal(SLOT_FEET, feetEquipped)
    end

    if (handsEquipped ~= handsMounted) then
      MaximumWarp:SetNormal(SLOT_HANDS, handsEquipped)
    end
  end
end

local function shouldThrottleEquip(slot, id, now)
  local shouldThrottle = lastEquippedItemId[slot] and lastEquippedItemId[slot] == id
  return shouldThrottle and (now - lastEquipTime) < THROTTLE_THRESHOLD
end

local function safeEquipItem(slot, id, expectedEquippedID)
  if (id == nil) then
    log(LOG_TRACE, "Attempted to equip nil item - bailing out.")
    return
  end

  local equippedItemID = GetInventoryItemID("player", slot)

  local shouldEquip = false
  if (expectedEquippedID) then
    shouldEquip = equippedItemID == expectedEquippedID
    log(LOG_DEBUG, "Expected item is equipped: " .. tostring(shouldEquip))
  else
    shouldEquip = equippedItemID ~= id
    log(LOG_DEBUG, "No expected item - item is equipped: " .. tostring(shouldEquip))
  end

  local now = GetTime()
  local shouldThrottle = shouldThrottleEquip(slot, id, now)
  if (shouldThrottle) then
    log(LOG_DEBUG, "Throttling equip item call.")
  end

  if (shouldEquip and not shouldThrottle) then
    log(LOG_INFO, "Equipping item " .. getItemLink(id))
    EquipItemByName(id, slot)
    lastEquipTime = now
    lastEquippedItemId[slot] = id
  end
end

function MaximumWarp:EquipNormalGear()
  local trinketSlot = MaximumWarp:GetOption("trinketSlot")

  safeEquipItem(trinketSlot, MaximumWarp:GetNormal(SLOT_TRINKET), trinketMounted)

  if (trinketMounted == TRINKET_CARROT_ID) then
    safeEquipItem(8, MaximumWarp:GetNormal(SLOT_FEET), feetMounted)
    safeEquipItem(10, MaximumWarp:GetNormal(SLOT_HANDS), handsMounted)
  end
end

function MaximumWarp:EquipMountedGear()
  local trinketSlot = MaximumWarp:GetOption("trinketSlot")
  safeEquipItem(trinketSlot, trinketMounted)

  if (trinketMounted == TRINKET_CARROT_ID) then
    safeEquipItem(8, feetMounted)
    safeEquipItem(10, handsMounted)
  end
end

local function isItemInInventory(item)
  local count = GetItemCount(item, false)
  return count > 0
end

function MaximumWarp:CacheMountedHandsAndFeet()
  local isHandsCached = handsMounted and isItemInInventory(handsMounted)
  local isFeetCached = feetMounted and isItemInInventory(feetMounted)

  if (isHandsCached and isFeetCached) then
    return
  end

  for bag = 0, NUM_BAG_SLOTS do
    for slot = 0, GetContainerNumSlots(bag) do
      local link = GetContainerItemLink(bag, slot)

      if (link) then
        local itemID, enchantID = link:match("item:(%d+):(%d+)")

        if (enchantID == "930") then
          log(LOG_TRACE, "Found hands with riding: " .. link)
          handsMounted = tonumber(itemID)
        elseif (enchantID == "464") then
          log(LOG_TRACE, "Found feet with spurs: " .. link)
          feetMounted = tonumber(itemID)
        end
      end
    end
  end
end

function MaximumWarp:SearchInventory()
  for _, trinket in ipairs(RIDING_TRINKET_IDS) do
    local link = getItemLink(trinket)
    log(LOG_TRACE, "Testing for trinket: " .. link)
    if isItemInInventory(trinket) then
      log(LOG_DEBUG, "Found trinket: " .. link)
      trinketMounted = trinket

      if (MaximumWarp:GetNormal(SLOT_TRINKET) == nil and IsEquippedItem(trinket) == 1) then
        local msg = "Mount trinket equipped but normal trinket unknown!\n" ..
                    "Please equip your \"normal\" gear manually so that the " ..
                    "addon can identify your normal gear."
        log(LOG_ERROR, msg)
      end
      break
    end
  end

  if (trinketMounted == nil)  then
    return
  end

  log(LOG_TRACE, "trinketMounted = " .. trinketMounted)
  local iconTexture = TRINKET_TO_ICON[trinketMounted]
  log(LOG_DEBUG, "Setting icon to " .. iconTexture)
  icon:SetTexture(iconTexture)

  if trinketMounted == TRINKET_CARROT_ID then
    MaximumWarp:CacheMountedHandsAndFeet()

    log(LOG_INFO, "Hands item used for riding: " .. getItemLink(handsMounted))
    log(LOG_INFO, "Feet item used for riding: " .. getItemLink(feetMounted))
  end
end

function MaximumWarp:HandleClick()
  local enabled = MaximumWarp:GetOption("enable")

  if (enabled) then
    MaximumWarp:EquipNormalGear()
  end

  icon:SetDesaturated(enabled)
  MaximumWarp:SetOption("enable", not enabled)
end

function MaximumWarp:HandleDragStart()
  if IsAltKeyDown() then
    MaximumWarpButton:StartMoving()
  end
end

MaximumWarpButton:SetPoint("CENTER")
MaximumWarpButton:SetMovable(true)

MaximumWarpButton:RegisterForDrag("LeftButton")
MaximumWarpButton:SetScript("OnDragStart", MaximumWarp.HandleDragStart)
MaximumWarpButton:SetScript("OnDragStop", MaximumWarpButton.StopMovingOrSizing)
MaximumWarpButton:SetScript("OnClick", MaximumWarp.HandleClick)
