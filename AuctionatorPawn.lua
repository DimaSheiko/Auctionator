
local addonName, addonTable = ...;
local zc = addonTable.zc;

-----------------------------------------
-- Pawn integration. Isolates all Pawn contact and reimplements none of its
-- math: it only calls Pawn's public API to score an item with the scale that
-- matches the player's active spec. The rest of Auctionator only uses:
--     Atr_Pawn_IsAvailable ()
--     Atr_Pawn_GetScore (itemLink)   -> number (or nil if not scorable yet)
--     Atr_Pawn_WarmScans (scanList)
-----------------------------------------

-- Class token -> Wowhead scale internal names, in talent-tab order.
-- (Druid has 4 scales for 3 tabs: Feral maps to the DPS variant by default.)
local ATR_PAWN_CLASS_SCALES =
{
	WARRIOR		= { "WarriorArms",			"WarriorFury",			"WarriorTank" },
	PALADIN		= { "PaladinHoly",			"PaladinTank",			"PaladinRetribution" },
	HUNTER		= { "HunterBeastMastery",	"HunterMarksman",		"HunterSurvival" },
	ROGUE		= { "RogueAssassination",	"RogueCombat",			"RogueSubtlety" },
	PRIEST		= { "PriestDiscipline",		"PriestHoly",			"PriestShadow" },
	DEATHKNIGHT	= { "DeathKnightBloodTank",	"DeathKnightFrostDps",	"DeathKnightUnholyDps" },
	SHAMAN		= { "ShamanElemental",		"ShamanEnhancement",	"ShamanRestoration" },
	MAGE		= { "MageArcane",			"MageFire",				"MageFrost" },
	WARLOCK		= { "WarlockAffliction",	"WarlockDemonology",	"WarlockDestruction" },
	DRUID		= { "DruidBalance",			"DruidFeralDps",		"DruidRestoration" },
};

-- Class token -> PascalCase prefix of its Wowhead scale names (for the selector).
local ATR_PAWN_CLASS_PREFIX =
{
	WARRIOR		= "Warrior",
	PALADIN		= "Paladin",
	HUNTER		= "Hunter",
	ROGUE		= "Rogue",
	PRIEST		= "Priest",
	DEATHKNIGHT	= "DeathKnight",
	SHAMAN		= "Shaman",
	MAGE		= "Mage",
	WARLOCK		= "Warlock",
	DRUID		= "Druid",
};

-----------------------------------------
-- A scale is only usable by a character of its own class.

local function Atr_Pawn_IsScaleForPlayerClass (fullName)

	if (not fullName or fullName == "") then
		return false;
	end

	local _, classToken = UnitClass ("player");
	local prefix = classToken and ATR_PAWN_CLASS_PREFIX[classToken];
	if (not prefix) then
		return false;
	end

	local internal = fullName:match ('^"[^"]*":(.+)$');

	return (internal ~= nil and internal:sub (1, #prefix) == prefix);
end

-----------------------------------------

local ATR_PAWN_PROVIDER = "Wowhead";

local ATR_PAWN_MAX_TRIES = 25;			-- per-item retries before giving up

-- equipLoc -> inventory slot IDs to compare against.
local ATR_PAWN_EQUIPLOC_SLOTS =
{
	INVTYPE_HEAD			= { 1 },
	INVTYPE_NECK			= { 2 },
	INVTYPE_SHOULDER		= { 3 },
	INVTYPE_BODY			= { 4 },
	INVTYPE_CHEST			= { 5 },
	INVTYPE_ROBE			= { 5 },
	INVTYPE_WAIST			= { 6 },
	INVTYPE_LEGS			= { 7 },
	INVTYPE_FEET			= { 8 },
	INVTYPE_WRIST			= { 9 },
	INVTYPE_HAND			= { 10 },
	INVTYPE_FINGER			= { 11, 12 },
	INVTYPE_TRINKET			= { 13, 14 },
	INVTYPE_CLOAK			= { 15 },
	INVTYPE_WEAPON			= { 16, 17 },
	INVTYPE_2HWEAPON		= { 16 },
	INVTYPE_WEAPONMAINHAND	= { 16 },
	INVTYPE_WEAPONOFFHAND	= { 17 },
	INVTYPE_SHIELD			= { 17 },
	INVTYPE_HOLDABLE		= { 17 },
	INVTYPE_RANGED			= { 18 },
	INVTYPE_RANGEDRIGHT		= { 18 },
	INVTYPE_THROWN			= { 18 },
	INVTYPE_RELIC			= { 18 },
	INVTYPE_TABARD			= { 19 },
};

-- Types that share a slot but are only interchangeable within their own group
-- (a weapon must not be compared against a shield in slot 17).
local ATR_PAWN_WEAPON_LOCS =
{
	INVTYPE_WEAPON			= true,
	INVTYPE_WEAPONMAINHAND	= true,
	INVTYPE_WEAPONOFFHAND	= true,
	INVTYPE_2HWEAPON		= true,
};

local ATR_PAWN_OFFHAND_LOCS =
{
	INVTYPE_SHIELD			= true,
	INVTYPE_HOLDABLE		= true,
};

local ATR_PAWN_CHEST_LOCS =
{
	INVTYPE_CHEST			= true,
	INVTYPE_ROBE			= true,
};

local ATR_PAWN_RANGED_LOCS =
{
	INVTYPE_RANGED			= true,
	INVTYPE_RANGEDRIGHT		= true,
	INVTYPE_THROWN			= true,
	INVTYPE_RELIC			= true,
};

local function Atr_Pawn_EquipLocsComparable (a, b)

	if (a == b) then return true; end
	if (ATR_PAWN_WEAPON_LOCS[a]  and ATR_PAWN_WEAPON_LOCS[b])  then return true; end
	if (ATR_PAWN_OFFHAND_LOCS[a] and ATR_PAWN_OFFHAND_LOCS[b]) then return true; end
	if (ATR_PAWN_CHEST_LOCS[a]   and ATR_PAWN_CHEST_LOCS[b])   then return true; end
	if (ATR_PAWN_RANGED_LOCS[a]  and ATR_PAWN_RANGED_LOCS[b])  then return true; end
	return false;
end

local gActiveScaleName	= nil;			-- active scale full name (cache)
local gScoreCache		= {};			-- [itemLink] = raw score, or false if not scorable
local gEquippedCache	= {};			-- [equipLoc] = lowest equipped score, or false
local gPending			= {};			-- [itemLink] = retries left
local gTicker			= nil;

-----------------------------------------

function Atr_Pawn_IsAvailable ()

	return (type(PawnGetItemData) == "function"
		and type(PawnGetSingleValueFromItem) == "function"
		and PawnCommon ~= nil
		and PawnCommon.Scales ~= nil);
end

-----------------------------------------
-- Scale internal name from the dominant talent tab.

local function Atr_Pawn_DetectInternalScale ()

	local _, classToken = UnitClass ("player");

	local scales = classToken and ATR_PAWN_CLASS_SCALES[classToken];
	if (not scales) then
		return nil;
	end

	local group = 1;
	if (type(GetActiveTalentGroup) == "function") then
		group = GetActiveTalentGroup() or 1;
	end

	local numTabs = 3;
	if (type(GetNumTalentTabs) == "function") then
		numTabs = GetNumTalentTabs() or 3;
	end

	local bestTab		= 1;
	local bestPoints	= -1;

	local i;
	for i = 1, numTabs do
		local _, _, pointsSpent = GetTalentTabInfo (i, false, false, group);
		pointsSpent = pointsSpent or 0;
		if (pointsSpent > bestPoints) then
			bestPoints	= pointsSpent;
			bestTab		= i;
		end
	end

	return scales[bestTab];
end

-----------------------------------------
-- Active scale full name, honoring the character's manual override.

function Atr_Pawn_GetActiveScaleName ()

	if (gActiveScaleName) then
		return gActiveScaleName;
	end

	if (not Atr_Pawn_IsAvailable()) then
		return nil;
	end

	local override = Atr_Pawn_GetScaleOverride();
	if (override and PawnCommon.Scales[override]) then
		gActiveScaleName = override;
		return gActiveScaleName;
	end

	local internal = Atr_Pawn_DetectInternalScale();
	if (not internal) then
		return nil;
	end

	local name = '"'..ATR_PAWN_PROVIDER..'":'..internal;

	if (PawnCommon.Scales[name]) then
		gActiveScaleName = name;
		return name;
	end

	return nil;
end

-----------------------------------------

local function Atr_Pawn_EnsureTicker ()

	if (gTicker == nil) then
		gTicker = CreateFrame ("Frame");
		gTicker.elapsed = 0;
		gTicker:Hide();
		gTicker:SetScript ("OnUpdate", Atr_Pawn_TickerOnUpdate);
	end

	gTicker:Show();
end

-----------------------------------------
-- PawnGetSingleValueFromItem returns (enchanted, unenchanted). Match Pawn's
-- tooltip choice (defaults to the unenchanted/base value).

local function Atr_Pawn_PickDisplayValue (enchanted, unenchanted)

	if (PawnCommon and PawnCommon.ShowEnchanted) then
		return enchanted or unenchanted or 0;
	end

	return unenchanted or enchanted or 0;
end

-----------------------------------------
-- Number (>0), nil if not cached yet, or false if not scorable for this scale.

local function Atr_Pawn_ComputeNow (itemLink, scaleName)

	if (not GetItemInfo (itemLink)) then
		return nil;
	end

	local Item = PawnGetItemData (itemLink);
	if (not Item or not Item.Values or #Item.Values == 0) then
		return nil;
	end

	local value = Atr_Pawn_PickDisplayValue (PawnGetSingleValueFromItem (Item, scaleName));
	if (not value or value <= 0) then
		return false;
	end

	return value;
end

-----------------------------------------
-- Raw score for the active scale, with cache and retry queue for uncached items.

local function Atr_Pawn_GetRawScore (itemLink)

	if (not itemLink or not Atr_Pawn_IsAvailable()) then
		return nil;
	end

	local cached = gScoreCache[itemLink];
	if (cached ~= nil) then
		if (cached == false) then return nil; end
		return cached;
	end

	local scaleName = Atr_Pawn_GetActiveScaleName();
	if (not scaleName) then
		return nil;
	end

	local result = Atr_Pawn_ComputeNow (itemLink, scaleName);

	if (result == nil) then
		if (gPending[itemLink] == nil) then
			gPending[itemLink] = ATR_PAWN_MAX_TRIES;
			Atr_Pawn_EnsureTicker();
		end
		return nil;
	end

	gScoreCache[itemLink]	= result;
	gPending[itemLink]		= nil;

	if (result == false) then return nil; end
	return result;
end

-----------------------------------------

function Atr_Pawn_DiffMode ()
	return (AUCTIONATOR_SAVEDVARS and AUCTIONATOR_SAVEDVARS.PawnShowDiff) and true or false;
end

function Atr_Pawn_SetDiffMode (on)
	if (AUCTIONATOR_SAVEDVARS) then
		AUCTIONATOR_SAVEDVARS.PawnShowDiff = on and true or false;
	end
	if (type(Atr_Pawn_NotifyScoresReady) == "function") then
		Atr_Pawn_NotifyScoresReady();
	end
end

-----------------------------------------
-- Lowest score among items equipped in an equipLoc's slots. nil if the slot is
-- empty or nothing comparable is equipped (i.e. show the full value).

local function Atr_Pawn_GetEquippedScoreForLoc (equipLoc, scaleName)

	if (not equipLoc or equipLoc == "" or equipLoc == "INVTYPE_NON_EQUIP") then
		return nil;
	end

	local cached = gEquippedCache[equipLoc];
	if (cached ~= nil) then
		if (cached == false) then return nil; end
		return cached;
	end

	local slots = ATR_PAWN_EQUIPLOC_SLOTS[equipLoc];
	if (not slots) then
		gEquippedCache[equipLoc] = false;
		return nil;
	end

	local best = nil;

	local i;
	for i = 1, #slots do
		local link = GetInventoryItemLink ("player", slots[i]);
		if (link) then
			local equippedLoc = select (9, GetItemInfo (link));
			if (Atr_Pawn_EquipLocsComparable (equipLoc, equippedLoc)) then
				local Item = PawnGetItemData (link);
				local v = 0;
				if (Item and Item.Values and #Item.Values > 0) then
					v = Atr_Pawn_PickDisplayValue (PawnGetSingleValueFromItem (Item, scaleName)) or 0;
				end
				if (v > 0) then
					if (best == nil or v < best) then best = v; end
				else
					best = 0;		-- comparable but not scorable -> treat as empty
				end
			end
		else
			best = 0;				-- empty applicable slot -> full upgrade
		end
	end

	if (best == nil or best == 0) then
		gEquippedCache[equipLoc] = false;
		return nil;
	end

	gEquippedCache[equipLoc] = best;
	return best;
end

-----------------------------------------
-- Value to display and sort by: raw score, or difference vs equipped in diff mode.

function Atr_Pawn_GetScore (itemLink)

	local raw = Atr_Pawn_GetRawScore (itemLink);
	if (raw == nil) then
		return nil;
	end

	if (not Atr_Pawn_DiffMode()) then
		return raw;
	end

	local scaleName = Atr_Pawn_GetActiveScaleName();
	if (not scaleName) then
		return raw;
	end

	local equipLoc = select (9, GetItemInfo (itemLink));
	local equipped = Atr_Pawn_GetEquippedScoreForLoc (equipLoc, scaleName);

	if (equipped) then
		return raw - equipped;
	end

	return raw;
end

-----------------------------------------
-- Prewarm scores for a whole AtrScan list.

function Atr_Pawn_WarmScans (scanList)

	if (not scanList or not Atr_Pawn_IsAvailable()) then
		return;
	end

	if (not Atr_Pawn_GetActiveScaleName()) then
		return;
	end

	local n;
	for n = 1, #scanList do
		local scn = scanList[n];
		if (scn and scn.itemLink) then
			Atr_Pawn_GetScore (scn.itemLink);
		end
	end
end

-----------------------------------------
-- Format with the same decimals Pawn uses (PawnCommon.Digits, default 1).

function Atr_Pawn_FormatScore (score)

	if (not score) then
		return "";
	end

	local digits = 1;
	if (PawnCommon and PawnCommon.Digits) then
		digits = PawnCommon.Digits;
	end

	return string.format ("%."..digits.."f", score);
end

-----------------------------------------

function Atr_Pawn_TickerOnUpdate (self, elapsed)

	self.elapsed = self.elapsed + elapsed;
	if (self.elapsed < 0.15) then
		return;
	end
	self.elapsed = 0;

	local scaleName = Atr_Pawn_GetActiveScaleName();
	if (not scaleName) then
		self:Hide();
		return;
	end

	local anyResolved	= false;
	local anyPending	= false;
	local processed		= 0;

	local itemLink, tries;
	for itemLink, tries in pairs (gPending) do

		local result = Atr_Pawn_ComputeNow (itemLink, scaleName);

		if (result ~= nil) then
			gScoreCache[itemLink]	= result;
			gPending[itemLink]		= nil;
			anyResolved				= true;
		else
			tries = tries - 1;
			if (tries <= 0) then
				gScoreCache[itemLink]	= false;
				gPending[itemLink]		= nil;
			else
				gPending[itemLink]		= tries;
				anyPending				= true;
			end
		end

		processed = processed + 1;
		if (processed >= 20) then					-- spread the cost across frames
			anyPending = true;
			break;
		end
	end

	if (anyResolved and type(Atr_Pawn_NotifyScoresReady) == "function") then
		Atr_Pawn_NotifyScoresReady();
	end

	if (not anyPending and not next (gPending)) then
		self:Hide();
	end
end

-----------------------------------------
-- Spec change: the active scale (and every score) changes; invalidate and repaint.

local function Atr_Pawn_OnSpecChanged ()

	gActiveScaleName	= nil;
	gScoreCache			= {};
	gEquippedCache		= {};
	gPending			= {};

	if (gTicker) then
		gTicker:Hide();
	end

	if (type(Atr_Pawn_NotifyScoresReady) == "function") then
		Atr_Pawn_NotifyScoresReady();
	end
end

-----------------------------------------
-- Equipment change: only comparisons change, and only matter in diff mode.

local function Atr_Pawn_OnEquipmentChanged ()

	gEquippedCache = {};

	if (Atr_Pawn_DiffMode() and type(Atr_Pawn_NotifyScoresReady) == "function") then
		Atr_Pawn_NotifyScoresReady();
	end
end

-----------------------------------------

local gEventFrame = CreateFrame ("Frame");
gEventFrame:RegisterEvent ("PLAYER_LOGIN");
gEventFrame:RegisterEvent ("PLAYER_TALENT_UPDATE");
gEventFrame:RegisterEvent ("CHARACTER_POINTS_CHANGED");
gEventFrame:RegisterEvent ("ACTIVE_TALENT_GROUP_CHANGED");
gEventFrame:RegisterEvent ("PLAYER_EQUIPMENT_CHANGED");
gEventFrame:SetScript ("OnEvent", function (self, event, ...)
	if (event == "PLAYER_LOGIN") then
		-- drop the old account-wide override; the setting is per character now
		if (AUCTIONATOR_SAVEDVARS) then
			AUCTIONATOR_SAVEDVARS.PawnScaleOverride = nil;
		end
	elseif (event == "PLAYER_EQUIPMENT_CHANGED") then
		Atr_Pawn_OnEquipmentChanged();
	else
		Atr_Pawn_OnSpecChanged();
	end
end);

-----------------------------------------
-- Wowhead scales of the player's class, for the options selector.
-- Each entry: { name = '"Wowhead":XxxYyy', display = localized name }.

function Atr_Pawn_GetSelectableScales ()

	local result = {};

	if (not Atr_Pawn_IsAvailable() or type(PawnGetAllScalesEx) ~= "function") then
		return result;
	end

	local _, s;
	for _, s in ipairs (PawnGetAllScalesEx()) do
		if (s.IsProvider and s.Name and Atr_Pawn_IsScaleForPlayerClass (s.Name)) then
			local internal = s.Name:match ('^"[^"]*":(.+)$');
			table.insert (result, { name = s.Name, display = s.LocalizedName or internal });
		end
	end

	return result;
end

-----------------------------------------

function Atr_Pawn_GetScaleDisplayName (fullName)

	if (not fullName or type(PawnGetAllScalesEx) ~= "function") then
		return nil;
	end

	local _, s;
	for _, s in ipairs (PawnGetAllScalesEx()) do
		if (s.Name == fullName) then
			return s.LocalizedName;
		end
	end

	return nil;
end

-----------------------------------------

-- The override is per character (AUCTIONATOR_PAWN_SCALE); a scale belonging to
-- another class is ignored so the column falls back to automatic detection.

function Atr_Pawn_GetScaleOverride ()

	local ov = AUCTIONATOR_PAWN_SCALE;

	if (ov and ov ~= "" and Atr_Pawn_IsScaleForPlayerClass (ov)) then
		return ov;
	end

	return nil;
end

-----------------------------------------
-- Set (or clear, with nil) the scale used by the column; resets caches and repaints.

function Atr_Pawn_SetScaleOverride (fullName)

	if (fullName and fullName ~= "" and PawnCommon and PawnCommon.Scales and PawnCommon.Scales[fullName]
			and Atr_Pawn_IsScaleForPlayerClass (fullName)) then
		AUCTIONATOR_PAWN_SCALE = fullName;
	else
		AUCTIONATOR_PAWN_SCALE = nil;
	end

	Atr_Pawn_OnSpecChanged();
end

-----------------------------------------
--   /atr pawnscale                 -> show the detected active scale
--   /atr pawnscale "Wowhead":Xxx   -> set a manual override
--   /atr pawnscale auto            -> back to automatic detection

function Atr_Pawn_HandleScaleCommand (arg)

	if (not Atr_Pawn_IsAvailable()) then
		zc.msg_pink ("Pawn is not available.");
		return;
	end

	arg = arg and strtrim(arg) or "";

	if (arg == "auto" or arg == "") then
		if (arg == "auto") then
			Atr_Pawn_SetScaleOverride (nil);
		end
		zc.msg_pink ("Active Pawn scale: "..(Atr_Pawn_GetActiveScaleName() or "(none)"));
		return;
	end

	if (not PawnCommon.Scales[arg]) then
		zc.msg_pink ("No such Pawn scale: "..arg);
		return;
	end

	if (not Atr_Pawn_IsScaleForPlayerClass (arg)) then
		zc.msg_pink ("Not a Pawn scale for this character's class: "..arg);
		return;
	end

	Atr_Pawn_SetScaleOverride (arg);
	zc.msg_pink ("Pawn scale set: "..arg);
end

-----------------------------------------
--   /atr pawndiff        -> toggle
--   /atr pawndiff on|off -> set the mode

function Atr_Pawn_HandleDiffCommand (arg)

	arg = arg and strtrim(arg):lower() or "";

	if (arg == "on") then
		Atr_Pawn_SetDiffMode (true);
	elseif (arg == "off") then
		Atr_Pawn_SetDiffMode (false);
	else
		Atr_Pawn_SetDiffMode (not Atr_Pawn_DiffMode());
	end

	zc.msg_pink ("Pawn column: "..(Atr_Pawn_DiffMode() and "difference vs equipped" or "full score"));
end
