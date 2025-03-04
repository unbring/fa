-----------------------------------------------------------------
-- File      : /lua/unit.lua
-- Authors   : John Comes, David Tomandl, Gordon Duclos
-- Summary   : The Unit lua module
-- Copyright © 2005 Gas Powered Games, Inc.  All rights reserved.
-----------------------------------------------------------------

-- Imports. Localise commonly used subfunctions for speed
local Entity = import('/lua/sim/Entity.lua').Entity
local EffectTemplate = import('/lua/EffectTemplates.lua')
local explosion = import('/lua/defaultexplosions.lua')

local EffectUtilities = import('/lua/EffectUtilities.lua')
local Game = import('/lua/game.lua')
local utilities = import('/lua/utilities.lua')
local Shield = import('/lua/shield.lua').Shield
local PersonalBubble = import('/lua/shield.lua').PersonalBubble
local TransportShield = import('/lua/shield.lua').TransportShield
local PersonalShield = import('/lua/shield.lua').PersonalShield
local AntiArtilleryShield = import('/lua/shield.lua').AntiArtilleryShield

local Buff = import('/lua/sim/buff.lua')
local AIUtils = import('/lua/ai/aiutilities.lua')
local BuffFieldBlueprints = import('/lua/sim/BuffField.lua').BuffFieldBlueprints
local Wreckage = import('/lua/wreckage.lua')
local Set = import('/lua/system/setutils.lua')
local Factions = import('/lua/factions.lua').GetFactions(true)

local DeprecatedWarnings = { }


-- allows us to skip ai-specific functionality
local GameHasAIs = ScenarioInfo.GameHasAIs

-- cached categories for performance
local UpdateAssistersConsumptionCats = categories.REPAIR - categories.INSIGNIFICANTUNIT     -- anything that repairs but insignificant things, such as drones

-- upvalues for performance
local IsAlly = IsAlly

-- Localised global functions for speed. ~10% for single references, ~30% for double (eg table.insert)

-- Deprecated function warning flags
local GetUnitBeingBuiltWarning = false

SyncMeta = {
    __index = function(t, key)
        local id = rawget(t, 'id')
        return UnitData[id].Data[key]
    end,

    __newindex = function(t, key, val)
        local id = rawget(t, 'id')
        local army = rawget(t, 'army')
        if not UnitData[id] then
            UnitData[id] = {
                OwnerArmy = rawget(t, 'army'),
                Data = {}
            }
        end
        UnitData[id].Data[key] = val

        local focus = GetFocusArmy()
        if army == focus or focus == -1 then -- Let observers get unit data
            if not Sync.UnitData[id] then
                Sync.UnitData[id] = {}
            end
            Sync.UnitData[id][key] = val
        end
    end,
}

local function PopulateBlueprintCache(projectile, blueprint)

    -- populate the cache
    local cache = { }
    cache.Blueprint = blueprint 

    cache.Cats = blueprint.Categories
    cache.CatsCount = table.getn(blueprint.Categories)
    cache.HashedCats = table.hash(blueprint.Categories)

    cache.DoNotCollideCats = blueprint.DoNotCollideList or false
    cache.DoNotCollideCatsCount = table.getn(blueprint.DoNotCollideList or { })
    cache.HashedDoNotCollideCats = table.hash(blueprint.DoNotCollideList)

    cache.Audio = blueprint.Audio
  
    -- store the result
    local meta = getmetatable(projectile)
    meta.BlueprintCache = cache

    SPEW("Populated blueprint cache for unit: " .. tostring(blueprint.BlueprintId))
end

Unit = Class(moho.unit_methods) {

    BlueprintCache = false,

    Weapons = {},

    FxScale = 1,
    FxDamageScale = 1,
    -- FX Damage tables. A random damage effect table of emitters is chosen out of this table
    FxDamage1 = {EffectTemplate.DamageSmoke01, EffectTemplate.DamageSparks01},
    FxDamage2 = {EffectTemplate.DamageFireSmoke01, EffectTemplate.DamageSparks01},
    FxDamage3 = {EffectTemplate.DamageFire01, EffectTemplate.DamageSparks01},

    -- Disables all collisions. This will be true for all units being constructed as upgrades
    DisallowCollisions = false,

    -- Destruction parameters
    PlayDestructionEffects = true,
    PlayEndAnimDestructionEffects = true,
    ShowUnitDestructionDebris = true,
    DestructionExplosionWaitDelayMin = 0,
    DestructionExplosionWaitDelayMax = 0.5,
    DeathThreadDestructionWaitTime = 0.1,
    DestructionPartsHighToss = {},
    DestructionPartsLowToss = {},
    DestructionPartsChassisToss = {},
    EconomyProductionInitiallyActive = true,

    GetSync = function(self)
        if not Sync.UnitData[self.EntityId] then
            Sync.UnitData[self.EntityId] = {}
        end
        return Sync.UnitData[self.EntityId]
    end,

    -- The original builder of this unit, set by OnStartBeingBuilt. Used for calculating differential
    -- upgrade costs, and tracking the original owner of a unit (for tracking gifting and so on)
    originalBuilder = nil,

    -------------------------------------------------------------------------------------------
    ---- INITIALIZATION
    -------------------------------------------------------------------------------------------
    OnPreCreate = function(self)
        -- Each unit has a sync table to replicate values to the global sync table to be copied to the user layer at sync time.
        self.Sync = {}
        self.Sync.id = self:GetEntityId()
        self.Sync.army = self:GetArmy()
        setmetatable(self.Sync, SyncMeta)

        if not self.Trash then
            self.Trash = TrashBag()
        end

        self.IntelDisables = {
            Radar = {NotInitialized = true},
            Sonar = {NotInitialized = true},
            Omni = {NotInitialized = true},
            RadarStealth = {NotInitialized = true},
            SonarStealth = {NotInitialized = true},
            RadarStealthField = {NotInitialized = true},
            SonarStealthField = {NotInitialized = true},
            Cloak = {NotInitialized = true},
            CloakField = {NotInitialized = true}, -- We really shouldn't use this. Cloak/Stealth fields are pretty busted
            Spoof = {NotInitialized = true},
            Jammer = {NotInitialized = true},
        }

        self.EventCallbacks = {
            OnKilled = {},
            OnUnitBuilt = {},
            OnStartBuild = {},
            OnReclaimed = {},
            OnStartReclaim = {},
            OnStopReclaim = {},
            OnStopBeingBuilt = {},
            OnHorizontalStartMove = {},
            OnCaptured = {},
            OnCapturedNewUnit = {},
            OnDamaged = {},
            OnStartCapture = {},
            OnStopCapture = {},
            OnFailedCapture = {},
            OnStartBeingCaptured = {},
            OnStopBeingCaptured = {},
            OnFailedBeingCaptured = {},
            OnFailedToBuild = {},
            OnVeteran = {},
            OnGiven = {},
            ProjectileDamaged = {},
            SpecialToggleEnableFunction = false,
            SpecialToggleDisableFunction = false,
            OnAttachedToTransport = {}, -- Returns self, transport, bone
            OnDetachedFromTransport = {}, -- Returns self, transport, bone
        }
    end,

    OnCreate = function(self)
        Entity.OnCreate(self)   

        local bp = self:GetBlueprint()

        -- populate blueprint cache if we haven't done that yet
        if not self.BlueprintCache then 
            PopulateBlueprintCache(self, bp)
        end

        -- copy reference from meta table to inner table
        self.BlueprintCache = self.BlueprintCache

        -- copy frequently used values from cache to reduce table look ups
        self.Audio = self.BlueprintCache.Audio

        -- the entity that produces sound, by default ourself
        self.SoundEntity = self

        -- cache commonly used values from the engine
        -- self.Layer = self:GetCurrentLayer() -- Not required: ironically OnLayerChange is called _before_ OnCreate is called!

        -- Turn off land bones if this unit has them.
        self:HideLandBones()

        -- Set number of effects per damage depending on its volume
        local x, y, z = self:GetUnitSizes()
        local vol = x * y * z

        self:ShowPresetEnhancementBones()

        local damageamounts = 1
        if vol >= 20 then
            damageamounts = 6
            self.FxDamageScale = 2
        elseif vol >= 10 then
            damageamounts = 4
            self.FxDamageScale = 1.5
        elseif vol >= 0.5 then
            damageamounts = 2
        end

        self.FxDamage1Amount = self.FxDamage1Amount or damageamounts
        self.FxDamage2Amount = self.FxDamage2Amount or damageamounts
        self.FxDamage3Amount = self.FxDamage3Amount or damageamounts
        self.DamageEffectsBag = {
            {},
            {},
            {},
        }

        -- Set up effect emitter bags
        self.MovementEffectsBag = {}
        self.IdleEffectsBag = {}
        self.TopSpeedEffectsBag = {}
        self.BeamExhaustEffectsBag = {}
        self.TransportBeamEffectsBag = {}
        self.BuildEffectsBag = TrashBag()
        self.ReclaimEffectsBag = TrashBag()
        self.OnBeingBuiltEffectsBag = TrashBag()
        self.CaptureEffectsBag = TrashBag()
        self.UpgradeEffectsBag = TrashBag()
        self.TeleportFxBag = TrashBag()

        -- Store targets and attackers for proper Stealth management
        self.Targets = {}
        self.WeaponTargets = {}
        self.WeaponAttackers = {}

        -- Set up veterancy
        self.xp = 0
        self.Instigators = {}
        self.totalDamageTaken = 0

        self.debris_Vector = Vector(0, 0, 0)

        local bp = self:GetBlueprint()

        -- Store build information for performance
        self.BuildExtentsX = bp.Physics.MeshExtentsX or bp.Footprint.SizeX
        self.BuildExtentsY = bp.Physics.MeshExtentsY or bp.Footprint.SizeY
        self.BuildExtentsZ = bp.Physics.MeshExtentsZ or bp.Footprint.SizeZ
        self.Elevation = bp.Physics.Elevation
        self.MeshBlueprint = bp.Display.MeshBlueprint
        self.MeshBuildBlueprint = bp.Display.MeshBuildBlueprint

        -- Store weapon information for performance
        self.WeaponCount = self:GetWeaponCount() or 0
        self.WeaponInstances = { }
        for k = 1, self.WeaponCount do 
            local weapon = self:GetWeapon(k)
            self.WeaponInstances[weapon.Label] = weapon
            self.WeaponInstances[k] = weapon
        end

        -- Store animations for performance
        self.AnimationWater = bp.Display.AnimationWater

        -- Store common accessed information for performance
        self.Audio = bp.Audio
        self.Brain = self:GetAIBrain()
        self.UnitId = self:GetUnitId()
        self.techCategory = bp.TechCategory
        self.layerCategory = bp.LayerCategory
        self.factionCategory = bp.FactionCategory
        self.MovementEffects = bp.Display.MovementEffects

        -- Define Economic modifications
        local bpEcon = bp.Economy
        self:SetConsumptionPerSecondEnergy(bpEcon.MaintenanceConsumptionPerSecondEnergy or 0)
        self:SetConsumptionPerSecondMass(bpEcon.MaintenanceConsumptionPerSecondMass or 0)
        self:SetProductionPerSecondEnergy(bpEcon.ProductionPerSecondEnergy or 0)
        self:SetProductionPerSecondMass(bpEcon.ProductionPerSecondMass or 0)

        if self.EconomyProductionInitiallyActive then
            self:SetProductionActive(true)
        end

        self.Buffs = {
            BuffTable = {},
            Affects = {},
        }

        local bpVision = bp.Intel.VisionRadius
        self:SetIntelRadius('Vision', bpVision or 0)

        self:SetCanTakeDamage(true)
        self:SetCanBeKilled(true)

        local bpDeathAnim = bp.Display.AnimationDeath
        if bpDeathAnim and not table.empty(bpDeathAnim) then
            self.PlayDeathAnimation = true
        end

        -- Used for keeping track of resource consumption
        self.MaintenanceConsumption = false
        self.ActiveConsumption = false
        self.ProductionEnabled = true
        self.EnergyModifier = 0
        self.MassModifier = 0

        -- Cheating
        if self:GetAIBrain().CheatEnabled then
            AIUtils.ApplyCheatBuffs(self)
        end

        self.Dead = false

        self:InitBuffFields()
        self:OnCreated()

        -- Ensure transport slots are available
        self.attachmentBone = nil

        -- Set up Adjacency container
        self.AdjacentUnits = {}

        self.Repairers = {}
    end,

    OnGotTarget = function(self, Weapon)
    end,

    OnLostTarget = function(self, Weapon)
    end,

    -------------------------------------------------------------------------------------------
    ---- MISC FUNCTIONS
    -------------------------------------------------------------------------------------------
    SetDead = function(self)
        self.Dead = true
    end,

    IsDead = function(self)
        return self.Dead
    end,

    GetCachePosition = function(self)
        return self:GetPosition()
    end,

    GetFootPrintSize = function(self)
        local fp = self:GetBlueprint().Footprint
        return math.max(fp.SizeX, fp.SizeZ)
    end,

    -- Returns 4 numbers: skirt x0, skirt z0, skirt.x1, skirt.z1
    GetSkirtRect = function(self)
        local bp = self:GetBlueprint()
        local x, y, z = unpack(self:GetPosition())
        local fx = x - bp.Footprint.SizeX * .5
        local fz = z - bp.Footprint.SizeZ * .5
        local sx = fx + bp.Physics.SkirtOffsetX
        local sz = fz + bp.Physics.SkirtOffsetZ

        return sx, sz, sx + bp.Physics.SkirtSizeX, sz + bp.Physics.SkirtSizeZ
    end,

    -- Returns collision box size
    GetUnitSizes = function(self)
        local bp = self:GetBlueprint()
        return bp.SizeX, bp.SizeY, bp.SizeZ
    end,

    GetRandomOffset = function(self, scalar)
        local sx, sy, sz = self:GetUnitSizes()
        local heading = self:GetHeading()
        sx = sx * scalar
        sy = sy * scalar
        sz = sz * scalar
        local rx = Random() * sx - (sx * 0.5)
        local y  = Random() * sy + (self:GetBlueprint().CollisionOffsetY or 0)
        local rz = Random() * sz - (sz * 0.5)
        local x = math.cos(heading) * rx - math.sin(heading) * rz
        local z = math.sin(heading) * rx - math.cos(heading) * rz

        return x, y, z
    end,

    ForkThread = function(self, fn, ...)
        if fn then
            local thread = ForkThread(fn, self, unpack(arg))
            self.Trash:Add(thread)
            return thread
        else
            return nil
        end
    end,

    SetTargetPriorities = function(self, priTable)
        for i = 1, self.WeaponCount do
            self.WeaponInstances[i]:SetWeaponPriorities(priTable)
        end
    end,

    SetLandTargetPriorities = function(self, priTable)
        for i = 1, self.WeaponCount do
            local wep = self.WeaponInstances[i]
            for onLayer, targetLayers in wep:GetBlueprint().FireTargetLayerCapsTable do
                if string.find(targetLayers, 'Land') then
                    wep:SetWeaponPriorities(priTable)
                    break
                end
            end
        end
    end,

    -- Updates build restrictions of any unit passed, used for support factories
    UpdateBuildRestrictions = function(self)

        -- retrieve info of factory
        local faction = self.factionCategory
        local layer = self.layerCategory
        local aiBrain = self:GetAIBrain()

        -- the pessimists we are, remove all the units!
        self:AddBuildRestriction((categories.TECH3 + categories.TECH2) * categories.MOBILE)

        -- if there is a specific T3 HQ - allow all t2 / t3 units of this type
        if aiBrain:CountHQs(faction, layer, "TECH3") > 0 then 
            self:RemoveBuildRestriction((categories.TECH3 + categories.TECH2) * categories.MOBILE)

        -- if there is some T3 HQ - allow t2 / t3 engineers
        elseif aiBrain:CountHQsAllLayers(faction, "TECH3") > 0 then 
            self:RemoveBuildRestriction((categories.TECH3 + categories.TECH2) * categories.MOBILE * categories.CONSTRUCTION)
        end 

        -- if there is a specific T2 HQ - allow all t2 units of this type
        if aiBrain:CountHQs(faction, layer, "TECH2") > 0 then 
            self:RemoveBuildRestriction(categories.TECH2 * categories.MOBILE)

        -- if there is some T2 HQ - allow t2 engineers
        elseif aiBrain:CountHQsAllLayers(faction, "TECH2") > 0 then 
            self:RemoveBuildRestriction(categories.TECH2 * categories.MOBILE * categories.CONSTRUCTION)
        end
    end,

    -- Deprecation / refactored warning for mods.
    updateBuildRestrictions = function(self)
        if not DeprecatedWarnings.updateBuildRestrictions then 
            WARN("updateBuildRestrictions is refactored since PR #3319. Call UpdateBuildRestrictions instead.")
            DeprecatedWarnings.updateBuildRestrictions = true 
        end

        -- call the old function
        self.UpdateBuildRestrictions(self)
    end,

    -- Deprecation warning for mods.
    FindHQType = function(aiBrain, category)
        if not DeprecatedWarnings.FindHQType then 
            WARN("FindHQType is deprecated since PR #3319.")
            DeprecatedWarnings.FindHQType = true 
        end
    end,

    -------------------------------------------------------------------------------------------
    ---- TOGGLES
    -------------------------------------------------------------------------------------------
    OnScriptBitSet = function(self, bit)
        if bit == 0 then -- Shield toggle
            self:PlayUnitAmbientSound('ActiveLoop')
            self:EnableShield()
        elseif bit == 1 then -- Weapon toggle
            -- Amended in individual unit's script file
        elseif bit == 2 then -- Jamming toggle
            self:StopUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionInactive()
            self:DisableUnitIntel('ToggleBit2', 'Jammer')
        elseif bit == 3 then -- Intel toggle
            self:StopUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionInactive()
            self:DisableUnitIntel('ToggleBit3', 'RadarStealth')
            self:DisableUnitIntel('ToggleBit3', 'RadarStealthField')
            self:DisableUnitIntel('ToggleBit3', 'SonarStealth')
            self:DisableUnitIntel('ToggleBit3', 'SonarStealthField')
            self:DisableUnitIntel('ToggleBit3', 'Sonar')
            self:DisableUnitIntel('ToggleBit3', 'Omni')
            self:DisableUnitIntel('ToggleBit3', 'Cloak')
            self:DisableUnitIntel('ToggleBit3', 'CloakField') -- We really shouldn't use this. Cloak/Stealth fields are pretty busted
            self:DisableUnitIntel('ToggleBit3', 'Spoof')
            self:DisableUnitIntel('ToggleBit3', 'Jammer')
            self:DisableUnitIntel('ToggleBit3', 'Radar')
        elseif bit == 4 then -- Production toggle
            self:OnProductionPaused()
        elseif bit == 5 then -- Stealth toggle
            self:StopUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionInactive()
            self:DisableUnitIntel('ToggleBit5', 'RadarStealth')
            self:DisableUnitIntel('ToggleBit5', 'RadarStealthField')
            self:DisableUnitIntel('ToggleBit5', 'SonarStealth')
            self:DisableUnitIntel('ToggleBit5', 'SonarStealthField')
        elseif bit == 6 then -- Generic pause toggle
            self:SetPaused(true)
        elseif bit == 7 then -- Special toggle
            self:EnableSpecialToggle()
        elseif bit == 8 then -- Cloak toggle
            self:StopUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionInactive()
            self:DisableUnitIntel('ToggleBit8', 'Cloak')
        end

        if not self.MaintenanceConsumption then
            self.ToggledOff = true
        end
    end,

    OnScriptBitClear = function(self, bit)
        if bit == 0 then -- Shield toggle
            self:StopUnitAmbientSound('ActiveLoop')
            self:DisableShield()
        elseif bit == 1 then -- Weapon toggle
        elseif bit == 2 then -- Jamming toggle
            self:PlayUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionActive()
            self:EnableUnitIntel('ToggleBit2', 'Jammer')
        elseif bit == 3 then -- Intel toggle
            self:PlayUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionActive()
            self:EnableUnitIntel('ToggleBit3', 'Radar')
            self:EnableUnitIntel('ToggleBit3', 'RadarStealth')
            self:EnableUnitIntel('ToggleBit3', 'RadarStealthField')
            self:EnableUnitIntel('ToggleBit3', 'SonarStealth')
            self:EnableUnitIntel('ToggleBit3', 'SonarStealthField')
            self:EnableUnitIntel('ToggleBit3', 'Sonar')
            self:EnableUnitIntel('ToggleBit3', 'Omni')
            self:EnableUnitIntel('ToggleBit3', 'Cloak')
            self:EnableUnitIntel('ToggleBit3', 'CloakField') -- We really shouldn't use this. Cloak/Stealth fields are pretty busted
            self:EnableUnitIntel('ToggleBit3', 'Spoof')
            self:EnableUnitIntel('ToggleBit3', 'Jammer')
        elseif bit == 4 then -- Production toggle
            self:OnProductionUnpaused()
        elseif bit == 5 then -- Stealth toggle
            self:PlayUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionActive()
            self:EnableUnitIntel('ToggleBit5', 'RadarStealth')
            self:EnableUnitIntel('ToggleBit5', 'RadarStealthField')
            self:EnableUnitIntel('ToggleBit5', 'SonarStealth')
            self:EnableUnitIntel('ToggleBit5', 'SonarStealthField')
        elseif bit == 6 then -- Generic pause toggle
            self:SetPaused(false)
        elseif bit == 7 then -- Special toggle
            self:DisableSpecialToggle()
        elseif bit == 8 then -- Cloak toggle
            self:PlayUnitAmbientSound('ActiveLoop')
            self:SetMaintenanceConsumptionActive()
            self:EnableUnitIntel('ToggleBit8', 'Cloak')
        end

        if self.MaintenanceConsumption then
            self.ToggledOff = false
        end
    end,

    OnPaused = function(self)
        if self:IsUnitState('Building') or self:IsUnitState('Upgrading') or self:IsUnitState('Repairing') then
            self:SetActiveConsumptionInactive()
            self:StopUnitAmbientSound('ConstructLoop')
        end
    end,

    OnUnpaused = function(self)
        if self:IsUnitState('Building') or self:IsUnitState('Upgrading') or self:IsUnitState('Repairing') then
            self:SetActiveConsumptionActive()
            self:PlayUnitAmbientSound('ConstructLoop')
        end
    end,

    EnableSpecialToggle = function(self)
        if self.EventCallbacks.SpecialToggleEnableFunction then
            self.EventCallbacks.SpecialToggleEnableFunction(self)
        end
    end,

    DisableSpecialToggle = function(self)
        if self.EventCallbacks.SpecialToggleDisableFunction then
            self.EventCallbacks.SpecialToggleDisableFunction(self)
        end
    end,

    AddSpecialToggleEnable = function(self, fn)
        if fn then
            self.EventCallbacks.SpecialToggleEnableFunction = fn
        end
    end,

    AddSpecialToggleDisable = function(self, fn)
        if fn then
            self.EventCallbacks.SpecialToggleDisableFunction = fn
        end
    end,

    EnableDefaultToggleCaps = function(self)
        if self.ToggleCaps then
            for _, v in self.ToggleCaps do
                self:AddToggleCap(v)
            end
        end
    end,

    DisableDefaultToggleCaps = function(self)
        self.ToggleCaps = {}
        local capsCheckTable = {'RULEUTC_WeaponToggle', 'RULEUTC_ProductionToggle', 'RULEUTC_GenericToggle', 'RULEUTC_SpecialToggle'}
        for _, v in capsCheckTable do
            if self:TestToggleCaps(v) == true then
                table.insert(self.ToggleCaps, v)
            end
            self:RemoveToggleCap(v)
        end
    end,

    -------------------------------------------------------------------------------------------
    ---- MISC EVENTS
    -------------------------------------------------------------------------------------------
    OnSpecialAction = function(self, location)
    end,

    OnProductionActive = function(self)
    end,

    OnActive = function(self)
    end,

    OnInactive = function(self)
    end,

    OnStartCapture = function(self, target)
        self:DoUnitCallbacks('OnStartCapture', target)
        self:StartCaptureEffects(target)
        self:PlayUnitSound('StartCapture')
        self:PlayUnitAmbientSound('CaptureLoop')
    end,

    OnStopCapture = function(self, target)
        self:DoUnitCallbacks('OnStopCapture', target)
        self:StopCaptureEffects(target)
        self:PlayUnitSound('StopCapture')
        self:StopUnitAmbientSound('CaptureLoop')
    end,

    StartCaptureEffects = function(self, target)
        self.CaptureEffectsBag:Add(self:ForkThread(self.CreateCaptureEffects, target))
    end,

    CreateCaptureEffects = function(self, target)
    end,

    StopCaptureEffects = function(self, target)
        self.CaptureEffectsBag:Destroy()
    end,

    OnFailedCapture = function(self, target)
        self:DoUnitCallbacks('OnFailedCapture', target)
        self:StopCaptureEffects(target)
        self:StopUnitAmbientSound('CaptureLoop')
        self:PlayUnitSound('FailedCapture')
    end,

    CheckCaptor = function(self, captor)
        if captor.Dead or captor:GetFocusUnit() ~= self then
            self:RemoveCaptor(captor)
        else
            local progress = captor:GetWorkProgress()
            if not self.CaptureProgress or progress > self.CaptureProgress then
                self.CaptureProgress = progress
            elseif progress < self.CaptureProgress then
                captor:SetWorkProgress(self.CaptureProgress)
            end
        end
    end,

    AddCaptor = function(self, captor)
        if not self.Captors then
            self.Captors = {}
        end

        self.Captors[captor.EntityId] = captor

        if not self.CaptureThread then
            self.CaptureThread = self:ForkThread(function()
                local captors = self.Captors or {}
                while not table.empty(captors) do
                    for _, c in captors do
                        self:CheckCaptor(c)
                    end

                    WaitTicks(1)
                    captors = self.Captors or {}
                end
            end)
        end
    end,

    ResetCaptors = function(self)
        if self.CaptureThread then
            KillThread(self.CaptureThread)
        end
        self.Captors = {}
        self.CaptureThread = nil
        self.CaptureProgress = nil
    end,

    RemoveCaptor = function(self, captor)
        self.Captors[captor.EntityId] = nil

        if table.empty(self.Captors) then
            self:ResetCaptors()
        end
    end,

    OnStartBeingCaptured = function(self, captor)
        self:AddCaptor(captor)
        self:DoUnitCallbacks('OnStartBeingCaptured', captor)
        self:PlayUnitSound('StartBeingCaptured')
    end,

    OnStopBeingCaptured = function(self, captor)
        self:RemoveCaptor(captor)
        self:DoUnitCallbacks('OnStopBeingCaptured', captor)
        self:PlayUnitSound('StopBeingCaptured')
    end,

    OnFailedBeingCaptured = function(self, captor)
        self:RemoveCaptor(captor)
        self:DoUnitCallbacks('OnFailedBeingCaptured', captor)
        self:PlayUnitSound('FailedBeingCaptured')
    end,

    OnReclaimed = function(self, entity)
        self:DoUnitCallbacks('OnReclaimed', entity)
        self.CreateReclaimEndEffects(entity, self)
        self:Destroy()
    end,

    OnStartRepair = function(self, unit)
        unit.Repairers[self.EntityId] = self

        if unit.WorkItem ~= self.WorkItem then
            self:InheritWork(unit)
        end

        self:SetUnitState('Repairing', true)

        -- Force assist over repair when unit is assisting something
        if unit:GetFocusUnit() and unit:IsUnitState('Building') then
            self:ForkThread(function()
                self:CheckAssistFocus()
            end)
        end
    end,

    OnStopRepair = function(self, unit)
    end,

    OnStartReclaim = function(self, target)
        self:SetUnitState('Reclaiming', true)
        self:SetFocusEntity(target)
        self:CheckAssistersFocus()
        self:DoUnitCallbacks('OnStartReclaim', target)
        self:StartReclaimEffects(target)
        self:PlayUnitSound('StartReclaim')
        self:PlayUnitAmbientSound('ReclaimLoop')

        -- Force me to move on to the guard properly when done
        local guard = self:GetGuardedUnit()
        if guard then
            IssueClearCommands({self})
            IssueReclaim({self}, target)
            IssueGuard({self}, guard)
        end
    end,

    OnStopReclaim = function(self, target)
        self:DoUnitCallbacks('OnStopReclaim', target)
        self:StopReclaimEffects(target)
        self:StopUnitAmbientSound('ReclaimLoop')
        self:PlayUnitSound('StopReclaim')
        self:SetUnitState('Reclaiming', false)
        if target.MaxMassReclaim then -- This is a prop
            target:UpdateReclaimLeft()
        end
    end,

    StartReclaimEffects = function(self, target)
        self.ReclaimEffectsBag:Add(self:ForkThread(self.CreateReclaimEffects, target))
    end,

    CreateReclaimEffects = function(self, target)
    end,

    CreateReclaimEndEffects = function(self, target)
    end,

    StopReclaimEffects = function(self, target)
        self.ReclaimEffectsBag:Destroy()
    end,

    OnDecayed = function(self)
        self:Destroy()
    end,

    OnCaptured = function(self, captor)
        if self and not self.Dead and captor and not captor.Dead and self:GetAIBrain() ~= captor:GetAIBrain() then
            if not self:IsCapturable() then
                self:Kill()
                return
            end

            -- Kill non-capturable things which are in a transport
            if EntityCategoryContains(categories.TRANSPORTATION, self) then
                local cargo = self:GetCargo()
                for _, v in cargo do
                    if not v.Dead and not v:IsCapturable() then
                        v:Kill()
                    end
                end
            end

            self:DoUnitCallbacks('OnCaptured', captor)
            local newUnitCallbacks = {}
            if self.EventCallbacks.OnCapturedNewUnit then
                newUnitCallbacks = self.EventCallbacks.OnCapturedNewUnit
            end

            local captorBrain = false

            -- Ignore army cap during unit transfer in Campaign
            if ScenarioInfo.CampaignMode then
                captorBrain = captor:GetAIBrain()
                SetIgnoreArmyUnitCap(captor.Army, true)
            end

            if ScenarioInfo.CampaignMode and not captorBrain.IgnoreArmyCaps then
                SetIgnoreArmyUnitCap(captor.Army, false)
            end

            -- Fix captured units not retaining their data
            self:ResetCaptors()
            local newUnits = import('/lua/SimUtils.lua').TransferUnitsOwnership({self}, captor.Army, true) or {}

            -- The unit transfer function returns a table of units. Since we transferred 1 unit, the table contains 1 unit (The new unit).
            -- If table would have been nil (Set to {} above), was empty, or contains more than one, kill this sequence
            if table.empty(newUnits) or table.getn(newUnits) ~= 1 then
                return
            end

            local newUnit = newUnits[1]

            -- Because the old unit is lost we cannot call a member function for newUnit callbacks
            for _, cb in newUnitCallbacks do
                if cb then
                    cb(newUnit, captor)
                end
            end
        end
    end,

    OnGiven = function(self, newUnit)
        newUnit:SendNotifyMessage('transferred')
        self:DoUnitCallbacks('OnGiven', newUnit)
    end,

    AddOnGivenCallback = function(self, fn)
        self:AddUnitCallback(fn, 'OnGiven')
    end,

    -------------------------------------------------------------------------------------------
    -- ECONOMY
    -------------------------------------------------------------------------------------------
    OnConsumptionActive = function(self)
    end,

    OnConsumptionInActive = function(self)
    end,

    -- We are splitting Consumption into two catagories:
    -- Maintenance -- for units that are usually "on": radar, mass extractors, etc.
    -- Active -- when upgrading, constructing, or something similar.
    --
    -- It will be possible for both or neither of these consumption methods to be
    -- in operation at the same time.  Here are the functions to turn them off and on.
    SetMaintenanceConsumptionActive = function(self)
        self.MaintenanceConsumption = true
        self:UpdateConsumptionValues()
    end,

    SetMaintenanceConsumptionInactive = function(self)
        self.MaintenanceConsumption = false
        self:UpdateConsumptionValues()
    end,

    SetActiveConsumptionActive = function(self)
        self.ActiveConsumption = true
        self:UpdateConsumptionValues()
    end,

    SetActiveConsumptionInactive = function(self)
        self.ActiveConsumption = false
        self:UpdateConsumptionValues()
    end,

    OnProductionPaused = function(self)
        self:SetMaintenanceConsumptionInactive()
        self:SetProductionActive(false)
    end,

    OnProductionUnpaused = function(self)
        self:SetMaintenanceConsumptionActive()
        self:SetProductionActive(true)
    end,

    SetBuildTimeMultiplier = function(self, time_mult)
        self.BuildTimeMultiplier = time_mult
    end,

    GetMassBuildAdjMod = function(self)
        return self.MassBuildAdjMod or 1
    end,

    GetEnergyBuildAdjMod = function(self)
        return self.EnergyBuildAdjMod or 1
    end,

    GetEconomyBuildRate = function(self)
        return self:GetBuildRate()
    end,

    GetBuildRate = function(self)
        return math.max(moho.unit_methods.GetBuildRate(self), 0.00001) -- Make sure we're never returning 0, this value will be used to divide with
    end,

    UpdateAssistersConsumption = function(self)
        local units = {}
        -- We need to check all the units assisting.
        for _, v in self:GetGuards() do
            if not v.Dead and (v:IsUnitState('Building') or v:IsUnitState('Repairing')) and not (EntityCategoryContains(categories.INSIGNIFICANTUNIT, v)) then
                table.insert(units, v)
            end
        end

        local workers = self:GetAIBrain():GetUnitsAroundPoint(UpdateAssistersConsumptionCats, self:GetPosition(), 50, 'Ally')
        for _, v in workers do
            if not v.Dead and v:IsUnitState('Repairing') and v:GetFocusUnit() == self then
                table.insert(units, v)
            end
        end

        for _, v in units do
            if not v.updatedConsumption then
                v.updatedConsumption = true -- Recursive protection
                v:UpdateConsumptionValues()
                v.updatedConsumption = false
            end
        end
    end,

    -- Called when we start building a unit, turn on/off, get/lose bonuses, or on
    -- any other change that might affect our build rate or resource use.
    UpdateConsumptionValues = function(self)
        local energy_rate = 0
        local mass_rate = 0

        if self.ActiveConsumption then
            local focus = self:GetFocusUnit()
            local time = 1
            local mass = 0
            local energy = 0
            local targetData
            local baseData
            local repairRatio = 0.75

            if focus then -- Always inherit work status of focus
                self:InheritWork(focus)
            end

            if self.WorkItem then -- Enhancement
                targetData = self.WorkItem
            elseif focus then -- Handling upgrades
                if self:IsUnitState('Upgrading') then
                    baseData = self:GetBlueprint().Economy -- Upgrading myself, subtract ev. baseCost
                elseif focus.originalBuilder and not focus.originalBuilder.Dead and focus.originalBuilder:IsUnitState('Upgrading') and focus.originalBuilder:GetFocusUnit() == focus then
                    baseData = focus.originalBuilder:GetBlueprint().Economy
                end

                if baseData then
                    targetData = focus:GetBlueprint().Economy
                end
            end

            if targetData then -- Upgrade/enhancement
                time, energy, mass = Game.GetConstructEconomyModel(self, targetData, baseData)
            elseif focus then -- Building/repairing something
                if focus:IsUnitState('SiloBuildingAmmo') then
                    local siloBuildRate = focus:GetBuildRate() or 1
                    time, energy, mass = focus:GetBuildCosts(focus.SiloProjectile)
                    energy = (energy / siloBuildRate) * (self:GetBuildRate() or 1)
                    mass = (mass / siloBuildRate) * (self:GetBuildRate() or 1)
                else
                    time, energy, mass = self:GetBuildCosts(focus:GetBlueprint())
                    if self:IsUnitState('Repairing') and focus.isFinishedUnit then
                        energy = energy * repairRatio
                        mass = mass * repairRatio
                    end
                end
            end

            energy = math.max(1, energy * (self.EnergyBuildAdjMod or 1))
            mass = math.max(1, mass * (self.MassBuildAdjMod or 1))
            energy_rate = energy / time
            mass_rate = mass / time
        end

        -- only run this part if we actually have AIs in the game, they are the ones that use
        -- this functionality apparently. A consequence of this is that engineers start assisting
        -- slower if they are chain-assisting each other. However, in practice it is a lot cheaper
        -- on the performance of the game. Best to just assist what you want it to assist directly.
        -- if GameHasAIs then 
        --     self:UpdateAssistersConsumption()
        -- end

        local myBlueprint = self:GetBlueprint()
        if self.MaintenanceConsumption then
            local mai_energy = (self.EnergyMaintenanceConsumptionOverride or myBlueprint.Economy.MaintenanceConsumptionPerSecondEnergy)  or 0
            local mai_mass = myBlueprint.Economy.MaintenanceConsumptionPerSecondMass or 0

            -- Apply economic bonuses
            mai_energy = mai_energy * (100 + self.EnergyModifier) * (self.EnergyMaintAdjMod or 1) * 0.01
            mai_mass = mai_mass * (100 + self.MassModifier) * (self.MassMaintAdjMod or 1) * 0.01

            energy_rate = energy_rate + mai_energy
            mass_rate = mass_rate + mai_mass
        end

         -- Apply minimum rates
        energy_rate = math.max(energy_rate, myBlueprint.Economy.MinConsumptionPerSecondEnergy or 0)
        mass_rate = math.max(mass_rate, myBlueprint.Economy.MinConsumptionPerSecondMass or 0)

        self:SetConsumptionPerSecondEnergy(energy_rate)
        self:SetConsumptionPerSecondMass(mass_rate)
        self:SetConsumptionActive(energy_rate > 0 or mass_rate > 0)
    end,

    UpdateProductionValues = function(self)
        local bpEcon = self:GetBlueprint().Economy
        if not bpEcon then return end

        self:SetProductionPerSecondEnergy((bpEcon.ProductionPerSecondEnergy or 0) * (self.EnergyProdAdjMod or 1))
        self:SetProductionPerSecondMass((bpEcon.ProductionPerSecondMass or 0) * (self.MassProdAdjMod or 1))
    end,

    SetEnergyMaintenanceConsumptionOverride = function(self, override)
        self.EnergyMaintenanceConsumptionOverride = override or 0
    end,

    SetBuildRateOverride = function(self, overRide)
        self.BuildRateOverride = overRide
    end,

    GetBuildRateOverride = function(self)
        return self.BuildRateOverride
    end,

    -------------------------------------------------------------------------------------------
    -- DAMAGE
    -------------------------------------------------------------------------------------------
    SetCanTakeDamage = function(self, val)
        self.CanTakeDamage = val
    end,

    CheckCanTakeDamage = function(self)
        return self.CanTakeDamage
    end,

    OnDamage = function(self, instigator, amount, vector, damageType)
        if self.CanTakeDamage then
            self:DoOnDamagedCallbacks(instigator)

            -- Pass damage to an active personal shield, as personal shields no longer have collisions
            if self:GetShieldType() == 'Personal' and self:ShieldIsOn() and not self.MyShield.Charging then
                self.MyShield:ApplyDamage(instigator, amount, vector, damageType)
            else
                self:DoTakeDamage(instigator, amount, vector, damageType)
            end
        end
    end,

    DoTakeDamage = function(self, instigator, amount, vector, damageType)
        local preAdjHealth = self:GetHealth()

        -- Keep track of incoming damage, but only if it is from a unit
        if instigator and IsUnit(instigator) and instigator ~= self then
            amountForVet = math.min(amount, preAdjHealth) -- Don't let massive alpha (OC, Percy etc) skew which unit gets vet
            self.totalDamageTaken = self.totalDamageTaken + amountForVet

            -- We want to keep track of damage from things that cannot gain vet (deathweps etc)
            -- But not enter them into the table to have credit dispersed later
            if instigator.gainsVeterancy then
                local previousDamage = self.Instigators[instigator.EntityId].damage
                if previousDamage then
                    self.Instigators[instigator.EntityId].damage = previousDamage + amountForVet
                else
                    self.Instigators[instigator.EntityId] = {unit = instigator, damage = amountForVet}
                end
            end
        end

        self:AdjustHealth(instigator, -amount)

        local health = self:GetHealth()
        if health < 1 then
            -- this if statement is an issue too
            if damageType == 'Reclaimed' then
                self:Destroy()
            else
                local excessDamageRatio = 0.0
                -- Calculate the excess damage amount
                local excess = preAdjHealth - amount
                local maxHealth = self:GetMaxHealth()
                if excess < 0 and maxHealth > 0 then
                    excessDamageRatio = -excess / maxHealth
                end

                if not EntityCategoryContains(categories.VOLATILE, self) then
                    self:SetReclaimable(false)
                end
                self:Kill(instigator, damageType, excessDamageRatio)
            end
        end

        if health < 1 or self.Dead then
            self.debris_Vector = vector or ''
        end
    end,

    ManageDamageEffects = function(self, newHealth, oldHealth)
        -- Health values come in at fixed 25% intervals
        if newHealth < oldHealth then
            if oldHealth == 0.75 then
                for i = 1, self.FxDamage1Amount do
                    self:PlayDamageEffect(self.FxDamage1, self.DamageEffectsBag[1])
                end
            elseif oldHealth == 0.5 then
                for i = 1, self.FxDamage2Amount do
                    self:PlayDamageEffect(self.FxDamage2, self.DamageEffectsBag[2])
                end
            elseif oldHealth == 0.25 then
                for i = 1, self.FxDamage3Amount do
                    self:PlayDamageEffect(self.FxDamage3, self.DamageEffectsBag[3])
                end
            end
        else
            if newHealth <= 0.25 and newHealth > 0 then
                for _, v in self.DamageEffectsBag[3] do
                    v:Destroy()
                end
            elseif newHealth <= 0.5 and newHealth > 0.25 then
                for _, v in self.DamageEffectsBag[2] do
                    v:Destroy()
                end
            elseif newHealth <= 0.75 and newHealth > 0.5 then
                for _, v in self.DamageEffectsBag[1] do
                    v:Destroy()
                end
            elseif newHealth > 0.75 then
                self:DestroyAllDamageEffects()
            end
        end
    end,

    PlayDamageEffect = function(self, fxTable, fxBag)
        local effects = fxTable[Random(1, table.getn(fxTable))]
        if not effects then return end

        local totalBones = self:GetBoneCount()
        local bone = Random(1, totalBones) - 1
        local bpDE = self:GetBlueprint().Display.DamageEffects
        for _, v in effects do
            local fx
            if bpDE then
                local num = Random(1, table.getsize(bpDE))
                local bpFx = bpDE[num]
                fx = CreateAttachedEmitter(self, bpFx.Bone or 0, self.Army, v):ScaleEmitter(self.FxDamageScale):OffsetEmitter(bpFx.OffsetX or 0, bpFx.OffsetY or 0, bpFx.OffsetZ or 0)
            else
                fx = CreateAttachedEmitter(self, bone, self.Army, v):ScaleEmitter(self.FxDamageScale)
            end
            table.insert(fxBag, fx)
        end
    end,

    OnHealthChanged = function(self, new, old)
        self:ManageDamageEffects(new, old)
    end,

    DestroyAllDamageEffects = function(self)
        for kb, vb in self.DamageEffectsBag do
            for ke, ve in vb do
                ve:Destroy()
            end
        end
    end,

    CheckCanBeKilled = function(self, other)
        return self.CanBeKilled
    end,

    -- On killed: this function plays when the unit takes a mortal hit. Plays death effects and spawns wreckage, dependant on overkill
    OnKilled = function(self, instigator, type, overkillRatio)
        local layer = self.Layer
        self.Dead = true

        -- Clear out any remaining projectiles
        for k = 1, self.WeaponCount do 
            self.WeaponInstances[k]:ClearProjectileTrash();
        end

        -- Units killed while being invisible because they're teleporting should show when they're killed
        if self.TeleportFx_IsInvisible then
            self:ShowBone(0, true)
            self:ShowEnhancementBones()
        end

        local bp = self:GetBlueprint()
        if layer == 'Water' and bp.Physics.MotionType == 'RULEUMT_Hover' then
            self:PlayUnitSound('HoverKilledOnWater')
        elseif layer == 'Land' and bp.Physics.MotionType == 'RULEUMT_AmphibiousFloating' then
            -- Handle ships that can walk on land
            self:PlayUnitSound('AmphibiousFloatingKilledOnLand')
        else
            self:PlayUnitSound('Killed')
        end

        -- apply death animation on half built units (do not apply for ML and mega)
        local FractionThreshold = bp.General.FractionThreshold or 0.5
        if self.PlayDeathAnimation and self:GetFractionComplete() > FractionThreshold then
            self:ForkThread(self.PlayAnimationThread, 'AnimationDeath')
            self.DisallowCollisions = true
        end

        self:DoUnitCallbacks('OnKilled')
        if self.UnitBeingTeleported and not self.UnitBeingTeleported.Dead then
            self.UnitBeingTeleported:Destroy()
            self.UnitBeingTeleported = nil
        end

        ArmyBrains[self:GetArmy()].LastUnitKilledBy = (instigator or self):GetArmy()

        if self.DeathWeaponEnabled ~= false then
            self:DoDeathWeapon()
        end

        -- Notify instigator of kill and spread veterancy
        -- We prevent any vet spreading if the instigator isn't part of the vet system (EG - Self destruct)
        -- This is so that you can bring a damaged Experimental back to base, kill, and rebuild, without granting
        -- instant vet to the enemy army, as well as other obscure reasons
        if self.totalDamageTaken > 0 and not self.veterancyDispersed then
            self:VeterancyDispersal(not instigator or not IsUnit(instigator))
        end

        self:DisableShield()
        self:DisableUnitIntel('Killed')
        self:ForkThread(self.DeathThread, overkillRatio , instigator)

        ArmyBrains[self.Army]:AddUnitStat(self.UnitId, "lost", 1)
    end,

    -- Argument val is true or false. False = cannot be killed
    SetCanBeKilled = function(self, val)
        self.CanBeKilled = val
    end,

    -- This section contains functions used by the new mass-based veterancy system
    ------------------------------------------------------------------------------

    -- Tell any living instigators that they need to gain some veterancy
    VeterancyDispersal = function(self, suicide)
        local bp = self:GetBlueprint()
        local mass = self:GetVeterancyValue()
        local massTrue
        -- Adjust mass based on current health when a unit is self destructed
        if suicide then
            mass = mass * (1 - self:GetHealth() / self:GetMaxHealth())
        end

        massTrue = mass

        for _, data in self.Instigators do
            local unit = data.unit
            -- Make sure the unit is something which can vet, and is not maxed
            if unit and not unit.Dead and unit.gainsVeterancy then
                local proportion = data.damage / self.totalDamageTaken

                -- True value for "Mass killed"
                local massKilledTrue = math.floor(massTrue * proportion)
                unit.Sync.totalMassKilledTrue = math.floor(unit.Sync.totalMassKilledTrue + massKilledTrue)

                if unit.Sync.VeteranLevel < 5 then
                    -- Find the proportion of yourself that each instigator killed
                    local massKilled = math.floor(mass * proportion)
                    unit:OnKilledUnit(self, massKilled)
                end
            end
        end
    end,

    GetVeterancyValue = function(self)
        local bp = self:GetBlueprint()
        local mass = bp.Economy.BuildCostMass
        local fractionComplete = self:GetFractionComplete()

        if fractionComplete == 1 then
            -- Add the value of any enhancements
            local enhancements = SimUnitEnhancements[self.EntityId]
            if enhancements then
                for _, name in enhancements do
                    mass = mass + bp.Enhancements[name].BuildCostMass or 0
                end
            end

            -- Subtract the value of any enhancements from a preset because their value is included in bp.Economy.BuildCostMass
            if bp.EnhancementPresetAssigned.Enhancements then
                for _, name in bp.EnhancementPresetAssigned.Enhancements do
                    mass = mass - bp.Enhancements[name].BuildCostMass or 0
                end
            end
        end

        -- Allow units to count for more or less than their real mass if needed.
        return mass * fractionComplete * (bp.VeteranImportanceMult or 1) + (self.cargoMass or 0)
    end,

    --- Called when this unit kills another. Chiefly responsible for the veterancy system for now.
    OnKilledUnit = function(self, unitKilled, massKilled)
        if not massKilled or massKilled == 0 then return end -- Make sure engine calls aren't passed with massKilled == 0
        if IsAlly(self.Army, unitKilled.Army) then return end -- No XP for friendly fire...

        self:CalculateVeterancyLevel(massKilled) -- Bails if we've not gone up

        ArmyBrains[self.Army]:AddUnitStat(unitKilled.UnitId, "kills", 1)
    end,

    CalculateVeterancyLevel = function(self, massKilled, noLimit)
        if not noLimit then 
            -- Limit the veterancy gain from one kill to one level worth
            massKilled = math.min(massKilled, self.Sync.myValue or self.Sync.manualVeterancy[self.Sync.VeteranLevel + 1])
        end

        -- Total up the mass the unit has killed overall, and store it
        self.Sync.totalMassKilled = math.floor(self.Sync.totalMassKilled + massKilled)

        -- Calculate veterancy level. By default killing your own mass value (Build cost mass * 2 by default) grants a level
        if self.Sync.myValue then
            local newVetLevel = math.min(math.floor(self.Sync.totalMassKilled / self.Sync.myValue), 5)

            -- Bail if our veterancy hasn't increased
            if newVetLevel == self.Sync.VeteranLevel then return end

            -- Update our recorded veterancy level
            self.Sync.VeteranLevel = newVetLevel
        else
            if self.Sync.totalMassKilled - self.Sync.manualVeterancy[self.Sync.VeteranLevel + 1] >= 0 then
                self.Sync.VeteranLevel = self.Sync.VeteranLevel + 1
            else
                return
            end
        end

        self:SetVeteranLevel(self.Sync.VeteranLevel)
    end,

    CalculateVeterancyLevelAfterTransfer = function(self, massKilled, massKilledTrue)
        self.Sync.totalMassKilled = math.floor(massKilled)
        self.Sync.totalMassKilledTrue = math.floor(massKilledTrue)

        if self.Sync.myValue then
            local newVetLevel = math.min(math.floor(self.Sync.totalMassKilled / self.Sync.myValue), 5)

            if newVetLevel == self.Sync.VeteranLevel then return end

            self.Sync.VeteranLevel = newVetLevel
        else
            if self.Sync.totalMassKilled  < self.Sync.manualVeterancy[1] then
                return
            elseif self.Sync.totalMassKilled < self.Sync.manualVeterancy[2] then
                self.Sync.VeteranLevel = 1
            elseif self.Sync.totalMassKilled < self.Sync.manualVeterancy[3] then
                self.Sync.VeteranLevel = 2
            elseif self.Sync.totalMassKilled < self.Sync.manualVeterancy[4] then
                self.Sync.VeteranLevel = 3
            elseif self.Sync.totalMassKilled < self.Sync.manualVeterancy[5] then
                self.Sync.VeteranLevel = 4
            else
                self.Sync.VeteranLevel = 5
            end
        end

        self:SetVeteranLevel(self.Sync.VeteranLevel)
    end,

    -- Use this to set a veterancy level directly, usually used by a scenario
    SetVeterancy = function(self, veteranLevel)
        if veteranLevel <= 0 or veteranLevel > 5 then return end
        if not self.gainsVeterancy then return end

        if self.Sync.myValue then
            self:CalculateVeterancyLevel(self.Sync.myValue * veteranLevel, true)
        else
            self:CalculateVeterancyLevel(self.Sync.manualVeterancy[veteranLevel], true)
        end
    end,

    -- Set the veteran level to the level specified
    SetVeteranLevel = function(self, level)
        local buffs = self:CreateVeterancyBuffs(level)
        if buffs then
            for _, buffName in buffs do
                Buff.ApplyBuff(self, buffName)
            end
        end

        self:GetAIBrain():OnBrainUnitVeterancyLevel(self, level)
        self:DoVeterancyHealing(level)

        self:DoUnitCallbacks('OnVeteran')
    end,

    -- Veterancy can't be 'Undone', so we heal the unit directly, one-off, rather than using a buff. Much more flexible.
    DoVeterancyHealing = function(self, level)
        local bp = self:GetBlueprint()
        local maxHealth = bp.Defense.MaxHealth
        local mult = bp.VeteranHealingMult[level] or 0.1

        self:AdjustHealth(self, maxHealth * mult) -- Adjusts health by the given value (Can be +tv or -tv), not to the given value
    end,

    CreateVeterancyBuffs = function(self, level)
        local healthBuffName = 'VeterancyMaxHealth' .. level -- Currently there is no difference between units, therefore no need for unique buffs
        local regenBuffName = self.UnitId .. 'VeterancyRegen' .. level -- Generate a buff based on the unitId - eg. uel0001VeterancyRegen3

        if not Buffs[regenBuffName] then
            -- Maps self.techCategory to a number so we can do math on it for naval units
            local techLevels = {
                TECH1 = 1,
                TECH2 = 2,
                TECH3 = 3,
                COMMAND = 3,
                SUBCOMMANDER = 4,
                EXPERIMENTAL = 5,
            }

            local techLevel = techLevels[self.techCategory] or 1

            -- Treat naval units as one level higher
            if techLevel < 4 and EntityCategoryContains(categories.NAVAL, self) then
                techLevel = techLevel + 1
            end

            -- Regen values by tech level and veterancy level
            local regenBuffs = {
                {1,  2,  3,  4,  5}, -- T1
                {3,  6,  9,  12, 15}, -- T2
                {6,  12, 18, 24, 30}, -- T3 / ACU
                {9,  18, 27, 36, 45}, -- SACU
                {25, 50, 75, 100,125}, -- Experimental
            }

            BuffBlueprint {
                Name = regenBuffName,
                DisplayName = regenBuffName,
                BuffType = 'VeterancyRegen',
                Stacks = 'REPLACE',
                Duration = -1,
                Affects = {
                    Regen = {
                        Add = regenBuffs[techLevel][level],
                    },
                },
            }
        end

        return {regenBuffName, healthBuffName}
    end,

    -- Returns true if a unit can gain veterancy (Has a weapon)
    ShouldUseVetSystem = function(self)
        local bp = self:GetBlueprint()

        -- Bail if we don't have any weapons or have the ExcludeFromVeterancy flag (TMD, SMD, stealth boat, mobile stealth, mobile shields, aeon T3 sonar, mercy, beetle)
        if not bp.Weapon[1] or bp.General.ExcludeFromVeterancy then
            return false
        end

        -- Find a weapon which is not a DeathWeapon / DeathImpact
        local No_vet_label = {
        ['DeathWeapon'] = true,
        ['DeathImpact'] = true,
        }
        for index, wep in bp.Weapon do
            if not No_vet_label[wep.Label] then
                return true
            end
        end

        -- We only have DeathWeapon / DeathImpact labels. Bail.
        return false
    end,

    -- End of Veterancy Section
    ------------------------------------------------------------------------------

    DoDeathWeapon = function(self)
        if self:IsBeingBuilt() then return end

        local bp = self:GetBlueprint()
        for _, v in bp.Weapon do
            if v.Label == 'DeathWeapon' then
                if v.FireOnDeath == true then
                    self:SetWeaponEnabledByLabel('DeathWeapon', true)
                    self.WeaponInstances['DeathWeapon']:Fire()
                else
                    self:ForkThread(self.DeathWeaponDamageThread, v.DamageRadius, v.Damage, v.DamageType, v.DamageFriendly)
                end
                break
            end
        end
    end,

    --- Called when a unit collides with a projectile to check if the collision is valid
    -- @param self The unit we're checking the collision for
    -- @param other The projectile we're checking the collision with
    OnCollisionCheck = function(self, other, firingWeapon)

        -- bail out immediately
        if self.DisallowCollisions then
            return false
        end

        -- if we're allied, check if we allow allied collisions
        if self.Army == other.Army or IsAlly(self.Army, other.Army) then
            return other.CollideFriendly
        end

        -- check for exclusions from projectile perspective
        for k = 1, other.BlueprintCache.DoNotCollideCatsCount do 
            if self.BlueprintCache.CategoriesHash[other.BlueprintCache.DoNotCollideCats[k]] then 
                return false 
            end
        end

        -- check for exclusions from unit perspective
        for k = 1, self.BlueprintCache.DoNotCollideCatsCount do 
            if other.BlueprintCache.CategoriesHash[self.BlueprintCache.DoNotCollideCats[k]] then 
                return false 
            end
        end

        return true 
    end,

    ChooseAnimBlock = function(self, bp)
        local totWeight = 0
        for _, v in bp do
            if v.Weight then
                totWeight = totWeight + v.Weight
            end
        end

        local val = 1
        local num = Random(0, totWeight)
        for _, v in bp do
            if v.Weight then
                val = val + v.Weight
            end
            if num < val then
                return v
            end
        end
    end,

    PlayAnimationThread = function(self, anim, rate)
        local bp = self:GetBlueprint().Display[anim]
        if bp then
            local animBlock = self:ChooseAnimBlock(bp)

            -- for determining wreckage offset after dying with an animation
            if anim == 'AnimationDeath' then
                self.DeathHitBox = animBlock.HitBox
            end

            if animBlock.Mesh then
                self:SetMesh(animBlock.Mesh)
            end
            if animBlock.Animation and (self:ShallSink() or not EntityCategoryContains(categories.NAVAL, self)) then
                local sinkAnim = CreateAnimator(self)
                self.DeathAnimManip = sinkAnim
                sinkAnim:PlayAnim(animBlock.Animation)
                rate = rate or 1
                if animBlock.AnimationRateMax and animBlock.AnimationRateMin then
                    rate = Random(animBlock.AnimationRateMin * 10, animBlock.AnimationRateMax * 10) / 10
                end
                sinkAnim:SetRate(rate)
                self.Trash:Add(sinkAnim)
                WaitFor(sinkAnim)
                self.StopSink = true
            end
        end
    end,

    -- Create a unit's wrecked mesh blueprint from its regular mesh blueprint, by changing the shader and albedo
    CreateWreckage = function (self, overkillRatio)
        if overkillRatio and overkillRatio > 1.0 then
            return
        end
        if self:GetFractionComplete() < 0.5 then
            return
        end
        return self:CreateWreckageProp(overkillRatio)
    end,

    CreateWreckageProp = function(self, overkillRatio)
        local bp = self:GetBlueprint()

        local wreck = bp.Wreckage.Blueprint
        if not wreck then
            return nil
        end

        local mass = bp.Economy.BuildCostMass * (bp.Wreckage.MassMult or 0)
        local energy = bp.Economy.BuildCostEnergy * (bp.Wreckage.EnergyMult or 0)
        local time = (bp.Wreckage.ReclaimTimeMultiplier or 1)
        local pos = self:GetPosition()
        local layer = self.Layer

        -- Reduce the mass value of submerged wrecks
        if layer == 'Water' or layer == 'Sub' then
            mass = mass * 0.5
            energy = energy * 0.5
        end

        local halfBuilt = self:GetFractionComplete() < 1

        -- Make sure air / naval wrecks stick to ground / seabottom, unless they're in a factory.
        if not halfBuilt and (layer == 'Air' or EntityCategoryContains(categories.NAVAL - categories.STRUCTURE, self)) then
            pos[2] = GetTerrainHeight(pos[1], pos[3]) + GetTerrainTypeOffset(pos[1], pos[3])
        end

        local overkillMultiplier = 1 - (overkillRatio or 1)
        mass = mass * overkillMultiplier * self:GetFractionComplete()
        energy = energy * overkillMultiplier * self:GetFractionComplete()
        time = time * overkillMultiplier

        -- Now we adjust the global multiplier. This is used for balance purposes to adjust global reclaim rate.
        local time  = time * 2

        local prop = Wreckage.CreateWreckage(bp, pos, self:GetOrientation(), mass, energy, time, self.DeathHitBox)

        -- Attempt to copy our animation pose to the prop. Only works if
        -- the mesh and skeletons are the same, but will not produce an error if not.
        if layer ~= 'Air' or (layer == "Air" and halfBuilt) then
            TryCopyPose(self, prop, true)
        end

        -- Create some ambient wreckage smoke
        if layer == 'Land' then
            explosion.CreateWreckageEffects(self, prop)
        end

        return prop
    end,

    CreateUnitDestructionDebris = function(self, high, low, chassis)
        local HighDestructionParts = table.getn(self.DestructionPartsHighToss)
        local LowDestructionParts = table.getn(self.DestructionPartsLowToss)
        local ChassisDestructionParts = table.getn(self.DestructionPartsChassisToss)

        -- Limit the number of parts that we throw out
        local HighPartLimit = HighDestructionParts
        local LowPartLimit = LowDestructionParts
        local ChassisPartLimit = ChassisDestructionParts

        -- Create projectiles and accelerate them out and away from the unit
        if high and HighDestructionParts > 0 then
            HighPartLimit = Random(1, HighDestructionParts)
            for i = 1, HighPartLimit do
                self:ShowBone(self.DestructionPartsHighToss[i], false)
                local boneProj = self:CreateProjectileAtBone('/effects/entities/DebrisBoneAttachHigh01/DebrisBoneAttachHigh01_proj.bp', self.DestructionPartsHighToss[i])

                self:AttachBoneToEntityBone(self.DestructionPartsHighToss[i], boneProj, -1, false)
            end
        end

        if low and LowDestructionParts > 0 then
            LowPartLimit = Random(1, LowDestructionParts)
            for i = 1, LowPartLimit do
                self:ShowBone(self.DestructionPartsLowToss[i], false)
                local boneProj = self:CreateProjectileAtBone('/effects/entities/DebrisBoneAttachLow01/DebrisBoneAttachLow01_proj.bp', self.DestructionPartsLowToss[i])

                self:AttachBoneToEntityBone(self.DestructionPartsLowToss[i], boneProj, -1, false)
            end
        end

        if chassis and ChassisDestructionParts > 0 then
            ChassisPartLimit = Random(1, ChassisDestructionParts)
            for i = 1, Random(1, ChassisDestructionParts) do
                self:ShowBone(self.DestructionPartsChassisToss[i], false)
                local boneProj = self:CreateProjectileAtBone('/effects/entities/DebrisBoneAttachChassis01/DebrisBoneAttachChassis01_proj.bp', self.DestructionPartsChassisToss[i])

                self:AttachBoneToEntityBone(self.DestructionPartsChassisToss[i], boneProj, -1, false)
            end
        end
    end,

    CreateDestructionEffects = function(self, overKillRatio)
        explosion.CreateScalableUnitExplosion(self, overKillRatio)
    end,

    DeathWeaponDamageThread = function(self, damageRadius, damage, damageType, damageFriendly)
        WaitSeconds(0.1)
        DamageArea(self, self:GetPosition(), damageRadius or 1, damage or 1, damageType or 'Normal', damageFriendly or false)
    end,

    SinkDestructionEffects = function(self)
        local sx, sy, sz = self:GetUnitSizes()
        local vol = sx * sy * sz
        local numBones = self:GetBoneCount() - 1
        local pos = self:GetPosition()
        local surfaceHeight = GetSurfaceHeight(pos[1], pos[3])
        local i = 0

        while i < 1 do
            local randBone = utilities.GetRandomInt(0, numBones)
            local boneHeight = self:GetPosition(randBone)[2]
            local toSurface = surfaceHeight - boneHeight
            local y = toSurface
            local rx, ry, rz = self:GetRandomOffset(0.3)
            local rs = math.max(math.min(2.5, vol / 20), 0.5)
            local scale = utilities.GetRandomFloat(rs/2, rs)

            self:DestroyAllDamageEffects()
            if toSurface < 1 then
                CreateAttachedEmitter(self, randBone, self.Army, '/effects/emitters/destruction_water_sinking_ripples_01_emit.bp'):OffsetEmitter(rx, y, rz):ScaleEmitter(scale)
                CreateAttachedEmitter(self, randBone, self.Army, '/effects/emitters/destruction_water_sinking_wash_01_emit.bp'):OffsetEmitter(rx, y, rz):ScaleEmitter(scale)
            end

            if toSurface < 0 then
                explosion.CreateDefaultHitExplosionAtBone(self, randBone, scale*1.5)
            else
                local lifetime = utilities.GetRandomInt(50, 200)

                if toSurface > 1 then
                    CreateEmitterAtBone(self, randBone, self.Army, '/effects/emitters/underwater_bubbles_01_emit.bp'):OffsetEmitter(rx, ry, rz)
                        :ScaleEmitter(scale)
                        :SetEmitterParam('LIFETIME', lifetime)

                    CreateAttachedEmitter(self, -1, self.Army, '/effects/emitters/destruction_underwater_sinking_wash_01_emit.bp'):OffsetEmitter(rx, ry, rz):ScaleEmitter(scale)
                end
                CreateEmitterAtBone(self, randBone, self.Army, '/effects/emitters/destruction_underwater_explosion_flash_01_emit.bp'):OffsetEmitter(rx, ry, rz):ScaleEmitter(scale)
                CreateEmitterAtBone(self, randBone, self.Army, '/effects/emitters/destruction_underwater_explosion_splash_01_emit.bp'):OffsetEmitter(rx, ry, rz):ScaleEmitter(scale)
            end
            local rd = utilities.GetRandomFloat(0.4, 1.0)
            WaitSeconds(i + rd)
            i = i + 0.3
        end
    end,

    StartSinking = function(self, callback)

        -- add flag to identify a unit died but is sinking before it is destroyed
        self.Sinking = true 

        local bp = self:GetBlueprint()
        local scale = ((bp.SizeX or 0 + bp.SizeZ or 0) * 0.5)
        local bone = 0

        -- Create sinker projectile
        local proj = self:CreateProjectileAtBone('/projectiles/Sinker/Sinker_proj.bp', bone)

        -- Start the sinking after a delay of the given number of seconds, attaching to a given bone
        -- and entity.
        proj:Start(10 * math.max(2, math.min(7, scale)), self, bone, callback)
        self.Trash:Add(proj)
    end,

    SeabedWatcher = function(self)
        local pos = self:GetPosition()
        local seafloor = GetTerrainHeight(pos[1], pos[3]) + GetTerrainTypeOffset(pos[1], pos[3])
        local watchBone = self:GetBlueprint().WatchBone or 0

        self.StopSink = false
        while not self.StopSink do
            WaitTicks(1)
            if self:GetPosition(watchBone)[2]-0.2 <= seafloor then
                self.StopSink = true
            end
        end
    end,

    ShallSink = function(self)
        local layer = self.Layer
        local shallSink = (
            (layer == 'Water' or layer == 'Sub') and  -- In a layer for which sinking is meaningful
            not EntityCategoryContains(categories.STRUCTURE, self)  -- Exclude structures
        )
        return shallSink
    end,

    DeathThread = function(self, overkillRatio, instigator)
        local isNaval = EntityCategoryContains(categories.NAVAL, self)
        local shallSink = self:ShallSink()

        WaitSeconds(utilities.GetRandomFloat(self.DestructionExplosionWaitDelayMin, self.DestructionExplosionWaitDelayMax))

        if not self.BagsDestroyed then
            self:DestroyAllBuildEffects()
            self:DestroyAllTrashBags()
            self.BagsDestroyed = true
        end

        -- Stop any motion sounds we may have
        self:StopUnitAmbientSound('AmbientMove')
        self:StopUnitAmbientSound('AmbientMoveLand')
        self:StopUnitAmbientSound('AmbientMoveWater')

        -- BOOM!
        if self.PlayDestructionEffects then
            self:CreateDestructionEffects(overkillRatio)
        end

        -- Flying bits of metal and whatnot. More bits for more overkill.
        if self.ShowUnitDestructionDebris and overkillRatio then
            self.CreateUnitDestructionDebris(self, true, true, overkillRatio > 2)
        end

        if shallSink then
            self.DisallowCollisions = true

            -- Bubbles and stuff coming off the sinking wreck.
            self:ForkThread(self.SinkDestructionEffects)

            -- Avoid slightly ugly need to propagate this through callback hell...
            self.overkillRatio = overkillRatio

            if isNaval and self:GetBlueprint().Display.AnimationDeath then
                -- Waits for wreck to hit bottom or end of animation
                if self:GetFractionComplete() > 0.5 then
                    self:SeabedWatcher()
                else
                    self:DestroyUnit(overkillRatio)
                end
            else
                -- A non-naval unit or boat with no sinking animation dying over water needs to sink, but lacks an animation for it. Let's make one up.
                local this = self
                self:StartSinking(
                    function()
                        this:DestroyUnit(overkillRatio)
                    end
                )

                -- Wait for the sinking callback to actually destroy the unit.
                return
            end
        elseif self.DeathAnimManip then -- wait for non-sinking animations
            WaitFor(self.DeathAnimManip)
        end

        -- If we're not doing fancy sinking rubbish, just blow the damn thing up.
        self:DestroyUnit(overkillRatio)
    end,

    --- Called at the end of the destruction thread: create the wreckage and Destroy this unit.
    DestroyUnit = function(self, overkillRatio)
        self:CreateWreckage(overkillRatio or self.overkillRatio)

        -- wait at least 1 tick before destroying unit
        WaitSeconds(math.max(0.1, self.DeathThreadDestructionWaitTime))

        self:PlayUnitSound('Destroyed')
        self:Destroy()
    end,

    DestroyAllBuildEffects = function(self)
        if self.BuildEffectsBag then
            self.BuildEffectsBag:Destroy()
        end
        if self.CaptureEffectsBag then
            self.CaptureEffectsBag:Destroy()
        end
        if self.ReclaimEffectsBag then
            self.ReclaimEffectsBag:Destroy()
        end
        if self.OnBeingBuiltEffectsBag then
            self.OnBeingBuiltEffectsBag:Destroy()
        end
        if self.UpgradeEffectsBag then
            self.UpgradeEffectsBag:Destroy()
        end
        if self.TeleportFxBag then
            self.TeleportFxBag:Destroy()
        end

        -- TODO: This really shouldn't be here...
        if self.buildBots then
            for _, bot in self.buildBots do
                if not bot:BeenDestroyed() then
                    bot:SetCanTakeDamage(true)
                    bot:SetCanBeKilled(true)

                    bot:Kill(nil, "Normal", 1)
                end
            end

            self.buildBots = nil
        end
    end,

    DestroyAllTrashBags = function(self)
        -- Some bags should really be managed by their classes
        -- but for mod compatibility reasons we delete them all here.
        for _, v in self.EffectsBag or {} do
            v:Destroy()
        end
        for k, v in self.ShieldEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.ReleaseEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.AmbientExhaustEffectsBag or {} do
            v:Destroy()
        end
        for k, v in self.OmniEffectsBag or {} do
            v:Destroy()
        end
        for k, v in self.AdjacencyBeamsBag or {} do
            v.Trash:Destroy()
            self.AdjacencyBeamsBag[k] = nil
        end
        for _, v in self.IntelEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.TeleportDestChargeBag or {} do
            v:Destroy()
        end
        for _, v in self.TeleportSoundChargeBag or {} do
            v:Destroy()
        end
        for _, EffectsBag in self.DamageEffectsBag or {} do
            for _, v in EffectsBag do
                v:Destroy()
            end
        end
        for _, v in self.IdleEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.TopSpeedEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.BeamExhaustEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.MovementEffectsBag or {} do
            v:Destroy()
        end
        for _, v in self.TransportBeamEffectsBag or {} do
            v:Destroy()
        end

        -- destroy remaining trash of weapon
        for k = 1, self.WeaponCount do 
            self.WeaponInstances[k].Trash:Destroy();
        end
    end,

    OnDestroy = function(self)
        self.Dead = true

        -- clear out all manipulators, at this point the wreck has been made
        for k = 1, self.WeaponCount do 
            self.WeaponInstances[k]:ClearProjectileTrash();
            self.WeaponInstances[k]:ClearManipulatorTrash();
        end

        if self:GetFractionComplete() < 1 then
            self:SendNotifyMessage('cancelled')
        end

        -- Clear out our sync data
        UnitData[self.EntityId] = false
        Sync.UnitData[self.EntityId] = false

        -- Don't allow anyone to stuff anything else in the table
        self.Sync = false

        -- Let the user layer know this id is gone
        Sync.ReleaseIds[self.EntityId] = true

        -- Destroy everything added to the trash
        self.Trash:Destroy()
        -- Destroy all extra trashbags in case the DeathTread() has not already destroyed it (modded DeathThread etc.)
        if not self.BagsDestroyed then
            self:DestroyAllBuildEffects()
            self:DestroyAllTrashBags()
        end

        if self.TeleportDrain then
            RemoveEconomyEvent(self, self.TeleportDrain)
        end

        RemoveAllUnitEnhancements(self)

        -- remove all callbacks from the unit
        if self.EventCallbacks then
            self.EventCallbacks = nil
        end

        ChangeState(self, self.DeadState)
    end,

    HideLandBones = function(self)
        -- Hide the bones for buildings built on land
        if self.LandBuiltHiddenBones and self.Layer == 'Land' then
            for _, v in self.LandBuiltHiddenBones do
                if self:IsValidBone(v) then
                    self:HideBone(v, true)
                end
            end
        end
    end,

    -- Generic function for showing a table of bones
    -- Table = List of bones
    -- Childrend = True/False to show child bones
    ShowBones = function(self, table, children)
        for _, v in table do
            if self:IsValidBone(v) then
                self:ShowBone(v, children)
            else
                WARN('*WARNING: TRYING TO SHOW BONE ', repr(v), ' ON UNIT ', repr(self.UnitId), ' BUT IT DOES NOT EXIST IN THE MODEL. PLEASE CHECK YOUR SCRIPT IN THE BUILD PROGRESS BONES.')
            end
        end
    end,

    --- Called under mysterous circumstances, previously held logic for nonexistent sound effects.
    OnDamageBy = function(self, index) end,

    --- Called when a nuke is armed, played a nonexistent sound effect
    OnNukeArmed = function(self) end,

    OnNukeLaunched = function(self)
    end,

    --- STRATEGIC LAUNCH DETECTED
    NukeCreatedAtUnit = function(self)
        if self:GetNukeSiloAmmoCount() <= 0 then
            return
        end

        local bp = self:GetBlueprint().Audio
        if bp then
            for num, aiBrain in ArmyBrains do
                local factionIndex = aiBrain:GetFactionIndex()

                if bp['NuclearLaunchDetected'] then
                    aiBrain:NuclearLaunchDetected(bp['NuclearLaunchDetected'])
                end
            end
        end
    end,

    SetAllWeaponsEnabled = function(self, enable)
        for i = 1, self.WeaponCount do
            local wep = self.WeaponInstances[i]
            wep:SetWeaponEnabled(enable)
            wep:AimManipulatorSetEnabled(enable)
        end
    end,

    SetWeaponEnabledByLabel = function(self, label, enable)

        local weapon = self:GetWeaponByLabel(label)
        if not weapon then 
            return 
        end

        if not enable then
            weapon:OnLostTarget()
        end

        weapon:SetWeaponEnabled(enable)
        weapon:AimManipulatorSetEnabled(enable)
    end,

    GetWeaponManipulatorByLabel = function(self, label)
        local weapon = self:GetWeaponByLabel(label)
        if weapon then 
            return weapon:GetAimManipulator()
        end
    end,

    GetWeaponByLabel = function(self, label)

        -- if we're sinking then all death weapons should already have been applied
        if self.Sinking or self.BeenDestroyed(self) then 
            return nil
        end

        -- return the instanced weapon
        return self.WeaponInstances[label]
    end,

    ResetWeaponByLabel = function(self, label)
        local weapon = self:GetWeaponByLabel(label)
        if weapon then 
            weapon:ResetTarget()
        end
    end,

    SetDeathWeaponEnabled = function(self, enable)
        self.DeathWeaponEnabled = enable
    end,

    ----------------------------------------------------------------------------------------------
    -- CONSTRUCTING - BEING BUILT
    ----------------------------------------------------------------------------------------------
    OnBeingBuiltProgress = function(self, unit, oldProg, newProg)
    end,

    SetRotation = function(self, angle)
        local qx, qy, qz, qw = explosion.QuatFromRotation(angle, 0, 1, 0)
        self:SetOrientation({qx, qy, qz, qw}, true)
    end,

    Rotate = function(self, angle)
        local qx, qy, qz, qw = unpack(self:GetOrientation())
        local a = math.atan2(2.0 * (qx * qz + qw * qy), qw * qw + qx * qx - qz * qz - qy * qy)
        local current_yaw = math.floor(math.abs(a) * (180 / math.pi) + 0.5)

        self:SetRotation(angle + current_yaw)
    end,

    RotateTowards = function(self, tpos)
        local pos = self:GetPosition()
        local rad = math.atan2(tpos[1] - pos[1], tpos[3] - pos[3])
        self:SetRotation(rad * (180 / math.pi))
    end,

    RotateTowardsMid = function(self)
        local x, y = GetMapSize()
        self:RotateTowards({x / 2, 0, y / 2})
    end,

    OnStartBeingBuilt = function(self, builder, layer)
        self:StartBeingBuiltEffects(builder, layer)

        local aiBrain = self:GetAIBrain()
        if not table.empty(aiBrain.UnitBuiltTriggerList) then
            for _, v in aiBrain.UnitBuiltTriggerList do
                if EntityCategoryContains(v.Category, self) then
                    self:ForkThread(self.UnitBuiltPercentageCallbackThread, v.Percent, v.Callback)
                end
            end
        end

        self.originalBuilder = builder

        self:SendNotifyMessage('started')
    end,

    UnitBuiltPercentageCallbackThread = function(self, percent, callback)
        while not self.Dead and self:GetHealthPercent() < percent do
            WaitSeconds(1)
        end

        local aiBrain = self:GetAIBrain()
        for k, v in aiBrain.UnitBuiltTriggerList do
            if v.Callback == callback then
                callback(self)
                aiBrain.UnitBuiltTriggerList[k] = nil
            end
        end
    end,

    OnStopBeingBuilt = function(self, builder, layer)
        if self.Dead or self:BeenDestroyed() then -- Sanity check, can prevent strange shield bugs and stuff
            self:Kill()
            return false
        end

        local bp = self:GetBlueprint()
        self.isFinishedUnit = true

        -- Set up Veterancy tracking here. Avoids needing to check completion later.
        -- Do all this here so we only have to do for things which get completed
        -- Don't need to track damage for things which cannot attack!
        self.gainsVeterancy = self:ShouldUseVetSystem()

        if self.gainsVeterancy then
            self.Sync.totalMassKilled = 0
            self.Sync.totalMassKilledTrue = 0
            self.Sync.VeteranLevel = 0

            -- Values can be setting up manually via bp.
            if bp.VeteranMass then
                self.Sync.manualVeterancy = {
                    [1] = bp.VeteranMass[1],
                    [2] = bp.VeteranMass[1] + bp.VeteranMass[2],
                    [3] = bp.VeteranMass[1] + bp.VeteranMass[2] + bp.VeteranMass[3],
                    [4] = bp.VeteranMass[1] + bp.VeteranMass[2] + bp.VeteranMass[3] + bp.VeteranMass[4],
                    [5] = bp.VeteranMass[1] + bp.VeteranMass[2] + bp.VeteranMass[3] + bp.VeteranMass[4] + bp.VeteranMass[5],
                }
            else
                -- Allow units to require more or less mass to level up. Decimal multipliers mean
                -- faster leveling, >1 mean slower. Doing this here means doing it once instead of every kill.
                local techMultipliers = {
                    TECH1 = 2,
                    TECH2 = 1.5,
                    TECH3 = 1.25,
                    SUBCOMMANDER = 2,
                    EXPERIMENTAL = 2,
                    COMMAND = 2,
                }
                local defaultMult = techMultipliers[self.techCategory] or 2

                self.Sync.myValue = math.max(math.floor(bp.Economy.BuildCostMass * (bp.VeteranMassMult or defaultMult)), 1)
            end
        end

        self:EnableUnitIntel('NotInitialized', nil)
        self:ForkThread(self.StopBeingBuiltEffects, builder, layer)

        if self.Layer == 'Water' then
            local surfaceAnim = bp.Display.AnimationSurface
            if not self.SurfaceAnimator and surfaceAnim then
                self.SurfaceAnimator = CreateAnimator(self)
            end
            if surfaceAnim and self.SurfaceAnimator then
                self.SurfaceAnimator:PlayAnim(surfaceAnim):SetRate(1)
            end
        end

        self:PlayUnitSound('DoneBeingBuilt')
        self:PlayUnitAmbientSound('ActiveLoop')

        if self.IsUpgrade and builder then
            -- Set correct hitpoints after upgrade
            local hpDamage = builder:GetMaxHealth() - builder:GetHealth() -- Current damage
            local damagePercent = hpDamage / self:GetMaxHealth() -- Resulting % with upgraded building
            local newHealthAmount = builder:GetMaxHealth() * (1 - damagePercent) -- HP for upgraded building
            builder:SetHealth(builder, newHealthAmount) -- Seems like the engine uses builder to determine new HP
            self.DisallowCollisions = false
            self:SetCanTakeDamage(true)
            self:RevertCollisionShape()
            self.IsUpgrade = nil
        end

        -- Turn off land bones if this unit has them.
        self:HideLandBones()
        self:DoUnitCallbacks('OnStopBeingBuilt')

        -- Create any idle effects on unit
        if table.empty(self.IdleEffectsBag) then
            self:CreateIdleEffects()
        end

        -- If we have a shield specified, create it.
        -- Blueprint registration always creates a dummy Shield entry:
        -- {
        --     ShieldSize = 0
        --     RegenAssistMult = 1
        -- }
        -- ... Which we must carefully ignore.
        local bpShield = bp.Defense.Shield
        if bpShield.ShieldSize ~= 0 then
            self:CreateShield(bpShield)
        end

        -- Create spherical collisions if defined
        if bp.SizeSphere then
            self:SetCollisionShape(
                'Sphere',
                bp.CollisionSphereOffsetX or 0,
                bp.CollisionSphereOffsetY or 0,
                bp.CollisionSphereOffsetZ or 0,
                bp.SizeSphere
            )
        end

        if bp.Display.AnimationPermOpen then
            self.PermOpenAnimManipulator = CreateAnimator(self):PlayAnim(bp.Display.AnimationPermOpen)
            self.Trash:Add(self.PermOpenAnimManipulator)
        end

        -- Initialize movement effects subsystems, idle effects, beam exhaust, and footfall manipulators
        local movementEffects = self.MovementEffects
        if movementEffects.Land or movementEffects.Air or movementEffects.Water or movementEffects.Sub or movementEffects.BeamExhaust then
            self.MovementEffectsExist = true
            if movementEffects.BeamExhaust and (movementEffects.BeamExhaust.Idle ~= false) then
                self:UpdateBeamExhaust('Idle')
            end
            if not self.Footfalls and movementEffects[layer].Footfall then
                self.Footfalls = self:CreateFootFallManipulators(movementEffects[layer].Footfall)
            end
        else
            self.MovementEffectsExist = false
        end

        ArmyBrains[self.Army]:AddUnitStat(self.UnitId, "built", 1)

        -- Prevent UI mods from violating game/scenario restrictions
        local id = self.UnitId
        local index = self.Army
        if not ScenarioInfo.CampaignMode and Game.IsRestricted(id, index) then
            WARN('Unit.OnStopBeingBuilt() Army ' ..index.. ' cannot create restricted unit: ' .. (bp.Description or id))
            if self ~= nil then self:Destroy() end

            return false -- Report failure of OnStopBeingBuilt
        end

        if bp.EnhancementPresetAssigned then
            self:ForkThread(self.CreatePresetEnhancementsThread)
        end

        -- Don't try sending a Notify message from here if we're an ACU
        if self.techCategory ~= 'COMMAND' then
            self:SendNotifyMessage('completed')
        end

        return true
    end,

    StartBeingBuiltEffects = function(self, builder, layer)
        local BuildMeshBp = self:GetBlueprint().Display.BuildMeshBlueprint
        if BuildMeshBp then
            self:SetMesh(BuildMeshBp, true)
        end
    end,

    StopBeingBuiltEffects = function(self, builder, layer)
        local bp = self:GetBlueprint().Display
        local useTerrainType = false
        if bp then
            if bp.TerrainMeshes then
                local bpTM = bp.TerrainMeshes
                local pos = self:GetPosition()
                local terrainType = GetTerrainType(pos[1], pos[3])
                if bpTM[terrainType.Style] then
                    self:SetMesh(bpTM[terrainType.Style])
                    useTerrainType = true
                end
            end
            if not useTerrainType then
                self:SetMesh(bp.MeshBlueprint, true)
            end
        end
        self.OnBeingBuiltEffectsBag:Destroy()
    end,

    OnFailedToBeBuilt = function(self)
        self:ForkThread(function()
            WaitTicks(1)
            self:Destroy()
        end)
    end,

    OnSiloBuildStart = function(self, weapon)
        self.SiloWeapon = weapon
        self.SiloProjectile = weapon:GetProjectileBlueprint()
    end,

    OnSiloBuildEnd = function(self, weapon)
        self.SiloWeapon = nil
        self.SiloProjectile = nil
    end,

    -------------------------------------------------------------------------------------------
    -- UNIT ENHANCEMENT PRESETS
    -------------------------------------------------------------------------------------------
    ShowPresetEnhancementBones = function(self)
        -- Hide bones not involved in the preset enhancements.
        -- Useful during the build process to show the contours of the unit being built. Only visual.
        local bp = self:GetBlueprint()
        if bp.Enhancements and (bp.CategoriesHash.USEBUILDPRESETS or bp.CategoriesHash.ISPREENHANCEDUNIT) then

            -- Create a blank slate: Hide all enhancement bones as specified in the unit BP
            for k, enh in bp.Enhancements do
                if enh.HideBones then
                    for _, bone in enh.HideBones do
                        self:HideBone(bone, true)
                    end
                end
            end

            -- For the barebone version we're done here. For the presets versions: show the bones of the enhancements we'll create later on
            if bp.EnhancementPresetAssigned then
                for _, v in bp.EnhancementPresetAssigned.Enhancements do
                    -- First show all relevant bones
                    if bp.Enhancements[v] and bp.Enhancements[v].ShowBones then
                        for _, bone in bp.Enhancements[v].ShowBones do
                            self:ShowBone(bone, true)
                        end
                    end

                    -- Now hide child bones of previously revealed bones, that should remain hidden
                    if bp.Enhancements[v] and bp.Enhancements[v].HideBones then
                        for _, bone in bp.Enhancements[v].HideBones do
                            self:HideBone(bone, true)
                        end
                    end
                end
            end
        end
    end,

    CreatePresetEnhancements = function(self)
        local bp = self:GetBlueprint()
        if bp.Enhancements and bp.EnhancementPresetAssigned and bp.EnhancementPresetAssigned.Enhancements then
            for k, v in bp.EnhancementPresetAssigned.Enhancements do
                -- Enhancements may already have been created by SimUtils.TransferUnitsOwnership
                if not self:HasEnhancement(v) then
                    self:CreateEnhancement(v)
                end
            end
        end
    end,

    CreatePresetEnhancementsThread = function(self)
        -- Creating the preset enhancements on SCUs after they've been constructed. Delaying this by 1 tick to fix a problem where cloak and
        -- stealth enhancements work incorrectly.
        WaitTicks(1)
        if self and not self.Dead then
            self:CreatePresetEnhancements()
        end
    end,

    ShowEnhancementBones = function(self)
        -- Hide and show certain bones based on available enhancements
        local bp = self:GetBlueprint()
        if bp.Enhancements then
            for _, enh in bp.Enhancements do
                if enh.HideBones then
                    for _, bone in enh.HideBones do
                        self:HideBone(bone, true)
                    end
                end
            end
            for k, enh in bp.Enhancements do
                if self:HasEnhancement(k) and enh.ShowBones then
                    for _, bone in enh.ShowBones do
                        self:ShowBone(bone, true)
                    end
                end
            end
        end
    end,

    ----------------------------------------------------------------------------------------------
    -- CONSTRUCTING - BUILDING - REPAIR
    ----------------------------------------------------------------------------------------------
    SetupBuildBones = function(self)
        local bp = self:GetBlueprint()
        if not bp.General.BuildBones or
           not bp.General.BuildBones.YawBone or
           not bp.General.BuildBones.PitchBone or
           not bp.General.BuildBones.AimBone then
           return
        end

        -- Syntactical reference:
        -- CreateBuilderArmController(unit, turretBone, [barrelBone], [aimBone])
        -- BuilderArmManipulator:SetAimingArc(minHeading, maxHeading, headingMaxSlew, minPitch, maxPitch, pitchMaxSlew)
        self.BuildArmManipulator = CreateBuilderArmController(self, bp.General.BuildBones.YawBone or 0 , bp.General.BuildBones.PitchBone or 0, bp.General.BuildBones.AimBone or 0)
        self.BuildArmManipulator:SetAimingArc(-180, 180, 360, -90, 90, 360)
        self.BuildArmManipulator:SetPrecedence(5)
        if self.BuildingOpenAnimManip and self.BuildArmManipulator then
            self.BuildArmManipulator:Disable()
        end
        self.Trash:Add(self.BuildArmManipulator)
    end,

    BuildManipulatorSetEnabled = function(self, enable)
        if self.Dead or not self.BuildArmManipulator then return end
        if enable then
            self.BuildArmManipulator:Enable()
        else
            self.BuildArmManipulator:Disable()
        end
    end,

    GetRebuildBonus = function(self, bp)
        -- The engine intends to delete a wreck when our next build job starts. Remember this so we
        -- can regenerate the wreck if it's got the wrong one.
        self.EngineIsDeletingWreck = true

        return 0
    end,

    --- Look for a wreck of the thing we just started building at the same location. If there is
    -- one, give the rebuild bonus.
    SetRebuildProgress = function(self, unit)
        local upos = unit:GetPosition()
        local props = GetReclaimablesInRect(Rect(upos[1], upos[3], upos[1], upos[3]))
        local wreckage = {}
        local bpid = unit.UnitId

        if EntityCategoryContains(categories.ENGINEER, self) then
            for _, p in props do
                local pos = p.CachePosition
                if p.IsWreckage and p.AssociatedBP == bpid and upos[1] == pos[1] and upos[3] == pos[3] then
                    local bp = unit:GetBlueprint()
                    local UnitMaxMassReclaim = bp.Economy.BuildCostMass * (bp.Wreckage.MassMult or 0)
                    if UnitMaxMassReclaim and UnitMaxMassReclaim > 0 then
                        local progress = (p.ReclaimLeft * p.MaxMassReclaim) / UnitMaxMassReclaim * 0.5
                        -- Set health according to how much is left of the wreck
                        unit:SetHealth(self, unit:GetMaxHealth() * progress)
                    end

                    -- Clear up wreck after rebuild bonus applied if engine won't
                    if not unit.EngineIsDeletingWreck then
                        p:Destroy()
                    end

                    return
                end
            end
        end

        if self.EngineIsDeletingWreck then
            -- Control reaches this point when:
            -- A structure build template was created atop a wreck of the same building type.
            -- The build template was then moved somewhere else.
            -- The build template was not moved back onto the wreck before construction started.

            -- This is a pretty hilariously rare case (in reality, it's probably only going to arise
            -- rarely, or when someone is trying to use the remote-wreck-deletion exploit).
            -- As such, I don't feel especially guilty doing the following. This approach means we
            -- don't have to waste a ton of memory keeping lists of wrecks of various sorts, we just
            -- do this one hideously expensive routine in the exceptionally rare circumstance that
            -- the badness happens.

            local x, y = GetMapSize()
            local reclaimables = GetReclaimablesInRect(0, 0, x, y)

            for _, r in reclaimables do
                if r.IsWreckage and r.AssociatedBP == bpid and r:BeenDestroyed() then
                    r:Clone()
                    return
                end
            end
        end
    end,

    CheckAssistFocus = function(self)
        if not (self and EntityCategoryContains(categories.ENGINEER, self)) or self.Dead then
            return
        end

        local guarded = self:GetGuardedUnit()
        if guarded and not guarded.Dead then
            local focus = guarded:GetFocusUnit()
            if not focus then return end

            local cmd
            if guarded:IsUnitState('Reclaiming') then
                cmd = IssueReclaim
            elseif guarded:IsUnitState('Building') then
                cmd = IssueRepair
            end

            if cmd then
                IssueClearCommands({self})
                cmd({self}, focus)
                IssueGuard({self}, guarded)
            end
        end
    end,

    CheckAssistersFocus = function(self)
        for _, u in self:GetGuards() do
            if u:IsUnitState('Repairing') and not EntityCategoryContains(categories.INSIGNIFICANTUNIT, u) then
                u:CheckAssistFocus()
            end
        end
    end,

    OnStartBuild = function(self, built, order)
        -- Prevent UI mods from violating game/scenario restrictions
        local id = built.UnitId
        local bp = built:GetBlueprint()
        local bpSelf = self:GetBlueprint()
        if not ScenarioInfo.CampaignMode and Game.IsRestricted(id, self.Army) then
            WARN('Unit.OnStartBuild() Army ' ..self.Army.. ' cannot build restricted unit: ' .. (bp.Description or id))
            self:OnFailedToBuild() -- Don't use: self:OnStopBuild()
            IssueClearFactoryCommands({self})
            IssueClearCommands({self})
            return false -- Report failure of OnStartBuild
        end

        -- We just started a construction (and haven't just been tasked to work on a half-done
        -- project.)
        if built:GetHealth() == 1 then
            self:SetRebuildProgress(built)
            self.EngineIsDeletingWreck = nil
        end

        -- OnStartBuild() is called on paused engineers when they roll up to their next construction
        -- task. This is a native-code bug: it shouldn't be calling OnStartBuild at all in this case
        if self:IsPaused() then
            return true
        end

        if order == 'Repair' then
            self:OnStartRepair(built)
        elseif self:GetHealth() < self:GetMaxHealth() and not table.empty(self:GetGuards()) then
            -- Unit building something is damaged and has assisters, check their focus
            self:CheckAssistersFocus()
        end

        if order ~= 'Upgrade' or bpSelf.Display.ShowBuildEffectsDuringUpgrade then
            self:StartBuildingEffects(built, order)
        end

        self:SetActiveConsumptionActive()
        self:PlayUnitSound('Construct')
        self:PlayUnitAmbientSound('ConstructLoop')

        self:DoOnStartBuildCallbacks(built)


        if order == 'Upgrade' and bp.General.UpgradesFrom == self.UnitId then
            built.DisallowCollisions = true
            built:SetCanTakeDamage(false)
            built:SetCollisionShape('None')
            built.IsUpgrade = true

            --Transfer flag
            self.TransferUpgradeProgress = true
            self.UpgradeBuildTime = bp.Economy.BuildTime
            self.UpgradesTo = bp.BlueprintId
        end

        return true
    end,

    OnStopBuild = function(self, built)
        self:StopBuildingEffects(built)
        self:SetActiveConsumptionInactive()
        self:DoOnUnitBuiltCallbacks(built)
        self:StopUnitAmbientSound('ConstructLoop')
        self:PlayUnitSound('ConstructStop')
        self.TransferUpgradeProgress = nil

        if built.Repairers[self.EntityId] then
            self:OnStopRepair(self, built)
            built.Repairers[self.EntityId] = nil
        end
    end,

    OnFailedToBuild = function(self)
        self:DoOnFailedToBuildCallbacks()
        self:StopUnitAmbientSound('ConstructLoop')
    end,

    OnPrepareArmToBuild = function(self)
    end,

    OnStartBuilderTracking = function(self)
    end,

    OnStopBuilderTracking = function(self)
    end,

    OnBuildProgress = function(self, unit, oldProg, newProg)
    end,

    StartBuildingEffects = function(self, built, order)
        self.BuildEffectsBag:Add(self:ForkThread(self.CreateBuildEffects, built, order))
    end,

    CreateBuildEffects = function(self, built, order)
    end,

    StopBuildingEffects = function(self, built)
        self.BuildEffectsBag:Destroy()

        -- kept after #3355 for backwards compatibility with mods
        if self.buildBots then
            for _, b in self.buildBots do
                ChangeState(b, b.IdleState)
            end
        end
    end,

    OnStartSacrifice = function(self, target_unit)
        EffectUtilities.PlaySacrificingEffects(self, target_unit)
    end,

    OnStopSacrifice = function(self, target_unit)
        EffectUtilities.PlaySacrificeEffects(self, target_unit)
        self:SetDeathWeaponEnabled(false)
        self:Destroy()
    end,

    -------------------------------------------------------------------------------------------
    -- INTEL
    -------------------------------------------------------------------------------------------
    -- There are several ways to disable a unit's intel: The intel actually being part of an upgrade
    -- (enhancement) that is not present, the intel requiring energy and energy being stalled, etc.
    -- The intel is turned on using the EnableIntel engine call if all disablers are removed.
    -- As an optimisation, EnableIntel and DisableIntel are only called when going from one disabler
    -- present to zero, and when going from zero disablers to one.

    DisableUnitIntel = function(self, disabler, intel)
        local function DisableOneIntel(disabler, intel)
            local intDisabled = false
            if Set.Empty(self.IntelDisables[intel]) then
                local active = self:GetBlueprint().Intel.ActiveIntel
                if active and active[intel] then
                    return
                end
                self:DisableIntel(intel)

                -- Handle the cloak FX timing
                if intel == 'Cloak' or intel == 'CloakField' then
                    if disabler ~= 'NotInitialized' and self:GetBlueprint().Intel[intel] then
                        self:UpdateCloakEffect(false, intel)
                    end
                end

                intDisabled = true
            end
            self.IntelDisables[intel][disabler] = true
            return intDisabled
        end

        local intDisabled = false

        -- We need this guard because the engine emits an early OnLayerChange event that would screw us up here with certain units that have Intel changes on layer change
        -- The NotInitialized disabler is removed in OnStopBeingBuilt, when the Unit's intel engine state is properly initialized.
        if self.IntelDisables['Radar']['NotInitialized'] then
            return
        end

        if intel then
            intDisabled = DisableOneIntel(disabler, intel)
        else
            -- Loop over all intels and add disabler
            for intel, v in self.IntelDisables do
                intDisabled = DisableOneIntel(disabler, intel) or intDisabled -- Beware of short-circuiting
            end
        end

        if intDisabled then
            self:OnIntelDisabled(disabler, intel)
        end
    end,

    EnableUnitIntel = function(self, disabler, intel)
        local function EnableOneIntel(disabler, intel)
            local intEnabled = false
            if self.IntelDisables[intel][disabler] then -- Must check for explicit true contained
                self.IntelDisables[intel][disabler] = nil
                if Set.Empty(self.IntelDisables[intel]) then
                    self:EnableIntel(intel)

                    -- Handle the cloak FX timing
                    if intel == 'Cloak' or intel == 'CloakField' then
                        if disabler ~= 'NotInitialized' and self:GetBlueprint().Intel[intel] then
                            self:UpdateCloakEffect(true, intel)
                        end
                    end

                    intEnabled = true
                end
            end
            return intEnabled
        end

        local intEnabled = false

        -- We need this guard because the engine emits an early OnLayerChange event that would screw us up here.
        -- The NotInitialized disabler is removed in OnStopBeingBuilt, when the Unit's intel engine state is properly initialized.
        if self.IntelDisables['Radar']['NotInitialized'] == true and disabler ~= 'NotInitialized' then
            return
        end

        if intel then
            intEnabled = EnableOneIntel(disabler, intel)
        else
            -- Loop over all intels and remove disabler
            for intel, v in self.IntelDisables do
                intEnabled = EnableOneIntel(disabler, intel) or intEnabled -- Beware of short-circuiting
            end
        end

        if not self.IntelThread then
            self.IntelThread = self:ForkThread(self.IntelWatchThread)
        end

        if intEnabled then
            self:OnIntelEnabled()
        end
    end,

    OnIntelEnabled = function(self)
    end,

    OnIntelDisabled = function(self)
    end,

    UpdateCloakEffect = function(self, cloaked, intel)
        -- When debugging cloak FX issues, remember that once a structure unit is seen by the enemy,
        -- recloaking won't make it vanish again, and they'll see the new FX.
        if self and not self.Dead then
            if intel == 'Cloak' then
                local bpDisplay = self:GetBlueprint().Display

                if cloaked then
                    self:SetMesh(bpDisplay.CloakMeshBlueprint, true)
                else
                    self:SetMesh(bpDisplay.MeshBlueprint, true)
                end
            elseif intel == 'CloakField' then
                if self.CloakFieldWatcherThread then
                    KillThread(self.CloakFieldWatcherThread)
                    self.CloakFieldWatcherThread = nil
                end

                if cloaked then
                    self.CloakFieldWatcherThread = self:ForkThread(self.CloakFieldWatcher)
                end
            end
        end
    end,

    CloakFieldWatcher = function(self)
        if self and not self.Dead then
            local bp = self:GetBlueprint()
            local radius = bp.Intel.CloakFieldRadius - 2 -- Need to take off 2, because engine reasons
            local brain = self:GetAIBrain()

            while self and not self.Dead and self:IsIntelEnabled('CloakField') do
                local pos = self:GetPosition()
                local units = brain:GetUnitsAroundPoint(categories.ALLUNITS, pos, radius, 'Ally')

                for _, unit in units do
                    if unit and not unit.Dead and unit ~= self then
                        if unit.CloakFXWatcherThread then
                            KillThread(unit.CloakFXWatcherThread)
                            unit.CloakFXWatcherThread = nil
                        end

                        unit:UpdateCloakEffect(true, 'Cloak') -- Turn on the FX for the unit
                        unit.CloakFXWatcherThread = unit:ForkThread(unit.CloakFXWatcher)
                    end
                end

                WaitTicks(6)
            end
        end
    end,

    CloakFXWatcher = function(self)
        WaitTicks(6)

        if self and not self.Dead then
            self:UpdateCloakEffect(false, 'Cloak')
        end
    end,

    ShouldWatchIntel = function(self)
        if self:GetBlueprint().Intel.FreeIntel then
            return false
        end
        local bpVal = self:GetBlueprint().Economy.MaintenanceConsumptionPerSecondEnergy
        -- Check enhancements
        if not bpVal or bpVal <= 0 then
            local enh = self:GetBlueprint().Enhancements
            if enh then
                for k, v in enh do
                    if self:HasEnhancement(k) and v.MaintenanceConsumptionPerSecondEnergy and v.MaintenanceConsumptionPerSecondEnergy > 0 then
                        bpVal = v.MaintenanceConsumptionPerSecondEnergy
                        break
                    end
                end
            end
        end
        local watchPower = false
        if bpVal and bpVal > 0 then
            local intelTypeTbl = {'JamRadius', 'SpoofRadius'}
            local intelTypeBool = {'RadarStealth', 'SonarStealth', 'Cloak'}
            local intelTypeNum = {'RadarRadius', 'SonarRadius', 'OmniRadius', 'RadarStealthFieldRadius', 'SonarStealthFieldRadius', 'CloakFieldRadius', }
            local bpInt = self:GetBlueprint().Intel
            if bpInt then
                for _, v in intelTypeTbl do
                    for ki, vi in bpInt[v] do
                        if vi > 0 then
                            watchPower = true
                            break
                        end
                    end
                    if watchPower then break end
                end
                for _, v in intelTypeBool do
                    if bpInt[v] then
                        watchPower = true
                        break
                    end
                end
                for _, v in intelTypeNum do
                    if bpInt[v] > 0 then
                        watchPower = true
                        break
                    end
                end
            end
        end
        return watchPower
    end,

    IntelWatchThread = function(self)
        local aiBrain = self:GetAIBrain()
        local bp = self:GetBlueprint()
        local recharge = bp.Intel.ReactivateTime or 10
        while self:ShouldWatchIntel() do
            WaitSeconds(0.5)

            -- Checking for less than 1 because sometimes there's more
            -- than 0 and less than 1 in stock and that last bit of
            -- energy isn't used. This results in the radar being
            -- on even though there's no energy to run it. Shields
            -- have a similar bug with a similar fix.
            if aiBrain:GetEconomyStored('ENERGY') < 1 and not self.ToggledOff then
                self:DisableUnitIntel('Energy', nil)
                WaitSeconds(recharge)
                self:EnableUnitIntel('Energy', nil)
            end
        end
        if self.IntelThread then
            self.IntelThread = nil
        end
    end,

    AddDetectedByHook = function(self, hook)
        if not self.DetectedByHooks then
            self.DetectedByHooks = {}
        end
        table.insert(self.DetectedByHooks, hook)
    end,

    RemoveDetectedByHook = function(self, hook)
        if self.DetectedByHooks then
            for k, v in self.DetectedByHooks do
                if v == hook then
                    table.remove(self.DetectedByHooks, k)
                    return
                end
            end
        end
    end,

    OnDetectedBy = function(self, index)
        if self.DetectedByHooks then
            for k, v in self.DetectedByHooks do
                v(self, index)
            end
        end
    end,

    -------------------------------------------------------------------------------------------
    -- GENERIC WORK
    -------------------------------------------------------------------------------------------
    InheritWork = function(self, target)
        self.WorkItem = target.WorkItem
        self.WorkItemBuildCostEnergy = target.WorkItemBuildCostEnergy
        self.WorkItemBuildCostMass = target.WorkItemBuildCostMass
        self.WorkItemBuildTime = target.WorkItemBuildTime
    end,

    ClearWork = function(self)
        self.WorkProgress = 0
        self.WorkItem = nil
        self.WorkItemBuildCostEnergy = nil
        self.WorkItemBuildCostMass = nil
        self.WorkItemBuildTime = nil
    end,

    OnWorkBegin = function(self, work)
        local enhCommon = import('/lua/enhancementcommon.lua')
        local restrictions = enhCommon.GetRestricted()
        if restrictions[work] then
            self:OnWorkFail(work)
            return false
        end

        local unitEnhancements = enhCommon.GetEnhancements(self.EntityId)
        local tempEnhanceBp = self:GetBlueprint().Enhancements[work]
        --LOG('ACU is ordering enhancement ['..repr(tempEnhanceBp.Name)..'] ' )
        if tempEnhanceBp.Prerequisite then
            if unitEnhancements[tempEnhanceBp.Slot] ~= tempEnhanceBp.Prerequisite then
                WARN('*WARNING: Ordered enhancement ['..tempEnhanceBp.Name..'] does not have the proper prerequisite. Slot ['..tempEnhanceBp.Slot..'] - Needed: ['..unitEnhancements[tempEnhanceBp.Slot]..'] - Installed: ['..tempEnhanceBp.Prerequisite..']')
                return false
            end
        elseif unitEnhancements[tempEnhanceBp.Slot] then
            WARN('*WARNING: Ordered enhancement ['..tempEnhanceBp.Name..'] does not have the proper slot available. Slot ['..tempEnhanceBp.Slot..'] has already ['..unitEnhancements[tempEnhanceBp.Slot]..'] installed.')
            return false
        end


        self.WorkItem = tempEnhanceBp
        self.WorkItemBuildCostEnergy = tempEnhanceBp.BuildCostEnergy
        self.WorkItemBuildCostMass = tempEnhanceBp.BuildCostEnergy
        self.WorkItemBuildTime = tempEnhanceBp.BuildTime
        self.WorkProgress = 0

        self:PlayUnitSound('EnhanceStart')
        self:PlayUnitAmbientSound('EnhanceLoop')
        self:CreateEnhancementEffects(work)
        if not self:IsPaused() then
            self:SetActiveConsumptionActive()
        end

        ChangeState(self, self.WorkingState)

        -- Inform EnhanceTask that enhancement is not restricted
        return true
    end,

    OnWorkEnd = function(self, work)
        self:ClearWork()
        self:SetActiveConsumptionInactive()
        self:PlayUnitSound('EnhanceEnd')
        self:StopUnitAmbientSound('EnhanceLoop')
        self:CleanupEnhancementEffects()
    end,

    OnWorkFail = function(self, work)
        self:ClearWork()
        self:SetActiveConsumptionInactive()
        self:PlayUnitSound('EnhanceFail')
        self:StopUnitAmbientSound('EnhanceLoop')
        self:CleanupEnhancementEffects()
    end,

    CreateEnhancement = function(self, enh)
        local bp = self:GetBlueprint().Enhancements[enh]
        if not bp then
            error('*ERROR: Got CreateEnhancement call with an enhancement that doesnt exist in the blueprint.', 2)
            return false
        end

        if bp.ShowBones then
            for _, v in bp.ShowBones do
                if self:IsValidBone(v) then
                    self:ShowBone(v, true)
                end
            end
        end

        if bp.HideBones then
            for _, v in bp.HideBones do
                if self:IsValidBone(v) then
                    self:HideBone(v, true)
                end
            end
        end

        AddUnitEnhancement(self, enh, bp.Slot or '')
        if bp.RemoveEnhancements then
            for _, v in bp.RemoveEnhancements do
                RemoveUnitEnhancement(self, v)
            end
        end

        self:RequestRefreshUI()
    end,

    CreateEnhancementEffects = function(self, enhancement)
        local bp = self:GetBlueprint().Enhancements[enhancement]
        local effects = TrashBag()
        local scale = math.min(4, math.max(1, (bp.BuildCostEnergy / bp.BuildTime or 1) / 50))

        if bp.UpgradeEffectBones then
            for _, v in bp.UpgradeEffectBones do
                if self:IsValidBone(v) then
                    EffectUtilities.CreateEnhancementEffectAtBone(self, v, self.UpgradeEffectsBag)
                end
            end
        end

        if bp.UpgradeUnitAmbientBones then
            for _, v in bp.UpgradeUnitAmbientBones do
                if self:IsValidBone(v) then
                    EffectUtilities.CreateEnhancementUnitAmbient(self, v, self.UpgradeEffectsBag)
                end
            end
        end

        for _, e in effects do
            e:ScaleEmitter(scale)
            self.UpgradeEffectsBag:Add(e)
        end
    end,

    CleanupEnhancementEffects = function(self)
        self.UpgradeEffectsBag:Destroy()
    end,

    HasEnhancement = function(self, enh)
        local unitEnh = SimUnitEnhancements[self.EntityId]
        if unitEnh then
            for k, v in unitEnh do
                if v == enh then
                    return true
                end
            end
        end

        return false
    end,

    -------------------------------------------------------------------------------------------
    -- LAYER EVENTS
    -------------------------------------------------------------------------------------------
    OnLayerChange = function(self, new, old)

        -- this function is called _before_ OnCreate is called. 
        -- You can identify this original call by checking whether 'old' is set to 'None'.

        -- This function is called when:
        -- - A unit changes layer (heh)
        -- - For all units part of a transport, when the transport changes layer (e.g., land units can become 'Air')
        -- - When a jet lands, it changes to land (from Air)

        -- Store latest layer for performance, preventing .Layer engine calls.
        self.Layer = new 

        -- Bail out early if dead. The engine calls this function AFTER entity:Destroy() has killed
        -- the C object. Any functions down this line which expect a live C object (self:CreateAnimator())
        -- for example, will throw an error.
        if self.Dead then return end

        -- set valid targets for weapons
        -- if old is defined as 'None' then OnCreate hasn't been called yet - do it the old way.
        if old ~= 'None' then 
            for i = 1, self.WeaponCount do
                self.WeaponInstances[i]:SetValidTargetsForCurrentLayer(new)
            end
        else 
            for i = 1, self:GetWeaponCount() do
                self:GetWeapon(i):SetValidTargetsForCurrentLayer(new)
            end
        end

        if (old == 'Seabed' or old == 'Water' or old == 'Sub' or old == 'None') and new == 'Land' then
            self:DisableIntel('WaterVision')
        elseif (old == 'Land' or old == 'None') and (new == 'Seabed' or new == 'Water' or new == 'Sub') then
            self:EnableIntel('WaterVision')
        end

        -- All units want normal vision!
        if old == 'None' then
            self:EnableIntel('Vision')
        end

        if new == 'Land' then
            self:PlayUnitSound('TransitionLand')
            self:PlayUnitAmbientSound('AmbientMoveLand')
        elseif new == 'Water' or new == 'Seabed' then
            self:PlayUnitSound('TransitionWater')
            self:PlayUnitAmbientSound('AmbientMoveWater')
        elseif new == 'Sub' then
            self:PlayUnitAmbientSound('AmbientMoveSub')
        end

        local movementEffects = self.MovementEffects
        if not self.Footfalls and movementEffects[new].Footfall then
            self.Footfalls = self:CreateFootFallManipulators(movementEffects[new].Footfall)
        end
        self:CreateLayerChangeEffects(new, old)

        -- Trigger the re-worded stuff that used to be inherited, no longer because of the engine bug above.
        if self.LayerChangeTrigger then
            self:LayerChangeTrigger(new, old)
        end
    end,

    OnMotionHorzEventChange = function(self, new, old)
        if self.Dead then
            return
        end
        local layer = self.Layer

        if old == 'Stopped' or (old == 'Stopping' and (new == 'Cruise' or new == 'TopSpeed')) then
            -- Try the specialised sound, fall back to the general one.
            if not self:PlayUnitSound('StartMove' .. layer) then
                self:PlayUnitSound('StartMove')
            end

            -- Initiate the unit's ambient movement sound
            -- Note that there is not currently an 'Air' version, and that
            -- AmbientMoveWater plays if the unit is in either the Water or Seabed layer.
            if not (
                ((layer == 'Water' or layer == 'Seabed') and self:PlayUnitAmbientSound('AmbientMoveWater')) or
                (layer == 'Sub' and self:PlayUnitAmbientSound('AmbientMoveSub')) or
                (layer == 'Land' and self:PlayUnitAmbientSound('AmbientMoveLand'))
                )
            then
                self:PlayUnitAmbientSound('AmbientMove')
            end

        end

        if (new == 'Stopped' or new == 'Stopping') and (old == 'Cruise' or old == 'TopSpeed') then
            -- Try the specialised sound, fall back to the general one.
            if not self:PlayUnitSound('StopMove' .. layer) then
                self:PlayUnitSound('StopMove')
            end
        end

        if new == 'Stopped' or new == 'Stopping' then
            -- Stop ambient sounds
            self:StopUnitAmbientSound('AmbientMove')
            self:StopUnitAmbientSound('AmbientMoveWater')
            self:StopUnitAmbientSound('AmbientMoveSub')
            self:StopUnitAmbientSound('AmbientMoveLand')
        end

        if self.MovementEffectsExist then
            self:UpdateMovementEffectsOnMotionEventChange(new, old)
        end

        if old == 'Stopped' then
            self:DoOnHorizontalStartMoveCallbacks()
        end

        -- update weapon capabilities
        for k = 1, self.WeaponCount do
            self.WeaponInstances[k]:OnMotionHorzEventChange(new, old)
        end
    end,

    OnMotionVertEventChange = function(self, new, old)
        if self.Dead then
            return
        end

        if new == 'Down' then
            -- Play the "landing" sound
            self:PlayUnitSound('Landing')
        elseif new == 'Bottom' or new == 'Hover' then
            -- Play the "landed" sound
            self:PlayUnitSound('Landed')
        elseif new == 'Up' or (new == 'Top' and (old == 'Down' or old == 'Bottom')) then
            -- Play the "takeoff" sound
            self:PlayUnitSound('TakeOff')
        end

        -- Adjust any beam exhaust
        if new == 'Bottom' then
            self:UpdateBeamExhaust('Landed')
        elseif old == 'Bottom' then
            self:UpdateBeamExhaust('Cruise')
        end

        -- Surfacing and sinking, landing and take off idle effects
        local layer = self.Layer
        if (new == 'Up' and old == 'Bottom') or (new == 'Down' and old == 'Top') then
            self:DestroyIdleEffects()

            if new == 'Up' and layer == 'Sub' then
                self:PlayUnitSound('SurfaceStart')
            end
            if new == 'Down' and layer == 'Water' then
                self:PlayUnitSound('SubmergeStart')
                if self.SurfaceAnimator then
                    self.SurfaceAnimator:SetRate(-1)
                end
            end
        end

        if (new == 'Top' and old == 'Up') or (new == 'Bottom' and old == 'Down') then
            self:CreateIdleEffects()

            if new == 'Bottom' and layer == 'Sub' then
                self:PlayUnitSound('SubmergeEnd')
            end
            if new == 'Top' and layer == 'Water' then
                self:PlayUnitSound('SurfaceEnd')
                local surfaceAnim = self:GetBlueprint().Display.AnimationSurface
                if not self.SurfaceAnimator and surfaceAnim then
                    self.SurfaceAnimator = CreateAnimator(self)
                end
                if surfaceAnim and self.SurfaceAnimator then
                    self.SurfaceAnimator:PlayAnim(surfaceAnim):SetRate(1)
                end
            end
        end
        self:CreateMotionChangeEffects(new, old)
    end,

    -- Called as planes whoosh round corners. No sounds were shipped for use with this and it was a
    -- cycle eater, so we killed it.
    OnMotionTurnEventChange = function() end,

    OnTerrainTypeChange = function(self, new, old)
        if self.MovementEffectsExist then
            self:DestroyMovementEffects()
            self:CreateMovementEffects(self.MovementEffectsBag, nil, new)
        end
    end,

    OnAnimCollision = function(self, bone, x, y, z)
        local layer = self.Layer
        local movementEffects = self.MovementEffects and self.MovementEffects[layer] and self.MovementEffects[layer].Footfall

        if movementEffects then
            local effects = {}
            local scale = 1
            local offset
            local boneTable

            if movementEffects.Damage then
                local bpDamage = movementEffects.Damage
                DamageArea(self, self:GetPosition(bone), bpDamage.Radius, bpDamage.Amount, bpDamage.Type, bpDamage.DamageFriendly)
            end

            if movementEffects.CameraShake then
                local shake = movementEffects.CameraShake
                self:ShakeCamera(shake.Radius, shake.MaxShakeEpicenter, shake.MinShakeAtRadius, shake.Interval)
            end

            for _, v in movementEffects.Bones do
                if bone == v.FootBone then
                    boneTable = v
                    bone = v.FootBone
                    scale = boneTable.Scale or 1
                    offset = bone.Offset
                    if v.Type then
                        effects = self.GetTerrainTypeEffects('FXMovement', layer, self:GetPosition(v.FootBone), v.Type)
                    end

                    break
                end
            end

            if boneTable.Tread and self:GetTTTreadType(self:GetPosition(bone)) ~= 'None' then
                CreateSplatOnBone(self, boneTable.Tread.TreadOffset, 0, boneTable.Tread.TreadMarks, boneTable.Tread.TreadMarksSizeX, boneTable.Tread.TreadMarksSizeZ, 100, boneTable.Tread.TreadLifeTime or 15, self.Army)
                local treadOffsetX = boneTable.Tread.TreadOffset[1]
                if x and x > 0 then
                    if layer ~= 'Seabed' then
                    self:PlayUnitSound('FootFallLeft')
                    else
                        self:PlayUnitSound('FootFallLeftSeabed')
                    end
                elseif x and x < 0 then
                    if layer ~= 'Seabed' then
                    self:PlayUnitSound('FootFallRight')
                    else
                        self:PlayUnitSound('FootFallRightSeabed')
                    end
                end
            end

            for k, v in effects do
                CreateEmitterAtBone(self, bone, self.Army, v):ScaleEmitter(scale):OffsetEmitter(offset.x or 0, offset.y or 0, offset.z or 0)
            end
        end

        if layer ~= 'Seabed' then
            self:PlayUnitSound('FootFallGeneric')
        else
            self:PlayUnitSound('FootFallGenericSeabed')
        end
    end,

    UpdateMovementEffectsOnMotionEventChange = function(self, new, old)
        if old == 'TopSpeed' then
            -- Destroy top speed contrails and exhaust effects
            self:DestroyTopSpeedEffects()
        end

        local layer = self.Layer
        local movementEffects = self.MovementEffects
        local movementEffectsLayer = movementEffects[layer]
        if new == 'TopSpeed' and self.HasFuel then
            if movementEffectsLayer.Contrails and self.ContrailEffects then
                self:CreateContrails(movementEffectsLayer.Contrails)
            end
            if movementEffectsLayer.TopSpeedFX then
                self:CreateMovementEffects(self.TopSpeedEffectsBag, 'TopSpeed')
            end
        end

        if (old == 'Stopped' and new ~= 'Stopping') or (old == 'Stopping' and new ~= 'Stopped') then
            self:DestroyIdleEffects()
            self:DestroyMovementEffects()
            self:CreateMovementEffects(self.MovementEffectsBag, nil)
            if movementEffects.BeamExhaust then
                self:UpdateBeamExhaust('Cruise')
            end
            if self.Detector then
                self.Detector:Enable()
            end
        end

        if new == 'Stopped' then
            self:DestroyMovementEffects()
            self:DestroyIdleEffects()
            self:CreateIdleEffects()
            if movementEffects.BeamExhaust then
                self:UpdateBeamExhaust('Idle')
            end
            if self.Detector then
                self.Detector:Disable()
            end
        end
    end,

    GetTTTreadType = function(self, pos)
        local TerrainType = GetTerrainType(pos.x, pos.z)
        return TerrainType.Treads or 'None'
    end,

    GetTerrainTypeEffects = function(FxType, layer, pos, type, typesuffix)
        local TerrainType

        -- Get terrain type mapped to local position and if none defined use default
        if type then
            TerrainType = GetTerrainType(pos.x, pos.z)
        else
            TerrainType = GetTerrainType(-1, -1)
            type = 'Default'
        end

        -- Add in type suffix to type mask name
        if typesuffix then
            type = type .. typesuffix
        end

        -- If our current masking is empty try and get the default layer effect
        if TerrainType[FxType][layer][type] == nil then
            TerrainType = GetTerrainType(-1, -1)
        end

        return TerrainType[FxType][layer][type] or {}
    end,

    CreateTerrainTypeEffects = function(self, effectTypeGroups, FxBlockType, FxBlockKey, TypeSuffix, EffectBag, TerrainType)
        local pos = self:GetPosition()
        local effects = {}
        local emit

        for kBG, vTypeGroup in effectTypeGroups do
            if TerrainType then
                effects = TerrainType[FxBlockType][FxBlockKey][vTypeGroup.Type] or {}
            else
                effects = self.GetTerrainTypeEffects(FxBlockType, FxBlockKey, pos, vTypeGroup.Type, TypeSuffix)
            end

            if not vTypeGroup.Bones or (vTypeGroup.Bones and (table.empty(vTypeGroup.Bones))) then
                WARN('*WARNING: No effect bones defined for layer group ', repr(self.UnitId), ', Add these to a table in Display.[EffectGroup].', self.Layer, '.Effects {Bones ={}} in unit blueprint.')
            else
                for kb, vBone in vTypeGroup.Bones do
                    for ke, vEffect in effects do
                        emit = CreateAttachedEmitter(self, vBone, self.Army, vEffect):ScaleEmitter(vTypeGroup.Scale or 1)
                        if vTypeGroup.Offset then
                            emit:OffsetEmitter(vTypeGroup.Offset[1] or 0, vTypeGroup.Offset[2] or 0, vTypeGroup.Offset[3] or 0)
                        end
                        if EffectBag then
                            table.insert(EffectBag, emit)
                        end
                    end
                end
            end
        end
    end,

    CreateIdleEffects = function(self)
        local layer = self.Layer
        local bpTable = self:GetBlueprint().Display.IdleEffects
        if bpTable[layer] and bpTable[layer].Effects then
            self:CreateTerrainTypeEffects(bpTable[layer].Effects, 'FXIdle',  layer, nil, self.IdleEffectsBag)
        end
    end,

    CreateMovementEffects = function(self, EffectsBag, TypeSuffix, TerrainType)
        local layer = self.Layer
        local bpTable = self:GetBlueprint().Display.MovementEffects

        if bpTable[layer] then
            bpTable = bpTable[layer]
            local effectTypeGroups = bpTable.Effects

            if bpTable.Treads then
                self:CreateTreads(bpTable.Treads)
            else
                self:RemoveScroller()
            end

            if not effectTypeGroups or (effectTypeGroups and (table.empty(effectTypeGroups))) then
                if not self.Footfalls and bpTable.Footfall then
                    WARN('*WARNING: No movement effect groups defined for unit ', repr(self.UnitId), ', Effect groups with bone lists must be defined to play movement effects. Add these to the Display.MovementEffects', layer, '.Effects table in unit blueprint. ')
                end
                return false
            end

            if bpTable.CameraShake then
                self.CamShakeT1 = self:ForkThread(self.MovementCameraShakeThread, bpTable.CameraShake)
            end

            self:CreateTerrainTypeEffects(effectTypeGroups, 'FXMovement', layer, TypeSuffix, EffectsBag, TerrainType)
        end
    end,

    CreateLayerChangeEffects = function(self, new, old)
        local key = old..new
        local bpTable = self:GetBlueprint().Display.LayerChangeEffects[key]

        if bpTable then
            self:CreateTerrainTypeEffects(bpTable.Effects, 'FXLayerChange', key)
        end
    end,

    CreateMotionChangeEffects = function(self, new, old)
        local key = self.Layer..old..new
        local bpTable = self:GetBlueprint().Display.MotionChangeEffects[key]

        if bpTable then
            self:CreateTerrainTypeEffects(bpTable.Effects, 'FXMotionChange', key)
        end
    end,

    DestroyMovementEffects = function(self)
        EffectUtilities.CleanupEffectBag(self, 'MovementEffectsBag')

        -- Clean up any camera shake going on.
        local bpTable = self:GetBlueprint().Display.MovementEffects
        local layer = self.Layer
        if self.CamShakeT1 then
            KillThread(self.CamShakeT1)

            local shake = bpTable[layer].CameraShake
            if shake and shake.Radius and shake.MaxShakeEpicenter and shake.MinShakeAtRadius then
                self:ShakeCamera(shake.Radius, shake.MaxShakeEpicenter * 0.25, shake.MinShakeAtRadius * 0.25, 1)
            end
        end

        -- Clean up treads
        if self.TreadThreads then
            for k, v in self.TreadThreads do
                KillThread(v)
            end
            self.TreadThreads = {}
        end

        if bpTable[layer].Treads.ScrollTreads then
            self:RemoveScroller()
        end
    end,

    DestroyTopSpeedEffects = function(self)
        EffectUtilities.CleanupEffectBag(self, 'TopSpeedEffectsBag')
    end,

    DestroyIdleEffects = function(self)
        EffectUtilities.CleanupEffectBag(self, 'IdleEffectsBag')
    end,

    UpdateBeamExhaust = function(self, motionState)
        local beamExhaust = self.MovementEffects.BeamExhaust

        if not beamExhaust then
            return false
        end

        if motionState == 'Idle' then
            if self.BeamExhaustCruise  then
                self:DestroyBeamExhaust()
            end
            if self.BeamExhaustIdle and table.empty(self.BeamExhaustEffectsBag) and beamExhaust.Idle ~= false then
                self:CreateBeamExhaust(beamExhaust, self.BeamExhaustIdle)
            end
        elseif motionState == 'Cruise' then
            if self.BeamExhaustIdle and self.BeamExhaustCruise then
                self:DestroyBeamExhaust()
            end
            if self.BeamExhaustCruise and beamExhaust.Cruise ~= false then
                self:CreateBeamExhaust(beamExhaust, self.BeamExhaustCruise)
            end
        elseif motionState == 'Landed' then
            if not beamExhaust.Landed then
                self:DestroyBeamExhaust()
            end
        end
    end,

    CreateBeamExhaust = function(self, bpTable, beamBP)
        local effectBones = bpTable.Bones
        if not effectBones or (effectBones and table.empty(effectBones)) then
            WARN('*WARNING: No beam exhaust effect bones defined for unit ', repr(self.UnitId), ', Effect Bones must be defined to play beam exhaust effects. Add these to the Display.MovementEffects.BeamExhaust.Bones table in unit blueprint.')
            return false
        end
        for kb, vb in effectBones do
            table.insert(self.BeamExhaustEffectsBag, CreateBeamEmitterOnEntity(self, vb, self.Army, beamBP))
        end
    end,

    DestroyBeamExhaust = function(self)
        EffectUtilities.CleanupEffectBag(self, 'BeamExhaustEffectsBag')
    end,

    CreateContrails = function(self, tableData)
        local effectBones = tableData.Bones
        if not effectBones or (effectBones and table.empty(effectBones)) then
            WARN('*WARNING: No contrail effect bones defined for unit ', repr(self.UnitId), ', Effect Bones must be defined to play contrail effects. Add these to the Display.MovementEffects.Air.Contrail.Bones table in unit blueprint. ')
            return false
        end
        local ZOffset = tableData.ZOffset or 0.0
        for ke, ve in self.ContrailEffects do
            for kb, vb in effectBones do
                table.insert(self.TopSpeedEffectsBag, CreateTrail(self, vb, self.Army, ve):SetEmitterParam('POSITION_Z', ZOffset))
            end
        end
    end,

    MovementCameraShakeThread = function(self, camShake)
        local radius = camShake.Radius or 5.0
        local maxShakeEpicenter = camShake.MaxShakeEpicenter or 1.0
        local minShakeAtRadius = camShake.MinShakeAtRadius or 0.0
        local interval = camShake.Interval or 10.0
        if interval ~= 0.0 then
            while true do
                self:ShakeCamera(radius, maxShakeEpicenter, minShakeAtRadius, interval)
                WaitSeconds(interval)
            end
        end
    end,

    CreateTreads = function(self, treads)
        if treads.ScrollTreads then
            self:AddThreadScroller(1.0, treads.ScrollMultiplier or 0.2)
        end

        self.TreadThreads = {}
        if treads.TreadMarks then
            local type = self:GetTTTreadType(self:GetPosition())
            if type ~= 'None' then
                for k, v in treads.TreadMarks do
                    table.insert(self.TreadThreads, self:ForkThread(self.CreateTreadsThread, v, type))
                end
            end
        end
    end,

    CreateTreadsThread = function(self, treads, type)
        local sizeX = treads.TreadMarksSizeX
        local sizeZ = treads.TreadMarksSizeZ
        local interval = treads.TreadMarksInterval
        local treadOffset = treads.TreadOffset
        local treadBone = treads.BoneName or 0
        local treadTexture = treads.TreadMarks
        local duration = treads.TreadLifeTime or 10

        while true do
            -- Syntactic reference
            -- CreateSplatOnBone(entity, offset, boneName, textureName, sizeX, sizeZ, lodParam, duration, army)
            CreateSplatOnBone(self, treadOffset, treadBone, treadTexture, sizeX, sizeZ, 130, duration, self.Army)
            WaitSeconds(interval)
        end
    end,

    CreateFootFallManipulators = function(self, footfall)
        if not footfall.Bones or (footfall.Bones and (table.empty(footfall.Bones))) then
            WARN('*WARNING: No footfall bones defined for unit ', repr(self.UnitId), ', ', 'these must be defined to animation collision detector and foot plant controller')
            return false
        end

        self.Detector = CreateCollisionDetector(self)
        self.Trash:Add(self.Detector)
        for _, v in footfall.Bones do
            self.Detector:WatchBone(v.FootBone)
            if v.FootBone and v.KneeBone and v.HipBone then
                CreateFootPlantController(self, v.FootBone, v.KneeBone, v.HipBone, v.StraightLegs or true, v.MaxFootFall or 0):SetPrecedence(10)
            end
        end

        return true
    end,

    GetWeaponClass = function(self, label)
        return self.Weapons[label] or import('/lua/sim/Weapon.lua').Weapon
    end,

    -- Return the total time in seconds, cost in energy, and cost in mass to build the given target type.
    GetBuildCosts = function(self, target_bp)
        return Game.GetConstructEconomyModel(self, target_bp.Economy)
    end,

    SetReclaimTimeMultiplier = function(self, time_mult)
        self.ReclaimTimeMultiplier = time_mult
    end,

    -- Return the total time in seconds, cost in energy, and cost in mass to reclaim the given target from 100%.
    -- The energy and mass costs will normally be negative, to indicate that you gain mass/energy back.
    GetReclaimCosts = function(self, target_entity)
        if IsUnit(target_entity) then
            local bp = self:GetBlueprint()
            local target_bp = target_entity:GetBlueprint()
            local mtime = target_bp.Economy.BuildCostEnergy / self:GetBuildRate()
            local etime = target_bp.Economy.BuildCostMass / self:GetBuildRate()
            local time = mtime
            if mtime < etime then
                time = etime
            end

            time = time * (self.ReclaimTimeMultiplier or 1)
            time = math.max((time / 10), 0.0001)  -- This should never be 0 or we'll divide by 0

            return time, target_bp.Economy.BuildCostEnergy, target_bp.Economy.BuildCostMass
        elseif IsProp(target_entity) then
            return target_entity:GetReclaimCosts(self)
        end
    end,

    SetCaptureTimeMultiplier = function(self, time_mult)
        self.CaptureTimeMultiplier = time_mult
    end,

    -- Return the total time in seconds, cost in energy, and cost in mass to capture the given target.
    GetCaptureCosts = function(self, target_entity)
        local target_bp = target_entity:GetBlueprint().Economy
        local bp = self:GetBlueprint().Economy
        local time = ((target_bp.BuildTime or 10) / self:GetBuildRate()) / 2
        local energy = target_bp.BuildCostEnergy or 100
        time = time * (self.CaptureTimeMultiplier or 1)

        return time, energy, 0
    end,

    GetHealthPercent = function(self)
        local health = self:GetHealth()
        local maxHealth = self:GetBlueprint().Defense.MaxHealth
        return health / maxHealth
    end,

    ValidateBone = function(self, bone)
        if self:IsValidBone(bone) then
            return true
        end
        error('*ERROR: Trying to use the bone, ' .. bone .. ' on unit ' .. self.UnitId .. ' and it does not exist in the model.', 2)

        return false
    end,

    CheckBuildRestriction = function(self, target_bp)
        if self:CanBuild(target_bp.BlueprintId) then
            return true
        else
            return false
        end
    end,

    -------------------------------------------------------------------------------------------
    -- Sound
    -------------------------------------------------------------------------------------------

    --- Plays a sound using the unit as a source. Returns true if successful, false otherwise
    -- @param self A unit
    -- @param sound A string identifier that represents the sound to be played.
    PlayUnitSound = function(self, sound)
        local audio = self.Audio[sound]
        if not audio then 
            return false
        end

        self.SoundEntity:PlaySound(audio)
        return true
    end,

    --- Plays an ambient sound using the unit as a source. Returns true if successful, false otherwise
    -- @param self A unit
    -- @param sound A string identifier that represents the ambient sound to be played.
    PlayUnitAmbientSound = function(self, sound)
        local audio = self.Audio[sound]
        if not audio then 
            return false
        end

        self.SoundEntity:SetAmbientSound(audio, nil)
        return true 
    end,

    --- Stops playing the ambient sound that is currently being played.
    -- @param self A unit
    StopUnitAmbientSound = function(self)
        self.SoundEntity:SetAmbientSound(nil, nil)
        return true
    end,

    -------------------------------------------------------------------------------------------
    -- UNIT CALLBACKS
    -------------------------------------------------------------------------------------------
    AddUnitCallback = function(self, fn, type)
        if not fn then
            error('*ERROR: Tried to add a callback type - ' .. type .. ' with a nil function')
            return
        end
        table.insert(self.EventCallbacks[type], fn)
    end,

    DoUnitCallbacks = function(self, type, param)
        if self.EventCallbacks[type] then
            for num, cb in self.EventCallbacks[type] do
                cb(self, param)
            end
        end
    end,

    AddProjectileDamagedCallback = function(self, fn)
        self:AddUnitCallback(fn, "ProjectileDamaged")
    end,

    AddOnCapturedCallback = function(self, cbOldUnit, cbNewUnit)
        if not cbOldUnit and not cbNewUnit then
            error('*ERROR: Tried to add an OnCaptured callback without any functions', 2)
            return
        end
        if cbOldUnit then
            self:AddUnitCallback(cbOldUnit, 'OnCaptured')
        end
        if cbNewUnit then
            self:AddUnitCallback(cbNewUnit, 'OnCapturedNewUnit')
        end
    end,

    --- Add a callback to be invoked when this unit starts building another. The unit being built is
    -- passed as a parameter to the callback function.
    AddOnStartBuildCallback = function(self, fn)
        self:AddUnitCallback(fn, "OnStartBuild")
    end,

    DoOnStartBuildCallbacks = function(self, unit)
        self:DoUnitCallbacks("OnStartBuild", unit)
    end,

    DoOnFailedToBuildCallbacks = function(self)
        self:DoUnitCallbacks("OnFailedToBuild")
    end,

    AddOnUnitBuiltCallback = function(self, fn, category)
        table.insert(self.EventCallbacks['OnUnitBuilt'], {category=category, cb=fn})
    end,

    DoOnUnitBuiltCallbacks = function(self, unit)
        for _, v in self.EventCallbacks['OnUnitBuilt'] or {} do
            if unit and not unit.Dead and EntityCategoryContains(v.category, unit) then
                v.cb(self, unit)
            end
        end
    end,

    AddOnHorizontalStartMoveCallback = function(self, fn)
        self:AddUnitCallback(fn, "OnHorizontalStartMove")
    end,

    DoOnHorizontalStartMoveCallbacks = function(self)
        self:DoUnitCallbacks("OnHorizontalStartMove")
    end,

    RemoveCallback = function(self, fn)
        for k, v in self.EventCallbacks do
            if type(v) == "table" then
                for kcb, vcb in v do
                    if vcb == fn then
                        v[kcb] = nil
                    end
                end
            end
        end
    end,

    AddOnDamagedCallback = function(self, fn, amount, repeatNum)
        if not fn then
            error('*ERROR: Tried to add an OnDamaged callback with a nil function')
            return
        end
        local num = amount or -1
        repeatNum = repeatNum or 1
        table.insert(self.EventCallbacks.OnDamaged, {Func = fn, Amount=num, Called=0, Repeat = repeatNum})
    end,

    DoOnDamagedCallbacks = function(self, instigator)
        if self.EventCallbacks.OnDamaged then
            for num, callback in self.EventCallbacks.OnDamaged do
                if (callback.Called < callback.Repeat or callback.Repeat == -1) and (callback.Amount == -1 or (1 - self:GetHealthPercent() > callback.Amount)) then
                    callback.Called = callback.Called + 1
                    callback.Func(self, instigator)
                end
            end
        end
    end,

    -------------------------------------------------------------------------------------------
    -- STATES
    -------------------------------------------------------------------------------------------
    IdleState = State {
        Main = function(self)
        end,
    },

    DeadState = State {
        Main = function(self)
        end,
    },

    WorkingState = State {
        Main = function(self)
            while self.WorkProgress < 1 and not self.Dead do
                WaitSeconds(0.1)
            end
        end,

        OnWorkEnd = function(self, work)
            self:ClearWork()
            self:SetActiveConsumptionInactive()
            AddUnitEnhancement(self, work)
            self:CleanupEnhancementEffects(work)
            self:CreateEnhancement(work)
            self:PlayUnitSound('EnhanceEnd')
            self:StopUnitAmbientSound('EnhanceLoop')
            self:EnableDefaultToggleCaps()
            ChangeState(self, self.IdleState)
        end,
    },

    -------------------------------------------------------------------------------------------
    -- BUFFS
    -------------------------------------------------------------------------------------------
    AddBuff = function(self, buffTable, PosEntity)
        local bt = buffTable.BuffType
        if not bt then
            error('*ERROR: Tried to add a unit buff in unit.lua but got no buff table.  Wierd.', 1)
            return
        end

        -- When adding debuffs we have to make sure that we check for permissions
        local category = buffTable.TargetAllow and ParseEntityCategory(buffTable.TargetAllow) or categories.ALLUNITS
        if buffTable.TargetDisallow then
            category = category - ParseEntityCategory(buffTable.TargetDisallow)
        end

        if bt == 'STUN' then
            local targets
            if buffTable.Radius and buffTable.Radius > 0 then
                -- If the radius is bigger than 0 then we will use the unit as the center of the stun blast
                targets = utilities.GetTrueEnemyUnitsInSphere(self, PosEntity or self:GetPosition(), buffTable.Radius, category)
            else
                -- The buff will be applied to the unit only
                if EntityCategoryContains(category, self) then
                    targets = {self}
                end
            end

            -- Exclude things currently flying around
            for _, target in targets or {} do
                if target.Layer ~= 'Air' then
                    target:SetStunned(buffTable.Duration or 1)
                end
            end
        elseif bt == 'MAXHEALTH' then
            self:SetMaxHealth(self:GetMaxHealth() + (buffTable.Value or 0))
        elseif bt == 'HEALTH' then
            self:SetHealth(self, self:GetHealth() + (buffTable.Value or 0))
        elseif bt == 'SPEEDMULT' then
            self:SetSpeedMult(buffTable.Value or 0)
        elseif bt == 'MAXFUEL' then
            self:SetFuelUseTime(buffTable.Value or 0)
        elseif bt == 'FUELRATIO' then
            self:SetFuelRatio(buffTable.Value or 0)
        elseif bt == 'HEALTHREGENRATE' then
            self:SetRegenRate(buffTable.Value or 0)
        end
    end,

    AddWeaponBuff = function(self, buffTable, weapon)
        local bt = buffTable.BuffType
        if not bt then
            error('*ERROR: Tried to add a weapon buff in unit.lua but got no buff table.  Wierd.', 1)
            return
        end

        if bt == 'RATEOFFIRE' then
            weapon:ChangeRateOfFire(buffTable.Value or 1)
        elseif bt == 'TURRETYAWSPEED' then
            weapon:SetTurretYawSpeed(buffTable.Value or 0)
        elseif bt == 'TURRETPITCHSPEED' then
            weapon:SetTurretPitchSpeed(buffTable.Value or 0)
        elseif bt == 'DAMAGE' then
            weapon:AddDamageMod(buffTable.Value or 0)
        elseif bt == 'MAXRADIUS' then
            weapon:ChangeMaxRadius(buffTable.Value or weapon:GetBlueprint().MaxRadius)
        elseif bt == 'FIRINGRANDOMNESS' then
            weapon:SetFiringRandomness(buffTable.Value or 0)
        else
            self:AddBuff(buffTable)
        end
    end,

    SetRegen = function(self, value)
        self:SetRegenRate(value)
        self.Sync.regen = value
    end,

    -------------------------------------------------------------------------------------------
    -- SHIELDS
    -------------------------------------------------------------------------------------------
    CreateShield = function(self, bpShield)
        -- Copy the shield template so we don't alter the blueprint table.
        local bpShield = table.deepcopy(bpShield)
        self:DestroyShield()

        if bpShield.PersonalShield then
            self.MyShield = PersonalShield(bpShield, self)
        elseif bpShield.AntiArtilleryShield then
            self.MyShield = AntiArtilleryShield(bpShield, self)
        elseif bpShield.PersonalBubble then
            self.MyShield = PersonalBubble(bpShield, self)
        elseif bpShield.TransportShield then
            self.MyShield = TransportShield(bpShield, self)
        else
            self.MyShield = Shield(bpShield, self)
        end

        self:SetFocusEntity(self.MyShield)
        self:EnableShield()
        self.Trash:Add(self.MyShield)
    end,

    EnableShield = function(self)
        self:SetScriptBit('RULEUTC_ShieldToggle', true)
        if self.MyShield then
            self.MyShield:TurnOn()
        end
    end,

    DisableShield = function(self)
        self:SetScriptBit('RULEUTC_ShieldToggle', false)
        if self.MyShield then
            self.MyShield:TurnOff()
        end
    end,

    DestroyShield = function(self)
        if self.MyShield then
            self:ClearFocusEntity()
            self.MyShield:Destroy()
            self.MyShield = nil
        end
    end,

    ShieldIsOn = function(self)
        if self.MyShield then
            return self.MyShield:IsOn()
        end
    end,

    GetShieldType = function(self)
        if self.MyShield then
            return self.MyShield.ShieldType or 'Unknown'
        end
        return 'None'
    end,

    OnAdjacentBubbleShieldDamageSpillOver = function(self, instigator, spillingUnit, damage, type)
        if self.MyShield then
            self.MyShield:OnAdjacentBubbleShieldDamageSpillOver(instigator, spillingUnit, damage, type)
        end
    end,

    -------------------------------------------------------------------------------------------
    -- TRANSPORTING
    -------------------------------------------------------------------------------------------

    GetTransportClass = function(self)
        return self:GetBlueprint().Transport.TransportClass or 1
    end,

    OnStartTransportBeamUp = function(self, transport, bone)
        local slot = transport.slots[bone]
        if slot then
            self:GetAIBrain():OnTransportFull()
            IssueClearCommands({self})
            return
        end

        self:DestroyIdleEffects()
        self:DestroyMovementEffects()

        table.insert(self.TransportBeamEffectsBag, AttachBeamEntityToEntity(self, -1, transport, bone, self.Army, EffectTemplate.TTransportBeam01))
        table.insert(self.TransportBeamEffectsBag, AttachBeamEntityToEntity(transport, bone, self, -1, self.Army, EffectTemplate.TTransportBeam02))
        table.insert(self.TransportBeamEffectsBag, CreateEmitterAtBone(transport, bone, self.Army, EffectTemplate.TTransportGlow01))
        self:TransportAnimation()
    end,

    OnStopTransportBeamUp = function(self)
        self:DestroyIdleEffects()
        self:DestroyMovementEffects()
        for k, v in self.TransportBeamEffectsBag do
            v:Destroy()
        end

        -- Reset weapons to ensure torso centres and unit survives drop
        for i = 1, self.WeaponCount do
            self.WeaponInstances[i]:ResetTarget()
        end
    end,

    MarkWeaponsOnTransport = function(self, bool)
        for i = 1, self.WeaponCount do
            self.WeaponInstances[i]:SetOnTransport(bool)
        end
    end,

    OnStorageChange = function(self, loading)
        self:MarkWeaponsOnTransport(loading)

        if loading then
            self:HideBone(0, true)
        else
            self:ShowBone(0, true)
        end

        self:SetCanTakeDamage(not loading)
        self:SetDoNotTarget(loading)
        self:SetReclaimable(not loading)
        self:SetCapturable(not loading)
    end,

    OnAddToStorage = function(self, unit)
        self:OnStorageChange(true)
    end,

    OnRemoveFromStorage = function(self, unit)
        self:OnStorageChange(false)
    end,

    -- Animation when being dropped from a transport.
    TransportAnimation = function(self, rate)
        self:ForkThread(self.TransportAnimationThread, rate)
    end,

    TransportAnimationThread = function(self, rate)
        local bp = self:GetBlueprint().Display
        local animbp
        rate = rate or 1

        if rate < 0 and bp.TransportDropAnimation then
            animbp = bp.TransportDropAnimation
            rate = bp.TransportDropAnimationSpeed or -rate
        else
            animbp = bp.TransportAnimation
            rate = bp.TransportAnimationSpeed or rate
        end

        WaitSeconds(.5)
        if animbp then
            local animBlock = self:ChooseAnimBlock(animbp)
            if animBlock.Animation then
                if not self.TransAnimation then
                    self.TransAnimation = CreateAnimator(self)
                    self.Trash:Add(self.TransAnimation)
                end
                self.TransAnimation:PlayAnim(animBlock.Animation)
                self.TransAnimation:SetRate(rate)
                WaitFor(self.TransAnimation)
            end
        end
    end,

    -------------------------------------------------------------------------------------------
    -- TELEPORTING
    -------------------------------------------------------------------------------------------
    OnTeleportUnit = function(self, teleporter, location, orientation)
        if self.TeleportDrain then
            RemoveEconomyEvent(self, self.TeleportDrain)
            self.TeleportDrain = nil
        end

        if self.TeleportThread then
            KillThread(self.TeleportThread)
            self.TeleportThread = nil
        end

        self:CleanupTeleportChargeEffects()
        self.TeleportThread = self:ForkThread(self.InitiateTeleportThread, teleporter, location, orientation)
    end,

    OnFailedTeleport = function(self)
        if self.TeleportDrain then
            RemoveEconomyEvent(self, self.TeleportDrain)
            self.TeleportDrain = nil
        end

        if self.TeleportThread then
            KillThread(self.TeleportThread)
            self.TeleportThread = nil
        end

        self:StopUnitAmbientSound('TeleportLoop')
        self:CleanupTeleportChargeEffects()
        self:CleanupRemainingTeleportChargeEffects()
        self:SetWorkProgress(0.0)
        self:SetImmobile(false)
        self.UnitBeingTeleported = nil
    end,

    InitiateTeleportThread = function(self, teleporter, location, orientation)
        self.UnitBeingTeleported = self
        self:SetImmobile(true)
        self:PlayUnitSound('TeleportStart')
        self:PlayUnitAmbientSound('TeleportLoop')

        local bp = self:GetBlueprint().Economy
        local energyCost, time
        if bp then
            local mass = (bp.TeleportMassCost or bp.BuildCostMass or 1) * (bp.TeleportMassMod or 0.01)
            local energy = (bp.TeleportEnergyCost or bp.BuildCostEnergy or 1) * (bp.TeleportEnergyMod or 0.01)
            energyCost = mass + energy
            time = energyCost * (bp.TeleportTimeMod or 0.01)
        end

        self.TeleportDrain = CreateEconomyEvent(self, energyCost or 100, 0, time or 5, self.UpdateTeleportProgress)

        -- Create teleport charge effect
        self:PlayTeleportChargeEffects(location, orientation)
        WaitFor(self.TeleportDrain)

        if self.TeleportDrain then
            RemoveEconomyEvent(self, self.TeleportDrain)
            self.TeleportDrain = nil
        end

        self:PlayTeleportOutEffects()
        self:CleanupTeleportChargeEffects()
        WaitSeconds(0.1)
        self:SetWorkProgress(0.0)
        Warp(self, location, orientation)
        self:PlayTeleportInEffects()
        self:CleanupRemainingTeleportChargeEffects()

        WaitSeconds(0.1) -- Perform cooldown Teleportation FX here

        -- Landing Sound
        self:StopUnitAmbientSound('TeleportLoop')
        self:PlayUnitSound('TeleportEnd')
        self:SetImmobile(false)
        self.UnitBeingTeleported = nil
        self.TeleportThread = nil
    end,

    UpdateTeleportProgress = function(self, progress)
        self:SetWorkProgress(progress)
        EffectUtilities.TeleportChargingProgress(self, progress)
    end,

    PlayTeleportChargeEffects = function(self, location, orientation, teleDelay)
        EffectUtilities.PlayTeleportChargingEffects(self, location, self.TeleportFxBag, teleDelay)
    end,

    CleanupTeleportChargeEffects = function(self)
        EffectUtilities.DestroyTeleportChargingEffects(self, self.TeleportFxBag)
    end,

    CleanupRemainingTeleportChargeEffects = function(self)
        EffectUtilities.DestroyRemainingTeleportChargingEffects(self, self.TeleportFxBag)
    end,

    PlayTeleportOutEffects = function(self)
        EffectUtilities.PlayTeleportOutEffects(self, self.TeleportFxBag)
    end,

    PlayTeleportInEffects = function(self)
        EffectUtilities.PlayTeleportInEffects(self, self.TeleportFxBag)
    end,

    ------------------------------------------------------------------------------------------
    -- ROCKING
    -------------------------------------------------------------------------------------------
    -- Causes units to rock from side to side on water

    --- Allows the unit to rock from side to side. Useful when the unit is on water. Is not used
    -- in practice, nor by this repository or by any of the commonly played mod packs.
    StartRocking = function(self)
        local bp = self:GetBlueprint().Display
        local speed = bp.MaxRockSpeed
        if (not self.RockManip) and (not self.Dead) and speed and speed > 0 then 

            -- clear it so that GC can take it, if it exists
            if self.StopRockThread then 
                KillThread(self.StopRockThread)
                self.StopRockThread = nil 
            end

            self.StartRockThread = self:ForkThread(self.RockingThread, speed)
        end
    end,

    --- Stops the unit to rock from side to side. Useful when the unit is on water. Is not used
    -- in practice, nor by this repository or by any of the commonly played mod packs.
    StopRocking = function(self)
        if self.StartRockThread then
            -- clear it so that GC can take it
            KillThread(self.StartRockThread)
            self.StartRockThread = nil

            local bp = self:GetBlueprint().Display
            local speed = bp.MaxRockSpeed

            self.StopRockThread = self:ForkThread(self.EndRockingThread, speed)
        end
    end,

    --- Rocking thread to move a unit when it is on the water.
    RockingThread = function(self, speed)
        -- default value
        speed = speed or 1.5

        self.RockManip = CreateRotator(self, 0, 'z', nil, 0, speed * 0.2, speed * 0.6)
        self.Trash:Add(self.RockManip)
        self.RockManip:SetPrecedence(0)

        while true do
            WaitFor(self.RockManip)

            if self.Dead then break end -- Abort if the unit died

            self.RockManip:SetTargetSpeed(-speed) 
            WaitFor(self.RockManip)

            if self.Dead then break end -- Abort if the unit died

            self.RockManip:SetTargetSpeed(speed)
        end
    end,

    --- Stopping of the rocking thread, allowing it to gracefully end instead of suddenly
    -- warping to the original position.
    EndRockingThread = function(self, speed)
        if self.RockManip then

            -- default value
            speed = speed or 1.5

            self.RockManip:SetGoal(0)
            self.RockManip:SetSpeed(speed / 4)
            WaitFor(self.RockManip)

            if self.RockManip then
                self.RockManip:Destroy()
                self.RockManip = nil
            end
        end
    end,

    OnCreated = function(self) end,
    -- Buff Fields
    InitBuffFields = function(self)
        -- Creates all buff fields
        local bp = self:GetBlueprint()
        if self.BuffFields and bp.BuffFields then
            for scriptName, field in self.BuffFields do
                -- Getting buff field blueprint

                local BuffFieldBp = BuffFieldBlueprints[bp.BuffFields[scriptName]]
                if not BuffFieldBp or type(BuffFieldBp) ~= 'table' then
                    WARN('BuffField: no blueprint data for buff field '..repr(scriptName))
                else
                    -- We need a different buff field instance for each unit. This takes care of that.
                    if not self.MyBuffFields then
                        self.MyBuffFields = {}
                    end
                    self.MyBuffFields[scriptName] = self:CreateBuffField(scriptName, BuffFieldBp)
                end
            end
        end
    end,

    CreateBuffField = function(self, name, buffFieldBP) -- Buff field stuff
        local spec = {
            Name = buffFieldBP.Name,
            Owner = self,
        }
        return (self.BuffFields[name](spec))
    end,

    GetBuffFieldByName = function(self, name)
        if self.BuffFields and self.MyBuffFields then
            for k, field in self.MyBuffFields do
                local fieldBP = field:GetBlueprint()
                if fieldBP.Name == name then
                    return field
                end
            end
        end
    end,

    OnAttachedToTransport = function(self, transport, bone)
        self:MarkWeaponsOnTransport(true)
        if self:ShieldIsOn() or self.MyShield.Charging then
            self:DisableShield()
            self:DisableDefaultToggleCaps()
        end
        self:DoUnitCallbacks('OnAttachedToTransport', transport, bone)
    end,

    OnDetachedFromTransport = function(self, transport, bone)
        self:MarkWeaponsOnTransport(false)
        self:EnableShield()
        self:EnableDefaultToggleCaps()
        self:TransportAnimation(-1)
        self:DoUnitCallbacks('OnDetachedFromTransport', transport, bone)
    end,

    -- Utility Functions
    SendNotifyMessage = function(self, trigger, source)
        local focusArmy = GetFocusArmy()
        if focusArmy == -1 or focusArmy == self.Army then
            local id
            local unitType
            local category

            if not source then
                local bp = self:GetBlueprint()
                if bp.CategoriesHash.RESEARCH then
                    unitType = string.lower('research' .. self.layerCategory .. self.techCategory)
                    category = 'tech'
                elseif EntityCategoryContains(categories.NUKE * categories.STRUCTURE - categories.EXPERIMENTAL, self) then -- Ensure to exclude Yolona Oss, which gets its own message
                    unitType = 'nuke'
                    category = 'other'
                elseif EntityCategoryContains(categories.TECH3 * categories.STRUCTURE * categories.ARTILLERY, self) then
                    unitType = 'arty'
                    category = 'other'
                elseif self.techCategory == 'EXPERIMENTAL' then
                    unitType = bp.BlueprintId
                    category = 'experimentals'
                else
                    return
                end
            else -- We are being called from the Enhancements chain (ACUs)
                id = self.EntityId
                category = string.lower(self.factionCategory)
            end

            if trigger == 'transferred' then
                if not Sync.EnhanceMessage then return end
                for index, msg in Sync.EnhanceMessage do
                    if msg.source == (source or unitType) and msg.trigger == 'completed' and msg.category == category and msg.id == id then
                        table.remove(Sync.EnhanceMessage, index)
                        break
                    end
                end
            else
                if not Sync.EnhanceMessage then Sync.EnhanceMessage = {} end
                local message = {source = source or unitType, trigger = trigger, category = category, id = id, army = self.Army}
                table.insert(Sync.EnhanceMessage, message)
            end
        end
    end,

    --- Deprecated functionality
    GetUnitBeingBuilt = function(self)
        if not GetUnitBeingBuiltWarning then
            WARN("Deprecated function GetUnitBeingBuilt called at")
            WARN(debug.traceback())
            WARN("Further warnings of this will be suppressed")
            GetUnitBeingBuiltWarning = true
        end

        return self.UnitBeingBuilt
    end,

    OnShieldEnabled = function(self) end,
    OnShieldDisabled = function(self) end,

    --- Deprecated functionality

    OnCollisionCheckWeapon = function(self, firingWeapon)
        if self.DisallowCollisions then
            return false
        end

        -- Skip friendly collisions
        local weaponBP = firingWeapon:GetBlueprint()
        local collide = weaponBP.CollideFriendly
        if collide == false then
            if IsAlly(self.Army, firingWeapon.unit.Army) then
                return false
            end
        end

        -- Check for specific non-collisions
        if weaponBP.DoNotCollideList then
            for _, v in pairs(weaponBP.DoNotCollideList) do
                if EntityCategoryContains(ParseEntityCategory(v), self) then
                    return false
                end
            end
        end

        return true
    end,

}

-- upvalied math functions for performance
local MathMax = math.max

-- upvalued globals for performance
local EntityCategoryContains = EntityCategoryContains

-- upvalued moho functions for performance
local EntityGetArmy = _G.moho.entity_methods.GetArmy
local EntityGetBlueprint = _G.moho.entity_methods.GetBlueprint
local EntityGetEntityId = _G.moho.entity_methods.GetEntityId

local UnitGetCurrentLayer = _G.moho.unit_methods.GetCurrentLayer
local UnitGetUnitId = _G.moho.unit_methods.GetUnitId

-- upvalued categories for performance
local CategoriesDummyUnit = categories.DUMMYUNIT

DummyUnit = Class(moho.unit_methods) {
    -- the only things we need
    __init = function(self) end,
    __post_init = function(self) end,
    OnCreate = function(self) 

        local bp = self:GetBlueprint()

        -- populate blueprint cache if we haven't done that yet
        if not self.BlueprintCache then 
            PopulateBlueprintCache(self, bp)
        end

        -- copy reference from meta table to inner table
        self.BlueprintCache = self.BlueprintCache

        -- values that are expected on all units
        self.EntityId = EntityGetEntityId(self)
        self.UnitId = UnitGetUnitId(self)
        self.Army = EntityGetArmy(self)
        self.Layer = UnitGetCurrentLayer(self)
        self.Blueprint = bp
        self.Footprint = bp.Footprint

        -- basic check if this insignificant unit is truely insignificant
        if not EntityCategoryContains(CategoriesDummyUnit, self) then 
            WARN("Unit " .. tostring(self.UnitId) .. " is a dummy unit but doesn't have the right categories set!")

            -- todo: add more info for dev
        end
    
    end,

    --- Used in the formation script
    GetFootPrintSize = function(self)
        local fp = self.Footprint
        return MathMax(fp.SizeX, fp.SizeZ)
    end,

    --- Typically called by functions
    CheckAssistFocus = function(self) end,
    UpdateAssistersConsumption = function (self) end,
}