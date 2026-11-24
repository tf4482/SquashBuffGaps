-- Closes gaps between shown tracked buffs (icons and bars) in the Cooldown Manager

local _, ns = ...

-- setting key per Blizzard viewer frame name
local viewers = {
  BuffIconCooldownViewer = "icons",
  BuffBarCooldownViewer = "bars",
}
-- item frames already hooked
local hooked = {}
-- reused list of item frames, sorted by slot
local items = {}

-- sort item frames by their Blizzard slot
local function BySlot(a, b)
  return a.layoutIndex < b.layoutIndex
end

-- item frames this addon made invisible
local faded = {}

-- cooldown ID per item frame that has shown a totem
local totemItems = {}

-- whether a value is hidden from addons
local function Secret(value)
  return issecretvalue ~= nil and issecretvalue(value)
end

-- totem item whose totem no longer exists; only checked out of combat, where totem data is
-- readable; in combat the game's own display stays untouched
local function Stale(item)
  local data, cooldownID = item.totemData, item.cooldownID
  if InCombatLockdown() or Secret(data) or Secret(cooldownID) then
    return false
  end
  if data then
    if not data.slot then
      return false
    end
    -- remember totem items until the frame gets another cooldown
    totemItems[item] = cooldownID
    -- empty slots still report haveTotem = true, but with no spell and no duration
    local have, _, _, duration, _, _, spellID = GetTotemInfo(data.slot)
    return not have or duration == 0 or spellID ~= data.spellID
  end
  if totemItems[item] == nil or totemItems[item] ~= cooldownID then
    totemItems[item] = nil
    return false
  end
  -- totem gone but Blizzard keeps the item active through its linked spell; keep it only
  -- while the buff the totem gives is still on
  return item.auraInstanceID == nil
end

-- fade stale totem items out and bring back the ones that are fine again
local function Fade(item)
  if Stale(item) then
    item:SetAlpha(0)
    faded[item] = true
  elseif faded[item] then
    item:SetAlpha(1)
    faded[item] = nil
  end
end

-- whether an item takes a slot when squashing
local function Visible(item)
  return item:IsShown() and not faded[item]
end

-- place items like Blizzard's grid layout: shown items packed from the start edge when
-- squashing, every item in its own slot when restoring after switching off
local function Apply(viewer, restore)
  if ns.db == nil or not viewer.itemFramePool or viewer.isHorizontal == nil then
    return
  end
  local squash = ns.db[viewers[viewer:GetName()]]

  wipe(items)
  for item in viewer.itemFramePool:EnumerateActive() do
    if item.layoutIndex then
      items[#items + 1] = item
      Fade(item)
    end
  end
  if not (squash or restore) then
    return
  end
  table.sort(items, BySlot)

  -- start corner and growth direction from Edit Mode; bars stack in the chosen direction
  local right, up = viewer.layoutFramesGoingRight, viewer.layoutFramesGoingUp
  local horizontal = viewer.isHorizontal
  if squash and viewer:GetName() == "BuffBarCooldownViewer" then
    horizontal, up = false, ns.db.barsGrow == "up"
  end
  local point = (up and "BOTTOM" or "TOP") .. (right and "LEFT" or "RIGHT")
  local padding = (horizontal and viewer.childXPadding or viewer.childYPadding) or 0
  local forward = horizontal and right or (not horizontal and up)
  local sign = forward and 1 or -1

  -- Blizzard sizes the viewer to the items shown at its last layout; keep the start edge
  -- where it is with all items shown (as in Edit Mode) so it never moves
  local full, scale = -padding, items[1] and items[1]:GetScale() or 1
  for _, item in ipairs(items) do
    full = full + (horizontal and item:GetWidth() or item:GetHeight()) + padding
  end
  full = full * scale
  local current = horizontal and viewer:GetWidth() or viewer:GetHeight()
  local anchor = viewer:GetPoint(1)
  local shift = 0
  if anchor and current > 0 and #items > 0 then
    -- anchor position along the axis, from the left or bottom edge
    local low, high = horizontal and "LEFT" or "BOTTOM", horizontal and "RIGHT" or "TOP"
    local f = anchor:find(low) and 0 or anchor:find(high) and 1 or 0.5
    shift = (forward and f * (current - full) or (1 - f) * (full - current)) / scale
  end

  -- icons pack against the edge their direction points to: skip the room of hidden ones
  local offset = 0
  if squash and viewer:GetName() == "BuffIconCooldownViewer" then
    for _, item in ipairs(items) do
      if not Visible(item) then
        offset = offset + (horizontal and item:GetWidth() or item:GetHeight()) + padding
      end
    end
  end

  -- walk the slots; hidden items take no room when squashing
  for _, item in ipairs(items) do
    if Visible(item) or not squash then
      local pos = shift + offset * sign
      item:ClearAllPoints()
      if horizontal then
        item:SetPoint(point, viewer, point, pos, 0)
      else
        item:SetPoint(point, viewer, point, 0, pos)
      end
      offset = offset + (horizontal and item:GetWidth() or item:GetHeight()) + padding
    end
  end
end

-- viewers waiting for Apply, with their restore flag
local pending = {}
-- debounce timer; bursts of layout and show/hide calls collapse into one Apply per viewer
local timer

-- apply pending viewers; protected ones wait for the end of combat
local function RunPending()
  timer = nil
  local blocked = false
  for viewer, restore in pairs(pending) do
    if InCombatLockdown() and viewer:IsProtected() then
      blocked = true
    else
      pending[viewer] = nil
      Apply(viewer, restore)
    end
  end
  if blocked then
    ns.AfterCombat(RunPending)
  end
end

-- queue a viewer for Apply shortly; a restore request sticks until applied
local function Schedule(viewer, restore)
  pending[viewer] = pending[viewer] or restore or false
  if not timer then
    timer = C_Timer.NewTimer(0.05, RunPending)
  end
end

-- re-place the viewer of an item that was shown or hidden
local function OnItemToggled(item)
  local viewer = item:GetParent()
  if viewer and viewers[viewer:GetName()] then
    Schedule(viewer)
  end
end

-- hook new pooled item frames, then place all items
local function Refresh(viewer, restore)
  if viewer.itemFramePool then
    for item in viewer.itemFramePool:EnumerateActive() do
      if not hooked[item] then
        hooked[item] = true
        item:HookScript("OnShow", OnItemToggled)
        item:HookScript("OnHide", OnItemToggled)
      end
    end
  end
  Schedule(viewer, restore)
end

-- re-place both viewers after a setting changes
local function RefreshAll()
  for name in pairs(viewers) do
    local viewer = _G[name]
    if viewer then
      Refresh(viewer, true)
    end
  end
end

-- re-check both viewers after Blizzard handled a totem change
local totemPending = false
local function CheckTotems()
  totemPending = false
  for name in pairs(viewers) do
    local viewer = _G[name]
    if viewer then
      Schedule(viewer)
    end
  end
end

-- own panel below Blizzard's Edit Mode dialog of a tracked buff viewer
local panel

-- show the panel while the Edit Mode dialog belongs to a tracked buff viewer
local function UpdatePanel()
  local dialog = EditModeSystemSettingsDialog
  local system = dialog and dialog:IsShown() and dialog.attachedToSystem
  local key = system and viewers[system:GetName() or ""]
  if not key or ns.db == nil then
    panel:Hide()
    return
  end
  panel.key = key
  panel.gaps:SetChecked(ns.db[key])
  panel.grow:SetShown(key == "bars")
  panel:SetHeight(key == "bars" and 110 or 75)
  panel:SetWidth(dialog:GetWidth())
  panel.grow:GenerateMenu()
  panel:Show()
end

-- build the panel and follow the Edit Mode dialog
local function CreatePanel()
  local dialog = EditModeSystemSettingsDialog
  if panel or not dialog then
    return
  end
  panel = CreateFrame("Frame", nil, UIParent)
  panel:SetFrameStrata("DIALOG")
  panel:SetPoint("TOPLEFT", dialog, "BOTTOMLEFT", 0, 2)
  panel:Hide()
  CreateFrame("Frame", nil, panel, "DialogBorderTranslucentTemplate"):SetAllPoints()

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  title:SetPoint("TOP", 0, -14)
  title:SetText("SquashBuffGaps")

  -- close gaps of the current viewer
  panel.gaps = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  panel.gaps:SetPoint("TOPLEFT", 16, -34)
  panel.gaps.Text:SetFontObject("GameFontHighlightMedium")
  panel.gaps.Text:SetText("Close Gaps")
  panel.gaps:SetScript("OnClick", function(self)
    ns.Set(panel.key, self:GetChecked())
  end)

  -- growth direction of the bars
  panel.grow = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
  panel.grow:SetPoint("TOPRIGHT", -20, -72)
  panel.grow:SetWidth(150)
  local label = panel.grow:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
  -- same top and height as the dropdown, so both share one line
  label:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -72)
  label:SetHeight(panel.grow:GetHeight())
  label:SetJustifyH("LEFT")
  label:SetJustifyV("MIDDLE")
  label:SetText("Bars Grow")
  local function IsSelected(value)
    return ns.db.barsGrow == value
  end
  local function SetSelected(value)
    ns.Set("barsGrow", value)
  end
  panel.grow:SetupMenu(function(_, root)
    root:CreateRadio("Down", IsSelected, SetSelected, "down")
    root:CreateRadio("Up", IsSelected, SetSelected, "up")
  end)

  hooksecurefunc(dialog, "AttachToSystemFrame", UpdatePanel)
  dialog:HookScript("OnHide", UpdatePanel)
end

-- apply a setting change and mirror it in the Edit Mode panel
local function OnSettingChanged()
  RefreshAll()
  if panel and panel:IsShown() then
    UpdatePanel()
  end
end

-- one status line per viewer, with a hint when the Cooldown Manager is missing
local function Status()
  ns.Status("Icons", ns.OnOff(ns.db.icons))
  ns.Status("Bars", ns.OnOff(ns.db.bars))
  ns.Status("Bars grow", ns.Color("value", ns.db.barsGrow))
  if not BuffIconCooldownViewer then
    ns.Warn("Cooldown Manager not loaded (inactive)")
  end
end

-- switch one viewer and report the new state
local function Switch(key, enabled)
  ns.Set(key, enabled)
  Status()
end

-- run after every Blizzard layout pass of a viewer, then place once
local function HookViewers()
  for name in pairs(viewers) do
    local viewer = _G[name]
    if viewer and not hooked[viewer] then
      hooked[viewer] = true
      hooksecurefunc(viewer, "Layout", Refresh)
      Refresh(viewer)
    end
  end
end

-- event handlers by event name
local events = {}

-- viewers exist once the world is ready
function events.PLAYER_LOGIN()
  HookViewers()
  CreatePanel()
end

-- Cooldown Manager loaded later than this addon
function events.ADDON_LOADED(name)
  if name == "Blizzard_CooldownViewer" then
    HookViewers()
  end
end

-- check totems once Blizzard handled the current change
local function ScheduleCheck()
  if not totemPending and not InCombatLockdown() then
    totemPending = true
    C_Timer.After(0, CheckTotems)
  end
end

-- totem placed or removed
events.PLAYER_TOTEM_UPDATE = ScheduleCheck

-- player buffs changed: a totem buff may have ended
events.UNIT_AURA = ScheduleCheck

-- combat over: totem data is readable again
events.PLAYER_REGEN_ENABLED = ScheduleCheck

-- one frame dispatching all events above; unit events only for the player
local frame = CreateFrame("Frame")
for event in pairs(events) do
  if event:find("^UNIT_") then
    frame:RegisterUnitEvent(event, "player")
  else
    frame:RegisterEvent(event)
  end
end
frame:SetScript("OnEvent", function(_, event, ...)
  events[event](...)
end)

-- saved state; settings page once loaded
ns.Store("SquashBuffGapsDB", { icons = false, bars = false, barsGrow = "down" }, function()
  ns.Settings()
  ns.Checkbox("icons", "Tracked buff icons", "Close gaps between shown buff icons", OnSettingChanged)
  ns.Checkbox("bars", "Tracked buff bars", "Close gaps between shown buff bars", OnSettingChanged)
  ns.Dropdown("barsGrow", "Bars grow", { { "down", "Down" }, { "up", "Up" } }, "Direction new buff bars are added in", OnSettingChanged)
end)

-- chat commands
local onOff = { { name = "state", choices = { "on", "off" } } }
ns.Command({ name = "icons", help = "close gaps between buff icons", args = onOff, run = function(args) Switch("icons", args.state == "on") end })
ns.Command({ name = "bars", help = "close gaps between buff bars", args = onOff, run = function(args) Switch("bars", args.state == "on") end })
ns.Command({
  name = "grow",
  help = "set the direction buff bars grow in",
  args = { { name = "direction", choices = { "down", "up" } } },
  run = function(args)
    ns.Set("barsGrow", args.direction)
    Status()
  end,
})
ns.Command({ name = "config", help = "open the settings page", run = ns.OpenSettings })
ns.Slash({ "/sbg", "/squashbuffgaps" }, Status)
