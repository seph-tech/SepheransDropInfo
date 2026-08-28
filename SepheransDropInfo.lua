local ADDON_NAME = ...
local SDI = CreateFrame("Frame", "SepheransDropInfoFrame")

SepheransDropInfoDB = SepheransDropInfoDB or {}

local DB
local REALM_KEY
local pendingDeaths = {}
local activeLoot = nil
local recentKillMarks = {}
local MAX_LOG = 2000
local UI = {
  _editBoxes = {},
  _accentTexts = {},
  _styledInsetPanels = {},
  optionsSwatches = {},
  _fontTargets = {},
}
local applyUITheme
local applyUIScale
local updateVisibleMobRows
local refreshItemInfoPopup
local openItemInfoPopup
local ensureRootDB
local ensureRealmDB
local getPrimaryZone
local makeItemSyncKey


local function getStoredUIColor(kind, d1, d2, d3)
  local settings = SepheransDropInfoDB and SepheransDropInfoDB.settings
  local colors = settings and settings.uiColors
  local value = colors and colors[kind]
  return (value and value[1]) or d1, (value and value[2]) or d2, (value and value[3]) or d3
end

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function getMobRowThemeColors()
  local r, g, b = getStoredUIColor("mobRow", 0.01568627450980392, 0.06274509803921569, 0.6745098039215687)
  return {
    baseR = r,
    baseG = g,
    baseB = b,
    hoverR = clamp01(r + 0.07),
    hoverG = clamp01(g + 0.05),
    hoverB = clamp01(b + 0.02),
    selectedR = clamp01(r + 0.15),
    selectedG = clamp01(g + 0.10),
    selectedB = clamp01(b + 0.03),
    borderR = clamp01(r + 0.25),
    borderG = clamp01(g + 0.20),
    borderB = clamp01(b + 0.08),
  }
end

local function styleAlternateDataRow(row, kind, index)
  if not row or not row.bg then return end
  if kind == "header" then
    row.bg:SetVertexColor(0.30, 0.22, 0.08, 0.55)
  elseif kind == "spacer" then
    row.bg:SetVertexColor(0, 0, 0, 0)
  elseif index and (index % 2 == 0) then
    row.bg:SetVertexColor(1, 1, 1, 0.035)
  else
    row.bg:SetVertexColor(0, 0, 0, 0)
  end
end

local function getItemDisplayLabel(item)
  if not item then return "Unknown item" end
  return item.link or item.name or "Unknown item"
end

local function getItemIconTexture(itemData)
  if not itemData then return nil end
  local icon
  if itemData.itemID and GetItemIcon then
    icon = GetItemIcon(itemData.itemID)
  end
  if (not icon) and itemData.link and GetItemIcon then
    icon = GetItemIcon(itemData.link)
  end
  if (not icon) and itemData.name and GetItemIcon then
    icon = GetItemIcon(itemData.name)
  end
  return icon
end
local function getItemInfoSortMode()
  local settings = SepheransDropInfoDB and SepheransDropInfoDB.settings
  local mode = settings and settings.itemInfoSortMode
  if mode ~= "opens" and mode ~= "rate" then mode = "rate" end
  return mode
end

local function setItemInfoSortMode(mode)
  ensureRootDB()
  if mode ~= "opens" and mode ~= "rate" then mode = "rate" end
  SepheransDropInfoDB.settings.itemInfoSortMode = mode
  if UI and UI.itemInfoSortButton and UI.itemInfoSortButton.text then
    UI.itemInfoSortButton.text:SetText("Sort: " .. (mode == "opens" and "Opens" or "Drop rate"))
  end
end

local function refreshItemIconTooltip(self)
  if not self or not self.itemData then return end
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if self.itemData.link then
    GameTooltip:SetHyperlink(self.itemData.link)
  elseif self.itemData.itemID and GameTooltip.SetHyperlink then
    GameTooltip:SetHyperlink("item:" .. tostring(self.itemData.itemID))
  elseif self.itemData.name and GameTooltip.SetText then
    GameTooltip:SetText(self.itemData.name)
  end
  GameTooltip:Show()
end


local function buildObservedItemSourceRows(itemData)
  ensureRealmDB()
  if not itemData then return {}, nil end

  local itemID, targetKey = makeItemSyncKey(itemData.key or itemData.link or itemData.name or "", itemData)
  local itemName = getItemDisplayLabel(itemData)
  local sources = {}
  local totalSeen, totalQty, totalOpens = 0, 0, 0

  for npcID, rec in pairs(DB.observed or {}) do
    for key, observedItem in pairs(rec.items or {}) do
      local observedID, observedKey = makeItemSyncKey(key, observedItem)
      if observedKey == targetKey or (itemID and observedID == itemID) then
        local opens = tonumber(rec.opens) or 0
        local seen = tonumber(observedItem.seen) or 0
        local qty = tonumber(observedItem.totalQty) or 0
        local pct = 0
        if opens > 0 then
          pct = (seen / opens) * 100
        end
        table.insert(sources, {
          npcID = npcID,
          mobName = rec.name or ("NPC " .. tostring(npcID)),
          opens = opens,
          seen = seen,
          totalQty = qty,
          dropPct = pct,
          zone = getPrimaryZone(rec),
        })
        totalSeen = totalSeen + seen
        totalQty = totalQty + qty
        totalOpens = totalOpens + opens
        if (not itemData.link) and observedItem.link then itemData.link = observedItem.link end
        if (not itemData.name) and observedItem.name then itemData.name = observedItem.name end
      end
    end
  end

  local sortMode = getItemInfoSortMode()
  table.sort(sources, function(a, b)
    if sortMode == "opens" then
      if a.opens ~= b.opens then return a.opens > b.opens end
      if a.dropPct ~= b.dropPct then return a.dropPct > b.dropPct end
      if a.seen ~= b.seen then return a.seen > b.seen end
    else
      if a.dropPct ~= b.dropPct then return a.dropPct > b.dropPct end
      if a.seen ~= b.seen then return a.seen > b.seen end
      if a.opens ~= b.opens then return a.opens > b.opens end
    end
    return string.lower(a.mobName or "") < string.lower(b.mobName or "")
  end)

  local summary = {
    itemID = itemID,
    label = itemName,
    mobCount = #sources,
    totalSeen = totalSeen,
    totalQty = totalQty,
    totalOpens = totalOpens,
  }
  return sources, summary
end

local FONT_BASE_PATH = "Interface\\AddOns\\SepheransDropInfo\\Media\\Fonts\\"
local FONT_PATHS = {
  body = FONT_BASE_PATH .. "sdi.ttf",
  heading = FONT_BASE_PATH .. "sdi1.ttf",
  ui = FONT_BASE_PATH .. "sdi2.ttf",
  meta = FONT_BASE_PATH .. "sdi3.ttf",
}
local FONT_STYLES = {
  brand = { path = FONT_PATHS.heading, size = 18, flags = "" },
  windowTitle = { path = FONT_PATHS.heading, size = 17, flags = "" },
  sectionTitle = { path = FONT_PATHS.heading, size = 14, flags = "" },
  tab = { path = FONT_PATHS.ui, size = 12, flags = "" },
  button = { path = FONT_PATHS.ui, size = 12, flags = "" },
  body = { path = FONT_PATHS.body, size = 12, flags = "" },
  bodySmall = { path = FONT_PATHS.body, size = 11, flags = "" },
  meta = { path = FONT_PATHS.meta, size = 11, flags = "" },
  metaSmall = { path = FONT_PATHS.meta, size = 10, flags = "" },
  edit = { path = FONT_PATHS.body, size = 12, flags = "" },
}

local function applySDIFont(target, role)
  if not target then return end
  local style = FONT_STYLES[role or "body"] or FONT_STYLES.body
  if target.SetFont then
    target:SetFont(style.path, style.size, style.flags)
  elseif target.GetFontString and target:GetFontString() and target:GetFontString().SetFont then
    target:GetFontString():SetFont(style.path, style.size, style.flags)
  end
end

local function registerSDIFont(target, role)
  if not target then return end
  UI._fontTargets = UI._fontTargets or {}
  target._sdiFontRole = role or "body"
  table.insert(UI._fontTargets, target)
  applySDIFont(target, target._sdiFontRole)
end

local function applyUIFontTheme()
  if not UI or not UI._fontTargets then return end
  for _, target in ipairs(UI._fontTargets) do
    if target then
      applySDIFont(target, target._sdiFontRole)
    end
  end
end

local function styleSDIEditBox(editBox)
  if not editBox then return end
  local bgR, bgG, bgB = getStoredUIColor("bg", 0.03137254901960784, 0.04313725490196078, 0.08235294117647059)
  local accentR, accentG, accentB = getStoredUIColor("accent", 0.4313725490196079, 0.8470588235294118, 1)
  applySDIFont(editBox, "edit")
  editBox:SetTextColor(1, 1, 1)
  editBox:SetBackdrop({
    bgFile = "Interface\\buttons\\white8x8",
    edgeFile = "Interface\\buttons\\white8x8",
    tile = false,
    tileSize = 0,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  editBox:SetBackdropColor(bgR * 0.90, bgG * 0.92, bgB * 0.98, 0.96)
  editBox:SetBackdropBorderColor(accentR * 0.75, accentG * 0.85, accentB, 0.85)
end

local SDIHoverTooltip = CreateFrame("GameTooltip", "SDIHoverTooltip", UIParent, "GameTooltipTemplate")
SDIHoverTooltip:SetFrameStrata("TOOLTIP")
SDIHoverTooltip:SetClampedToScreen(true)

local Session = { opens = 0, money = 0, newMobs = 0, newItems = 0 }
local countUniqueItems
local refreshMobList
local rebuildAggregateObserved
local cleanupPending
local refreshSyncUsersUI
local refreshSaveSlotsUI
local getPlayerClassToken
local toggleMainUI
local SYNC_PREFIX = "SDISync"
local DEFAULT_SYNC_CHANNEL = "sdi"
local SYNC_CHAT_PREFIX = "<SDI>"
local SyncState = { users = {}, selected = nil, status = "Idle", lastSync = "Never", pending = {}, seq = 0, refreshAt = 0 }
local SaveState = { selected = nil, status = "Idle", autosavedThisSession = false }
local SYNC_USER_TTL = 35

local function now()
  return time()
end

local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7fd0ffSepheransDropInfo:|r " .. tostring(text))
end

local function trimLog(tbl)
  while #tbl > MAX_LOG do
    table.remove(tbl, 1)
  end
end

local function formatRealmKey()
  local realm = (GetRealmName and GetRealmName()) or "UnknownRealm"
  realm = tostring(realm):gsub("%s+", "")
  return realm
end

ensureRootDB = function()
  SepheransDropInfoDB = SepheransDropInfoDB or {}
  SepheransDropInfoDB.realms = SepheransDropInfoDB.realms or {}
  SepheransDropInfoDB.settings = SepheransDropInfoDB.settings or {
    verbose = false,
    hidden = false,
    uiX = nil,
    uiY = nil,
    uiW = 760,
    uiH = 500,
    sortMode = "name",
    uiTab = "browser",
    autoSaveOnLogin = true,
    minimapAngle = 225,
    syncEnabled = false,
    syncInterval = 20,
    syncChannel = DEFAULT_SYNC_CHANNEL,
    uiScale = 1,
    uiColors = {
      bg = { 0.03137254901960784, 0.04313725490196078, 0.08235294117647059 },
      border = { 0.4509803921568628, 0.6, 0.8509803921568627 },
      accent = { 0.4313725490196079, 0.8470588235294118, 1 },
      mobRow = { 0.01568627450980392, 0.06274509803921569, 0.6745098039215687 },
    },
  }
  if not SepheransDropInfoDB.settings.sortMode then
    SepheransDropInfoDB.settings.sortMode = "name"
  end
  if not SepheransDropInfoDB.settings.syncChannel or SepheransDropInfoDB.settings.syncChannel == "" then
    SepheransDropInfoDB.settings.syncChannel = DEFAULT_SYNC_CHANNEL
  end
  if type(SepheransDropInfoDB.settings.uiScale) ~= "number" then
    SepheransDropInfoDB.settings.uiScale = 1
  end
  SepheransDropInfoDB.settings.uiColors = SepheransDropInfoDB.settings.uiColors or {}
  SepheransDropInfoDB.settings.uiColors.bg = SepheransDropInfoDB.settings.uiColors.bg or { 0.03137254901960784, 0.04313725490196078, 0.08235294117647059 }
  SepheransDropInfoDB.settings.uiColors.border = SepheransDropInfoDB.settings.uiColors.border or { 0.4509803921568628, 0.6, 0.8509803921568627 }
  SepheransDropInfoDB.settings.uiColors.accent = SepheransDropInfoDB.settings.uiColors.accent or { 0.4313725490196079, 0.8470588235294118, 1 }
  SepheransDropInfoDB.settings.uiColors.mobRow = SepheransDropInfoDB.settings.uiColors.mobRow or { 0.01568627450980392, 0.06274509803921569, 0.6745098039215687 }
end

local function getSyncChannelName()
  local settings = SepheransDropInfoDB and SepheransDropInfoDB.settings
  local name = settings and settings.syncChannel
  name = tostring(name or DEFAULT_SYNC_CHANNEL)
  name = string.match(name, "^%s*(.-)%s*$") or DEFAULT_SYNC_CHANNEL
  if name == "" then name = DEFAULT_SYNC_CHANNEL end
  return name
end

ensureRealmDB = function()
  ensureRootDB()
  REALM_KEY = formatRealmKey()
  SepheransDropInfoDB.realms[REALM_KEY] = SepheransDropInfoDB.realms[REALM_KEY] or {
    observed = {},
    localObserved = {},
    syncSources = {},
    quarantinedSources = {},
    syncFlags = {},
    pending = {},
    log = {},
    snapshots = {},
  }
  DB = SepheransDropInfoDB.realms[REALM_KEY]
  DB.observed = DB.observed or {}
  DB.localObserved = DB.localObserved or {}
  DB.syncSources = DB.syncSources or {}
  DB.quarantinedSources = DB.quarantinedSources or {}
  DB.syncFlags = DB.syncFlags or {}
  DB.pending = DB.pending or {}
  DB.log = DB.log or {}
  DB.snapshots = DB.snapshots or {}

  if not next(DB.localObserved) and next(DB.observed) then
    DB.localObserved = DB.observed
  end

  return DB
end

local function deepCopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do
    copy[deepCopy(k, seen)] = deepCopy(v, seen)
  end
  return copy
end

local function getObservedSummary(observed)
  local mobs, opens = 0, 0
  local unique = {}
  for _, rec in pairs(observed or {}) do
    mobs = mobs + 1
    opens = opens + (tonumber(rec.opens) or 0)
    for key in pairs(rec.items or {}) do unique[key] = true end
  end
  local items = 0
  for _ in pairs(unique) do items = items + 1 end
  return mobs, opens, items
end

local function normalizeSnapshotName(name)
  name = tostring(name or "")
  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")
  name = string.gsub(name, "%s+", " ")
  if name == "" then name = date("Save %Y-%m-%d %H:%M:%S") end
  return string.sub(name, 1, 48)
end

local function setSaveStatus(text)
  SaveState.status = text or "Idle"
  if UI.saveStatusValue then UI.saveStatusValue:SetText(SaveState.status) end
end

local function collectSnapshots()
  ensureRealmDB()
  local out = {}
  for name, snapshot in pairs(DB.snapshots or {}) do
    if type(snapshot) == "table" then
      snapshot.name = snapshot.name or name
      table.insert(out, snapshot)
    end
  end
  table.sort(out, function(a, b)
    local at = tonumber(a.savedAt) or 0
    local bt = tonumber(b.savedAt) or 0
    if at ~= bt then return at > bt end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)
  return out
end

local function saveCurrentSnapshot(name, isAuto)
  ensureRealmDB()
  local label = normalizeSnapshotName(name)
  local mobs, opens, items = getObservedSummary(DB.localObserved or DB.observed or {})
  DB.snapshots[label] = {
    name = label,
    isAuto = isAuto and true or false,
    savedAt = time(),
    savedText = date("%Y-%m-%d %H:%M:%S"),
    realm = REALM_KEY,
    version = 1,
    mobs = mobs,
    opens = opens,
    unique = items,
    data = {
      observed = deepCopy(DB.observed or {}),
      localObserved = deepCopy(DB.localObserved or {}),
      syncSources = deepCopy(DB.syncSources or {}),
      quarantinedSources = deepCopy(DB.quarantinedSources or {}),
      syncFlags = deepCopy(DB.syncFlags or {}),
      pending = deepCopy(DB.pending or {}),
      log = deepCopy(DB.log or {}),
    },
  }
  SaveState.selected = label
  setSaveStatus((isAuto and "Autosaved: " or "Saved: ") .. label)
  if refreshSaveSlotsUI then refreshSaveSlotsUI() end
end

local function loadSnapshot(name)
  ensureRealmDB()
  local snapshot = DB.snapshots and DB.snapshots[name]
  if not snapshot or type(snapshot.data) ~= "table" then
    setSaveStatus("Snapshot not found")
    return false
  end
  DB.observed = deepCopy(snapshot.data.observed or {})
  DB.localObserved = deepCopy(snapshot.data.localObserved or {})
  DB.syncSources = deepCopy(snapshot.data.syncSources or {})
  DB.quarantinedSources = deepCopy(snapshot.data.quarantinedSources or {})
  DB.syncFlags = deepCopy(snapshot.data.syncFlags or {})
  DB.pending = deepCopy(snapshot.data.pending or {})
  DB.log = deepCopy(snapshot.data.log or {})
  pendingDeaths = {}
  for guid, info in pairs(DB.pending or {}) do
    pendingDeaths[guid] = info
  end
  rebuildAggregateObserved()
  cleanupPending()
  UI.selectedEntry = nil
  SaveState.selected = name
  setSaveStatus("Loaded: " .. name)
  refreshMobList()
  if refreshSaveSlotsUI then refreshSaveSlotsUI() end
  return true
end

local function deleteSnapshot(name)
  ensureRealmDB()
  if not name or not DB.snapshots[name] then
    setSaveStatus("Snapshot not found")
    return false
  end
  DB.snapshots[name] = nil
  if SaveState.selected == name then SaveState.selected = nil end
  setSaveStatus("Deleted: " .. name)
  if refreshSaveSlotsUI then refreshSaveSlotsUI() end
  return true
end

local function addLog(kind, data)
  ensureRealmDB()
  data = data or {}
  data.kind = kind
  data.t = date("%Y-%m-%d %H:%M:%S")
  table.insert(DB.log, data)
  trimLog(DB.log)
end

local function isInGroup()
  local party = GetNumPartyMembers and GetNumPartyMembers() or 0
  local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
  return (party or 0) > 0 or (raid or 0) > 0
end

local function split(str, sep)
  local out = {}
  if not str then return out end
  sep = sep or "-"
  for part in string.gmatch(str, "([^" .. sep .. "]+)") do
    table.insert(out, part)
  end
  return out
end

local function parseNPCIDFromGUID(guid)
  if not guid or type(guid) ~= "string" then return nil end

  if string.find(guid, "Creature%-%") or string.find(guid, "Vehicle%-%") then
    local parts = split(guid, "-")
    return tonumber(parts[6])
  end

  if string.sub(guid, 1, 2) == "0x" then
    local hex = string.sub(guid, 3)
    if string.len(hex) >= 12 then
      local npcHex = string.sub(hex, 7, 10)
      return tonumber(npcHex, 16)
    end
  end

  return nil
end

local function isCreatureGUID(guid)
  if not guid or type(guid) ~= "string" then return false end
  if string.find(guid, "Creature%-%") or string.find(guid, "Vehicle%-%") then
    return true
  end
  if string.sub(guid, 1, 2) == "0x" then
    local unitTypeNibble = string.sub(guid, 5, 5)
    return unitTypeNibble == "3" or unitTypeNibble == "4"
  end
  return false
end

local function formatMoney(copper)
  copper = tonumber(copper) or 0
  if GetCoinTextureString then
    return GetCoinTextureString(copper)
  end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  return string.format("%dg %ds %dc", g, s, c)
end

local function parseMoneyText(text)
  if not text then return 0 end
  local gold = tonumber(string.match(text, "(%d+)%s*[Gg]old")) or 0
  local silver = tonumber(string.match(text, "(%d+)%s*[Ss]ilver")) or 0
  local copper = tonumber(string.match(text, "(%d+)%s*[Cc]opper")) or 0
  if gold == 0 and silver == 0 and copper == 0 then
    gold = tonumber(string.match(text, "(%d+)%s*[Gg]")) or 0
    silver = tonumber(string.match(text, "(%d+)%s*[Ss]")) or 0
    copper = tonumber(string.match(text, "(%d+)%s*[Cc]")) or 0
  end
  return gold * 10000 + silver * 100 + copper
end

local function isPlayerUnit(unit)
  return UnitIsPlayer and UnitIsPlayer(unit)
end


local function normalizeSearch(text)
  text = tostring(text or "")
  text = string.lower(text)
  text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
  text = string.gsub(text, "|r", "")
  text = string.gsub(text, "|H.-|h(.-)|h", "%1")
  text = string.gsub(text, "%s+", " ")
  return text
end

local function shouldCountKill(guid, npcID, name)
  local stamp = now()
  local key
  if guid and guid ~= "" then
    key = "guid:" .. tostring(guid)
  elseif npcID then
    key = "npc:" .. tostring(npcID) .. ":" .. normalizeSearch(name)
  else
    return true
  end

  local last = recentKillMarks[key]
  if last and (stamp - last) < 2 then
    return false
  end
  recentKillMarks[key] = stamp
  return true
end

local function cleanupRecentKillMarks()
  local cutoff = now() - 10
  for key, stamp in pairs(recentKillMarks) do
    if not stamp or stamp < cutoff then
      recentKillMarks[key] = nil
    end
  end
end

local function getCurrentZoneName()
  local zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or "Unknown"
  if not zone or zone == "" then zone = "Unknown" end
  return zone
end

local function getOrCreateMobRecord(npcID, name)
  ensureRealmDB()
  if not npcID then return nil end
  local rec = DB.localObserved[npcID]
  if not rec then
    rec = {
      npcID = npcID,
      name = name,
      opens = 0,
      totalMoney = 0,
      items = {},
      zones = {},
      firstSeen = date("%Y-%m-%d %H:%M:%S"),
      lastSeen = nil,
    }
    DB.localObserved[npcID] = rec
    Session.newMobs = (Session.newMobs or 0) + 1
  end
  rec.name = name or rec.name or ("NPC " .. tostring(npcID))
  rec.items = rec.items or {}
  rec.zones = rec.zones or {}
  return rec
end

local function updateMobZone(rec, zone)
  if not rec then return end
  zone = zone or getCurrentZoneName()
  rec.zones = rec.zones or {}
  rec.zones[zone] = (rec.zones[zone] or 0) + 1
  rec.lastZone = zone
  rec.lastSeen = date("%Y-%m-%d %H:%M:%S")
end

getPrimaryZone = function(rec)
  if not rec or not rec.zones then return "Unknown" end
  local bestZone = rec.lastZone or "Unknown"
  local bestCount = -1
  for zone, count in pairs(rec.zones) do
    if count > bestCount then
      bestZone = zone
      bestCount = count
    end
  end
  return bestZone or "Unknown"
end

local function unitLootCandidate(unit)
  if not UnitExists(unit) then return nil end
  if isPlayerUnit(unit) then return nil end
  local guid = UnitGUID(unit)
  if not guid or not isCreatureGUID(guid) then return nil end
  local npcID = parseNPCIDFromGUID(guid)
  if not npcID then return nil end
  return {
    unit = unit,
    guid = guid,
    npcID = npcID,
    name = UnitName(unit),
    dead = UnitIsDead(unit) and true or false,
    canLoot = CanLootUnit and CanLootUnit(unit) and true or false,
    zone = getCurrentZoneName(),
  }
end

local function rememberPendingDeath(guid, name, npcID)
  if not guid or not npcID or not isCreatureGUID(guid) then return end
  ensureRealmDB()
  cleanupRecentKillMarks()
  if not shouldCountKill(guid, npcID, name) then return end

  local zone = getCurrentZoneName()
  pendingDeaths[guid] = {
    guid = guid,
    name = name,
    npcID = npcID,
    at = now(),
    zone = zone,
  }
  DB.pending[guid] = pendingDeaths[guid]
end

cleanupPending = function()
  ensureRealmDB()
  cleanupRecentKillMarks()
  local cutoff = now() - 300
  for guid, info in pairs(pendingDeaths) do
    if not info.at or info.at < cutoff then
      pendingDeaths[guid] = nil
    end
  end
  for guid, info in pairs(DB.pending) do
    if not info.at or info.at < cutoff then
      DB.pending[guid] = nil
    end
  end
end

local function extractCLEU(...)
  local a = { ... }
  local subEvent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags

  if type(a[2]) == "string" then
    subEvent = a[2]
    sourceGUID = a[4]
    sourceName = a[5]
    sourceFlags = a[6]
    destGUID = a[8]
    destName = a[9]
    destFlags = a[10]
  else
    subEvent = a[3]
    sourceGUID = a[5]
    sourceName = a[6]
    sourceFlags = a[7]
    destGUID = a[9]
    destName = a[10]
    destFlags = a[11]
  end

  if not subEvent then return nil end
  return {
    subEvent = subEvent,
    sourceGUID = sourceGUID,
    sourceName = sourceName,
    sourceFlags = sourceFlags,
    destGUID = destGUID,
    destName = destName,
    destFlags = destFlags,
  }
end

local function isPlayerSource(guid, name)
  local playerGUID = UnitGUID("player")
  if guid and playerGUID and guid == playerGUID then return true end
  if UnitExists("pet") and guid and guid == UnitGUID("pet") then return true end
  if name and UnitName("player") and name == UnitName("player") then return true end
  if UnitExists("pet") and name and UnitName("pet") and name == UnitName("pet") then return true end
  return false
end

local function getLootSlotsSnapshot()
  local slots = {}
  local numLoot = GetNumLootItems and GetNumLootItems() or 0
  for i = 1, numLoot do
    local icon, lootName, lootQuantity, quality, locked = GetLootSlotInfo(i)
    local link = GetLootSlotLink and GetLootSlotLink(i) or nil
    local parsedMoney = parseMoneyText(lootName)

    local slotType = "unknown"
    if link then
      slotType = "item"
    elseif parsedMoney > 0 then
      slotType = "coin"
    elseif LootSlotHasItem then
      slotType = LootSlotHasItem(i) and "item" or "coin"
    end

    table.insert(slots, {
      slot = i,
      name = lootName,
      qty = tonumber(lootQuantity) or 1,
      quality = quality,
      locked = locked,
      link = link,
      slotType = slotType,
      money = slotType == "coin" and parsedMoney or 0,
    })
  end
  return slots
end

local function ensureKillCountForCandidate(candidate)
  if not candidate or not candidate.npcID then return end
  ensureRealmDB()
  if candidate.guid then
    pendingDeaths[candidate.guid] = pendingDeaths[candidate.guid] or {
      guid = candidate.guid,
      name = candidate.name,
      npcID = candidate.npcID,
      at = now(),
      zone = candidate.zone or getCurrentZoneName(),
    }
    DB.pending[candidate.guid] = DB.pending[candidate.guid] or pendingDeaths[candidate.guid]
  end
end

local function chooseLootSourceCandidate()
  local target = unitLootCandidate("target")
  local mouseover = unitLootCandidate("mouseover")

  if mouseover and mouseover.guid and mouseover.dead then
    return mouseover, "mouseover"
  end
  if target and target.guid and target.dead then
    return target, "target"
  end

  local newestGuid, newestInfo
  for guid, info in pairs(pendingDeaths) do
    if not newestInfo or (info.at or 0) > (newestInfo.at or 0) then
      newestGuid = guid
      newestInfo = info
    end
  end
  if newestInfo then
    return {
      unit = "pending",
      guid = newestGuid,
      npcID = newestInfo.npcID,
      name = newestInfo.name,
      dead = true,
      canLoot = nil,
      zone = newestInfo.zone,
    }, "pending"
  end

  return nil, "none"
end

local function buildSortedItems(rec)
  local items = {}
  for _, item in pairs(rec.items or {}) do
    item.dropPct = 0
    if (rec.opens or 0) > 0 then
      item.dropPct = ((item.seen or 0) / rec.opens) * 100
    end
    table.insert(items, item)
  end
  table.sort(items, function(a, b)
    local ap = a.dropPct or 0
    local bp = b.dropPct or 0
    if ap ~= bp then
      return ap > bp
    end
    local aSeen = a.seen or 0
    local bSeen = b.seen or 0
    if aSeen ~= bSeen then
      return aSeen > bSeen
    end
    local aQty = a.totalQty or 0
    local bQty = b.totalQty or 0
    if aQty ~= bQty then
      return aQty > bQty
    end
    return tostring(a.link or a.name or "") < tostring(b.link or b.name or "")
  end)
  return items
end

local function commitActiveLoot(reason)
  if not activeLoot then return end
  ensureRealmDB()

  if not activeLoot.npcID then
    activeLoot = nil
    return
  end

  local rec = getOrCreateMobRecord(activeLoot.npcID, activeLoot.name)
  updateMobZone(rec, activeLoot.zone)
  rec.opens = (rec.opens or 0) + 1
  Session.opens = (Session.opens or 0) + 1

  local moneyThisOpen = 0
  local seenThisOpen = {}

  for _, slot in ipairs(activeLoot.slots or {}) do
    if slot.slotType == "coin" then
      moneyThisOpen = moneyThisOpen + (tonumber(slot.money) or 0)
    elseif slot.link or slot.name then
      local itemID, itemKey = makeItemSyncKey(slot.link or slot.name or ("slot_" .. tostring(slot.slot)), { itemID = slot.itemID, link = slot.link, name = slot.name })
      local isNewItem = rec.items[itemKey] == nil
      rec.items[itemKey] = rec.items[itemKey] or {
        itemID = itemID,
        name = slot.name,
        link = slot.link,
        seen = 0,
        totalQty = 0,
      }
      if isNewItem then
        Session.newItems = (Session.newItems or 0) + 1
      end
      local item = rec.items[itemKey]
      if not seenThisOpen[itemKey] then
        item.seen = (item.seen or 0) + 1
        seenThisOpen[itemKey] = true
      end
      item.totalQty = (item.totalQty or 0) + (tonumber(slot.qty) or 0)
      item.itemID = item.itemID or itemID
      item.name = slot.name or item.name
      item.link = slot.link or item.link
    end
  end

  rec.totalMoney = (rec.totalMoney or 0) + moneyThisOpen
  Session.money = (Session.money or 0) + moneyThisOpen

  addLog("loot_closed", {
    reason = reason,
    guid = activeLoot.guid,
    npcID = activeLoot.npcID,
    name = activeLoot.name,
    sourceKind = activeLoot.sourceKind,
    slotCount = #(activeLoot.slots or {}),
    money = moneyThisOpen,
  })

  if activeLoot.guid then
    pendingDeaths[activeLoot.guid] = nil
    DB.pending[activeLoot.guid] = nil
  end

  rebuildAggregateObserved()
  activeLoot = nil
end

local function sanitizeTooltipItemLabel(item)
  local label = item.link or item.name or "Unknown"
  local plain = GetItemInfo(item.itemID or 0)
  if plain and plain ~= "" then
    label = plain
  else
    label = string.gsub(label, "|c%x%x%x%x%x%x%x%x", "")
    label = string.gsub(label, "|r", "")
    label = string.gsub(label, "|Hitem:.-|h%[(.-)%]|h", "%1")
  end
  if string.len(label) > 24 then
    label = string.sub(label, 1, 21) .. "..."
  end
  return label
end

local function getAccuracyForLootOpens(opens)
  opens = tonumber(opens) or 0
  if opens >= 100 then
    return "Precise", 0.25, 1.00, 0.25
  elseif opens >= 50 then
    return "High", 1.00, 0.88, 0.20
  elseif opens >= 20 then
    return "Medium", 1.00, 0.52, 0.12
  end
  return "Low", 1.00, 0.20, 0.20
end

local function addTooltipForMouseover(tooltip, unit)
  ensureRealmDB()
  tooltip = tooltip or GameTooltip
  if SDIHoverTooltip then SDIHoverTooltip:Hide() end
  if SepheransDropInfoDB.settings.hidden then return end
  unit = unit or "mouseover"
  if not UnitExists(unit) then return end
  if isPlayerUnit(unit) then return end
  if not tooltip or not tooltip:IsShown() then return end

  local guid = UnitGUID(unit)
  if not guid or not isCreatureGUID(guid) then return end
  if tooltip.sdiGUID == guid then return end

  local npcID = parseNPCIDFromGUID(guid)
  if not npcID then return end

  local rec = DB.localObserved[npcID]
  if not rec then return end

  tooltip.sdiGUID = guid

  local items = buildSortedItems(rec)
  local avgMoney = 0
  if (rec.opens or 0) > 0 then
    avgMoney = math.floor((rec.totalMoney or 0) / rec.opens)
  end

  tooltip:AddLine(" ")
  tooltip:AddLine("Sepheran's Drop Info", 0.5, 0.8, 1)
  tooltip:AddLine("/sdi to open info panel", 0.7, 0.7, 0.7)
  tooltip:AddLine("------Item drops-----", 1, 0.82, 0)
  if #items == 0 then
    tooltip:AddLine("No observed items yet", 0.7, 0.7, 0.7)
  else
    local shown = 0
    for _, item in ipairs(items) do
      shown = shown + 1
      local label = sanitizeTooltipItemLabel(item)
      tooltip:AddDoubleLine(label, string.format("%.1f%%", item.dropPct or 0), 0.85, 0.85, 0.85, 0.65, 1, 0.65)
      if shown >= 8 then
        break
      end
    end
    if #items > 8 then
      tooltip:AddLine("...and " .. tostring(#items - 8) .. " more", 0.7, 0.7, 0.7)
    end
  end

  tooltip:AddLine("------Money------", 1, 0.82, 0)
  tooltip:AddDoubleLine("Total:", formatMoney(rec.totalMoney or 0), 1, 1, 1, 1, 0.82, 0)
  tooltip:AddDoubleLine("Average:", formatMoney(avgMoney), 1, 1, 1, 1, 0.82, 0)
  tooltip:AddLine("------Accuracy------", 1, 0.82, 0)
  local accuracyLabel, accuracyR, accuracyG, accuracyB = getAccuracyForLootOpens(rec.opens)
  tooltip:AddDoubleLine("Accuracy:", accuracyLabel, 1, 1, 1, accuracyR, accuracyG, accuracyB)
  tooltip:Show()
end

local function clearTooltipMarker()
  if GameTooltip then
    GameTooltip.sdiGUID = nil
  end
  if SDIHoverTooltip then
    SDIHoverTooltip:Hide()
  end
end

local function addPanelTexture(frame, inset)
  inset = inset or 0
  local tex = frame:CreateTexture(nil, "BACKGROUND")
  tex:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  tex:SetPoint("TOPLEFT", inset, -inset)
  tex:SetPoint("BOTTOMRIGHT", -inset, inset)
  tex:SetVertexColor(0.06, 0.05, 0.04, 1)
  frame._sdiPanelTexture = tex
  return tex
end

local function createBackdrop(frame, bgR, bgG, bgB, bgA, edgeR, edgeG, edgeB, edgeA)
  frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
  })
  frame:SetBackdropColor(bgR or 0.08, bgG or 0.07, bgB or 0.05, bgA or 1)
  frame:SetBackdropBorderColor(edgeR or 0.78, edgeG or 0.62, edgeB or 0.18, edgeA or 1)
end

local function createInsetPanel(parent, left, top, right, bottom)
  local panel = CreateFrame("Frame", nil, parent)
  panel:SetPoint("TOPLEFT", left, top)
  panel:SetPoint("BOTTOMRIGHT", right, bottom)
  createBackdrop(panel, 0.10, 0.09, 0.07, 1, 0.55, 0.44, 0.12, 1)

  local inner = panel:CreateTexture(nil, "BACKGROUND")
  inner:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  inner:SetPoint("TOPLEFT", 5, -5)
  inner:SetPoint("BOTTOMRIGHT", -5, 5)
  inner:SetVertexColor(0.14, 0.12, 0.09, 1)

  local shadeTop = panel:CreateTexture(nil, "BORDER")
  shadeTop:SetTexture("Interface\\Buttons\\WHITE8X8")
  shadeTop:SetPoint("TOPLEFT", 5, -5)
  shadeTop:SetPoint("TOPRIGHT", -5, -5)
  shadeTop:SetHeight(18)
  shadeTop:SetVertexColor(1, 1, 1, 0.04)

  local shadeBottom = panel:CreateTexture(nil, "BORDER")
  shadeBottom:SetTexture("Interface\\Buttons\\WHITE8X8")
  shadeBottom:SetPoint("BOTTOMLEFT", 5, 5)
  shadeBottom:SetPoint("BOTTOMRIGHT", -5, 5)
  shadeBottom:SetHeight(18)
  shadeBottom:SetVertexColor(0, 0, 0, 0.18)

  panel.inner = inner
  panel._shadeTop = shadeTop
  panel._shadeBottom = shadeBottom
  UI._styledInsetPanels = UI._styledInsetPanels or {}
  table.insert(UI._styledInsetPanels, panel)
  return panel
end


applyUITheme = function()
  if not UI or not UI.frame then return end
  ensureRootDB()
  local bgR, bgG, bgB = getStoredUIColor("bg", 0.03137254901960784, 0.04313725490196078, 0.08235294117647059)
  local borderR, borderG, borderB = getStoredUIColor("border", 0.4509803921568628, 0.6, 0.8509803921568627)
  local accentR, accentG, accentB = getStoredUIColor("accent", 0.4313725490196079, 0.8470588235294118, 1)

  UI.frame:SetBackdropColor(bgR, bgG, bgB, 1)
  UI.frame:SetBackdropBorderColor(borderR, borderG, borderB, 1)
  if UI.frame._sdiPanelTexture then
    UI.frame._sdiPanelTexture:SetVertexColor(bgR * 0.5, bgG * 0.5, bgB * 0.5, 1)
  end
  if UI.itemInfoFrame then
    UI.itemInfoFrame:SetBackdropColor(bgR, bgG, bgB, 1)
    UI.itemInfoFrame:SetBackdropBorderColor(borderR, borderG, borderB, 1)
    if UI.itemInfoFrame._sdiPanelTexture then
      UI.itemInfoFrame._sdiPanelTexture:SetVertexColor(bgR * 0.5, bgG * 0.5, bgB * 0.5, 1)
    end
  end

  local bars = {
    { UI.header, bgR + 0.01, bgG + 0.015, bgB + 0.02, 0.98 },
    { UI.footer, bgR + 0.01, bgG + 0.015, bgB + 0.02, 0.95 },
    { UI.headerBottom, accentR, accentG, accentB, 0.35 },
    { UI.footerTop, accentR, accentG, accentB, 0.25 },
    { UI.rightRule, accentR, accentG, accentB, 0.18 },
    { UI.leftRule, accentR, accentG, accentB, 0.18 },
    { UI.itemInfoHeader, bgR + 0.16, bgG + 0.11, bgB + 0.01, 1 },
    { UI.itemInfoHeaderBottom, accentR, accentG, accentB, 0.35 },
    { UI.itemInfoRule, accentR, accentG, accentB, 0.18 },
  }
  for _, info in ipairs(bars) do
    if info[1] then info[1]:SetVertexColor(info[2], info[3], info[4], info[5]) end
  end

  if UI._styledInsetPanels then
    for _, panel in ipairs(UI._styledInsetPanels) do
      if panel and panel.SetBackdropColor then
        panel:SetBackdropColor(bgR * 0.85, bgG * 0.85, bgB * 0.85, 1)
        panel:SetBackdropBorderColor(borderR * 0.72, borderG * 0.72, borderB * 0.72, 1)
      end
      if panel.inner then panel.inner:SetVertexColor(bgR * 0.92, bgG * 0.94, bgB * 0.98, 0.98) end
      if panel._shadeTop then panel._shadeTop:SetVertexColor(1, 1, 1, 0.025) end
      if panel._shadeBottom then panel._shadeBottom:SetVertexColor(0, 0, 0, 0.22) end
    end
  end

  if UI._accentTexts then
    for _, fs in ipairs(UI._accentTexts) do
      if fs and fs.SetTextColor then fs:SetTextColor(accentR, accentG, accentB) end
    end
  end

  if UI._editBoxes then
    for _, eb in ipairs(UI._editBoxes) do
      if eb then styleSDIEditBox(eb) end
    end
  end

  if UI.optionsSwatches then
    for kind, swatch in pairs(UI.optionsSwatches) do
      if swatch then
        local r, g, b = getStoredUIColor(kind, 1, 1, 1)
        swatch:SetVertexColor(r, g, b, 1)
      end
    end
  end

  applyUIFontTheme()
end

updateVisibleMobRows = function()
  if not UI or not UI.listButtons or not UI.listContent then return end
  local height = UI.listContent:GetHeight() or 0
  UI.visibleMobRows = 14
end

applyUIScale = function()
  ensureRootDB()
  if not UI or not UI.frame then return end
  local scale = tonumber(SepheransDropInfoDB.settings.uiScale) or 1
  if scale < 0.70 then scale = 0.70 end
  if scale > 1.35 then scale = 1.35 end
  SepheransDropInfoDB.settings.uiScale = scale
  UI.frame:SetScale(scale)
  if UI.itemInfoFrame then UI.itemInfoFrame:SetScale(scale) end
  if UI.optionsFrame and UI.optionsFrame:IsShown() then UI.optionsFrame:ClearAllPoints(); UI.optionsFrame:SetPoint("TOPLEFT", UI.frame, "TOPRIGHT", 8, 0) end
  if UI.scaleSlider and (math.abs((UI.scaleSlider:GetValue() or scale) - scale) > 0.001) then
    UI.scaleSlider._ignore = true
    UI.scaleSlider:SetValue(scale)
    UI.scaleSlider._ignore = nil
  end
  if UI.scaleValue then UI.scaleValue:SetText(string.format("%.2fx", scale)) end
  updateVisibleMobRows()
  if refreshMobList then refreshMobList() end
end

local function getActiveTab()
  ensureRootDB()
  return SepheransDropInfoDB.settings.uiTab or "browser"
end

local function setActiveTab(tab)
  ensureRootDB()
  if tab ~= "analytics" and tab ~= "sync" and tab ~= "saves" and tab ~= "export" then
    tab = "browser"
  end
  SepheransDropInfoDB.settings.uiTab = tab
end

local function isAnalyticsTab()
  return getActiveTab() == "analytics"
end

local function isSyncTab()
  return getActiveTab() == "sync"
end

local function isSavesTab()
  return getActiveTab() == "saves"
end

local function isExportTab()
  return getActiveTab() == "export"
end


local SORT_MODES = { "name", "opens", "money" }

local function getSortLabel(mode)
  if mode == "opens" then return "Loot opens" end
  if mode == "money" then return "Money" end
  return "Name"
end

local function getCurrentSortMode()
  ensureRootDB()
  local mode = SepheransDropInfoDB.settings.sortMode or "name"
  return mode
end

local function advanceSortMode()
  local current = getCurrentSortMode()
  local idx = 1
  for i, mode in ipairs(SORT_MODES) do
    if mode == current then
      idx = i
      break
    end
  end
  idx = idx + 1
  if idx > #SORT_MODES then idx = 1 end
  SepheransDropInfoDB.settings.sortMode = SORT_MODES[idx]
end

countUniqueItems = function(rec)
  local n = 0
  for _ in pairs(rec.items or {}) do n = n + 1 end
  return n
end

local function getGlobalUniqueItemCount()
  ensureRealmDB()
  local seen = {}
  for _, rec in pairs(DB.localObserved or {}) do
    for key in pairs(rec.items or {}) do
      seen[key] = true
    end
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  return n
end

local function getSessionSummaryText()
  return string.format("Session: Opens %d   Money %s   New mobs %d   New items %d",
    Session.opens or 0, formatMoney(Session.money or 0), Session.newMobs or 0, Session.newItems or 0)
end

local function getPlayerNameClean(name)
  name = tostring(name or UnitName("player") or "Unknown")
  local dash = string.find(name, "%-")
  if dash then name = string.sub(name, 1, dash - 1) end
  return name
end

local function extractItemID(value)
  if type(value) == "number" then return value end
  if type(value) ~= "string" then return nil end
  local id = string.match(value, "Hitem:(%d+)") or string.match(value, "item:(%d+)")
  return tonumber(id) or nil
end

makeItemSyncKey = function(key, itemData)
  local itemID = nil
  if type(itemData) == "table" then
    itemID = tonumber(itemData.itemID) or extractItemID(itemData.link) or extractItemID(itemData.name)
  end
  itemID = itemID or extractItemID(key)
  if itemID then
    return itemID, "item:" .. tostring(itemID)
  end
  local name = nil
  if type(itemData) == "table" then
    name = itemData.name
  end
  name = name or (type(key) == "string" and key) or "unknown"
  name = tostring(name)
  name = string.gsub(name, "|c%x%x%x%x%x%x%x%x", "")
  name = string.gsub(name, "|r", "")
  name = string.gsub(name, "|Hitem:.-|h%[(.-)%]|h", "%1")
  name = string.lower(name)
  return nil, "name:" .. name
end



local function cloneObservedDataset(source)
  local out = {}
  for npcID, src in pairs(source or {}) do
    local numNpcID = tonumber(npcID) or npcID
    if type(src) == "table" then
      local dst = {
        npcID = tonumber(src.npcID) or numNpcID,
        name = src.name,
        opens = tonumber(src.opens) or 0,
        totalMoney = tonumber(src.totalMoney) or 0,
        items = {},
        zones = {},
        firstSeen = src.firstSeen,
        lastSeen = src.lastSeen,
        lastZone = src.lastZone,
      }
      local srcZones = type(src.zones) == "table" and src.zones or {}
      for zone, count in pairs(srcZones) do
        dst.zones[zone] = tonumber(count) or 0
      end
      local srcItems = type(src.items) == "table" and src.items or {}
      for key, item in pairs(srcItems) do
        local itemData = type(item) == "table" and item or {}
        local itemID, normKey = makeItemSyncKey(key, itemData)
        dst.items[normKey] = {
          itemID = tonumber(itemData.itemID) or itemID,
          name = itemData.name,
          link = itemData.link,
          seen = tonumber(itemData.seen) or 0,
          totalQty = tonumber(itemData.totalQty) or 0,
        }
      end
      out[numNpcID] = dst
    end
  end
  return out
end

local function combineObservedInto(dest, source)
  for npcID, src in pairs(source or {}) do
    local numNpcID = tonumber(npcID) or npcID
    if type(src) == "table" then
      local dst = dest[numNpcID]
      if not dst then
        dst = {
          npcID = tonumber(src.npcID) or numNpcID,
          name = src.name,
          opens = 0,
          totalMoney = 0,
          items = {},
          zones = {},
          firstSeen = src.firstSeen,
          lastSeen = src.lastSeen,
          lastZone = src.lastZone,
        }
        dest[numNpcID] = dst
      end

      dst.name = dst.name or src.name
      dst.opens = (tonumber(dst.opens) or 0) + (tonumber(src.opens) or 0)
      dst.totalMoney = (tonumber(dst.totalMoney) or 0) + (tonumber(src.totalMoney) or 0)

      if src.firstSeen and (not dst.firstSeen or src.firstSeen < dst.firstSeen) then dst.firstSeen = src.firstSeen end
      if src.lastSeen and (not dst.lastSeen or src.lastSeen > dst.lastSeen) then dst.lastSeen = src.lastSeen end
      if src.lastZone then dst.lastZone = src.lastZone end

      local srcZones = type(src.zones) == "table" and src.zones or {}
      for zone, count in pairs(srcZones) do
        dst.zones[zone] = (tonumber(dst.zones[zone]) or 0) + (tonumber(count) or 0)
      end

      local srcItems = type(src.items) == "table" and src.items or {}
      for key, item in pairs(srcItems) do
        local itemData = type(item) == "table" and item or {}
        local itemID, normKey = makeItemSyncKey(key, itemData)
        local di = dst.items[normKey]
        if not di then
          di = { itemID = itemID, name = itemData.name, link = itemData.link, seen = 0, totalQty = 0 }
          dst.items[normKey] = di
        end
        di.itemID = di.itemID or tonumber(itemData.itemID) or itemID
        di.name = di.name or itemData.name
        di.link = di.link or itemData.link
        di.seen = (tonumber(di.seen) or 0) + (tonumber(itemData.seen) or 0)
        di.totalQty = (tonumber(di.totalQty) or 0) + (tonumber(itemData.totalQty) or 0)
      end
    end
  end
end

rebuildAggregateObserved = function()
  ensureRealmDB()
  local merged = {}
  combineObservedInto(merged, DB.localObserved or {})
  for _, snapshot in pairs(DB.syncSources or {}) do
    combineObservedInto(merged, snapshot)
  end
  DB.observed = merged
  return merged
end

local function getSyncSummary()
  ensureRealmDB()
  local mobs, opens, money = 0, 0, 0
  local items = {}
  for _, rec in pairs(DB.localObserved or {}) do
    mobs = mobs + 1
    opens = opens + (tonumber(rec.opens) or 0)
    money = money + (tonumber(rec.totalMoney) or 0)
    for key in pairs(rec.items or {}) do items[key] = true end
  end
  local unique = 0
  for _ in pairs(items) do unique = unique + 1 end
  return { user = getPlayerNameClean(), mobs = mobs, opens = opens, unique = unique, money = money }
end

local function countObservedMobs(observed)
  local n = 0
  for _ in pairs(observed or {}) do n = n + 1 end
  return n
end

local function getMobSyncMetrics(rec)
  local unique, seen, qty = 0, 0, 0
  local items = type(rec) == "table" and type(rec.items) == "table" and rec.items or {}
  for _, item in pairs(items) do
    item = type(item) == "table" and item or {}
    unique = unique + 1
    seen = seen + (tonumber(item.seen) or 0)
    qty = qty + (tonumber(item.totalQty) or 0)
  end
  return {
    o = tonumber(rec and rec.opens) or 0,
    u = unique,
    s = seen,
    q = qty,
    m = tonumber(rec and rec.totalMoney) or 0,
  }
end

local function getStoredSyncSource(sender)
  ensureRealmDB()
  if not sender or sender == "" then return nil end
  local clean = getPlayerNameClean(sender)
  return (DB.syncSources and (DB.syncSources[clean] or DB.syncSources[sender])) or nil
end

local function getStoredSyncFlag(sender)
  ensureRealmDB()
  if not sender or sender == "" then return nil end
  local clean = getPlayerNameClean(sender)
  return (DB.syncFlags and (DB.syncFlags[clean] or DB.syncFlags[sender])) or nil
end

local function rememberSyncFlag(sender, report)
  ensureRealmDB()
  if not sender or sender == "" or type(report) ~= "table" then return end
  local clean = getPlayerNameClean(sender)
  report.checkedText = date("%Y-%m-%d %H:%M:%S")
  DB.syncFlags[clean] = {
    severity = report.severity or "clean",
    label = report.label or "Clean",
    issues = tonumber(report.issues) or 0,
    suspiciousMobs = tonumber(report.suspiciousMobs) or 0,
    reviewMobs = tonumber(report.reviewMobs) or 0,
    checkedText = report.checkedText,
    quarantined = report.quarantined and true or false,
  }
end

local function newSyncTrustReport()
  return {
    severity = "clean",
    label = "Clean",
    issues = 0,
    suspiciousMobs = 0,
    reviewMobs = 0,
  }
end

local function markSyncTrustIssue(report, severity)
  if not report then return end
  report.issues = (tonumber(report.issues) or 0) + 1
  if severity == "suspicious" then
    report.suspiciousMobs = (tonumber(report.suspiciousMobs) or 0) + 1
    report.severity = "suspicious"
    report.label = "Suspicious"
  elseif report.severity ~= "suspicious" then
    report.reviewMobs = (tonumber(report.reviewMobs) or 0) + 1
    report.severity = "review"
    report.label = "Review"
  end
end

local function finishSyncTrustReport(report)
  if not report then return newSyncTrustReport() end
  if report.quarantined then
    report.severity = "quarantined"
    report.label = "Quarantined"
  elseif (tonumber(report.suspiciousMobs) or 0) > 0 then
    report.severity = "suspicious"
    report.label = "Suspicious"
  elseif (tonumber(report.reviewMobs) or 0) > 0 then
    report.severity = "review"
    report.label = "Review"
  else
    report.severity = "clean"
    report.label = "Clean"
  end
  return report
end

local function analyzeMobSyncShape(rec, known, report)
  if type(rec) ~= "table" then
    markSyncTrustIssue(report, "suspicious")
    return
  end

  local opens = tonumber(rec.opens) or 0
  local totalMoney = tonumber(rec.totalMoney) or 0
  if opens < 0 or totalMoney < 0 then
    markSyncTrustIssue(report, "suspicious")
  end
  if rec.zones and type(rec.zones) ~= "table" then
    markSyncTrustIssue(report, "suspicious")
  end

  local itemCount = 0
  local itemSeenTotal = 0
  if rec.items and type(rec.items) ~= "table" then
    markSyncTrustIssue(report, "suspicious")
  end
  local items = type(rec.items) == "table" and rec.items or {}
  for _, item in pairs(items) do
    itemCount = itemCount + 1
    if type(item) ~= "table" then
      markSyncTrustIssue(report, "suspicious")
      item = {}
    end
    local seen = tonumber(item.seen) or 0
    local qty = tonumber(item.totalQty) or 0
    itemSeenTotal = itemSeenTotal + seen
    if seen < 0 or qty < 0 then
      markSyncTrustIssue(report, "suspicious")
    elseif opens == 0 and (seen > 0 or qty > 0) then
      markSyncTrustIssue(report, "suspicious")
    elseif opens > 0 and seen > opens then
      markSyncTrustIssue(report, "suspicious")
    elseif qty > 0 and qty < seen then
      markSyncTrustIssue(report, "review")
    end
  end

  if opens == 0 and (itemCount > 0 or totalMoney > 0) then
    markSyncTrustIssue(report, "suspicious")
  end

  if opens > 0 and itemCount > (opens * 10 + 25) then
    markSyncTrustIssue(report, "review")
  end

  if known then
    local knownOpens = tonumber(known.opens) or 0
    local knownItems = countUniqueItems(known)
    if opens < knownOpens or itemCount < knownItems then
      markSyncTrustIssue(report, "review")
    elseif knownOpens > 0 and opens > (knownOpens * 8 + 250) then
      markSyncTrustIssue(report, "review")
    end
  end

  if opens > 0 and itemSeenTotal > (opens * math.max(1, itemCount)) then
    markSyncTrustIssue(report, "suspicious")
  end
end

local function analyzeObservedSyncData(sender, observed)
  local report = newSyncTrustReport()
  if type(observed) ~= "table" then
    markSyncTrustIssue(report, "suspicious")
    return finishSyncTrustReport(report)
  end

  local known = getStoredSyncSource(sender) or {}
  for npcID, rec in pairs(observed or {}) do
    local numericID = tonumber(npcID)
    if not numericID then
      markSyncTrustIssue(report, "suspicious")
    end
    local stored = known[numericID or npcID] or known[tostring(npcID)]
    analyzeMobSyncShape(rec, stored, report)
  end

  return finishSyncTrustReport(report)
end

local function getEstimatedSyncMobCount(sender, remoteMobs)
  local remoteCount = tonumber(remoteMobs) or 0
  local knownCount = countObservedMobs(getStoredSyncSource(sender))
  local pending = remoteCount - knownCount
  if pending < 0 then pending = 0 end
  return pending
end

local function buildSyncCheckManifest()
  ensureRealmDB()
  local manifest = {}
  for npcID, rec in pairs(DB.localObserved or {}) do
    manifest[npcID] = getMobSyncMetrics(rec)
  end
  return manifest
end

local function isMobSyncNewer(remote, known)
  if type(remote) ~= "table" then return false end
  if not known then return true end
  local current = getMobSyncMetrics(known)
  return ((tonumber(remote.o) or 0) > current.o)
    or ((tonumber(remote.u) or 0) > current.u)
    or ((tonumber(remote.s) or 0) > current.s)
    or ((tonumber(remote.q) or 0) > current.q)
    or ((tonumber(remote.m) or 0) > current.m)
end

local function countMobsNeedingSync(sender, manifest, fallbackMobs)
  if type(manifest) ~= "table" then
    return getEstimatedSyncMobCount(sender, fallbackMobs)
  end

  local known = getStoredSyncSource(sender) or {}
  local count = 0
  for npcID, remote in pairs(manifest) do
    if type(npcID) ~= "string" or string.sub(npcID, 1, 2) ~= "__" then
      local numericID = tonumber(npcID)
      local stored = known[numericID or npcID] or known[tostring(npcID)]
      if isMobSyncNewer(remote, stored) then
        count = count + 1
      end
    end
  end
  return count
end

local function analyzeSyncCheckManifest(sender, manifest, fallbackMobs)
  local report = newSyncTrustReport()
  if type(manifest) ~= "table" then
    if fallbackMobs then
      report.severity = "unknown"
      report.label = "Unknown"
      return report
    end
    markSyncTrustIssue(report, "suspicious")
    return finishSyncTrustReport(report)
  end

  local known = getStoredSyncSource(sender) or {}
  local checked = 0
  for npcID, remote in pairs(manifest) do
    if type(npcID) ~= "string" or string.sub(npcID, 1, 2) ~= "__" then
      checked = checked + 1
      local numericID = tonumber(npcID)
      if not numericID then
        markSyncTrustIssue(report, "suspicious")
      end
      if type(remote) ~= "table" then
        markSyncTrustIssue(report, "suspicious")
      else
        local opens = tonumber(remote.o) or 0
        local unique = tonumber(remote.u) or 0
        local seen = tonumber(remote.s) or 0
        local qty = tonumber(remote.q) or 0
        local money = tonumber(remote.m) or 0
        if opens < 0 or unique < 0 or seen < 0 or qty < 0 or money < 0 then
          markSyncTrustIssue(report, "suspicious")
        elseif opens == 0 and (unique > 0 or seen > 0 or qty > 0 or money > 0) then
          markSyncTrustIssue(report, "suspicious")
        elseif opens > 0 and seen > (opens * math.max(1, unique)) then
          markSyncTrustIssue(report, "suspicious")
        elseif qty > 0 and qty < seen then
          markSyncTrustIssue(report, "review")
        end

        if opens > 0 and unique > (opens * 10 + 25) then
          markSyncTrustIssue(report, "review")
        end

        local stored = known[numericID or npcID] or known[tostring(npcID)]
        if stored then
          local storedMetrics = getMobSyncMetrics(stored)
          if opens < storedMetrics.o or unique < storedMetrics.u then
            markSyncTrustIssue(report, "review")
          elseif storedMetrics.o > 0 and opens > (storedMetrics.o * 8 + 250) then
            markSyncTrustIssue(report, "review")
          end
        end
      end
    end
  end

  if checked == 0 and (tonumber(fallbackMobs) or 0) > 0 then
    markSyncTrustIssue(report, "review")
  end
  if fallbackMobs and checked ~= (tonumber(fallbackMobs) or 0) then
    markSyncTrustIssue(report, "review")
  end
  return finishSyncTrustReport(report)
end

local function findSyncUserState(sender)
  local clean = getPlayerNameClean(sender)
  if SyncState.users and SyncState.users[clean] then return SyncState.users[clean] end
  for _, user in pairs(SyncState.users or {}) do
    if user.sender == clean or user.user == clean then
      return user
    end
  end
  return nil
end

local function setSyncUserCheckResult(sender, mobsToSync, checkPending)
  local user = findSyncUserState(sender)
  if not user then return end
  user.toSync = tonumber(mobsToSync) or 0
  user.checkPending = checkPending and true or false
  user.checkedAt = (GetTime and GetTime()) or now()
end

local function setSyncUserTrustReport(sender, report)
  local user = findSyncUserState(sender)
  if not user or type(report) ~= "table" then return end
  user.trustSeverity = report.severity or "clean"
  user.trustLabel = report.label or "Clean"
  user.trustIssues = tonumber(report.issues) or 0
  user.suspiciousMobs = tonumber(report.suspiciousMobs) or 0
  user.reviewMobs = tonumber(report.reviewMobs) or 0
  user.quarantined = report.quarantined and true or false
end

local function getSyncTrustDisplay(data)
  if not data then return "Unknown", 0.58, 0.65, 0.78 end
  if data.checkPending and not data.trustLabel then
    return "Checking", 0.4313725490196079, 0.8470588235294118, 1
  end

  local stored = getStoredSyncFlag(data.sender or data.user)
  local severity = data.trustSeverity or (stored and stored.severity) or "unknown"
  local label = data.trustLabel or (stored and stored.label) or "Unknown"
  if severity == "clean" then
    return label, 0.25, 1.00, 0.25
  elseif severity == "review" then
    return label, 1.00, 0.82, 0.00
  elseif severity == "suspicious" or severity == "quarantined" then
    return label, 1.00, 0.20, 0.20
  end
  return label, 0.58, 0.65, 0.78
end

local function setSyncStatus(text)
  SyncState.status = text or "Idle"
  if UI.syncStatusValue then UI.syncStatusValue:SetText(SyncState.status) end
end

local function setSyncLast(text)
  SyncState.lastSync = text or "Never"
  if UI.syncLastValue then UI.syncLastValue:SetText(SyncState.lastSync) end
end

local function getSyncInterval()
  ensureRootDB()
  local v = tonumber(SepheransDropInfoDB.settings.syncInterval) or 20
  if v < 5 then v = 5 end
  if v > 600 then v = 600 end
  return v
end

local function serializeLuaValue(v)
  local t = type(v)
  if t == "number" then
    return tostring(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local out = {"{"}
    local first = true
    for k, val in pairs(v) do
      if not first then table.insert(out, ",") end
      first = false
      local key
      if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then
        key = k .. "="
      else
        key = "[" .. serializeLuaValue(k) .. "]="
      end
      table.insert(out, key .. serializeLuaValue(val))
    end
    table.insert(out, "}")
    return table.concat(out)
  end
  return "nil"
end

local function deserializeLuaTable(text)
  if not text or text == "" then return nil end
  local fn = loadstring("return " .. text)
  if not fn then return nil end
  setfenv(fn, {})
  local ok, data = pcall(fn)
  if ok and type(data) == "table" then return data end
  return nil
end

local function mergeObservedData(sender, incoming)
  ensureRealmDB()
  if type(incoming) ~= "table" then return 0, 0 end

  local report = analyzeObservedSyncData(sender, incoming)
  local normalized = cloneObservedDataset(incoming)
  local mobsChanged, itemsChanged = 0, 0

  for _, src in pairs(normalized) do
    mobsChanged = mobsChanged + 1
    for _ in pairs(src.items or {}) do
      itemsChanged = itemsChanged + 1
    end
  end

  if sender and sender ~= "" then
    local clean = getPlayerNameClean(sender)
    if report.severity == "suspicious" then
      report.quarantined = true
      finishSyncTrustReport(report)
      DB.quarantinedSources[clean] = normalized
      DB.syncSources[clean] = nil
      rememberSyncFlag(clean, report)
      rebuildAggregateObserved()
      return mobsChanged, itemsChanged, report, true
    end
    DB.syncSources[clean] = normalized
    DB.quarantinedSources[clean] = nil
    rememberSyncFlag(clean, report)
  else
    combineObservedInto(DB.localObserved, normalized)
  end

  rebuildAggregateObserved()
  return mobsChanged, itemsChanged, report, false
end

local function getCustomSyncChannelID()
  if not GetChannelName then return 0 end
  local id = GetChannelName(getSyncChannelName())
  if type(id) == "number" then return id end
  return tonumber(id) or 0
end

local function setSyncChannelFromText(text)
  ensureRootDB()
  local name = tostring(text or "")
  name = string.match(name, "^%s*(.-)%s*$") or ""
  if name == "" then name = DEFAULT_SYNC_CHANNEL end
  SepheransDropInfoDB.settings.syncChannel = name
  if UI and UI.syncChannelBox then UI.syncChannelBox:SetText(name) end
  return name
end

local function ensureCustomSyncChannel()
  local id = getCustomSyncChannelID()
  return id or 0
end

local function joinConfiguredSyncChannel()
  local name = setSyncChannelFromText(UI and UI.syncChannelBox and UI.syncChannelBox:GetText() or getSyncChannelName())
  local id = getCustomSyncChannelID()
  if id and id > 0 then
    setSyncStatus("Already in channel: " .. name)
    refreshSyncUsersUI()
    return id
  end

  if JoinChannelByName then
    JoinChannelByName(name)
  elseif JoinTemporaryChannel then
    JoinTemporaryChannel(name)
  else
    setSyncStatus("Channel join is not available")
    refreshSyncUsersUI()
    return 0
  end

  id = getCustomSyncChannelID()
  if id and id > 0 then
    setSyncStatus("Joined channel: " .. name)
  else
    setSyncStatus("Joining channel: " .. name)
  end
  refreshSyncUsersUI()
  return id or 0
end

local function syncTargets()
  local targets = {}
  if IsInGuild and IsInGuild() then targets["GUILD"] = true end
  local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
  local party = GetNumPartyMembers and GetNumPartyMembers() or 0
  if raid > 0 then targets["RAID"] = true elseif party > 0 then targets["PARTY"] = true end
  return targets
end

local function sendSyncMessage(msg, channel, target)
  if not SendAddonMessage then return end
  if channel == "WHISPER" and target and target ~= "" then
    SendAddonMessage(SYNC_PREFIX, msg, "WHISPER", target)
  else
    SendAddonMessage(SYNC_PREFIX, msg, channel)
  end
end

local function sendSyncChatMessage(msg)
  local id = ensureCustomSyncChannel()
  if not id or id <= 0 or not SendChatMessage then return false end
  SendChatMessage(SYNC_CHAT_PREFIX .. msg, "CHANNEL", nil, id)
  return true
end

local function broadcastDiscovery(checkForUpdates)
  if SyncState.selected and (not SyncState.users[SyncState.selected]) then
    SyncState.selected = nil
  end
  SyncState.checkRequested = checkForUpdates and true or false
  SyncState.checkRequestedUsers = checkForUpdates and {} or nil
  SyncState.checkExpiresAt = checkForUpdates and ((GetTime and (GetTime() + 8)) or 0) or nil
  local targets = syncTargets()
  for channel in pairs(targets) do
    sendSyncMessage("QRY", channel)
  end
  sendSyncChatMessage("QRY")
  setSyncStatus(checkForUpdates and "Checking sync status..." or "Refreshing users...")
  SyncState.refreshAt = (GetTime and (GetTime() + 3)) or 0
  refreshSyncUsersUI()
end

local function sendHello(channel, target)
  local summary = getSyncSummary()
  local classToken = getPlayerClassToken and getPlayerClassToken() or "PRIEST"
  local syncFlag = SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.syncEnabled and "1" or "0"
  local msg = table.concat({"HELLO", summary.user, classToken, tostring(summary.mobs), tostring(summary.opens), tostring(summary.unique), syncFlag}, "\t")
  sendSyncMessage(msg, channel, target)
end

local function parseSyncChatMessage(message)
  if type(message) ~= "string" then return nil end
  if string.sub(message, 1, string.len(SYNC_CHAT_PREFIX)) ~= SYNC_CHAT_PREFIX then return nil end
  return string.sub(message, string.len(SYNC_CHAT_PREFIX) + 1)
end

getPlayerClassToken = function()
  local _, classToken = UnitClass("player")
  return classToken or "PRIEST"
end

local function getClassColor(classToken)
  local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
  if c then return c.r or 1, c.g or 1, c.b or 1 end
  return 0.95, 0.93, 0.88
end

local function applyNameColor(fontString, name, classToken)
  if not fontString then return end
  fontString:SetText(name or "")
  local r, g, b = getClassColor(classToken)
  fontString:SetTextColor(r, g, b)
end

local function updateSyncControlStates()
  local enabled = SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.syncEnabled and true or false
  if UI.refreshUsersButton then
    if enabled then UI.refreshUsersButton:Enable() else UI.refreshUsersButton:Disable() end
    UI.refreshUsersButton:SetAlpha(enabled and 1 or 0.45)
  end
  if UI.syncNowButton then
    if enabled then UI.syncNowButton:Enable() else UI.syncNowButton:Disable() end
    UI.syncNowButton:SetAlpha(enabled and 1 or 0.45)
  end
end

local function startSyncTo(target)
  if not target or target == "" then return end
  local payload = serializeLuaValue(DB.localObserved or {})
  SyncState.seq = (SyncState.seq or 0) + 1
  local id = tostring(time()) .. ":" .. tostring(SyncState.seq)
  local chunkSize = 220
  local total = math.ceil(string.len(payload) / chunkSize)
  sendSyncMessage(table.concat({"BEGIN", id, tostring(total)}, "	"), "WHISPER", target)
  for i = 1, total do
    local chunk = string.sub(payload, (i - 1) * chunkSize + 1, i * chunkSize)
    sendSyncMessage(table.concat({"DATA", id, tostring(i), chunk}, "	"), "WHISPER", target)
  end
  sendSyncMessage(table.concat({"END", id}, "	"), "WHISPER", target)
  setSyncStatus("Sent data to " .. target)
end

local function sendSyncCheckManifestTo(target)
  if not target or target == "" then return end
  local payload = serializeLuaValue(buildSyncCheckManifest())
  SyncState.seq = (SyncState.seq or 0) + 1
  local id = tostring(time()) .. ":check:" .. tostring(SyncState.seq)
  local chunkSize = 220
  local total = math.ceil(string.len(payload) / chunkSize)
  sendSyncMessage(table.concat({"BEGINCHECK", id, tostring(total)}, "	"), "WHISPER", target)
  for i = 1, total do
    local chunk = string.sub(payload, (i - 1) * chunkSize + 1, i * chunkSize)
    sendSyncMessage(table.concat({"CHECKDATA", id, tostring(i), chunk}, "	"), "WHISPER", target)
  end
  sendSyncMessage(table.concat({"ENDCHECK", id}, "	"), "WHISPER", target)
end

refreshSyncUsersUI = function()
  if not UI.syncRows or not UI.syncScroll then return end
  local list = {}
  local now = GetTime and GetTime() or 0
  local filtered = {}
  for userName, user in pairs(SyncState.users or {}) do
    local lastSeen = tonumber(user.lastSeen) or 0
    local active = (lastSeen > 0) and ((now - lastSeen) <= SYNC_USER_TTL) and (user.syncEnabled ~= false)
    if active then
      filtered[userName] = user
      table.insert(list, user)
    end
  end
  SyncState.users = filtered
  if SyncState.selected and not SyncState.users[SyncState.selected] then
    SyncState.selected = nil
  end
  table.sort(list, function(a, b) return string.lower(a.user or "") < string.lower(b.user or "") end)
  FauxScrollFrame_Update(UI.syncScroll, #list, #UI.syncRows, 22)
  local offset = FauxScrollFrame_GetOffset(UI.syncScroll)
  for i, row in ipairs(UI.syncRows) do
    local data = list[i + offset]
    if data then
      row.data = data
      applyNameColor(row.cols[1], data.user or "", data.class)
      row.cols[2]:SetText(tostring(data.mobs or 0))
      row.cols[3]:SetText(tostring(data.opens or 0))
      row.cols[4]:SetText(tostring(data.unique or 0))
      if row.cols[5] then
        if data.checkPending then
          row.cols[5]:SetText("Checking")
          row.cols[5]:SetTextColor(0.4313725490196079, 0.8470588235294118, 1)
        else
          local toSync = tonumber(data.toSync) or 0
          row.cols[5]:SetText(tostring(toSync))
          if toSync > 0 then
            row.cols[5]:SetTextColor(1, 0.82, 0)
          else
            row.cols[5]:SetTextColor(0.25, 1.00, 0.25)
          end
        end
      end
      if row.cols[6] then
        local trustLabel, trustR, trustG, trustB = getSyncTrustDisplay(data)
        row.cols[6]:SetText(trustLabel)
        row.cols[6]:SetTextColor(trustR, trustG, trustB)
      end
      if SyncState.selected == data.user then
        row.bg:SetVertexColor(0.32, 0.24, 0.09, 0.90)
      elseif (i + offset) % 2 == 0 then
        row.bg:SetVertexColor(1, 1, 1, 0.035)
      else
        row.bg:SetVertexColor(0, 0, 0, 0)
      end
      row:Show()
    else
      row.data = nil
      row:Hide()
    end
  end
  if UI.syncSelectedValue then
    local selectedUser = SyncState.selected and SyncState.users and SyncState.users[SyncState.selected]
    if selectedUser then
      applyNameColor(UI.syncSelectedValue, selectedUser.user or "", selectedUser.class)
    else
      UI.syncSelectedValue:SetText("None")
      UI.syncSelectedValue:SetTextColor(0.95,0.93,0.88)
    end
  end
  if UI.syncStatusValue then UI.syncStatusValue:SetText(SyncState.status or "Idle") end
  if UI.syncLastValue then UI.syncLastValue:SetText(SyncState.lastSync or "Never") end
  if UI.syncCurrentUser then applyNameColor(UI.syncCurrentUser, getPlayerNameClean(), getPlayerClassToken()) end
  updateSyncControlStates()
end

refreshSaveSlotsUI = function()
  if not UI.saveRows or not UI.saveScroll then return end
  local list = collectSnapshots()
  FauxScrollFrame_Update(UI.saveScroll, #list, #UI.saveRows, 22)
  local offset = FauxScrollFrame_GetOffset(UI.saveScroll)
  for i, row in ipairs(UI.saveRows) do
    local data = list[i + offset]
    if data then
      row.data = data
      local label = data.name or "Unnamed"
      if data.isAuto then label = label .. " |cff88ccff[AUTO]|r" end
      row.cols[1]:SetText(label)
      row.cols[2]:SetText(data.savedText or "-")
      row.cols[3]:SetText(tostring(data.mobs or 0))
      row.cols[4]:SetText(tostring(data.opens or 0))
      if SaveState.selected == data.name then
        row.bg:SetVertexColor(0.32, 0.24, 0.09, 0.90)
      elseif (i + offset) % 2 == 0 then
        row.bg:SetVertexColor(1, 1, 1, 0.035)
      else
        row.bg:SetVertexColor(0, 0, 0, 0)
      end
      row:Show()
    else
      row.data = nil
      row:Hide()
    end
  end
  if UI.saveSelectedValue then UI.saveSelectedValue:SetText(SaveState.selected or "None") end
  if UI.saveStatusValue then UI.saveStatusValue:SetText(SaveState.status or "Idle") end
end

local function handleSyncMessage(prefix, message, channel, sender)
  if prefix ~= SYNC_PREFIX then return end
  sender = getPlayerNameClean(sender)
  if sender == getPlayerNameClean() then return end
  local parts = {}
  for part in string.gmatch(message or "", "([^	]+)") do table.insert(parts, part) end
  local cmd = parts[1]
  if cmd == "QRY" then
    if SepheransDropInfoDB.settings.syncEnabled then
      sendHello("WHISPER", sender)
    end
  elseif cmd == "HELLO" then
    local user = getPlayerNameClean(parts[2] or sender)
    local classToken, mobsIdx = parts[3], 4
    if classToken and tonumber(classToken) then
      classToken, mobsIdx = nil, 3
    end
    local syncIdx = mobsIdx + 3
    if parts[syncIdx] ~= "0" and parts[syncIdx] ~= "1" then
      syncIdx = syncIdx + 1
    end
    local remoteMobs = tonumber(parts[mobsIdx]) or 0
    local remoteOpens = tonumber(parts[mobsIdx + 1]) or 0
    local remoteUnique = tonumber(parts[mobsIdx + 2]) or 0
    local previous = SyncState.users[user] or {}
    local sameSummary = previous.mobs == remoteMobs and previous.opens == remoteOpens and previous.unique == remoteUnique
    local estimatedToSync = getEstimatedSyncMobCount(sender, remoteMobs)
    local storedFlag = getStoredSyncFlag(sender) or getStoredSyncFlag(user)
    SyncState.users[user] = {
      user = user,
      sender = sender,
      class = classToken,
      mobs = remoteMobs,
      opens = remoteOpens,
      unique = remoteUnique,
      toSync = (sameSummary and previous.toSync) or estimatedToSync,
      checkPending = sameSummary and previous.checkPending and true or false,
      checkedAt = sameSummary and previous.checkedAt or nil,
      trustSeverity = (sameSummary and previous.trustSeverity) or (storedFlag and storedFlag.severity) or "unknown",
      trustLabel = (sameSummary and previous.trustLabel) or (storedFlag and storedFlag.label) or "Unknown",
      trustIssues = (sameSummary and previous.trustIssues) or (storedFlag and storedFlag.issues) or 0,
      suspiciousMobs = (sameSummary and previous.suspiciousMobs) or (storedFlag and storedFlag.suspiciousMobs) or 0,
      reviewMobs = (sameSummary and previous.reviewMobs) or (storedFlag and storedFlag.reviewMobs) or 0,
      quarantined = (sameSummary and previous.quarantined) or (storedFlag and storedFlag.quarantined) or false,
      syncEnabled = (parts[syncIdx] ~= "0"),
      lastSeen = GetTime and GetTime() or 0
    }
    if SyncState.checkRequested and SyncState.users[user].syncEnabled then
      SyncState.checkRequestedUsers = SyncState.checkRequestedUsers or {}
      if not SyncState.checkRequestedUsers[user] then
        SyncState.checkRequestedUsers[user] = true
        SyncState.users[user].checkPending = true
        sendSyncMessage("REQCHECK", "WHISPER", sender)
      end
    end
    refreshSyncUsersUI()
    if SyncState.status == "Refreshing users..." then setSyncStatus("Idle") end
  elseif cmd == "REQSYNC" then
    if SepheransDropInfoDB.settings.syncEnabled then startSyncTo(sender) end
  elseif cmd == "REQCHECK" then
    if SepheransDropInfoDB.settings.syncEnabled then sendSyncCheckManifestTo(sender) end
  elseif cmd == "BEGIN" then
    local id = parts[2]
    SyncState.pending[id] = { sender = sender, total = tonumber(parts[3]) or 0, parts = {} }
    setSyncStatus("Receiving sync from " .. sender)
  elseif cmd == "DATA" then
    local id = parts[2]
    local idx = tonumber(parts[3]) or 0
    local prefixText = parts[1] .. "	" .. parts[2] .. "	" .. parts[3] .. "	"
    local payload = string.sub(message, string.len(prefixText) + 1)
    if SyncState.pending[id] then SyncState.pending[id].parts[idx] = payload end
  elseif cmd == "END" then
    local id = parts[2]
    local pending = SyncState.pending[id]
    if pending then
      SyncState.pending[id] = nil
      local buf = {}
      for i = 1, pending.total do buf[i] = pending.parts[i] or "" end
      local data = deserializeLuaTable(table.concat(buf))
      if data then
        local mobsChanged, itemsChanged, report, quarantined = mergeObservedData(sender, data)
        report = report or newSyncTrustReport()
        setSyncUserTrustReport(sender, report)
        if quarantined then
          setSyncUserCheckResult(sender, mobsChanged, false)
          setSyncStatus("Quarantined sync from " .. sender .. " (" .. tostring(report.issues or 0) .. " flags)")
          setSyncLast("Blocked " .. date("%H:%M:%S") .. " from " .. sender)
          addLog("sync_quarantine", { from = sender, mobs = mobsChanged, items = itemsChanged, issues = report.issues })
        else
          setSyncUserCheckResult(sender, 0, false)
          if report.severity == "review" then
            setSyncStatus("Merged with review flags: " .. tostring(report.issues or 0))
          else
            setSyncStatus("Merged " .. tostring(mobsChanged) .. " mobs / " .. tostring(itemsChanged) .. " items")
          end
          setSyncLast(date("%H:%M:%S") .. " from " .. sender)
          addLog("sync_import", { from = sender, mobs = mobsChanged, items = itemsChanged, trust = report.severity, issues = report.issues })
        end
        refreshMobList()
        refreshSyncUsersUI()
      else
        setSyncStatus("Sync failed from " .. sender)
      end
    end
  elseif cmd == "BEGINCHECK" then
    local id = parts[2]
    SyncState.pending[id] = { sender = sender, total = tonumber(parts[3]) or 0, parts = {}, kind = "check" }
  elseif cmd == "CHECKDATA" then
    local id = parts[2]
    local idx = tonumber(parts[3]) or 0
    local prefixText = parts[1] .. "	" .. parts[2] .. "	" .. parts[3] .. "	"
    local payload = string.sub(message, string.len(prefixText) + 1)
    if SyncState.pending[id] then SyncState.pending[id].parts[idx] = payload end
  elseif cmd == "ENDCHECK" then
    local id = parts[2]
    local pending = SyncState.pending[id]
    if pending then
      SyncState.pending[id] = nil
      local buf = {}
      for i = 1, pending.total do buf[i] = pending.parts[i] or "" end
      local data = deserializeLuaTable(table.concat(buf))
      local userState = findSyncUserState(sender)
      local mobsToSync = countMobsNeedingSync(sender, data, userState and userState.mobs)
      local report = analyzeSyncCheckManifest(sender, data, userState and userState.mobs)
      rememberSyncFlag(sender, report)
      setSyncUserCheckResult(sender, mobsToSync, false)
      setSyncUserTrustReport(sender, report)
      setSyncStatus("Sync check: " .. tostring(mobsToSync) .. " mobs from " .. sender)
      refreshSyncUsersUI()
    end
  end
end

local function mobListData()
  ensureRealmDB()
  local list = {}
  local search = normalizeSearch(UI.searchText)
  for npcID, rec in pairs(DB.observed or {}) do
    local matches = true
    if search ~= "" then
      matches = false
      local mobName = normalizeSearch(rec.name)
      if string.find(mobName, search, 1, true) then
        matches = true
      else
        for _, item in pairs(rec.items or {}) do
          local itemText = normalizeSearch(item.link or item.name)
          if string.find(itemText, search, 1, true) then
            matches = true
            break
          end
        end
      end
    end
    if matches then
      table.insert(list, { npcID = npcID, rec = rec })
    end
  end
  local sortMode = getCurrentSortMode()
  table.sort(list, function(a, b)
    if sortMode == "opens" then
      local av = tonumber(a.rec.opens) or 0
      local bv = tonumber(b.rec.opens) or 0
      if av ~= bv then return av > bv end
    elseif sortMode == "money" then
      local av = tonumber(a.rec.totalMoney) or 0
      local bv = tonumber(b.rec.totalMoney) or 0
      if av ~= bv then return av > bv end
    end
    local an = string.lower(a.rec.name or "")
    local bn = string.lower(b.rec.name or "")
    if an ~= bn then return an < bn end
    return tostring(a.npcID) < tostring(b.npcID)
  end)
  return list
end


local function getTotalOpenCount()
  ensureRealmDB()
  local total = 0
  for _, rec in pairs(DB.observed or {}) do
    total = total + (tonumber(rec.opens) or 0)
  end
  return total
end

local function buildAnalyticsRows()

  ensureRealmDB()

  local totalMobs = 0
  local totalOpens = 0
  local totalMoney = 0
  local mobStats = {}
  local itemStats = {}

  for npcID, rec in pairs(DB.observed or {}) do
    totalMobs = totalMobs + 1
    totalOpens = totalOpens + (tonumber(rec.opens) or 0)
    totalMoney = totalMoney + (tonumber(rec.totalMoney) or 0)

    table.insert(mobStats, {
      npcID = npcID,
      name = rec.name or ("NPC " .. tostring(npcID)),
      opens = tonumber(rec.opens) or 0,
      money = tonumber(rec.totalMoney) or 0,
      unique = countUniqueItems(rec),
      avgMoney = ((tonumber(rec.opens) or 0) > 0) and math.floor((tonumber(rec.totalMoney) or 0) / (tonumber(rec.opens) or 1)) or 0,
    })

    for key, item in pairs(rec.items or {}) do
      local stat = itemStats[key]
      if not stat then
        stat = {
          key = key,
          name = item.name or key,
          link = item.link,
          seen = 0,
          totalQty = 0,
          mobCount = 0,
        }
        itemStats[key] = stat
      end
      stat.seen = stat.seen + (tonumber(item.seen) or 0)
      stat.totalQty = stat.totalQty + (tonumber(item.totalQty) or 0)
      stat.mobCount = stat.mobCount + 1
      if not stat.link and item.link then
        stat.link = item.link
      end
    end
  end

  table.sort(mobStats, function(a, b)
    if a.opens ~= b.opens then return a.opens > b.opens end
    return tostring(a.name) < tostring(b.name)
  end)
  local richestMobs = {}
  for i = 1, #mobStats do richestMobs[i] = mobStats[i] end
  table.sort(richestMobs, function(a, b)
    if a.money ~= b.money then return a.money > b.money end
    return tostring(a.name) < tostring(b.name)
  end)
  local efficientMobs = {}
  for i = 1, #mobStats do efficientMobs[i] = mobStats[i] end
  table.sort(efficientMobs, function(a, b)
    if a.avgMoney ~= b.avgMoney then return a.avgMoney > b.avgMoney end
    if a.opens ~= b.opens then return a.opens > b.opens end
    return tostring(a.name) < tostring(b.name)
  end)

  local items = {}
  for _, stat in pairs(itemStats) do
    table.insert(items, stat)
  end
  table.sort(items, function(a, b)
    if a.seen ~= b.seen then return a.seen > b.seen end
    if a.totalQty ~= b.totalQty then return a.totalQty > b.totalQty end
    return tostring(a.name) < tostring(b.name)
  end)

  local avgMoney = 0
  if totalOpens > 0 then
    avgMoney = math.floor(totalMoney / totalOpens)
  end

  local rows = {}
  table.insert(rows, { kind = "header", left = "Overview", right = "Value" })
  table.insert(rows, { kind = "line", left = "Observed mobs", right = tostring(totalMobs) })
  table.insert(rows, { kind = "line", left = "Loot opens", right = tostring(totalOpens) })
  table.insert(rows, { kind = "line", left = "Total coin", right = formatMoney(totalMoney) })
  table.insert(rows, { kind = "line", left = "Average coin per open", right = formatMoney(avgMoney) })
  table.insert(rows, { kind = "line", left = "Unique items seen", right = tostring(#items) })

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Session", right = "Value" })
  table.insert(rows, { kind = "line", left = "Session opens", right = tostring(Session.opens or 0) })
  table.insert(rows, { kind = "line", left = "Session money", right = formatMoney(Session.money or 0) })
  table.insert(rows, { kind = "line", left = "New mobs this session", right = tostring(Session.newMobs or 0) })
  table.insert(rows, { kind = "line", left = "New items this session", right = tostring(Session.newItems or 0) })

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Top mobs by opens", right = "Opens" })
  if #mobStats == 0 then
    table.insert(rows, { kind = "line", left = "No mob data yet", right = "--" })
  else
    for i = 1, math.min(5, #mobStats) do
      local m = mobStats[i]
      table.insert(rows, { kind = "line", left = m.name, right = tostring(m.opens) })
    end
  end

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Richest mobs", right = "Coin" })
  if #richestMobs == 0 then
    table.insert(rows, { kind = "line", left = "No money data yet", right = "--" })
  else
    for i = 1, math.min(5, #richestMobs) do
      local m = richestMobs[i]
      table.insert(rows, { kind = "line", left = m.name, right = formatMoney(m.money) })
    end
  end

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Best average coin per open", right = "Avg" })
  local addedEfficient = 0
  for i = 1, #efficientMobs do
    local m = efficientMobs[i]
    if m.opens > 0 then
      table.insert(rows, { kind = "line", left = m.name, right = formatMoney(m.avgMoney) })
      addedEfficient = addedEfficient + 1
      if addedEfficient >= 5 then break end
    end
  end
  if addedEfficient == 0 then
    table.insert(rows, { kind = "line", left = "Not enough loot data yet", right = "--" })
  end

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Top items seen", right = "Seen" })
  if #items == 0 then
    table.insert(rows, { kind = "line", left = "No item data yet", right = "--" })
  else
    for i = 1, math.min(8, #items) do
      local item = items[i]
      table.insert(rows, { kind = "line", left = item.link or item.name or "Unknown", right = tostring(item.seen), itemLink = item.link })
    end
  end

  return rows, totalMobs, totalOpens, totalMoney, #items
end

local function plainExportText(text)
  text = tostring(text or "")
  text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
  text = string.gsub(text, "|r", "")
  text = string.gsub(text, "|H.-|h%[(.-)%]|h", "%1")
  text = string.gsub(text, "|T.-|t", "")
  return text
end

local function buildDatabaseExportText()
  ensureRealmDB()
  rebuildAggregateObserved()

  local observed = DB.observed or DB.localObserved or {}
  local mobs = {}
  local totalMobs, totalOpens, totalItems = getObservedSummary(observed)
  local totalMoney = 0

  for npcID, rec in pairs(observed) do
    if type(rec) == "table" then
      totalMoney = totalMoney + (tonumber(rec.totalMoney) or 0)
      table.insert(mobs, { npcID = npcID, rec = rec })
    end
  end
  table.sort(mobs, function(a, b)
    local an = string.lower(tostring((a.rec and a.rec.name) or ""))
    local bn = string.lower(tostring((b.rec and b.rec.name) or ""))
    if an ~= bn then return an < bn end
    return tostring(a.npcID) < tostring(b.npcID)
  end)

  local lines = {}
  table.insert(lines, "Sepheran's Drop Info Export")
  table.insert(lines, "Realm: " .. tostring(REALM_KEY or "Unknown"))
  table.insert(lines, "Generated: " .. date("%Y-%m-%d %H:%M:%S"))
  table.insert(lines, string.format("Observed mobs: %d", totalMobs))
  table.insert(lines, string.format("Loot opens: %d", totalOpens))
  table.insert(lines, string.format("Unique observed items: %d", totalItems))
  table.insert(lines, string.format("Total coin: %s", plainExportText(formatMoney(totalMoney or 0))))
  table.insert(lines, "")

  if #mobs == 0 then
    table.insert(lines, "No observed mobs yet.")
  else
    for _, entry in ipairs(mobs) do
      local rec = entry.rec or {}
      local opens = tonumber(rec.opens) or 0
      table.insert(lines, tostring(rec.name or "Unknown") .. " (ID " .. tostring(entry.npcID) .. ")")
      table.insert(lines, "  Loot opens: " .. tostring(opens))
      table.insert(lines, "  Primary zone: " .. plainExportText(getPrimaryZone(rec)))
      table.insert(lines, "  Drops:")

      local items = buildSortedItems(rec)
      if #items == 0 then
        table.insert(lines, "    No observed item drops")
      else
        for _, item in ipairs(items) do
          local label = plainExportText(item.name or item.link or "Unknown")
          local pct = 0
          if opens > 0 then pct = ((tonumber(item.seen) or 0) / opens) * 100 end
          table.insert(lines, string.format("    - %s: %.1f%% (%d/%d)", label, pct, tonumber(item.seen) or 0, opens))
        end
      end
      table.insert(lines, "")
    end
  end

  return table.concat(lines, "\n")
end

local function refreshExportPanel(forceNew)
  if not SepheransDropInfoDB then ensureRootDB() end
  local exportText = SepheransDropInfoDB.lastExportText
  if forceNew or type(exportText) ~= "string" or exportText == "" then
    exportText = buildDatabaseExportText()
    SepheransDropInfoDB.lastExportText = exportText
    SepheransDropInfoDB.lastExportedAt = date("%Y-%m-%d %H:%M:%S")
  end
  if UI.exportBox then
    UI.exportBox:SetText(exportText)
    UI.exportBox:SetCursorPosition(0)
  end
  if UI.exportStatusValue then
    UI.exportStatusValue:SetText("Last export: " .. tostring(SepheransDropInfoDB.lastExportedAt or "Never"))
  end
end


local function applyTabLayout()
  if not UI.frame or not UI.leftPane or not UI.rightPane then return end

  if isAnalyticsTab() or isSyncTab() or isSavesTab() or isExportTab() then
    UI.leftPane:Hide()
    UI.rightPane:ClearAllPoints()
    UI.rightPane:SetPoint("TOPLEFT", UI.workspace, "TOPLEFT", 14, -78)
    UI.rightPane:SetPoint("BOTTOMRIGHT", UI.workspace, "BOTTOMRIGHT", -14, 14)
    if UI.sortButton then UI.sortButton:Hide() end
    if UI.searchBox then UI.searchBox:Hide() end
    if UI.workspaceTitle then
      if isAnalyticsTab() then
        UI.workspaceTitle:SetText("Analytics")
        UI.workspaceSub:SetText("High-level stats and drop observations.")
      elseif isSyncTab() then
        UI.workspaceTitle:SetText("Sync")
        UI.workspaceSub:SetText("Discover users and exchange raw observed data.")
      elseif isExportTab() then
        UI.workspaceTitle:SetText("Export")
        UI.workspaceSub:SetText("Create a readable text copy of the observed database.")
      else
        UI.workspaceTitle:SetText("Saves")
        UI.workspaceSub:SetText("Manage snapshots and restore stored databases.")
      end
    end
  else
    UI.leftPane:Show()
    UI.rightPane:ClearAllPoints()
    UI.rightPane:SetPoint("TOPLEFT", UI.workspace, "TOPLEFT", 414, -78)
    UI.rightPane:SetPoint("BOTTOMRIGHT", UI.workspace, "BOTTOMRIGHT", -14, 14)
    if UI.sortButton then UI.sortButton:Show() end
    if UI.searchBox then UI.searchBox:Show() end
    if UI.workspaceTitle then
      UI.workspaceTitle:SetText("Observed data")
      UI.workspaceSub:SetText("Browse creatures on the left and inspect observed drops on the right.")
    end
  end

  if UI.syncPanel then
    if isSyncTab() then UI.syncPanel:Show() else UI.syncPanel:Hide() end
  end
  if UI.savePanel then
    if isSavesTab() then UI.savePanel:Show() else UI.savePanel:Hide() end
  end
  if UI.exportPanel then
    if isExportTab() then UI.exportPanel:Show() else UI.exportPanel:Hide() end
  end

  for i = 1, #(UI.detailRows or {}) do
    local row = UI.detailRows[i]
    if row then
      row:SetWidth((isAnalyticsTab() or isSyncTab() or isSavesTab() or isExportTab()) and (row._analyticsWidth or 748) or (row._browserWidth or 500))
    end
  end
end

local function refreshDetailPanel()

  if not UI.frame or not UI.detailTitle then return end

  if isSyncTab() then
    UI.detailTitle:SetText("Synchronization")
    UI.detailMeta:SetText("Discover addon users and sync with the selected row.")
    UI.detailMeta:Show()
    for i = 1, #UI.detailRows do UI.detailRows[i]:Hide() end
    refreshSyncUsersUI()
    return
  end

  if isSavesTab() then
    UI.detailTitle:SetText("Database Saves")
    UI.detailMeta:SetText("Save the current realm database, load older snapshots, or rely on login autosave as a fallback.")
    UI.detailMeta:Show()
    for i = 1, #UI.detailRows do UI.detailRows[i]:Hide() end
    if refreshSaveSlotsUI then refreshSaveSlotsUI() end
    return
  end

  if isExportTab() then
    UI.detailTitle:SetText("Export Database")
    UI.detailMeta:SetText("Generate a plain text view of observed mobs and item drop rates.")
    UI.detailMeta:Show()
    for i = 1, #UI.detailRows do UI.detailRows[i]:Hide() end
    refreshExportPanel(false)
    return
  end

  if isAnalyticsTab() then
    local rows, totalMobs, totalOpens, totalMoney, totalItems = buildAnalyticsRows()
    UI.detailTitle:SetText("Analytics")
    UI.detailMeta:SetText(string.format("Mobs: %d    Opens: %d    Coin: %s    Unique items: %d", totalMobs, totalOpens, formatMoney(totalMoney), totalItems))
    UI.detailMeta:Show()

    FauxScrollFrame_Update(UI.detailScroll, #rows, #UI.detailRows, 20)
    local offset = FauxScrollFrame_GetOffset(UI.detailScroll)
    for i = 1, #UI.detailRows do
      local row = UI.detailRows[i]
      local data = rows[i + offset]
      if data then
        data._rowIndex = i + offset
        row.data = data
        row.itemLink = data.itemLink
        row.left:SetText(data.left or "")
        row.right:SetText(data.right or "")
        styleAlternateDataRow(row, data.kind, i + offset)
        if data.kind == "header" then
          row.left:SetTextColor(1, 0.82, 0)
          row.right:SetTextColor(1, 0.82, 0)
        elseif data.kind == "spacer" then
          row.left:SetText(" ")
          row.right:SetText("")
        else
          row.left:SetTextColor(0.95, 0.93, 0.88)
          row.right:SetTextColor(0.65, 0.85, 1)
        end
        row:Show()
      else
        row.data = nil
        row.itemLink = nil
        row:Hide()
      end
    end
    return
  end

  local entry = UI.selectedEntry
  if not entry then
    UI.detailTitle:SetText("Select a mob")
    UI.detailMeta:SetText("Choose a creature on the left to inspect observed drops. Switch to Analytics for global stats.")
    UI.detailMeta:Show()
    for i = 1, #UI.detailRows do
      UI.detailRows[i]:Hide()
    end
    return
  end

  local rec = entry.rec
  local zone = getPrimaryZone(rec)
  local avgMoney = 0
  if (rec.opens or 0) > 0 then
    avgMoney = math.floor((rec.totalMoney or 0) / rec.opens)
  end

  UI.detailTitle:SetText(rec.name or "Unknown")
  UI.detailMeta:SetText(string.format("Primary zone: %s    Loot opens: %d    Unique items: %d", zone, rec.opens or 0, countUniqueItems(rec)))
  UI.detailMeta:Show()

  local rows = {}
  table.insert(rows, { kind = "header", left = "Observed loot", right = "Drop rate" })
  table.insert(rows, { kind = "line", left = "Unique observed items", right = tostring(countUniqueItems(rec)) })
  local items = buildSortedItems(rec)
  if #items == 0 then
    table.insert(rows, { kind = "line", left = "No observed items yet", right = "--" })
  else
    for _, item in ipairs(items) do
      local label = item.link or item.name or "Unknown"
      table.insert(rows, {
        kind = "line",
        left = label,
        right = string.format("%.1f%%", item.dropPct or 0),
        itemLink = item.link,
        itemData = {
          key = select(2, makeItemSyncKey(item.link or item.name or label, item)),
          itemID = item.itemID,
          name = item.name,
          link = item.link,
          seen = item.seen,
          totalQty = item.totalQty,
        },
      })
    end
  end

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Money", right = "Value" })
  table.insert(rows, { kind = "line", left = "Total coin", right = formatMoney(rec.totalMoney or 0) })
  table.insert(rows, { kind = "line", left = "Average per open", right = formatMoney(avgMoney) })

  table.insert(rows, { kind = "spacer", left = "", right = "" })
  table.insert(rows, { kind = "header", left = "Zones seen", right = "Count" })
  local zoneRows = {}
  for z, count in pairs(rec.zones or {}) do
    table.insert(zoneRows, { zone = z, count = count })
  end
  table.sort(zoneRows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.zone < b.zone
  end)
  if #zoneRows == 0 then
    table.insert(rows, { kind = "line", left = "No zone data", right = "--" })
  else
    for _, z in ipairs(zoneRows) do
      table.insert(rows, { kind = "line", left = z.zone, right = tostring(z.count) })
    end
  end

  FauxScrollFrame_Update(UI.detailScroll, #rows, #UI.detailRows, 20)
  local offset = FauxScrollFrame_GetOffset(UI.detailScroll)
  for i = 1, #UI.detailRows do
    local row = UI.detailRows[i]
    local data = rows[i + offset]
    if data then
      data._rowIndex = i + offset
      row.data = data
      row.itemLink = data.itemLink
      row.left:SetText(data.left or "")
      row.right:SetText(data.right or "")
      data._rowIndex = i + offset
      styleAlternateDataRow(row, data.kind, i + offset)
      if data.kind == "header" then
        row.left:SetTextColor(1, 0.82, 0)
        row.right:SetTextColor(1, 0.82, 0)
      elseif data.kind == "spacer" then
        row.left:SetText(" ")
        row.right:SetText("")
      else
        row.left:SetTextColor(0.95, 0.93, 0.88)
        row.right:SetTextColor(0.65, 0.85, 1)
      end
      row:Show()
    else
      row.data = nil
      row.itemLink = nil
      row:Hide()
    end
  end
end

refreshItemInfoPopup = function()
  if not UI or not UI.itemInfoFrame or not UI.itemInfoTitle or not UI.itemInfoRows then return end

  local itemData = UI.itemInfoData
  if not itemData then
    UI.itemInfoTitle:SetText("Item details")
    UI.itemInfoMeta:SetText("Click an observed item to inspect where it drops.")
    if UI.itemInfoIcon then
      UI.itemInfoIcon:SetTexture("Interface\Icons\INV_Misc_QuestionMark")
    end
    for i = 1, #(UI.itemInfoRows or {}) do
      UI.itemInfoRows[i]:Hide()
    end
    return
  end

  local sources, summary = buildObservedItemSourceRows(itemData)
  local titleText = getItemDisplayLabel(itemData)
  UI.itemInfoTitle:SetText(titleText)
  if UI.itemInfoSortButton and UI.itemInfoSortButton.text then
    UI.itemInfoSortButton.text:SetText("Sort: " .. (getItemInfoSortMode() == "opens" and "Opens" or "Drop rate"))
  end
  if UI.itemInfoIcon then
    UI.itemInfoIcon:SetTexture(getItemIconTexture(itemData) or "Interface\Icons\INV_Misc_QuestionMark")
    UI.itemInfoIcon.itemData = itemData
  end
  if UI.itemInfoIconFrame then
    UI.itemInfoIconFrame.itemData = itemData
  end
  if summary then
    UI.itemInfoMeta:SetText(string.format("Observed on %d mobs    Seen %d times    Total qty %d", summary.mobCount or 0, summary.totalSeen or 0, summary.totalQty or 0))
  else
    UI.itemInfoMeta:SetText("No observed sources for this item yet.")
  end

  FauxScrollFrame_Update(UI.itemInfoScroll, #sources, #UI.itemInfoRows, 22)
  local offset = FauxScrollFrame_GetOffset(UI.itemInfoScroll)
  for i = 1, #UI.itemInfoRows do
    local row = UI.itemInfoRows[i]
    local data = sources[i + offset]
    if data then
      row.left:SetText(data.mobName or "Unknown mob")
      row.right:SetText(string.format("%.1f%%", data.dropPct or 0))
      row.meta:SetText(string.format("Seen %d/%d opens   Qty %d   %s", data.seen or 0, data.opens or 0, data.totalQty or 0, data.zone or "Unknown zone"))
      styleAlternateDataRow(row, "line", i + offset)
      row:Show()
    else
      row:Hide()
    end
  end
end

openItemInfoPopup = function(itemData)
  if not itemData then return end
  if not UI or not UI.itemInfoFrame then return end
  UI.itemInfoData = {
    key = itemData.key,
    itemID = itemData.itemID,
    name = itemData.name,
    link = itemData.link,
    seen = itemData.seen,
    totalQty = itemData.totalQty,
  }
  if UI.itemInfoScroll then
    if FauxScrollFrame_SetOffset then
      FauxScrollFrame_SetOffset(UI.itemInfoScroll, 0)
    else
      UI.itemInfoScroll.offset = 0
    end
  end
  if UI.itemInfoFrame:IsShown() then
    UI.itemInfoFrame:Raise()
  else
    UI.itemInfoFrame:ClearAllPoints()
    if UI.frame and UI.frame:IsShown() then
      UI.itemInfoFrame:SetPoint("CENTER", UI.frame, "CENTER", 120, -10)
    else
      UI.itemInfoFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    UI.itemInfoFrame:Show()
  end
  refreshItemInfoPopup()
end

refreshMobList = function()
  if not UI.frame then return end
  applyTabLayout()
  UI.mobData = mobListData()
  if UI.selectedEntry then
    local stillExists
    for _, entry in ipairs(UI.mobData) do
      if entry.npcID == UI.selectedEntry.npcID then
        stillExists = entry
        break
      end
    end
    UI.selectedEntry = stillExists
  end
  if UI.summaryText then
    UI.summaryText:SetText(string.format("Mobs: %d   Opens: %d   Unique items: %d", #UI.mobData, getTotalOpenCount(), getGlobalUniqueItemCount()))
  end
  if UI.sortButton and UI.sortButton.text then
    UI.sortButton.text:SetText("" .. getSortLabel(getCurrentSortMode()))
  end
  if UI.browserTab and UI.analyticsTab and UI.syncTab and UI.savesTab and UI.exportTab then
    local active = getActiveTab()
    local tabs = { { UI.browserTab, active == "browser" }, { UI.analyticsTab, active == "analytics" }, { UI.syncTab, active == "sync" }, { UI.savesTab, active == "saves" }, { UI.exportTab, active == "export" } }
    for _, pair in ipairs(tabs) do
      local tab, isActive = pair[1], pair[2]
      local borderR, borderG, borderB = getStoredUIColor("border", 0.4509803921568628, 0.6, 0.8509803921568627)
      local accentR, accentG, accentB = getStoredUIColor("accent", 0.4313725490196079, 0.8470588235294118, 1)
      local bgR, bgG, bgB = getStoredUIColor("bg", 0.03137254901960784, 0.04313725490196078, 0.08235294117647059)
      if isActive then
        tab.bg:SetVertexColor(accentR * 0.40, accentG * 0.40, accentB * 0.40, 0.95)
        tab:SetBackdropBorderColor(accentR, accentG, accentB, 1)
        if tab.text then tab.text:SetTextColor(1, 1, 1) end
      else
        tab.bg:SetVertexColor(bgR + 0.04, bgG + 0.05, bgB + 0.07, 0.92)
        tab:SetBackdropBorderColor(borderR * 0.5, borderG * 0.5, borderB * 0.5, 1)
        if tab.text then tab.text:SetTextColor(0.82, 0.88, 0.96) end
      end
    end
  end
  if UI.sessionText then
    UI.sessionText:SetText(getSessionSummaryText())
  end
  if not isAnalyticsTab() and not isSyncTab() and not isSavesTab() then
    local rowTheme = getMobRowThemeColors()
    local visibleRows = UI.visibleMobRows or #UI.listButtons
    FauxScrollFrame_Update(UI.listScroll, #UI.mobData, visibleRows, 22)
    local offset = FauxScrollFrame_GetOffset(UI.listScroll)
    for i = 1, #UI.listButtons do
      local btn = UI.listButtons[i]
      local entry = (i <= visibleRows) and UI.mobData[i + offset] or nil
      if entry then
      btn.entry = entry
      local extra = ""
      local sortMode = getCurrentSortMode()
      if sortMode == "opens" then
        extra = string.format("  |cffffd100[%d]|r", entry.rec.opens or 0)
      elseif sortMode == "money" then
        extra = string.format("  |cffffd100[%s]|r", formatMoney(entry.rec.totalMoney or 0))
      end
      btn.text:SetText((entry.rec.name or ("NPC " .. tostring(entry.npcID))) .. extra)
      if UI.selectedEntry and UI.selectedEntry.npcID == entry.npcID then
        btn.bg:SetVertexColor(rowTheme.selectedR, rowTheme.selectedG, rowTheme.selectedB, 0.90)
        btn:SetBackdropBorderColor(1, 0.82, 0, 1)
        btn.text:SetTextColor(1, 0.95, 0.8)
      else
        btn.bg:SetVertexColor(rowTheme.baseR, rowTheme.baseG, rowTheme.baseB, 0.75)
        btn:SetBackdropBorderColor(rowTheme.borderR, rowTheme.borderG, rowTheme.borderB, 1)
        btn.text:SetTextColor(0.91, 0.94, 0.98)
      end
      btn:Show()
    else
      btn.entry = nil
        btn:Hide()
      end
    end
  else
    for i = 1, #UI.listButtons do
      UI.listButtons[i]:Hide()
    end
  end
  refreshDetailPanel()
end

local function createMainUI()
  if UI.frame then return end

  local frame = CreateFrame("Frame", "SepheransDropInfoBrowser", UIParent)
  frame:SetWidth(1240)
  frame:SetHeight(720)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetScale(tonumber((SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.uiScale) or 1) or 1)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:EnableKeyboard(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local centerX = self:GetCenter()
    local centerY = self:GetCenter()
    local parentX = UIParent:GetWidth() / 2
    local parentY = UIParent:GetHeight() / 2
    SepheransDropInfoDB.settings.uiX = math.floor(centerX - parentX)
    SepheransDropInfoDB.settings.uiY = math.floor(centerY - parentY)
  end)
  frame:SetFrameStrata("DIALOG")
  frame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
      self:Hide()
    end
  end)
  frame:SetScript("OnHide", function(self)
    if UI and UI.optionsFrame and UI.optionsFrame:IsShown() then
      UI.optionsFrame:Hide()
    end
    if UI and UI.itemInfoFrame and UI.itemInfoFrame:IsShown() then
      UI.itemInfoFrame:Hide()
    end
  end)
  frame:Hide()
  createBackdrop(frame, 0.04, 0.05, 0.07, 0.98, 0.20, 0.25, 0.34, 1)
  addPanelTexture(frame, 0)

  local header = frame:CreateTexture(nil, "BORDER")
  header:SetTexture("Interface\\Buttons\\WHITE8X8")
  header:SetPoint("TOPLEFT", 5, -5)
  header:SetPoint("TOPRIGHT", -5, -5)
  header:SetHeight(44)
  header:SetVertexColor(0.050, 0.058, 0.074, 0.98)

  local headerBottom = frame:CreateTexture(nil, "BORDER")
  headerBottom:SetTexture("Interface\\Buttons\\WHITE8X8")
  headerBottom:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
  headerBottom:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
  headerBottom:SetHeight(1)
  headerBottom:SetVertexColor(0.24, 0.58, 1.00, 0.40)
  UI.header = header
  UI.headerBottom = headerBottom

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  registerSDIFont(title, "windowTitle")
  title:SetPoint("TOPLEFT", 18, -13)
  title:SetText("Sepheran's Drop Info")
  title:SetTextColor(0.96, 0.98, 1.00)

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  local optionsButton = CreateFrame("Button", nil, frame)
  optionsButton:SetWidth(82)
  optionsButton:SetHeight(22)
  optionsButton:SetPoint("RIGHT", close, "LEFT", -8, 0)
  createBackdrop(optionsButton, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.65)
  optionsButton.bg = optionsButton:CreateTexture(nil, "BACKGROUND")
  optionsButton.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  optionsButton.bg:SetPoint("TOPLEFT", 4, -4)
  optionsButton.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  optionsButton.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  optionsButton.text = optionsButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(optionsButton.text, "button")
  optionsButton.text:SetPoint("CENTER")
  optionsButton.text:SetText("Theme")

  local sidebar = createInsetPanel(frame, 14, -54, -1046, 37)
  local workspace = createInsetPanel(frame, 204, -54, -14, 37)
  local leftPane = createInsetPanel(workspace, 14, -78, -640, 14)
  leftPane._browserLeft = 14
  leftPane._browserBottom = 14
  local rightPane = createInsetPanel(workspace, 414, -78, -14, 14)
  rightPane._browserLeft = 414
  rightPane._analyticsLeft = 14
  rightPane._bottom = 14

  local brandTitle = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  registerSDIFont(brandTitle, "brand")
  brandTitle:SetPoint("TOPLEFT", 16, -16)
  brandTitle:SetText("Dashboard")
  brandTitle:SetTextColor(0.96, 0.98, 1.00)

  local sidebarRuleTop = sidebar:CreateTexture(nil, "BORDER")
  sidebarRuleTop:SetTexture("Interface\\Buttons\\WHITE8X8")
  sidebarRuleTop:SetPoint("TOPLEFT", 14, -58)
  sidebarRuleTop:SetPoint("TOPRIGHT", -14, -58)
  sidebarRuleTop:SetHeight(1)
  sidebarRuleTop:SetVertexColor(0.24, 0.58, 1.00, 0.20)

  local workspaceTitle = workspace:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  registerSDIFont(workspaceTitle, "windowTitle")
  workspaceTitle:SetPoint("TOPLEFT", 18, -18)
  workspaceTitle:SetText("Observed data")
  workspaceTitle:SetTextColor(0.96, 0.98, 1.00)

  local workspaceSub = workspace:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(workspaceSub, "meta")
  workspaceSub:SetPoint("TOPLEFT", 18, -38)
  workspaceSub:SetText("Modernized dashboard shell. Functional systems stay the same.")
  workspaceSub:SetTextColor(0.58, 0.65, 0.78)

  local workspaceRule = workspace:CreateTexture(nil, "BORDER")
  workspaceRule:SetTexture("Interface\\Buttons\\WHITE8X8")
  workspaceRule:SetPoint("TOPLEFT", 14, -58)
  workspaceRule:SetPoint("TOPRIGHT", -14, -58)
  workspaceRule:SetHeight(1)
  workspaceRule:SetVertexColor(0.24, 0.58, 1.00, 0.20)

  local leftTitle = leftPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(leftTitle, "sectionTitle")
  leftTitle:SetPoint("TOPLEFT", 14, -14)
  leftTitle:SetPoint("TOPRIGHT", -12, -14)
  leftTitle:SetJustifyH("LEFT")
  leftTitle:SetText("Observed mobs")
  leftTitle:SetTextColor(0.95, 0.97, 1.00)

  local summaryText = leftPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(summaryText, "meta")
  summaryText:SetPoint("TOPLEFT", 14, -34)
  summaryText:SetPoint("TOPRIGHT", -12, -34)
  summaryText:SetJustifyH("LEFT")
  summaryText:SetTextColor(0.58, 0.65, 0.78)
  summaryText:SetText("Mobs: 0   Opens: 0   Unique items: 0")

  local leftRule = leftPane:CreateTexture(nil, "BORDER")
  leftRule:SetTexture("Interface\\Buttons\\WHITE8X8")
  leftRule:SetPoint("TOPLEFT", 12, -54)
  leftRule:SetPoint("TOPRIGHT", -12, -54)
  leftRule:SetHeight(1)
  leftRule:SetVertexColor(0.24, 0.58, 1.00, 0.24)

  local searchLabel = leftPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(searchLabel, "meta")
  searchLabel:SetPoint("TOPLEFT", 14, -72)
  searchLabel:SetText("Search:")
  searchLabel:SetTextColor(0.73, 0.82, 0.94)

  local searchLabel = leftPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(searchLabel, "meta")
  searchLabel:SetPoint("TOPLEFT", 14, -102)
  searchLabel:SetText("Sort:")
  searchLabel:SetTextColor(0.73, 0.82, 0.94)
  

  local searchBox = CreateFrame("EditBox", nil, leftPane)
  searchBox:SetAutoFocus(false)
  searchBox:SetHeight(24)
  searchBox:SetWidth(170)
  searchBox:SetPoint("TOPLEFT", 66, -66)
  searchBox:SetTextInsets(6, 6, 0, 0)
  styleSDIEditBox(searchBox)
  table.insert(UI._editBoxes, searchBox)
  searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() if UI.frame then UI.frame:Hide() end end)
  searchBox:SetScript("OnTextChanged", function(self)
    UI.searchText = self:GetText() or ""
    UI.selectedEntry = nil
    refreshMobList()
  end)

  local sortButton = CreateFrame("Button", nil, leftPane)
  sortButton:SetWidth(92)
  sortButton:SetHeight(24)
  sortButton:SetPoint("TOPRIGHT", -14, -96)
  createBackdrop(sortButton, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.55)
  sortButton.bg = sortButton:CreateTexture(nil, "BACKGROUND")
  sortButton.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  sortButton.bg:SetPoint("TOPLEFT", 4, -4)
  sortButton.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  sortButton.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  sortButton.text = sortButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(sortButton.text, "button")
  sortButton.text:SetPoint("CENTER")
  sortButton.text:SetText("Sort: Name")
  sortButton:SetScript("OnClick", function()
    advanceSortMode()
    refreshMobList()
  end)
  sortButton:SetScript("OnEnter", function(self) self.bg:SetVertexColor(0.14, 0.18, 0.26, 1) end)
  sortButton:SetScript("OnLeave", function(self) self.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95) end)

  local browserTab = CreateFrame("Button", nil, rightPane)
  browserTab:SetWidth(146)
  browserTab:SetHeight(30)
  browserTab:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 16, -84)
  createBackdrop(browserTab, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.35)
  browserTab.bg = browserTab:CreateTexture(nil, "BACKGROUND")
  browserTab.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  browserTab.bg:SetPoint("TOPLEFT", 4, -4)
  browserTab.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  browserTab.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  browserTab.text = browserTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(browserTab.text, "tab")
  browserTab.text:SetPoint("CENTER")
  browserTab.text:SetText("Browser")
  browserTab:SetScript("OnClick", function()
    setActiveTab("browser")
    refreshMobList()
  end)

  local analyticsTab = CreateFrame("Button", nil, rightPane)
  analyticsTab:SetWidth(146)
  analyticsTab:SetHeight(30)
  analyticsTab:SetPoint("TOPLEFT", browserTab, "BOTTOMLEFT", 0, -10)
  createBackdrop(analyticsTab, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.35)
  analyticsTab.bg = analyticsTab:CreateTexture(nil, "BACKGROUND")
  analyticsTab.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  analyticsTab.bg:SetPoint("TOPLEFT", 4, -4)
  analyticsTab.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  analyticsTab.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  analyticsTab.text = analyticsTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(analyticsTab.text, "tab")
  analyticsTab.text:SetPoint("CENTER")
  analyticsTab.text:SetText("Analytics")
  analyticsTab:SetScript("OnClick", function()
    setActiveTab("analytics")
    refreshMobList()
  end)

  local syncTab = CreateFrame("Button", nil, rightPane)
  syncTab:SetWidth(146)
  syncTab:SetHeight(30)
  syncTab:SetPoint("TOPLEFT", analyticsTab, "BOTTOMLEFT", 0, -10)
  createBackdrop(syncTab, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.35)
  syncTab.bg = syncTab:CreateTexture(nil, "BACKGROUND")
  syncTab.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  syncTab.bg:SetPoint("TOPLEFT", 4, -4)
  syncTab.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  syncTab.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  syncTab.text = syncTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(syncTab.text, "tab")
  syncTab.text:SetPoint("CENTER")
  syncTab.text:SetText("Sync")
  syncTab:SetScript("OnClick", function()
    setActiveTab("sync")
    refreshMobList()
  end)

  local savesTab = CreateFrame("Button", nil, rightPane)
  savesTab:SetWidth(146)
  savesTab:SetHeight(30)
  savesTab:SetPoint("TOPLEFT", syncTab, "BOTTOMLEFT", 0, -10)
  createBackdrop(savesTab, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.35)
  savesTab.bg = savesTab:CreateTexture(nil, "BACKGROUND")
  savesTab.bg:SetTexture("Interface\\buttons\\white8x8")
  savesTab.bg:SetPoint("TOPLEFT", 4, -4)
  savesTab.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  savesTab.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  savesTab.text = savesTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(savesTab.text, "tab")
  savesTab.text:SetPoint("CENTER")
  savesTab.text:SetText("Saves")
  savesTab:SetScript("OnClick", function()
    setActiveTab("saves")
    refreshMobList()
  end)

  local exportTab = CreateFrame("Button", nil, rightPane)
  exportTab:SetWidth(146)
  exportTab:SetHeight(30)
  exportTab:SetPoint("TOPLEFT", savesTab, "BOTTOMLEFT", 0, -10)
  createBackdrop(exportTab, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.35)
  exportTab.bg = exportTab:CreateTexture(nil, "BACKGROUND")
  exportTab.bg:SetTexture("Interface\\buttons\\white8x8")
  exportTab.bg:SetPoint("TOPLEFT", 4, -4)
  exportTab.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  exportTab.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  exportTab.text = exportTab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(exportTab.text, "tab")
  exportTab.text:SetPoint("CENTER")
  exportTab.text:SetText("Export")
  exportTab:SetScript("OnClick", function()
    setActiveTab("export")
    refreshMobList()
  end)

  local detailTitle = rightPane:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  registerSDIFont(detailTitle, "windowTitle")
  detailTitle:SetPoint("TOPLEFT", 16, -16)
  detailTitle:SetPoint("TOPRIGHT", -32, -16)
  detailTitle:SetJustifyH("LEFT")
  detailTitle:SetText("Select a mob")
  detailTitle:SetTextColor(0.95, 0.97, 1.00)

  local detailMeta = rightPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(detailMeta, "meta")
  detailMeta:SetPoint("TOPLEFT", 16, -38)
  detailMeta:SetPoint("TOPRIGHT", -32, -38)
  detailMeta:SetJustifyH("LEFT")
  detailMeta:SetText("Choose a creature on the left to inspect observed drops.")
  detailMeta:SetTextColor(0.58, 0.65, 0.78)

  local rightRule = rightPane:CreateTexture(nil, "BORDER")
  rightRule:SetTexture("Interface\\Buttons\\WHITE8X8")
  rightRule:SetPoint("TOPLEFT", 14, -60)
  rightRule:SetPoint("TOPRIGHT", -14, -60)
  rightRule:SetHeight(1)
  rightRule:SetVertexColor(0.24, 0.58, 1.00, 0.24)

  UI.frame = frame
  UI.sidebar = sidebar
  UI.workspace = workspace
  UI.workspaceTitle = workspaceTitle
  UI.workspaceSub = workspaceSub
  UI.leftPane = leftPane
  UI.leftTitle = leftTitle
  UI.summaryText = summaryText
  UI.searchBox = searchBox
  UI.searchText = UI.searchText or ""
  UI.rightPane = rightPane
  UI.sortButton = sortButton
  UI.browserTab = browserTab
  UI.analyticsTab = analyticsTab
  UI.syncTab = syncTab
  UI.savesTab = savesTab
  UI.exportTab = exportTab
  UI.detailTitle = detailTitle
  UI.detailMeta = detailMeta
  UI.listButtons = {}
  UI.detailRows = {}
  UI.mobData = {}

  local listContent = CreateFrame("Frame", nil, leftPane)
  listContent:SetPoint("TOPLEFT", 14, -132)
  listContent:SetPoint("BOTTOMRIGHT", -14, 14)
  UI.listContent = listContent

  local listScroll = CreateFrame("ScrollFrame", "SepheransDropInfoListScroll", leftPane, "FauxScrollFrameTemplate")
  listScroll:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, 0)
  listScroll:SetPoint("BOTTOMRIGHT", listContent, "BOTTOMRIGHT", 0, 0)
  listScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, 22, refreshMobList)
  end)
  UI.listScroll = listScroll

  local listScrollBar = _G["SepheransDropInfoListScrollScrollBar"]
  if listScrollBar then
    listScrollBar:ClearAllPoints()
    listScrollBar:SetPoint("TOPLEFT", listContent, "TOPRIGHT", -2, -16)
    listScrollBar:SetPoint("BOTTOMLEFT", listContent, "BOTTOMRIGHT", -2, 16)
  end

  for i = 1, 28 do
    local btn = CreateFrame("Button", nil, leftPane)
    btn:SetWidth(330)
    btn:SetHeight(24)
    if i == 1 then
      btn:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, 0)
    else
      btn:SetPoint("TOPLEFT", UI.listButtons[i - 1], "BOTTOMLEFT", 0, -4)
    end
    createBackdrop(btn, 0.08, 0.10, 0.13, 0.98, 0.18, 0.22, 0.30, 1)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    btn.bg:SetPoint("TOPLEFT", 4, -4)
    btn.bg:SetPoint("BOTTOMRIGHT", -4, 4)
    do
      local rowTheme = getMobRowThemeColors()
      btn.bg:SetVertexColor(rowTheme.baseR, rowTheme.baseG, rowTheme.baseB, 0.75)
    end

    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(btn.text, "body")
    btn.text:SetPoint("LEFT", 8, 0)
    btn.text:SetPoint("RIGHT", -6, 0)
    btn.text:SetJustifyH("LEFT")
    btn.text:SetTextColor(0.91, 0.94, 0.98)

    btn:SetScript("OnClick", function(self)
      UI.selectedEntry = self.entry
      refreshMobList()
    end)

    btn:SetScript("OnEnter", function(self)
      if self.entry and (not UI.selectedEntry or UI.selectedEntry.npcID ~= self.entry.npcID) then
        local rowTheme = getMobRowThemeColors()
        self.bg:SetVertexColor(rowTheme.hoverR, rowTheme.hoverG, rowTheme.hoverB, 0.85)
      end
    end)
    btn:SetScript("OnLeave", function(self)
      if self.entry and (not UI.selectedEntry or UI.selectedEntry.npcID ~= self.entry.npcID) then
        local rowTheme = getMobRowThemeColors()
        self.bg:SetVertexColor(rowTheme.baseR, rowTheme.baseG, rowTheme.baseB, 0.75)
      end
    end)

    UI.listButtons[i] = btn
  end

  local detailContent = CreateFrame("Frame", nil, rightPane)
  detailContent:SetPoint("TOPLEFT", 14, -78)
  detailContent:SetPoint("BOTTOMRIGHT", -14, 14)

  local detailScroll = CreateFrame("ScrollFrame", "SepheransDropInfoDetailScroll", rightPane, "FauxScrollFrameTemplate")
  detailScroll:SetPoint("TOPLEFT", detailContent, "TOPLEFT", 0, 0)
  detailScroll:SetPoint("BOTTOMRIGHT", detailContent, "BOTTOMRIGHT", 0, 0)
  detailScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, 20, refreshDetailPanel)
  end)
  UI.detailScroll = detailScroll

  local itemInfoFrame = CreateFrame("Frame", "SepheransDropInfoItemInfo", UIParent)
  itemInfoFrame:SetWidth(560)
  itemInfoFrame:SetHeight(470)
  itemInfoFrame:SetScale(tonumber((SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.uiScale) or 1) or 1)
  itemInfoFrame:SetPoint("CENTER", frame, "CENTER", 120, -10)
  itemInfoFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  itemInfoFrame:SetFrameLevel(frame:GetFrameLevel() + 20)
  itemInfoFrame:SetMovable(true)
  itemInfoFrame:EnableMouse(true)
  itemInfoFrame:EnableKeyboard(true)
  itemInfoFrame:RegisterForDrag("LeftButton")
  itemInfoFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  itemInfoFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  itemInfoFrame:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
      self:Hide()
    end
  end)
  itemInfoFrame:Hide()
  createBackdrop(itemInfoFrame, 0.04, 0.05, 0.07, 0.98, 0.20, 0.25, 0.34, 1)
  addPanelTexture(itemInfoFrame, 0)

  local itemInfoHeader = itemInfoFrame:CreateTexture(nil, "BORDER")
  itemInfoHeader:SetTexture("Interface\\Buttons\\WHITE8X8")
  itemInfoHeader:SetPoint("TOPLEFT", 5, -5)
  itemInfoHeader:SetPoint("TOPRIGHT", -5, -5)
  itemInfoHeader:SetHeight(38)
  itemInfoHeader:SetVertexColor(0.055, 0.065, 0.082, 0.98)

  local itemInfoHeaderBottom = itemInfoFrame:CreateTexture(nil, "BORDER")
  itemInfoHeaderBottom:SetTexture("Interface\\Buttons\\WHITE8X8")
  itemInfoHeaderBottom:SetPoint("TOPLEFT", itemInfoHeader, "BOTTOMLEFT", 0, 0)
  itemInfoHeaderBottom:SetPoint("TOPRIGHT", itemInfoHeader, "BOTTOMRIGHT", 0, 0)
  itemInfoHeaderBottom:SetHeight(1)
  itemInfoHeaderBottom:SetVertexColor(0.24, 0.58, 1.00, 0.40)

  local itemInfoIconFrame = CreateFrame("Button", nil, itemInfoFrame)
  itemInfoIconFrame:SetWidth(30)
  itemInfoIconFrame:SetHeight(30)
  itemInfoIconFrame:SetPoint("TOPLEFT", 14, -12)
  itemInfoIconFrame:EnableMouse(true)
  createBackdrop(itemInfoIconFrame, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.55)

  local itemInfoIcon = itemInfoIconFrame:CreateTexture(nil, "ARTWORK")
  itemInfoIcon:SetPoint("TOPLEFT", 2, -2)
  itemInfoIcon:SetPoint("BOTTOMRIGHT", -2, 2)
  itemInfoIcon:SetTexture("Interface\Icons\INV_Misc_QuestionMark")
  itemInfoIconFrame:SetHitRectInsets(0, 0, 0, 0)
  itemInfoIconFrame:SetScript("OnEnter", refreshItemIconTooltip)
  itemInfoIconFrame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  local itemInfoTitle = itemInfoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(itemInfoTitle, "windowTitle")
  itemInfoTitle:SetPoint("TOPLEFT", itemInfoIconFrame, "TOPRIGHT", 8, -1)
  itemInfoTitle:SetPoint("TOPRIGHT", -32, -13)
  itemInfoTitle:SetJustifyH("LEFT")
  itemInfoTitle:SetText("Item details")

  local itemInfoMeta = itemInfoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(itemInfoMeta, "meta")
  itemInfoMeta:SetPoint("TOPLEFT", itemInfoIconFrame, "BOTTOMLEFT", 0, -8)
  itemInfoMeta:SetPoint("TOPRIGHT", -14, -42)
  itemInfoMeta:SetJustifyH("LEFT")
  itemInfoMeta:SetTextColor(0.58, 0.65, 0.78)
  itemInfoMeta:SetText("Click an observed item to inspect where it drops.")

  local itemInfoPanel = createInsetPanel(itemInfoFrame, 10, -64, -10, 10)
  local itemInfoRule = itemInfoPanel:CreateTexture(nil, "BORDER")
  itemInfoRule:SetTexture("Interface\\Buttons\\WHITE8X8")
  itemInfoRule:SetPoint("TOPLEFT", 10, -30)
  itemInfoRule:SetPoint("TOPRIGHT", -10, -30)
  itemInfoRule:SetHeight(1)
  itemInfoRule:SetVertexColor(0.24, 0.58, 1.00, 0.24)

  local itemInfoHeaderLeft = itemInfoPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(itemInfoHeaderLeft, "sectionTitle")
  itemInfoHeaderLeft:SetPoint("TOPLEFT", 12, -10)
  itemInfoHeaderLeft:SetText("Observed mob")

  local itemInfoHeaderRight = itemInfoPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(itemInfoHeaderRight, "sectionTitle")
  itemInfoHeaderRight:SetPoint("TOPRIGHT", -12, -10)
  itemInfoHeaderRight:SetText("Drop rate")

  local itemInfoSortButton = CreateFrame("Button", nil, itemInfoPanel)
  itemInfoSortButton:SetWidth(96)
  itemInfoSortButton:SetHeight(18)
  itemInfoSortButton:SetPoint("TOPRIGHT", itemInfoHeaderRight, "TOPLEFT", -12, 0)
  createBackdrop(itemInfoSortButton, 0.08, 0.10, 0.13, 1, 0.24, 0.58, 1.00, 0.55)
  itemInfoSortButton.bg = itemInfoSortButton:CreateTexture(nil, "BACKGROUND")
  itemInfoSortButton.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  itemInfoSortButton.bg:SetPoint("TOPLEFT", 4, -4)
  itemInfoSortButton.bg:SetPoint("BOTTOMRIGHT", -4, 4)
  itemInfoSortButton.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95)
  itemInfoSortButton.text = itemInfoSortButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(itemInfoSortButton.text, "button")
  itemInfoSortButton.text:SetPoint("CENTER")
  itemInfoSortButton.text:SetText("Sort: Drop rate")
  itemInfoSortButton:SetScript("OnClick", function()
    if getItemInfoSortMode() == "rate" then
      setItemInfoSortMode("opens")
    else
      setItemInfoSortMode("rate")
    end
    refreshItemInfoPopup()
  end)
  itemInfoSortButton:SetScript("OnEnter", function(self) self.bg:SetVertexColor(0.14, 0.18, 0.26, 1) end)
  itemInfoSortButton:SetScript("OnLeave", function(self) self.bg:SetVertexColor(0.10, 0.12, 0.17, 0.95) end)

  local itemInfoContent = CreateFrame("Frame", nil, itemInfoPanel)
  itemInfoContent:SetPoint("TOPLEFT", 10, -38)
  itemInfoContent:SetPoint("BOTTOMRIGHT", -28, 18)

  local itemInfoScroll = CreateFrame("ScrollFrame", "SepheransDropInfoItemInfoScroll", itemInfoPanel, "FauxScrollFrameTemplate")
  itemInfoScroll:SetPoint("TOPLEFT", itemInfoContent, "TOPLEFT", 0, 0)
  itemInfoScroll:SetPoint("BOTTOMRIGHT", itemInfoContent, "BOTTOMRIGHT", 0, 0)
  itemInfoScroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, 22, refreshItemInfoPopup)
  end)

  local itemInfoClose = CreateFrame("Button", nil, itemInfoFrame, "UIPanelCloseButton")
  itemInfoClose:SetPoint("TOPRIGHT", -4, -4)

  UI.itemInfoRows = {}
  for i = 1, 11 do
    local row = CreateFrame("Button", nil, itemInfoPanel)
    row:SetHeight(20)
    if i == 1 then
      row:SetPoint("TOPLEFT", itemInfoContent, "TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", UI.itemInfoRows[i - 1], "BOTTOMLEFT", 0, -2)
    end
    row:SetPoint("RIGHT", itemInfoContent, "RIGHT", 0, 0)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bg:SetAllPoints(row)
    row.bg:SetVertexColor(0, 0, 0, 0)

    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(row.left, "body")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetWidth(280)
    row.left:SetJustifyH("LEFT")

    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(row.right, "body")
    row.right:SetPoint("RIGHT", -8, 0)
    row.right:SetWidth(120)
    row.right:SetJustifyH("RIGHT")

    row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    registerSDIFont(row.meta, "meta")
    row.meta:SetPoint("TOPLEFT", row.left, "BOTTOMLEFT", 0, -1)
    row.meta:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetTextColor(0.72, 0.72, 0.72)

    row:SetHeight(24)
    UI.itemInfoRows[i] = row
  end

  UI.itemInfoFrame = itemInfoFrame
  UI.itemInfoHeader = itemInfoHeader
  UI.itemInfoHeaderBottom = itemInfoHeaderBottom
  UI.itemInfoIconFrame = itemInfoIconFrame
  UI.itemInfoIcon = itemInfoIcon
  UI.itemInfoTitle = itemInfoTitle
  UI.itemInfoMeta = itemInfoMeta
  UI.itemInfoPanel = itemInfoPanel
  UI.itemInfoRule = itemInfoRule
  UI.itemInfoHeaderLeft = itemInfoHeaderLeft
  UI.itemInfoHeaderRight = itemInfoHeaderRight
  UI.itemInfoSortButton = itemInfoSortButton
  UI.itemInfoScroll = itemInfoScroll
  UI._accentTexts = UI._accentTexts or {}
  table.insert(UI._accentTexts, itemInfoTitle)
  table.insert(UI._accentTexts, itemInfoHeaderLeft)
  table.insert(UI._accentTexts, itemInfoHeaderRight)
  setItemInfoSortMode(getItemInfoSortMode())
  if UISpecialFrames then
    table.insert(UISpecialFrames, "SepheransDropInfoItemInfo")
  end

  for i = 1, 21 do
    local row = CreateFrame("Button", nil, rightPane)
    row:SetWidth(500)
    row._browserWidth = 560
    row._analyticsWidth = 820
    row:SetHeight(18)
    if i == 1 then
      row:SetPoint("TOPLEFT", detailContent, "TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", UI.detailRows[i - 1], "BOTTOMLEFT", 0, -2)
    end

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bg:SetAllPoints(row)
    row.bg:SetVertexColor(0, 0, 0, 0)

    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(row.left, "body")
    row.left:SetPoint("LEFT", 6, 0)
    row.left:SetWidth(430)
    row.left:SetJustifyH("LEFT")
    row.left:SetJustifyV("MIDDLE")

    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(row.right, "body")
    row.right:SetPoint("RIGHT", -8, 0)
    row.right:SetWidth(120)
    row.right:SetJustifyH("RIGHT")
    row.right:SetJustifyV("MIDDLE")

    row:SetScript("OnClick", function(self)
      if self.data and self.data.itemData and openItemInfoPopup then
        openItemInfoPopup(self.data.itemData)
      end
    end)
    row:SetScript("OnEnter", function(self)
      if self.data and self.data.itemData then
        self.bg:SetVertexColor(0.18, 0.32, 0.55, 0.28)
      end
      if self.itemLink and GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function(self)
      styleAlternateDataRow(self, self.data and self.data.kind, self.data and self.data._rowIndex)
      if GameTooltip then
        GameTooltip:Hide()
      end
    end)

    UI.detailRows[i] = row
  end

  local footer = frame:CreateTexture(nil, "BORDER")
  footer:SetTexture("Interface\\Buttons\\WHITE8X8")
  footer:SetPoint("BOTTOMLEFT", 5, 5)
  footer:SetPoint("BOTTOMRIGHT", -5, 5)
  footer:SetHeight(28)
  footer:SetVertexColor(0.05, 0.06, 0.08, 0.95)

  local footerTop = frame:CreateTexture(nil, "BORDER")
  footerTop:SetTexture("Interface\\Buttons\\WHITE8X8")
  footerTop:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, 0)
  footerTop:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 0)
  footerTop:SetHeight(1)
  footerTop:SetVertexColor(0.24, 0.58, 1.00, 0.25)

  local bottomHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(bottomHint, "metaSmall")
  bottomHint:SetPoint("BOTTOMLEFT", 16, 30)
  bottomHint:SetPoint("BOTTOMRIGHT", -16, 30)
  bottomHint:SetJustifyH("LEFT")
  bottomHint:SetText(" ")
  bottomHint:SetTextColor(0.60, 0.67, 0.78)

  local sessionText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(sessionText, "meta")
  sessionText:SetPoint("BOTTOMLEFT", 16, 12)
  sessionText:SetPoint("BOTTOMRIGHT", -16, 12)
  sessionText:SetJustifyH("LEFT")
  sessionText:SetTextColor(0.70, 0.84, 1.00)
  sessionText:SetText(getSessionSummaryText())
  UI.sessionText = sessionText
  UI.footer = footer
  UI.footerTop = footerTop
  local optionsFrame = CreateFrame("Frame", nil, UIParent)
  optionsFrame:SetWidth(250)
  optionsFrame:SetHeight(265)
  optionsFrame:SetFrameStrata("DIALOG")
  optionsFrame:SetToplevel(true)
  createBackdrop(optionsFrame, 0.05, 0.06, 0.08, 1, 0.22, 0.30, 0.40, 1)
  addPanelTexture(optionsFrame, 0)
  optionsFrame:Hide()
  UI.optionsFrame = optionsFrame

  local optionsClose = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
  optionsClose:SetPoint("TOPRIGHT", -4, -4)

  local optionsTitle = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(optionsTitle, "sectionTitle")
  optionsTitle:SetPoint("TOPLEFT", 12, -12)
  optionsTitle:SetText("Dashboard Theme")

  local function createColorRow(parent, y, labelText, kind)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(label, "meta")
    label:SetPoint("TOPLEFT", 14, y)
    label:SetText(labelText)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(110)
    button:SetHeight(20)
    button:SetPoint("LEFT", label, "RIGHT", 10, 0)
    createBackdrop(button, 0.14, 0.11, 0.07, 1, 0.42, 0.34, 0.13, 1)
    local swatch = button:CreateTexture(nil, "BACKGROUND")
    swatch:SetTexture("Interface\\Buttons\\WHITE8X8")
    swatch:SetPoint("TOPLEFT", 4, -4)
    swatch:SetPoint("BOTTOMRIGHT", -28, 4)
    local btnText = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    registerSDIFont(btnText, "button")
    btnText:SetPoint("RIGHT", -8, 0)
    btnText:SetText("Pick")
    UI.optionsSwatches = UI.optionsSwatches or {}
    UI.optionsSwatches[kind] = swatch
    button:SetScript("OnClick", function()
      local r, g, b = getStoredUIColor(kind, 1, 1, 1)
      ColorPickerFrame.hasOpacity = false
      ColorPickerFrame.previousValues = { kind = kind, r = r, g = g, b = b }
      ColorPickerFrame.func = function()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        SepheransDropInfoDB.settings.uiColors[kind] = { nr, ng, nb }
        applyUITheme()
        refreshMobList()
      end
      ColorPickerFrame.cancelFunc = function(previous)
        if type(previous) == "table" and previous.kind then
          SepheransDropInfoDB.settings.uiColors[previous.kind] = { previous.r, previous.g, previous.b }
          applyUITheme()
          refreshMobList()
        end
      end
      ColorPickerFrame:SetColorRGB(r, g, b)
      ColorPickerFrame:Hide()
      ColorPickerFrame:Show()
    end)
    return label, button
  end

  local bgLabel = createColorRow(optionsFrame, -42, "Background", "bg")
  local borderLabel = createColorRow(optionsFrame, -70, "Border", "border")
  local accentLabel = createColorRow(optionsFrame, -98, "Accent", "accent")
  local mobRowLabel = createColorRow(optionsFrame, -126, "Mob Rows", "mobRow")

  local resetButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
  resetButton:SetWidth(96)
  resetButton:SetHeight(22)
  resetButton:SetPoint("TOPLEFT", 14, -152)
  resetButton:SetText("Reset Colors")
  resetButton:SetScript("OnClick", function()
    SepheransDropInfoDB.settings.uiColors.bg = { 0.03137254901960784, 0.04313725490196078, 0.08235294117647059 }
    SepheransDropInfoDB.settings.uiColors.border = { 0.4509803921568628, 0.6, 0.8509803921568627 }
    SepheransDropInfoDB.settings.uiColors.accent = { 0.4313725490196079, 0.8470588235294118, 1 }
    SepheransDropInfoDB.settings.uiColors.mobRow = { 0.01568627450980392, 0.06274509803921569, 0.6745098039215687 }
    applyUITheme()
    refreshMobList()
  end)

  local scaleLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(scaleLabel, "meta")
  scaleLabel:SetPoint("TOPLEFT", 14, -186)
  scaleLabel:SetText("UI Scale")
  local scaleValue = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(scaleValue, "meta")
  scaleValue:SetPoint("TOPRIGHT", -18, -186)
  scaleValue:SetText("1.00x")
  UI.scaleValue = scaleValue

  local scaleSlider = CreateFrame("Slider", "SepheransDropInfoScaleSlider", optionsFrame, "OptionsSliderTemplate")
  scaleSlider:SetPoint("TOPLEFT", 18, -204)
  scaleSlider:SetWidth(208)
  scaleSlider:SetMinMaxValues(0.70, 1.35)
  scaleSlider:SetValueStep(0.05)
  if scaleSlider.SetObeyStepOnDrag then
    scaleSlider:SetObeyStepOnDrag(true)
  end
  _G[scaleSlider:GetName() .. "Low"]:SetText("0.70")
  _G[scaleSlider:GetName() .. "High"]:SetText("1.35")
  _G[scaleSlider:GetName() .. "Text"]:SetText("")
  scaleSlider:SetScript("OnValueChanged", function(self, value)
    if self._ignore then return end
    value = math.floor((value * 20) + 0.5) / 20
    UI.pendingScale = value
    if UI.scaleValue then
      UI.scaleValue:SetText(string.format("%.2fx", value))
    end
  end)
  UI.scaleSlider = scaleSlider

  local applyScaleButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
  applyScaleButton:SetWidth(96)
  applyScaleButton:SetHeight(22)
  applyScaleButton:SetPoint("TOPLEFT", 14, -233)
  applyScaleButton:SetText("Apply UI Scale")
  applyScaleButton:SetScript("OnClick", function()
    local value = UI.pendingScale or tonumber(SepheransDropInfoDB.settings.uiScale) or 1
    value = math.floor((value * 20) + 0.5) / 20
    SepheransDropInfoDB.settings.uiScale = value
    applyUIScale()
  end)

  optionsButton:SetScript("OnClick", function()
    if not UI.optionsFrame then return end
    if UI.optionsFrame:IsShown() then
      UI.optionsFrame:Hide()
    else
      UI.optionsFrame:ClearAllPoints()
      UI.optionsFrame:SetPoint("TOPLEFT", UI.frame, "TOPRIGHT", 8, 0)
      UI.optionsFrame:Show()
      if UI.scaleSlider then
        local currentScale = tonumber(SepheransDropInfoDB.settings.uiScale) or 1
        UI.pendingScale = currentScale
        UI.scaleSlider._ignore = true
        UI.scaleSlider:SetValue(currentScale)
        UI.scaleSlider._ignore = nil
        if UI.scaleValue then
          UI.scaleValue:SetText(string.format("%.2fx", currentScale))
        end
      end
      applyUITheme()
      applyUIScale()
    end
  end)

  local savePanel = CreateFrame("Frame", nil, rightPane)
  savePanel:SetPoint("TOPLEFT", 10, -70)
  savePanel:SetPoint("BOTTOMRIGHT", -10, 8)
  savePanel:Hide()
  UI.savePanel = savePanel

  local saveNameLabel = savePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(saveNameLabel, "sectionTitle")
  saveNameLabel:SetPoint("TOPLEFT", 12, -12)
  saveNameLabel:SetText("Snapshot name:")
  saveNameLabel:SetTextColor(1, 0.82, 0)

  local saveNameBox = CreateFrame("EditBox", nil, savePanel)
  saveNameBox:SetAutoFocus(false)
  saveNameBox:SetWidth(220)
  saveNameBox:SetHeight(20)
  saveNameBox:SetPoint("LEFT", saveNameLabel, "RIGHT", 10, 0)
  saveNameBox:SetTextInsets(6, 6, 0, 0)
  styleSDIEditBox(saveNameBox)
  table.insert(UI._editBoxes, saveNameBox)
  saveNameBox:SetScript("OnEnterPressed", function(self) saveCurrentSnapshot(self:GetText(), false) self:ClearFocus() end)
  saveNameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  UI.saveNameBox = saveNameBox

  local autoSaveToggle = CreateFrame("CheckButton", nil, savePanel, "UICheckButtonTemplate")
  autoSaveToggle:SetPoint("LEFT", saveNameBox, "RIGHT", 16, 0)
  autoSaveToggle:SetScript("OnClick", function(self)
    SepheransDropInfoDB.settings.autoSaveOnLogin = self:GetChecked() and true or false
    setSaveStatus("Autosave on login: " .. ((SepheransDropInfoDB.settings.autoSaveOnLogin and "ON") or "OFF"))
  end)
  UI.autoSaveToggle = autoSaveToggle

  local autoSaveLabel = savePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(autoSaveLabel, "meta")
  autoSaveLabel:SetPoint("LEFT", autoSaveToggle, "RIGHT", 2, 0)
  autoSaveLabel:SetText("Autosave on login")
  autoSaveLabel:SetTextColor(0.95, 0.93, 0.88)

  local saveSidePanel = createInsetPanel(savePanel, 10, -74, -704, 220)
  saveSidePanel:ClearAllPoints()
  saveSidePanel:SetPoint("TOPLEFT", savePanel, "TOPLEFT", 10, -74)
  saveSidePanel:SetPoint("BOTTOMRIGHT", savePanel, "TOPLEFT", 160, -196)

  local saveCurrentButton = CreateFrame("Button", nil, saveSidePanel, "UIPanelButtonTemplate")
  saveCurrentButton:SetWidth(110)
  saveCurrentButton:SetHeight(22)
  saveCurrentButton:SetPoint("TOPLEFT", 12, -25)
  saveCurrentButton:SetText("Save Current")
  saveCurrentButton:SetScript("OnClick", function()
    saveCurrentSnapshot(UI.saveNameBox and UI.saveNameBox:GetText() or nil, false)
  end)

  local loadSelectedButton = CreateFrame("Button", nil, saveSidePanel, "UIPanelButtonTemplate")
  loadSelectedButton:SetWidth(110)
  loadSelectedButton:SetHeight(22)
  loadSelectedButton:SetPoint("TOPLEFT", 12, -57)
  loadSelectedButton:SetText("Load Selected")
  loadSelectedButton:SetScript("OnClick", function()
    if not SaveState.selected then
      setSaveStatus("Select a snapshot first")
      if refreshSaveSlotsUI then refreshSaveSlotsUI() end
      return
    end
    loadSnapshot(SaveState.selected)
  end)

  local deleteSelectedButton = CreateFrame("Button", nil, saveSidePanel, "UIPanelButtonTemplate")
  deleteSelectedButton:SetWidth(110)
  deleteSelectedButton:SetHeight(22)
  deleteSelectedButton:SetPoint("TOPLEFT", 12, -89)
  deleteSelectedButton:SetText("Delete Selected")
  deleteSelectedButton:SetScript("OnClick", function()
    if not SaveState.selected then
      setSaveStatus("Select a snapshot first")
      if refreshSaveSlotsUI then refreshSaveSlotsUI() end
      return
    end
    deleteSnapshot(SaveState.selected)
  end)


  local savesLabel = savePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(savesLabel, "sectionTitle")
  savesLabel:SetPoint("TOPLEFT", saveSidePanel, "TOPRIGHT", 28, 16)
  savesLabel:SetText("Saved databases:")
  savesLabel:SetTextColor(1, 0.82, 0)

  local saveGrid = createInsetPanel(savePanel, 188, -74, -10, 30)
  local saveHeaderBar = saveGrid:CreateTexture(nil, "BORDER")
  saveHeaderBar:SetTexture("Interface\\buttons\\white8x8")
  saveHeaderBar:SetPoint("TOPLEFT", 6, -6)
  saveHeaderBar:SetPoint("TOPRIGHT", -6, -6)
  saveHeaderBar:SetHeight(24)
  saveHeaderBar:SetVertexColor(0.30, 0.22, 0.08, 0.55)

  local saveHeaders = { {"Snapshot", 12, 250}, {"Saved", 270, 180}, {"Mobs", 460, 80}, {"Opens", 550, 80} }
  for _, c in ipairs(saveHeaders) do
    local fs = saveGrid:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    registerSDIFont(fs, "meta")
    fs:SetPoint("TOPLEFT", c[2], -12)
    fs:SetWidth(c[3])
    fs:SetJustifyH("LEFT")
    fs:SetText(c[1])
    fs:SetTextColor(1, 0.82, 0)
  end

  local saveSelectedLabel = savePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(saveSelectedLabel, "meta")
  saveSelectedLabel:SetPoint("BOTTOMLEFT", 14, 12)
  saveSelectedLabel:SetText("Selected:")
  saveSelectedLabel:SetTextColor(1, 0.82, 0)

  local saveSelectedValue = savePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(saveSelectedValue, "bodySmall")
  saveSelectedValue:SetPoint("LEFT", saveSelectedLabel, "RIGHT", 6, 0)
  saveSelectedValue:SetTextColor(0.95, 0.93, 0.88)
  UI.saveSelectedValue = saveSelectedValue

  local saveStatusLabel = savePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(saveStatusLabel, "meta")
  saveStatusLabel:SetPoint("LEFT", saveSelectedValue, "RIGHT", 30, 0)
  saveStatusLabel:SetText("Status:")
  saveStatusLabel:SetTextColor(1, 0.82, 0)

  local saveStatusValue = savePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(saveStatusValue, "bodySmall")
  saveStatusValue:SetPoint("LEFT", saveStatusLabel, "RIGHT", 6, 0)
  saveStatusValue:SetTextColor(0.95, 0.93, 0.88)
  UI.saveStatusValue = saveStatusValue

  local saveContent = CreateFrame("Frame", nil, saveGrid)
  saveContent:SetPoint("TOPLEFT", 8, -34)
  saveContent:SetPoint("BOTTOMRIGHT", -28, 12)
  local saveScroll = CreateFrame("ScrollFrame", "SepheransDropInfoSaveScroll", saveGrid, "FauxScrollFrameTemplate")
  saveScroll:SetPoint("TOPLEFT", saveContent, "TOPLEFT", 0, 0)
  saveScroll:SetPoint("BOTTOMRIGHT", saveContent, "BOTTOMRIGHT", 0, 0)
  UI.saveScroll = saveScroll
  UI.saveRows = {}
  saveScroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 22, refreshSaveSlotsUI) end)
  local saveXOffsets = { 6, 264, 454, 544 }
  local saveWidths = { 250, 180, 80, 80 }
  for i = 1, 14 do
    local row = CreateFrame("Button", nil, saveContent)
    row:SetHeight(20)
    if i == 1 then
      row:SetPoint("TOPLEFT", saveContent, "TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", UI.saveRows[i - 1], "BOTTOMLEFT", 0, -2)
    end
    row:SetPoint("RIGHT", saveContent, "RIGHT", 0, 0)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetTexture("Interface\\buttons\\white8x8")
    row.bg:SetAllPoints(row)
    row.bg:SetVertexColor(0, 0, 0, 0)
    row.cols = {}
    for ci = 1, 4 do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      registerSDIFont(fs, "bodySmall")
      fs:SetPoint("LEFT", saveXOffsets[ci], 0)
      fs:SetWidth(saveWidths[ci])
      fs:SetJustifyH("LEFT")
      fs:SetTextColor(0.95, 0.93, 0.88)
      row.cols[ci] = fs
    end
    row:SetScript("OnClick", function(self)
      if self.data then
        SaveState.selected = self.data.name
        if refreshSaveSlotsUI then refreshSaveSlotsUI() end
      end
    end)
    UI.saveRows[i] = row
  end

  local exportPanel = CreateFrame("Frame", nil, rightPane)
  exportPanel:SetPoint("TOPLEFT", 10, -70)
  exportPanel:SetPoint("BOTTOMRIGHT", -10, 8)
  exportPanel:Hide()
  UI.exportPanel = exportPanel

  local exportSidePanel = createInsetPanel(exportPanel, 10, -74, -704, 220)
  exportSidePanel:ClearAllPoints()
  exportSidePanel:SetPoint("TOPLEFT", exportPanel, "TOPLEFT", 10, -74)
  exportSidePanel:SetPoint("BOTTOMRIGHT", exportPanel, "TOPLEFT", 160, -166)

  local exportButton = CreateFrame("Button", nil, exportSidePanel, "UIPanelButtonTemplate")
  exportButton:SetWidth(110)
  exportButton:SetHeight(22)
  exportButton:SetPoint("TOPLEFT", 12, -25)
  exportButton:SetText("Export Database")
  exportButton:SetScript("OnClick", function()
    refreshExportPanel(true)
  end)
  UI.exportButton = exportButton

  local selectExportButton = CreateFrame("Button", nil, exportSidePanel, "UIPanelButtonTemplate")
  selectExportButton:SetWidth(110)
  selectExportButton:SetHeight(22)
  selectExportButton:SetPoint("TOPLEFT", 12, -57)
  selectExportButton:SetText("Select Text")
  selectExportButton:SetScript("OnClick", function()
    if UI.exportBox then
      UI.exportBox:SetFocus()
      UI.exportBox:HighlightText()
    end
  end)
  UI.selectExportButton = selectExportButton

  local exportLabel = exportPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(exportLabel, "sectionTitle")
  exportLabel:SetPoint("TOPLEFT", exportSidePanel, "TOPRIGHT", 28, 16)
  exportLabel:SetText("Export text:")
  exportLabel:SetTextColor(1, 0.82, 0)

  local exportGrid = createInsetPanel(exportPanel, 188, -74, -10, 30)
  local exportScroll = CreateFrame("ScrollFrame", "SepheransDropInfoExportScroll", exportGrid, "UIPanelScrollFrameTemplate")
  exportScroll:SetPoint("TOPLEFT", 10, -10)
  exportScroll:SetPoint("BOTTOMRIGHT", -30, 10)
  UI.exportScroll = exportScroll

  local exportBox = CreateFrame("EditBox", nil, exportScroll)
  exportBox:SetMultiLine(true)
  exportBox:SetAutoFocus(false)
  exportBox:SetWidth(780)
  exportBox:SetHeight(1800)
  exportBox:SetMaxLetters(999999)
  registerSDIFont(exportBox, "bodySmall")
  exportBox:SetTextColor(0.95, 0.93, 0.88)
  exportBox:SetJustifyH("LEFT")
  exportBox:SetJustifyV("TOP")
  exportBox:SetTextInsets(6, 6, 6, 6)
  exportBox:SetScript("OnTextChanged", function(self)
    local lineCount = (self.GetNumLines and self:GetNumLines()) or 1
    local minHeight = (exportScroll:GetHeight() or 400)
    local newHeight = math.max(minHeight, (lineCount * 14) + 40)
    if math.abs((self:GetHeight() or 0) - newHeight) > 1 then
      self:SetHeight(newHeight)
    end
  end)
  exportBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  exportScroll:SetScrollChild(exportBox)
  UI.exportBox = exportBox

  local exportStatusLabel = exportPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(exportStatusLabel, "meta")
  exportStatusLabel:SetPoint("BOTTOMLEFT", 14, 12)
  exportStatusLabel:SetText("Status:")
  exportStatusLabel:SetTextColor(1, 0.82, 0)

  local exportStatusValue = exportPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(exportStatusValue, "bodySmall")
  exportStatusValue:SetPoint("LEFT", exportStatusLabel, "RIGHT", 6, 0)
  exportStatusValue:SetTextColor(0.95, 0.93, 0.88)
  UI.exportStatusValue = exportStatusValue

  local syncPanel = CreateFrame("Frame", nil, rightPane)
  syncPanel:SetPoint("TOPLEFT", 10, -70)
  syncPanel:SetPoint("BOTTOMRIGHT", -10, 8)
  syncPanel:Hide()
  UI.syncPanel = syncPanel

  local syncEnableLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(syncEnableLabel, "sectionTitle")
  syncEnableLabel:SetPoint("TOPLEFT", 12, -12)
  syncEnableLabel:SetText("Enable Sync:")
  syncEnableLabel:SetTextColor(1, 0.82, 0)

  local syncEnable = CreateFrame("CheckButton", nil, syncPanel, "UICheckButtonTemplate")
  syncEnable:SetPoint("LEFT", syncEnableLabel, "RIGHT", 8, 0)
  syncEnable:SetScript("OnClick", function(self)
    SepheransDropInfoDB.settings.syncEnabled = self:GetChecked() and true or false
    if self:GetChecked() then
      setSyncStatus("Idle")
      broadcastDiscovery()
    else
      SyncState.users = {}
      SyncState.selected = nil
      setSyncStatus("Offline |cffff0000●|r")
      refreshSyncUsersUI()
    end
    updateSyncControlStates()
  end)
  UI.syncEnable = syncEnable

  local syncEveryLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(syncEveryLabel, "sectionTitle")
  syncEveryLabel:SetPoint("LEFT", syncEnable, "RIGHT", 18, 0)
  syncEveryLabel:SetText("Sync every")
  syncEveryLabel:SetTextColor(1, 0.82, 0)

  local syncEveryBox = CreateFrame("EditBox", nil, syncPanel)
  syncEveryBox:SetAutoFocus(false)
  syncEveryBox:SetWidth(44)
  syncEveryBox:SetHeight(20)
  syncEveryBox:SetPoint("LEFT", syncEveryLabel, "RIGHT", 10, 0)
  syncEveryBox:SetTextInsets(6, 6, 0, 0)
  styleSDIEditBox(syncEveryBox)
  table.insert(UI._editBoxes, syncEveryBox)
  syncEveryBox:SetNumeric(true)
  syncEveryBox:SetMaxLetters(3)
  syncEveryBox:SetScript("OnEnterPressed", function(self) local v=tonumber(self:GetText()) or 20 if v<5 then v=5 end if v>600 then v=600 end SepheransDropInfoDB.settings.syncInterval=v self:SetText(tostring(v)) self:ClearFocus() end)
  syncEveryBox:SetScript("OnEscapePressed", function(self) self:SetText(tostring(getSyncInterval())) self:ClearFocus() end)
  UI.syncEveryBox = syncEveryBox

  local syncEverySuffix = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(syncEverySuffix, "sectionTitle")
  syncEverySuffix:SetPoint("LEFT", syncEveryBox, "RIGHT", 8, 0)
  syncEverySuffix:SetText("seconds")
  syncEverySuffix:SetTextColor(1, 0.82, 0)

  local syncChannelLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(syncChannelLabel, "sectionTitle")
  syncChannelLabel:SetPoint("LEFT", syncEverySuffix, "RIGHT", 18, 0)
  syncChannelLabel:SetText("Channel")
  syncChannelLabel:SetTextColor(1, 0.82, 0)

  local syncChannelBox = CreateFrame("EditBox", nil, syncPanel)
  syncChannelBox:SetAutoFocus(false)
  syncChannelBox:SetWidth(90)
  syncChannelBox:SetHeight(20)
  syncChannelBox:SetPoint("LEFT", syncChannelLabel, "RIGHT", 10, 0)
  syncChannelBox:SetTextInsets(6, 6, 0, 0)
  styleSDIEditBox(syncChannelBox)
  table.insert(UI._editBoxes, syncChannelBox)
  syncChannelBox:SetMaxLetters(32)
  syncChannelBox:SetScript("OnEnterPressed", function(self)
    setSyncChannelFromText(self:GetText())
    self:ClearFocus()

    if UI and UI.syncEnable and SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.syncEnabled then
      UI.syncEnable:SetChecked(false)
      local onClick = UI.syncEnable:GetScript("OnClick")
      if onClick then onClick(UI.syncEnable) end
      UI.syncEnable:SetChecked(true)
      onClick = UI.syncEnable:GetScript("OnClick")
      if onClick then onClick(UI.syncEnable) end
    end
  end)
  syncChannelBox:SetScript("OnEscapePressed", function(self)
    self:SetText(getSyncChannelName())
    self:ClearFocus()
  end)
  UI.syncChannelBox = syncChannelBox

  local joinChannelButton = CreateFrame("Button", nil, syncPanel, "UIPanelButtonTemplate")
  joinChannelButton:SetWidth(104)
  joinChannelButton:SetHeight(22)
  joinChannelButton:SetPoint("LEFT", syncChannelBox, "RIGHT", 10, 0)
  joinChannelButton:SetText("Join Channel")
  joinChannelButton:SetScript("OnClick", function() joinConfiguredSyncChannel() end)
  UI.joinChannelButton = joinChannelButton

  local userLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(userLabel, "sectionTitle")
  userLabel:SetPoint("TOPLEFT", 12, -42)
  userLabel:SetText("User:")
  userLabel:SetTextColor(1, 0.82, 0)

  local currentUser = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  registerSDIFont(currentUser, "body")
  currentUser:SetPoint("LEFT", userLabel, "RIGHT", 8, 0)
  currentUser:SetTextColor(0.95, 0.93, 0.88)
  UI.syncCurrentUser = currentUser

  local sidePanel = createInsetPanel(syncPanel, 10, -74, -704, 250)
  sidePanel:ClearAllPoints()
  sidePanel:SetPoint("TOPLEFT", syncPanel, "TOPLEFT", 10, -74)
  sidePanel:SetPoint("BOTTOMRIGHT", syncPanel, "TOPLEFT", 160, -160)
  local refreshUsers = CreateFrame("Button", nil, sidePanel, "UIPanelButtonTemplate")
  refreshUsers:SetWidth(110)
  refreshUsers:SetHeight(22)
  refreshUsers:SetPoint("TOPLEFT", 12, -28)
  refreshUsers:SetText("Refresh Users")
  refreshUsers:SetScript("OnClick", function() broadcastDiscovery(true) end)
  UI.refreshUsersButton = refreshUsers

  local syncNow = CreateFrame("Button", nil, sidePanel, "UIPanelButtonTemplate")
  syncNow:SetWidth(110)
  syncNow:SetHeight(22)
  syncNow:SetPoint("TOPLEFT", 12, -58)
  syncNow:SetText("Sync Now")
  UI.syncNowButton = syncNow
  syncNow:SetScript("OnClick", function()
    if not SyncState.selected then
      setSyncStatus("Select a user first")
      refreshSyncUsersUI()
      return
    end
    sendSyncMessage("REQSYNC", "WHISPER", SyncState.selected)
    setSyncStatus("Sync requested from " .. SyncState.selected)
    refreshSyncUsersUI()
  end)

  local listLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  registerSDIFont(listLabel, "sectionTitle")
  listLabel:SetPoint("TOPLEFT", sidePanel, "TOPRIGHT", 28, 15)
  listLabel:SetText("Online users: ")
  listLabel:SetTextColor(1, 0.82, 0)

  local grid = createInsetPanel(syncPanel, 188, -74, -10, 30)
  local headerBar = grid:CreateTexture(nil, "BORDER")
  headerBar:SetTexture("Interface\\Buttons\\WHITE8X8")
  headerBar:SetPoint("TOPLEFT", 6, -6)
  headerBar:SetPoint("TOPRIGHT", -6, -6)
  headerBar:SetHeight(24)
  headerBar:SetVertexColor(0.30, 0.22, 0.08, 0.55)

  local headers = { {"User", 12, 190}, {"Mobs", 216, 70}, {"Opens", 300, 80}, {"Unique Loot", 398, 120}, {"To Sync", 536, 90}, {"Flags", 644, 150} }
  for _, c in ipairs(headers) do
    local fs = grid:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    registerSDIFont(fs, "meta")
    fs:SetPoint("TOPLEFT", c[2], -12)
    fs:SetWidth(c[3])
    fs:SetJustifyH("LEFT")
    fs:SetText(c[1])
    fs:SetTextColor(1, 0.82, 0)
  end

  local statusLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(statusLabel, "meta")
  statusLabel:SetPoint("BOTTOMLEFT", 14, 12)
  statusLabel:SetText("Selected:")
  statusLabel:SetTextColor(1, 0.82, 0)
  local selectedValue = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(selectedValue, "bodySmall")
  selectedValue:SetPoint("LEFT", statusLabel, "RIGHT", 6, 0)
  selectedValue:SetTextColor(0.95,0.93,0.88)
  UI.syncSelectedValue = selectedValue

  local status2Label = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(status2Label, "meta")
  status2Label:SetPoint("LEFT", selectedValue, "RIGHT", 30, 0)
  status2Label:SetText("Status:")
  status2Label:SetTextColor(1, 0.82, 0)
  local statusValue = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(statusValue, "bodySmall")
  statusValue:SetPoint("LEFT", status2Label, "RIGHT", 6, 0)
  statusValue:SetTextColor(0.95,0.93,0.88)
  UI.syncStatusValue = statusValue

  local lastLabel = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(lastLabel, "meta")
  lastLabel:SetPoint("LEFT", statusValue, "RIGHT", 30, 0)
  lastLabel:SetText("Last sync:")
  lastLabel:SetTextColor(1, 0.82, 0)
  local lastValue = syncPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  registerSDIFont(lastValue, "bodySmall")
  lastValue:SetPoint("LEFT", lastLabel, "RIGHT", 6, 0)
  lastValue:SetTextColor(0.95,0.93,0.88)
  UI.syncLastValue = lastValue

  local syncContent = CreateFrame("Frame", nil, grid)
  syncContent:SetPoint("TOPLEFT", 8, -34)
  syncContent:SetPoint("BOTTOMRIGHT", -28, 12)
  local syncScroll = CreateFrame("ScrollFrame", "SepheransDropInfoSyncScroll", grid, "FauxScrollFrameTemplate")
  syncScroll:SetPoint("TOPLEFT", syncContent, "TOPLEFT", 0, 0)
  syncScroll:SetPoint("BOTTOMRIGHT", syncContent, "BOTTOMRIGHT", 0, 0)
  UI.syncScroll = syncScroll
  UI.syncRows = {}
  syncScroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 22, refreshSyncUsersUI) end)
  local xOffsets = { 6, 210, 294, 392, 530, 638 }
  local widths = { 190, 70, 80, 120, 90, 150 }
  for i = 1, 14 do
    local row = CreateFrame("Button", nil, syncContent)
    row:SetHeight(20)
    if i == 1 then
      row:SetPoint("TOPLEFT", syncContent, "TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", UI.syncRows[i - 1], "BOTTOMLEFT", 0, -2)
    end
    row:SetPoint("RIGHT", syncContent, "RIGHT", 0, 0)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bg:SetAllPoints(row)
    row.bg:SetVertexColor(0, 0, 0, 0)
    row.cols = {}
    for ci = 1, 6 do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      registerSDIFont(fs, "bodySmall")
      fs:SetPoint("LEFT", xOffsets[ci], 0)
      fs:SetWidth(widths[ci])
      fs:SetJustifyH("LEFT")
      fs:SetTextColor(0.95, 0.93, 0.88)
      row.cols[ci] = fs
    end
    row:SetScript("OnClick", function(self) if self.data then SyncState.selected = self.data.user refreshSyncUsersUI() end end)
    UI.syncRows[i] = row
  end

  table.insert(UI._accentTexts, searchLabel)
  table.insert(UI._accentTexts, saveNameLabel)
  table.insert(UI._accentTexts, savesLabel)
  table.insert(UI._accentTexts, exportLabel)
  table.insert(UI._accentTexts, exportStatusLabel)
  table.insert(UI._accentTexts, syncEnableLabel)
  table.insert(UI._accentTexts, syncEveryLabel)
  table.insert(UI._accentTexts, syncEverySuffix)
  table.insert(UI._accentTexts, syncChannelLabel)
  table.insert(UI._accentTexts, userLabel)
  table.insert(UI._accentTexts, listLabel)
  table.insert(UI._accentTexts, statusLabel)
  table.insert(UI._accentTexts, status2Label)
  table.insert(UI._accentTexts, lastLabel)
  table.insert(UI._accentTexts, optionsTitle)
  table.insert(UI._accentTexts, bgLabel)
  table.insert(UI._accentTexts, borderLabel)
  table.insert(UI._accentTexts, accentLabel)
  table.insert(UI._accentTexts, scaleLabel)

  if UI.searchBox then
    UI.searchBox:SetText(UI.searchText or "")
  end
  if UI.sortButton and UI.sortButton.text then
    UI.sortButton.text:SetText("Sort: " .. getSortLabel(getCurrentSortMode()))
  end
  if UI.syncEnable then UI.syncEnable:SetChecked(SepheransDropInfoDB.settings.syncEnabled and true or false) end
  if UI.syncEveryBox then UI.syncEveryBox:SetText(tostring(getSyncInterval())) end
  if UI.syncChannelBox then UI.syncChannelBox:SetText(getSyncChannelName()) end
  if UI.autoSaveToggle then UI.autoSaveToggle:SetChecked(SepheransDropInfoDB.settings.autoSaveOnLogin ~= false) end
  if UI.saveNameBox then UI.saveNameBox:SetText(date("Save %Y-%m-%d %H:%M:%S")) end
  updateSyncControlStates()
  refreshSyncUsersUI()
  if refreshSaveSlotsUI then refreshSaveSlotsUI() end
  if refreshExportPanel then refreshExportPanel(false) end

  if SepheransDropInfoDB.settings.uiX and SepheransDropInfoDB.settings.uiY then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", SepheransDropInfoDB.settings.uiX, SepheransDropInfoDB.settings.uiY)
  end

  applyUITheme()
  applyUIScale()
end


local function updateMinimapButtonPosition()
  if not UI.minimapButton then return end
  local angle = tonumber(SepheransDropInfoDB.settings.minimapAngle) or 225
  local radius = 78
  local x = math.cos(math.rad(angle)) * radius
  local y = math.sin(math.rad(angle)) * radius
  UI.minimapButton:ClearAllPoints()
  UI.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local toggleMainUI

local function createMinimapButton()
  if UI.minimapButton or not Minimap then return end
  ensureRootDB()

  local btn = CreateFrame("Button", "SepheransDropInfoMiniMapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetWidth(32)
  btn:SetHeight(32)
  btn:SetMovable(true)
  btn:EnableMouse(true)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetAllPoints(btn)

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")
  icon:SetWidth(18)
  icon:SetHeight(18)
  icon:SetPoint("CENTER", 0, 1)

  local hl = btn:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  hl:SetBlendMode("ADD")
  hl:SetAllPoints(btn)

  btn.icon = icon
  btn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      SepheransDropInfoDB.settings.hidden = not SepheransDropInfoDB.settings.hidden
      msg("Tooltip lines " .. (SepheransDropInfoDB.settings.hidden and "disabled" or "enabled"))
    else
      toggleMainUI()
    end
  end)
  btn:SetScript("OnDragStart", function(self)
    self.dragging = true
  end)
  btn:SetScript("OnDragStop", function(self)
    self.dragging = nil
  end)
  btn:SetScript("OnUpdate", function(self)
    if not self.dragging then return end
    local mx, my = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = Minimap:GetCenter()
    mx = mx / scale
    my = my / scale
    local dx, dy = mx - cx, my - cy
    local angle
    if math.atan2 then
      angle = math.deg(math.atan2(dy, dx))
    else
      if dx == 0 then
        angle = (dy >= 0) and 90 or -90
      else
        angle = math.deg(math.atan(dy / dx))
        if dx < 0 then angle = angle + 180 end
      end
    end
    SepheransDropInfoDB.settings.minimapAngle = angle
    updateMinimapButtonPosition()
  end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Sepheran's Drop Info", 1, 0.82, 0)
    GameTooltip:AddLine("Left-click: Open / close", 0.9, 0.9, 0.9)
    GameTooltip:AddLine(" ", 0.9, 0.9, 0.9)
    GameTooltip:AddLine("Right-click: Toggle mouseover tooltip lines", 0.9, 0.9, 0.9)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  UI.minimapButton = btn
  updateMinimapButtonPosition()
end

toggleMainUI = function(show)

  createMainUI()
  createMinimapButton()
  rebuildAggregateObserved()
  if show == nil then
    if UI.frame:IsShown() then UI.frame:Hide() else UI.frame:Show() end
  elseif show then
    UI.frame:Show()
  else
    UI.frame:Hide()
    if UI.optionsFrame then UI.optionsFrame:Hide() end
  end
  if UI.frame:IsShown() then
    applyUIScale()
    applyUITheme()
    refreshMobList()
  end
end

function SDI:CHAT_MSG_ADDON(prefix, message, channel, sender)
  handleSyncMessage(prefix, message, channel, sender)
end

function SDI:CHAT_MSG_CHANNEL(message, sender, language, channelString, target, flags, unknown, channelNumber, channelName)
  local payload = parseSyncChatMessage(message)
  if not payload then return end
  sender = getPlayerNameClean(sender)
  if sender == getPlayerNameClean() then return end
  local chan = string.lower(tostring(channelName or channelString or ""))
  if chan ~= string.lower(getSyncChannelName()) and chan ~= tostring(channelNumber) .. ". " .. string.lower(getSyncChannelName()) then
    -- allow prefixed protocol on the right channel string formats only if they mention the channel name
    if not string.find(chan, string.lower(getSyncChannelName()), 1, true) then return end
  end
  if payload == "QRY" then
    if SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.syncEnabled then
      sendHello("WHISPER", sender)
    end
  end
end

function SDI:ADDON_LOADED(name)
  if name ~= ADDON_NAME then return end
  ensureRealmDB()
  self:RegisterEvent("CHAT_MSG_ADDON")
  self:RegisterEvent("CHAT_MSG_CHANNEL")

  for guid, info in pairs(DB.pending) do
    pendingDeaths[guid] = info
  end

  SLASH_SEPHERANSDROPINFO1 = "/sdi"
  SlashCmdList["SEPHERANSDROPINFO"] = function(msgText)
    local raw = msgText or ""
    local cmd = string.lower(string.match(raw, "^%s*(.-)%s*$") or "")
    if cmd == "" then
      toggleMainUI(true)
    elseif cmd == "help" then
      msg("Commands: /sdi, /sdi help, /sdi hide, /sdi show, /sdi toggle, /sdi status, /sdi verbose, /sdi dump, /sdi reset, /sdi top, /sdi session, /sdi sort, /sdi analytics, /sdi browser, /sdi sync, /sdi saves, /sdi export")
    elseif cmd == "sort" then
      advanceSortMode()
      refreshMobList()
      msg("Sort mode: " .. getSortLabel(getCurrentSortMode()))
    elseif cmd == "session" then
      msg(getSessionSummaryText())
    elseif cmd == "analytics" then
      setActiveTab("analytics")
      toggleMainUI(true)
      refreshMobList()
      msg("Analytics tab opened.")
    elseif cmd == "browser" then
      setActiveTab("browser")
      toggleMainUI(true)
      refreshMobList()
      msg("Browser tab opened.")
    elseif cmd == "sync" then
      setActiveTab("sync")
      toggleMainUI(true)
      refreshMobList()
      msg("Sync tab opened.")
    elseif cmd == "saves" then
      setActiveTab("saves")
      toggleMainUI(true)
      refreshMobList()
      msg("Saves tab opened.")
    elseif cmd == "export" then
      setActiveTab("export")
      toggleMainUI(true)
      refreshExportPanel(true)
      refreshMobList()
      msg("Database export generated.")
    elseif cmd == "top" then
      local entries = mobListData()
      msg("Top observed mobs (current sort: " .. getSortLabel(getCurrentSortMode()) .. ")")
      local maxN = math.min(10, #entries)
      for i = 1, maxN do
        local e = entries[i]
        if e and e.rec then
          msg(string.format("%d. %s | opens=%d money=%s uniqueItems=%d", i, tostring(e.rec.name), tonumber(e.rec.opens) or 0, formatMoney(e.rec.totalMoney or 0), countUniqueItems(e.rec)))
        end
      end
    elseif cmd == "reset" then
      SepheransDropInfoDB.realms[REALM_KEY] = { observed = {}, localObserved = {}, syncSources = {}, quarantinedSources = {}, syncFlags = {}, pending = {}, log = {}, snapshots = (DB and DB.snapshots) or {} }
      DB = SepheransDropInfoDB.realms[REALM_KEY]
      pendingDeaths = {}
      activeLoot = nil
      UI.selectedEntry = nil
      refreshMobList()
      msg("Realm database reset for " .. REALM_KEY .. ".")
    elseif cmd == "status" then
      local n = 0
      for _ in pairs(DB.observed or {}) do n = n + 1 end
      msg("Realm=" .. REALM_KEY .. " | Observed mobs=" .. n .. " | hidden=" .. tostring(SepheransDropInfoDB.settings.hidden) .. " | grouped=" .. tostring(isInGroup()))
    elseif cmd == "verbose" then
      SepheransDropInfoDB.settings.verbose = not SepheransDropInfoDB.settings.verbose
      msg("Verbose logging: " .. tostring(SepheransDropInfoDB.settings.verbose))
    elseif cmd == "hide" then
      SepheransDropInfoDB.settings.hidden = true
      msg("Tooltip hidden.")
    elseif cmd == "show" then
      SepheransDropInfoDB.settings.hidden = false
      msg("Tooltip visible.")
    elseif cmd == "toggle" then
      SepheransDropInfoDB.settings.hidden = not SepheransDropInfoDB.settings.hidden
      msg("Tooltip hidden: " .. tostring(SepheransDropInfoDB.settings.hidden))
    elseif cmd == "dump" then
      msg("Recent log entries for " .. REALM_KEY .. ": " .. tostring(#(DB.log or {})))
      local start = math.max(1, #(DB.log or {}) - 9)
      for i = start, #(DB.log or {}) do
        local e = DB.log[i]
        if e then
          msg(string.format("[%d] %s | %s | %s | %s", i, tostring(e.t), tostring(e.kind), tostring(e.name or e.subEvent or e.reason or "-"), tostring(e.guid or e.npcID or "-")))
        end
      end
    elseif cmd == "debug corrupt" then
      ensureRealmDB()
      saveCurrentSnapshot("Pre Debug Corrupt", true)
      local npcID = 999999991
      DB.localObserved[npcID] = {
        npcID = npcID,
        name = "SDI Corrupt Test Mob",
        opens = 1,
        totalMoney = -12345,
        items = {
          ["item:999999991"] = {
            itemID = 999999991,
            name = "SDI Corrupt Test Item",
            link = "|cffff0000|Hitem:999999991:0:0:0:0:0:0:0|h[SDI Corrupt Test Item]|h|r",
            seen = 999,
            totalQty = -5,
          },
        },
        zones = "debug-corrupt",
        firstSeen = date("%Y-%m-%d %H:%M:%S"),
        lastSeen = date("%Y-%m-%d %H:%M:%S"),
        lastZone = "Debug Test",
      }
      rebuildAggregateObserved()
      refreshMobList()
      msg("Debug corruption inserted. Use /sdi debug clean to remove it.")
    elseif cmd == "debug clean" then
      ensureRealmDB()
      DB.localObserved[999999991] = nil
      DB.syncSources["SDI Corrupt Test Mob"] = nil
      DB.quarantinedSources["SDI Corrupt Test Mob"] = nil
      rebuildAggregateObserved()
      refreshMobList()
      msg("Debug corruption removed.")
    else
      toggleMainUI(true)
    end
  end

  createMainUI()
  createMinimapButton()
  rebuildAggregateObserved()
  if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", function(self, event, message, sender, language, channelString, target, flags, unknown, channelNumber, channelName)
      local payload = parseSyncChatMessage(message)
      if not payload then return false end
      local chan = string.lower(tostring(channelName or channelString or ""))
      if chan ~= string.lower(getSyncChannelName()) and not string.find(chan, string.lower(getSyncChannelName()), 1, true) then
        return false
      end
      return true
    end)
  end
  if GameTooltip and not GameTooltip.sdiHooked then
    GameTooltip:HookScript("OnHide", clearTooltipMarker)
    GameTooltip:HookScript("OnTooltipSetUnit", function(self)
      local _, unit = self:GetUnit()
      if not unit then unit = "mouseover" end
      clearTooltipMarker()
      addTooltipForMouseover(self, unit)
    end)
    GameTooltip.sdiHooked = true
  end
  msg("Loaded. Use the minimap button to open the browser.")
end

function SDI:PLAYER_ENTERING_WORLD()
  ensureRealmDB()
  rebuildAggregateObserved()
  cleanupPending()
  if SepheransDropInfoDB.settings.autoSaveOnLogin ~= false and not SaveState.autosavedThisSession then
    saveCurrentSnapshot("Autosave", true)
    SaveState.autosavedThisSession = true
  end
  addLog("enter_world", { grouped = isInGroup() })
  refreshMobList()
  if SepheransDropInfoDB.settings.syncEnabled then
    broadcastDiscovery()
  end
end

function SDI:GROUP_ROSTER_UPDATE()
  addLog("group_state", { grouped = isInGroup() })
  if SepheransDropInfoDB.settings.verbose then
    msg("Group state changed. grouped=" .. tostring(isInGroup()))
  end
end

function SDI:PARTY_MEMBERS_CHANGED()
  self:GROUP_ROSTER_UPDATE()
end

function SDI:RAID_ROSTER_UPDATE()
  self:GROUP_ROSTER_UPDATE()
end

function SDI:COMBAT_LOG_EVENT_UNFILTERED(...)
  local info = extractCLEU(...)
  if not info then return end

  if info.subEvent == "PARTY_KILL" and isPlayerSource(info.sourceGUID, info.sourceName) then
    local npcID = parseNPCIDFromGUID(info.destGUID)
    rememberPendingDeath(info.destGUID, info.destName, npcID)
    addLog("party_kill", {
      subEvent = info.subEvent,
      guid = info.destGUID,
      name = info.destName,
      npcID = npcID,
    })
    if SepheransDropInfoDB.settings.verbose then
      msg(string.format("Kill candidate: %s | npcID=%s", tostring(info.destName), tostring(npcID)))
    end
    refreshMobList()
  elseif info.subEvent == "UNIT_DIED" then
    local npcID = parseNPCIDFromGUID(info.destGUID)
    addLog("unit_died", {
      subEvent = info.subEvent,
      guid = info.destGUID,
      name = info.destName,
      npcID = npcID,
      playerSource = isPlayerSource(info.sourceGUID, info.sourceName),
    })
  end
end

function SDI:LOOT_OPENED(autoLoot)
  cleanupPending()
  local candidate, sourceKind = chooseLootSourceCandidate()
  if candidate then
    ensureKillCountForCandidate(candidate)
  end
  local slots = getLootSlotsSnapshot()

  activeLoot = {
    openedAt = now(),
    autoLoot = autoLoot and true or false,
    guid = candidate and candidate.guid or nil,
    npcID = candidate and candidate.npcID or nil,
    name = candidate and candidate.name or nil,
    unit = candidate and candidate.unit or nil,
    sourceKind = sourceKind,
    slots = slots,
    zone = candidate and candidate.zone or getCurrentZoneName(),
    targetGUID = UnitGUID("target"),
    targetName = UnitName("target"),
    mouseoverGUID = UnitGUID("mouseover"),
    mouseoverName = UnitName("mouseover"),
    grouped = isInGroup(),
  }

  addLog("loot_opened", {
    guid = activeLoot.guid,
    npcID = activeLoot.npcID,
    name = activeLoot.name,
    sourceKind = sourceKind,
    slotCount = #slots,
    grouped = activeLoot.grouped,
    targetGUID = activeLoot.targetGUID,
    mouseoverGUID = activeLoot.mouseoverGUID,
  })

  if SepheransDropInfoDB.settings.verbose then
    msg(string.format("Loot opened | source=%s | name=%s | npcID=%s | slots=%d", tostring(sourceKind), tostring(activeLoot.name), tostring(activeLoot.npcID), #slots))
  end
  refreshMobList()
end

function SDI:LOOT_SLOT_CLEARED(slot)
  if not activeLoot then return end
  addLog("loot_slot_cleared", {
    slot = slot,
    guid = activeLoot.guid,
    npcID = activeLoot.npcID,
    name = activeLoot.name,
  })
end

function SDI:LOOT_CLOSED()
  commitActiveLoot("LOOT_CLOSED")
  refreshMobList()
end

function SDI:UPDATE_MOUSEOVER_UNIT()
  clearTooltipMarker()
  if SepheransDropInfoDB and SepheransDropInfoDB.settings and SepheransDropInfoDB.settings.hidden then
    return
  end
  if GameTooltip and GameTooltip:IsShown() and UnitExists("mouseover") and not isPlayerUnit("mouseover") then
    addTooltipForMouseover(GameTooltip, "mouseover")
  end
end

SDI:SetScript("OnUpdate", function(self, elapsed)
  SyncState._elapsed = (SyncState._elapsed or 0) + (elapsed or 0)
  if SyncState.refreshAt and SyncState.refreshAt > 0 and GetTime and GetTime() >= SyncState.refreshAt then
    SyncState.refreshAt = 0
    if SyncState.status == "Refreshing users..." then setSyncStatus("Online |cff00ff00●|r") end
    refreshSyncUsersUI()
  end
  if SyncState.checkExpiresAt and SyncState.checkExpiresAt > 0 and GetTime and GetTime() >= SyncState.checkExpiresAt then
    SyncState.checkExpiresAt = nil
    SyncState.checkRequested = false
    SyncState.checkRequestedUsers = nil
    for _, user in pairs(SyncState.users or {}) do
      if user.checkPending then
        user.toSync = getEstimatedSyncMobCount(user.sender or user.user, user.mobs)
        user.checkPending = false
      end
    end
    if SyncState.status == "Checking sync status..." then setSyncStatus("Sync check complete") end
    refreshSyncUsersUI()
  end
  if not SepheransDropInfoDB or not SepheransDropInfoDB.settings or not SepheransDropInfoDB.settings.syncEnabled then return end
  local every = getSyncInterval()
  if SyncState._elapsed >= every then
    SyncState._elapsed = 0
    broadcastDiscovery()
  end
end)

SDI:SetScript("OnEvent", function(self, event, ...)
  if self[event] then
    self[event](self, ...)
  end
end)

SDI:RegisterEvent("ADDON_LOADED")
SDI:RegisterEvent("PLAYER_ENTERING_WORLD")
SDI:RegisterEvent("PARTY_MEMBERS_CHANGED")
SDI:RegisterEvent("RAID_ROSTER_UPDATE")
SDI:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
SDI:RegisterEvent("LOOT_OPENED")
SDI:RegisterEvent("LOOT_SLOT_CLEARED")
SDI:RegisterEvent("LOOT_CLOSED")
SDI:RegisterEvent("UPDATE_MOUSEOVER_UNIT")

GameTooltip:HookScript("OnHide", function()
  clearTooltipMarker()
end)
