--[[--------------------------------------------------------------------
    Ovale Spell Priority
    Copyright (C) 2013 Johnny C. Lam

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License in the LICENSE
    file accompanying this program.
--]]--------------------------------------------------------------------

-- This addon tracks the player's stats as available on the in-game paper doll.

local _, Ovale = ...
local OvalePaperDoll = Ovale:NewModule("OvalePaperDoll", "AceEvent-3.0")
Ovale.OvalePaperDoll = OvalePaperDoll

--<private-static-properties>
local OvalePoolRefCount = Ovale.OvalePoolRefCount

-- Forward declarations for module dependencies.
local OvaleEquipement = nil
local OvaleStance = nil
local OvaleState = nil

local select = select
local tonumber = tonumber
local API_GetCritChance = GetCritChance
local API_GetMasteryEffect = GetMasteryEffect
local API_GetMeleeHaste = GetMeleeHaste
local API_GetRangedCritChance = GetRangedCritChance
local API_GetRangedHaste = GetRangedHaste
local API_GetSpecialization = GetSpecialization
local API_GetSpellBonusDamage = GetSpellBonusDamage
local API_GetSpellBonusHealing = GetSpellBonusHealing
local API_GetSpellCritChance = GetSpellCritChance
local API_GetTime = GetTime
local API_UnitAttackPower = UnitAttackPower
local API_UnitAttackSpeed = UnitAttackSpeed
local API_UnitClass = UnitClass
local API_UnitDamage = UnitDamage
local API_UnitLevel = UnitLevel
local API_UnitRangedAttackPower = UnitRangedAttackPower
local API_UnitSpellHaste = UnitSpellHaste
local API_UnitStat = UnitStat

-- Player's class.
local self_class = select(2, API_UnitClass("player"))
-- Snapshot table pool.
local self_pool = OvalePoolRefCount("OvalePaperDoll_pool")
-- Total number of snapshots taken.
local self_snapshotCount = 0

local OVALE_PAPERDOLL_DEBUG = "paper_doll"
local OVALE_SNAPSHOT_DEBUG = "snapshot"

local OVALE_SPELLDAMAGE_SCHOOL = {
	DEATHKNIGHT = 4, -- Nature
	DRUID = 4, -- Nature
	HUNTER = 4, -- Nature
	MAGE = 5, -- Frost
	MONK = 4, -- Nature
	PALADIN = 2, -- Holy
	PRIEST = 2, -- Holy
	ROGUE = 4, -- Nature
	SHAMAN = 4, -- Nature
	WARLOCK = 6, -- Shadow
	WARRIOR = 4, -- Nature
}
local OVALE_HEALING_CLASS = {
	DRUID = true,
	MONK = true,
	PALADIN = true,
	PRIEST = true,
	SHAMAN = true,
}
--</private-static-properties>

--<public-static-properties>
-- player's level
OvalePaperDoll.level = API_UnitLevel("player")
-- Player's current specialization.
OvalePaperDoll.specialization = nil
-- Most recent snapshot.
OvalePaperDoll.snapshot = nil

-- Maps field names to default value & descriptions for player's stats.
OvalePaperDoll.SNAPSHOT_STATS = {
	-- primary stats
	agility = 				{ default = 0, description = "agility" },
	intellect =				{ default = 0, description = "intellect" },
	spirit =				{ default = 0, description = "spirit" },
	stamina =				{ default = 0, description = "stamina" },
	strength =				{ default = 0, description = "strength" },

	attackPower =			{ default = 0, description = "attack power" },
	rangedAttackPower =		{ default = 0, description = "ranged attack power" },
	-- percent increase of effect due to mastery
	masteryEffect =			{ default = 0, description = "mastery effect" },
	-- percent increase to melee critical strike & haste
	meleeCrit =				{ default = 0, description = "melee critical strike chance" },
	meleeHaste =			{ default = 0, description = "melee haste effect" },
	-- percent increase to ranged critical strike & haste
	rangedCrit =			{ default = 0, description = "ranged critical strike chance" },
	rangedHaste =			{ default = 0, description = "ranged haste effect" },
	-- percent increase to spell critical strike & haste
	spellCrit =				{ default = 0, description = "spell critical strike chance" },
	spellHaste =			{ default = 0, description = "spell haste effect" },
	-- spellpower
	spellBonusDamage =		{ default = 0, description = "spell bonus damage" },
	spellBonusHealing =		{ default = 0, description = "spell bonus healing" },
	-- normalized weapon damage of mainhand and offhand weapons
	mainHandWeaponDamage =	{ default = 0, description = "normalized weapon damage (mainhand)" },
	offHandWeaponDamage =	{ default = 0, description = "normalized weapon damage (offhand)" },
	baseDamageMultiplier =	{ default = 1, description = "base damage multiplier" },
}
--</public-static-properties>

--<private-static-methods>
-- Return table for most recent snapshot to be updated through events.
local function UpdateCurrentSnapshot()
	local self = OvalePaperDoll
	local now = API_GetTime()
	if self.snapshot.snapshotTime < now then
		Ovale:DebugPrintf(OVALE_SNAPSHOT_DEBUG, true, "New snapshot.")
		self_snapshotCount = self_snapshotCount + 1
		local snapshot = self_pool:Get()
		-- Pre-populate snapshot with the most recent previously-captured stats.
		for k in pairs(self.SNAPSHOT_STATS) do
			snapshot[k] = self.snapshot[k]
		end
		snapshot.snapshotTime = now
		self_pool:Release(self.snapshot)
		self.snapshot = snapshot
	end
	return self.snapshot
end
--</private-static-methods>

--<public-static-methods>
function OvalePaperDoll:OnInitialize()
	-- Resolve module dependencies.
	OvaleEquipement = Ovale.OvaleEquipement
	OvaleStance = Ovale.OvaleStance
	OvaleState = Ovale.OvaleState

	-- Initialize latest snapshot table.
	if self.snapshot then
		self.snapshot:Release()
	end
	self.snapshot = self_pool:Get()
	for k, info in pairs(self.SNAPSHOT_STATS) do
		self.snapshot[k] = info.default
	end
	self.snapshot.snapshotTime = 0
end

function OvalePaperDoll:OnEnable()
	self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "UpdateStats")
	self:RegisterEvent("COMBAT_RATING_UPDATE")
	self:RegisterEvent("MASTERY_UPDATE")
	self:RegisterEvent("PLAYER_ALIVE", "UpdateStats")
	self:RegisterEvent("PLAYER_DAMAGE_DONE_MODS")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "UpdateStats")
	self:RegisterEvent("PLAYER_LEVEL_UP")
	self:RegisterEvent("PLAYER_REGEN_ENABLED")
	self:RegisterEvent("PLAYER_TALENT_UPDATE", "UpdateStats")
	self:RegisterEvent("SPELL_POWER_CHANGED")
	self:RegisterEvent("UNIT_ATTACK_POWER")
	self:RegisterEvent("UNIT_DAMAGE", "UpdateDamage")
	self:RegisterEvent("UNIT_LEVEL")
	self:RegisterEvent("UNIT_RANGEDDAMAGE")
	self:RegisterEvent("UNIT_RANGED_ATTACK_POWER")
	self:RegisterEvent("UNIT_SPELL_HASTE")
	self:RegisterEvent("UNIT_STATS")
	self:RegisterMessage("Ovale_EquipmentChanged", "UpdateDamage")
	self:RegisterMessage("Ovale_StanceChanged", "UpdateDamage")
	OvaleState:RegisterState(self, self.statePrototype)
end

function OvalePaperDoll:OnDisable()
	OvaleState:UnregisterState(self)
	self:UnregisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
	self:UnregisterEvent("COMBAT_RATING_UPDATE")
	self:UnregisterEvent("MASTERY_UPDATE")
	self:UnregisterEvent("PLAYER_ALIVE")
	self:UnregisterEvent("PLAYER_DAMAGE_DONE_MODS")
	self:UnregisterEvent("PLAYER_ENTERING_WORLD")
	self:UnregisterEvent("PLAYER_LEVEL_UP")
	self:UnregisterEvent("PLAYER_REGEN_ENABLED")
	self:UnregisterEvent("PLAYER_TALENT_UPDATE")
	self:UnregisterEvent("SPELL_POWER_CHANGED")
	self:UnregisterEvent("UNIT_ATTACK_POWER")
	self:UnregisterEvent("UNIT_DAMAGE")
	self:UnregisterEvent("UNIT_LEVEL")
	self:UnregisterEvent("UNIT_RANGEDDAMAGE")
	self:UnregisterEvent("UNIT_RANGED_ATTACK_POWER")
	self:UnregisterEvent("UNIT_SPELL_HASTE")
	self:UnregisterEvent("UNIT_STATS")
	self:UnregisterMessage("Ovale_EquipmentChanged")
	self:UnregisterMessage("Ovale_StanceChanged")
	self_pool:Drain()
end

function OvalePaperDoll:COMBAT_RATING_UPDATE(event)
	local snapshot = UpdateCurrentSnapshot()
	snapshot.meleeCrit = API_GetCritChance()
	snapshot.rangedCrit = API_GetRangedCritChance()
	snapshot.spellCrit = API_GetSpellCritChance(OVALE_SPELLDAMAGE_SCHOOL[self_class])
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s", event)
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f%%", self.SNAPSHOT_STATS["meleeCrit"].description, snapshot.meleeCrit)
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f%%", self.SNAPSHOT_STATS["rangedCrit"].description, snapshot.rangedCrit)
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f%%", self.SNAPSHOT_STATS["spellCrit"].description, snapshot.spellCrit)
end

function OvalePaperDoll:MASTERY_UPDATE(event)
	local snapshot = UpdateCurrentSnapshot()
	if self.level < 80 then
		snapshot.masteryEffect = 0
	else
		snapshot.masteryEffect = API_GetMasteryEffect()
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: %s = %f%%",
			event, self.SNAPSHOT_STATS["masteryEffect"].description, snapshot.masteryEffect)
	end
end

function OvalePaperDoll:PLAYER_LEVEL_UP(event, level, ...)
	self.level = tonumber(level) or API_UnitLevel("player")
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: level = %d", event, self.level)
end

function OvalePaperDoll:PLAYER_DAMAGE_DONE_MODS(event, unitId)
	local snapshot = UpdateCurrentSnapshot()
	snapshot.spellBonusHealing = API_GetSpellBonusHealing()
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: %s = %d",
		event, self.SNAPSHOT_STATS["spellBonusHealing"].description, snapshot.spellBonusHealing)
end

function OvalePaperDoll:PLAYER_REGEN_DISABLED(event)
	self_snapshotCount = 0
end

function OvalePaperDoll:PLAYER_REGEN_ENABLED(event)
	local now = API_GetTime()
	if Ovale.enCombat and Ovale.combatStartTime then
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%d snapshots in %f seconds.",
			self_snapshotCount, now - Ovale.combatStartTime)
	end
	self_pool:Drain()
end

function OvalePaperDoll:SPELL_POWER_CHANGED(event)
	local snapshot = UpdateCurrentSnapshot()
	snapshot.spellBonusDamage = API_GetSpellBonusDamage(OVALE_SPELLDAMAGE_SCHOOL[self_class])
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: %s = %d",
		event, self.SNAPSHOT_STATS["spellBonusDamage"].description, snapshot.spellBonusDamage)
end

function OvalePaperDoll:UNIT_ATTACK_POWER(event, unitId)
	if unitId == "player" then
		local snapshot = UpdateCurrentSnapshot()
		local base, posBuff, negBuff = API_UnitAttackPower(unitId)
		snapshot.attackPower = base + posBuff + negBuff
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: %s = %d",
			event, self.SNAPSHOT_STATS["attackPower"].description, snapshot.attackPower)
		self:UpdateDamage(event)
	end
end

function OvalePaperDoll:UNIT_LEVEL(event, unitId)
	if unitId == "player" then
		self.level = API_UnitLevel(unitId)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: level = %d", event, self.level)
	end
end

function OvalePaperDoll:UNIT_RANGEDDAMAGE(event, unitId)
	if unitId == "player" then
		local snapshot = UpdateCurrentSnapshot()
		snapshot.rangedHaste = API_GetRangedHaste()
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: %s = %f%%",
			event, self.SNAPSHOT_STATS["rangedHaste"].description, snapshot.rangedHaste)
	end
end

function OvalePaperDoll:UNIT_RANGED_ATTACK_POWER(event, unitId)
	if unitId == "player" then
		local base, posBuff, negBuff = API_UnitRangedAttackPower(unitId)
		local snapshot = UpdateCurrentSnapshot()
		snapshot.rangedAttackPower = base + posBuff + negBuff
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s: %s = %d",
			event, self.SNAPSHOT_STATS["rangedAttackPower"].description, snapshot.rangedAttackPower)
	end
end

function OvalePaperDoll:UNIT_SPELL_HASTE(event, unitId)
	if unitId == "player" then
		local snapshot = UpdateCurrentSnapshot()
		snapshot.meleeHaste = API_GetMeleeHaste()
		snapshot.spellHaste = API_UnitSpellHaste(unitId)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s", event)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f%%", self.SNAPSHOT_STATS["meleeHaste"].description, snapshot.meleeHaste)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f%%", self.SNAPSHOT_STATS["spellHaste"].description, snapshot.spellHaste)
		self:UpdateDamage(event)
	end
end

function OvalePaperDoll:UNIT_STATS(event, unitId)
	if unitId == "player" then
		local snapshot = UpdateCurrentSnapshot()
		snapshot.strength = API_UnitStat(unitId, 1)
		snapshot.agility = API_UnitStat(unitId, 2)
		snapshot.stamina = API_UnitStat(unitId, 3)
		snapshot.intellect = API_UnitStat(unitId, 4)
		snapshot.spirit = API_UnitStat(unitId, 5)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s", event)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %d", self.SNAPSHOT_STATS["agility"].description, snapshot.agility)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %d", self.SNAPSHOT_STATS["intellect"].description, snapshot.intellect)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %d", self.SNAPSHOT_STATS["spirit"].description, snapshot.spirit)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %d", self.SNAPSHOT_STATS["stamina"].description, snapshot.stamina)
		Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %d", self.SNAPSHOT_STATS["strength"].description, snapshot.strength)
		self:COMBAT_RATING_UPDATE(event)
	end
end

function OvalePaperDoll:UpdateDamage(event)
	local minDamage, maxDamage, minOffHandDamage, maxOffHandDamage, _, _, damageMultiplier = API_UnitDamage("player")
	local mainHandAttackSpeed, offHandAttackSpeed = API_UnitAttackSpeed("player")

	local snapshot = UpdateCurrentSnapshot()
	snapshot.baseDamageMultiplier = damageMultiplier
	if self_class == "DRUID" and OvaleStance:IsStance("druid_cat_form") then
		-- Cat Form: 100% increased auto-attack damage.
		damageMultiplier = damageMultiplier * 2
	elseif self_class == "MONK" and OvaleEquipement:HasOneHandedWeapon() then
		-- Way of the Monk: 40% increased auto-attack damage if dual-wielding.
		damageMultiplier = damageMultiplier * 1.4
	end

	-- weaponDamage = (weaponDPS + attackPower / 14) * weaponSpeed
	-- normalizedWeaponDamage = (weaponDPS + attackPower / 14) * normalizedWeaponSpeed
	local avgDamage = (minDamage + maxDamage) / 2 / damageMultiplier
	local mainHandWeaponSpeed = mainHandAttackSpeed * self:GetMeleeHasteMultiplier()
	local normalizedMainHandWeaponSpeed = OvaleEquipement.mainHandWeaponSpeed or 0
	if self_class == "DRUID" then
		if OvaleStance:IsStance("druid_cat_form") then
			normalizedMainHandWeaponSpeed = 1
		elseif OvaleStance:IsStance("druid_bear_form") then
			normalizedMainHandWeaponSpeed = 2.5
		end
	end
	snapshot.mainHandWeaponDamage = avgDamage / mainHandWeaponSpeed * normalizedMainHandWeaponSpeed
	--Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    MH weapon damage = ((%f + %f) / 2 / %f) / %f * %f",
	--	minDamage, maxDamage, damageMultiplier, mainHandWeaponSpeed, normalizedMainHandWeaponSpeed)

	if OvaleEquipement:HasOffHandWeapon() then
		local avgOffHandDamage = (minOffHandDamage + maxOffHandDamage) / 2 / damageMultiplier
		-- Sometimes, UnitAttackSpeed() doesn't return a value for OH attack speed, so approximate with MH one.
		offHandAttackSpeed = offHandAttackSpeed or mainHandAttackSpeed
		local offHandWeaponSpeed = offHandAttackSpeed * self:GetMeleeHasteMultiplier()
		local normalizedOffHandWeaponSpeed = OvaleEquipement.offHandWeaponSpeed or 0
		if self_class == "DRUID" then
			if OvaleStance:IsStance("druid_cat_form") then
				normalizedOffHandWeaponSpeed = 1
			elseif OvaleStance:IsStance("druid_bear_form") then
				normalizedOffHandWeaponSpeed = 2.5
			end
		end
		snapshot.offHandWeaponDamage = avgOffHandDamage / offHandWeaponSpeed * normalizedOffHandWeaponSpeed
		--Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    OH weapon damage = ((%f + %f) / 2 / %f) / %f * %f",
		--	minOffHandDamage, maxOffHandDamage, damageMultiplier, offHandWeaponSpeed, normalizedOffHandWeaponSpeed)
	else
		snapshot.offHandWeaponDamage = 0
	end

	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, true, "%s", event)
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f", self.SNAPSHOT_STATS["baseDamageMultiplier"].description, snapshot.baseDamageMultiplier)
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f", self.SNAPSHOT_STATS["mainHandWeaponDamage"].description, snapshot.mainHandWeaponDamage)
	Ovale:DebugPrintf(OVALE_PAPERDOLL_DEBUG, "    %s = %f", self.SNAPSHOT_STATS["offHandWeaponDamage"].description, snapshot.offHandWeaponDamage)
end

function OvalePaperDoll:UpdateSpecialization(event)
	local newSpecialization = API_GetSpecialization()
	if self.specialization ~= newSpecialization then
		self.specialization = newSpecialization
		self:SendMessage("Ovale_SpecializationChanged", self.specialization)
	end
end

function OvalePaperDoll:UpdateStats(event)
	self:UpdateSpecialization(event)
	self:COMBAT_RATING_UPDATE(event)
	self:MASTERY_UPDATE(event)
	self:PLAYER_DAMAGE_DONE_MODS(event, "player")
	self:SPELL_POWER_CHANGED(event)
	self:UNIT_ATTACK_POWER(event, "player")
	self:UNIT_RANGEDDAMAGE(event, "player")
	self:UNIT_RANGED_ATTACK_POWER(event, "player")
	self:UNIT_SPELL_HASTE(event, "player")
	self:UNIT_STATS(event, "player")
	self:UpdateDamage(event)
end

function OvalePaperDoll:GetMasteryMultiplier()
	local snapshot = self:CurrentSnapshot()
	return 1 + snapshot.masteryEffect / 100
end

function OvalePaperDoll:GetMeleeHasteMultiplier()
	local snapshot = self:CurrentSnapshot()
	return 1 + snapshot.meleeHaste / 100
end

function OvalePaperDoll:GetRangedHasteMultiplier()
	local snapshot = self:CurrentSnapshot()
	return 1 + snapshot.rangedHaste / 100
end

function OvalePaperDoll:GetSpellHasteMultiplier()
	local snapshot = self:CurrentSnapshot()
	return 1 + snapshot.spellHaste / 100
end

-- Copy the current snapshot into the given snapshot table.
function OvalePaperDoll:UpdateSnapshot(snapshot)
	local snapshot = self:CurrentSnapshot()
	for k in pairs(self.SNAPSHOT_STATS) do
		snapshot[k] = self.snapshot[k]
	end
	return snapshot
end

-- Return a raw reference to the current snapshot.
function OvalePaperDoll:CurrentSnapshot()
	local now = API_GetTime()
	if self.snapshot.snapshotTime < now then
		self:UpdateStats("CurrentSnapshot")
	end
	return self.snapshot
end

-- Get a new reference to a snapshot; if no snapshot is specified, use the current one.
function OvalePaperDoll:GetSnapshot(snapshot)
	snapshot = snapshot or self:CurrentSnapshot()
	return self_pool:GetReference(snapshot)
end

-- Release a reference to the given snapshot.
function OvalePaperDoll:ReleaseSnapshot(snapshot)
	return self_pool:ReleaseReference(snapshot)
end

function OvalePaperDoll:Debug(snapshot)
	snapshot = snapshot or self.snapshot
	self_pool:Debug()
	Ovale:FormatPrint("Total snapshots: %d", self_snapshotCount)
	Ovale:FormatPrint("Level: %d", self.level)
	Ovale:FormatPrint("Specialization: %s", self.specialization)
	Ovale:FormatPrint("Snapshot time: %f", snapshot.snapshotTime)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["agility"].description, snapshot.agility)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["intellect"].description, snapshot.intellect)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["spirit"].description, snapshot.spirit)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["stamina"].description, snapshot.stamina)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["strength"].description, snapshot.strength)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["attackPower"].description, snapshot.attackPower)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["rangedAttackPower"].description, snapshot.rangedAttackPower)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["spellBonusDamage"].description, snapshot.spellBonusDamage)
	Ovale:FormatPrint("%s: %d", self.SNAPSHOT_STATS["spellBonusHealing"].description, snapshot.spellBonusHealing)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["spellCrit"].description, snapshot.spellCrit)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["spellHaste"].description, snapshot.spellHaste)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["meleeCrit"].description, snapshot.meleeCrit)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["meleeHaste"].description, snapshot.meleeHaste)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["rangedCrit"].description, snapshot.rangedCrit)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["rangedHaste"].description, snapshot.rangedHaste)
	Ovale:FormatPrint("%s: %f%%", self.SNAPSHOT_STATS["masteryEffect"].description, snapshot.masteryEffect)
	Ovale:FormatPrint("%s: %f", self.SNAPSHOT_STATS["baseDamageMultiplier"].description, snapshot.baseDamageMultiplier)
	Ovale:FormatPrint("%s: %f", self.SNAPSHOT_STATS["mainHandWeaponDamage"].description, snapshot.mainHandWeaponDamage)
	Ovale:FormatPrint("%s: %f", self.SNAPSHOT_STATS["offHandWeaponDamage"].description, snapshot.offHandWeaponDamage)
end
--</public-static-methods>

--[[----------------------------------------------------------------------------
	State machine for simulator.
--]]----------------------------------------------------------------------------

--<public-static-properties>
OvalePaperDoll.statePrototype = {
	level = nil,
	specialization = nil,
	snapshot = nil,
}
--</public-static-properties>

--<public-static-methods>
-- Initialize the state.
function OvalePaperDoll:InitializeState(state)
	state.level = nil
	state.specialization = nil
	state.snapshot = nil
end

-- Reset the state to the current conditions.
function OvalePaperDoll:ResetState(state)
	state.level = self.level
	state.specialization = self.specialization
	local now = API_GetTime()
	if state.snapshot and state.snapshot.snapshotTime < now then
		self_pool:ReleaseReference(state.snapshot)
		state.snapshot = nil
	end
	state.snapshot = state.snapshot or self_pool:GetReference(self.snapshot)
end

-- Release state resources prior to removing from the simulator.
function OvalePaperDoll:CleanState(state)
	self_pool:ReleaseReference(state.snapshot)
end
--</public-static-methods>

--<state-methods>
do
	local statePrototype = OvalePaperDoll.statePrototype

	statePrototype.GetMasteryMultiplier = function(state, snapshot)
		snapshot = snapshot or state.snapshot
		return 1 + snapshot.masteryEffect / 100
	end

	statePrototype.GetMeleeHasteMultiplier = function(state, snapshot)
		snapshot = snapshot or state.snapshot
		return 1 + snapshot.meleeHaste / 100
	end

	statePrototype.GetRangedHasteMultiplier = function(state, snapshot)
		snapshot = snapshot or state.snapshot
		return 1 + snapshot.rangedHaste / 100
	end

	statePrototype.GetSpellHasteMultiplier = function(state, snapshot)
		snapshot = snapshot or state.snapshot
		return 1 + snapshot.spellHaste / 100
	end
end
--</state-methods>
