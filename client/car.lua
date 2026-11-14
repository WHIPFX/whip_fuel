--[[
    whip_fuel — THE CAR: THE NOZZLE AT ITS FILLER, THE JERRY CAN AT ITS DOORS

    The pump's nozzle goes in at the filler (whip_core's car part 'fuel': its petrol cap, which shows only while
    something is on offer there; a motorbike's and a boat's one prompt): "Insert Nozzle" puts it there, where the
    prompt is, and its pump then offers how much. "Remove Nozzle" puts it back in the hand (a torn-off pump's: on the
    ground, for good).

    The jerry can pours from the doors: with the can in hand (whip_gunny equips it as GTA's petrol can) and fuel in
    it, they offer "Refuel (jerry can)". On all four doors: nobody knows which side a model's filler is on. And on a
    motorbike's and a boat's one prompt. Not a bicycle's: there is no tank.

    Both go FIRST in the stack (AddAction's `first`) while they are on offer: it is what the player walked to the car
    to do, so E does it. Neither on an electric car: it has no fuel.
]]

--- How the nozzle sits in a filler, from the prompt's spot (on the car's skin, facing out of its side): its spout's
--- tip this far in past the skin, pointing in and this far down, the handle hanging out from the car. Nudge these if
--- it sits wrong.
local NOZZLE_IN_DEPTH = 0.04
local NOZZLE_IN_PITCH = -25.0

local function core() return exports.whip_core end

--- Is this car's tank full? Off its replicated fuel stat; unknown is not full (the server decides).
local function tankFull(veh)
    local fuel = core():GetVehicleStat({ entity = veh }, 'fuel')
    return fuel ~= nil and fuel >= 100
end

--- A refusal said on the circle the player used.
local function refuse(ctx, text)
    ctx.flash(230, 70, 70)
    ctx.status(text, 2500)
end

-- ============================================
-- The nozzle
-- ============================================

--- A nozzle in the hand (not spraying: the pump must be stopped first), and this car's filler free for it? Not an
--- electric car: it has no fuel. Not a torn pump's or an out-of-order side's: those only go back (the server says
--- the same).
local function canInsert(veh)
    local mine = Nozzle.myKey and Nozzle.faces[Nozzle.myKey]
    return Nozzle.myKey ~= nil and not Nozzle.busy and not (mine and (mine.p or mine.gone or mine.err))
        and not tankFull(veh) and Nozzle.inCar(veh) == nil and not Tank.isElectric(veh)
end

--- A point `e` of the nozzle (its own space), as an offset in the car's space, on a nozzle pitched `pitch` and turned
--- `yaw` on the car (heading, then pitch). Close enough to aim the spout at the filler; not to end the hose on (below).
local function turned(e, pitch, yaw)
    local p, a = math.rad(pitch), math.rad(yaw)
    local y1, z1 = e.y * math.cos(p) - e.z * math.sin(p), e.y * math.sin(p) + e.z * math.cos(p)
    return vector3(e.x * math.cos(a) - y1 * math.sin(a), e.x * math.sin(a) + y1 * math.cos(a), z1)
end

--- Where the hose goes into the nozzle as it really sits on the car, in the car's space: read off the tied nozzle once
--- the game has put it there, as whip_rope reads the nozzle in a hand (which always lines up). Worked out from the
--- tie's numbers instead (turned), the hose ended beside the handle, a little or a lot (Josh, 7 Nov). Waits a few
--- frames: from a thread. Nil when the nozzle never shows tied.
local function hoseEndOnCar(veh, obj)
    local e = Nozzle.HOSE_END
    for _ = 1, 10 do
        Wait(0)
        if not DoesEntityExist(obj) or not DoesEntityExist(veh) then return nil end
        if IsEntityAttachedToEntity(obj, veh) then
            Wait(0)   -- one more frame: the tie places it on the frame after it is made
            if not DoesEntityExist(obj) or not DoesEntityExist(veh) then return nil end
            local w = GetOffsetFromEntityInWorldCoords(obj, e.x, e.y, e.z)
            return GetOffsetFromEntityGivenWorldCoords(veh, w.x, w.y, w.z)
        end
    end
    return nil
end

--- A nozzle in this car's filler, and a hand free to take it?
local function canRemove(veh)
    return Nozzle.myKey == nil and not Nozzle.busy and Nozzle.inCar(veh) ~= nil
end

--- Put the nozzle in this car, where its fuel prompt is: made here (networked, so everyone sees it) and tied to the
--- car, then the server is told and takes it out of the hand. Refused: it is deleted again.
local function insert(ctx)
    local veh = ctx.entity
    if not veh or not DoesEntityExist(veh) or not canInsert(veh) then return end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local point = core():GetVehiclePoint({ entity = veh }, 'fuel')
    if not netId or netId <= 0 or type(point) ~= 'table' then return refuse(ctx, 'That vehicle cannot be refuelled') end

    Nozzle.busy = true
    TaskTurnPedToFaceEntity(PlayerPedId(), veh, 400)
    local hash = core():LoadModel(Nozzle.HASH, 2000)
    if not hash then
        Nozzle.busy = false
        return refuse(ctx, 'The nozzle did not go in')
    end
    -- The spout's tip a little in past the skin, against the way the prompt faces (out of the side), pointing in and
    -- down: the nozzle's middle is where that leaves it, out from the car.
    local h = point.heading or 0.0
    local r = math.rad(h)
    local tx, ty = point.x + math.sin(r) * NOZZLE_IN_DEPTH, point.y - math.cos(r) * NOZZLE_IN_DEPTH
    local tip = GetOffsetFromEntityGivenWorldCoords(veh, tx, ty, point.z)
    local yaw = (h + 180.0 - GetEntityHeading(veh)) % 360.0
    local off = tip - turned(Nozzle.SPOUT, NOZZLE_IN_PITCH, yaw)
    local at = GetOffsetFromEntityInWorldCoords(veh, off.x, off.y, off.z)
    local obj = CreateObject(hash, at.x, at.y, at.z, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    AttachEntityToEntity(obj, veh, 0, off.x, off.y, off.z, NOZZLE_IN_PITCH, 0.0, yaw, false, false, false, false, 2, true)
    -- The back of it, where the hose goes in, in the car's space (sent so: the server's copy of the car has no tilt)
    local back = hoseEndOnCar(veh, obj) or (off + turned(Nozzle.HOSE_END, NOZZLE_IN_PITCH, yaw))

    local ok, why = core():Callback('whip_fuel:insert', netId, NetworkGetNetworkIdFromEntity(obj), back.x, back.y, back.z)
    Nozzle.busy = false
    if ok ~= true then
        DeleteObject(obj)
        return refuse(ctx, why or 'The nozzle did not go in')
    end
    Nozzle.detach()          -- out of the hand here at once; the server's drop follows
    Nozzle.quotes[veh] = nil -- priced fresh for the pump's amounts
end

--- Take the nozzle out of this car: into the hand (the server deletes the one in the car, and stops a pour that is
--- running), or a torn-off pump's onto the ground.
local function remove(ctx)
    local veh = ctx.entity
    if not veh or not DoesEntityExist(veh) or not canRemove(veh) then return end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local key = Nozzle.inCar(veh)
    local torn = key and Nozzle.faces[key] and Nozzle.faces[key].n == 'torn'
    Nozzle.busy = true
    -- A torn pump's goes on the ground: made here at the filler, so it falls at once
    local made, obj = 0, nil
    if torn then
        local point = core():GetVehiclePoint({ entity = veh }, 'fuel')
        if type(point) == 'table' then made, obj = Nozzle.makeLoose(vector3(point.x, point.y, point.z), nil) end
    end
    local ok, why = core():Callback('whip_fuel:remove', netId, made)
    Nozzle.busy = false
    if ok ~= true then
        if obj and DoesEntityExist(obj) then DeleteObject(obj) end
        return refuse(ctx, why or 'The nozzle would not come out')
    end
    Nozzle.quotes[veh] = nil
end

-- ============================================
-- The jerry can
-- ============================================

--- Pour the jerry can into this car. The server checks the can, the car and the distance, runs the bar and pours; a
--- refusal comes back as a notification.
local function pour(ctx)
    local veh = ctx.entity
    if not veh or not DoesEntityExist(veh) or not Nozzle.jerryCanInHand(true) then return end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    if not netId or netId <= 0 then return refuse(ctx, 'That vehicle cannot be refuelled') end
    TaskTurnPedToFaceEntity(PlayerPedId(), veh, 500)
    Wait(500)
    TriggerServerEvent('whip_fuel:pourCan', netId)
end

-- ============================================
-- On the car's parts: only while there is something to offer
-- ============================================
-- whip_core asks an action's canInteract on every prompt pass, at each part of every car in reach (about 95 times a
-- second), and every ask crosses into this resource: its ctx packed in whip_core and unpacked here as a new table, memory
-- made each time even when the answer is no. So nothing is asked while there is nothing to offer:
--   the jerry can's   require = { held = 'jerry_can' }: whip_core checks the hand itself, and asks only while the can
--                     is in it (whip_gunny draws it and says so: SetHeldItem)
--   the nozzle's      a state only this resource knows, so each is ADDED only while it can apply and taken away after,
--                     as whip_rope's tie prompt is: Insert while a nozzle is in the hand, Remove while one sits in a car
-- Their canInteract still decides the rest (this car, a full tank, an electric one).

local FILLERS = { 'fuel', 'bike', 'boat' }
local DOORS = { 'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r', 'bike', 'boat' }

--- A nozzle in any car's filler (this game has heard of): Remove Nozzle has a car to be on.
local function nozzleInACar()
    for _, i in pairs(Nozzle.faces) do
        if i.car and (i.n == 'car' or i.n == 'torn') then return true end
    end
    return false
end

--- Each nozzle offer: when it is wanted, the parts it goes on, and its action at one part.
local OFFERS = {
    insert = {
        wanted = function() return Nozzle.myKey ~= nil end,
        parts = FILLERS,
        action = function(part)
            return { id = 'nozzle_in:' .. part, at = { vehiclePart = part }, icon = 'nozzle', first = true,
                     label = 'Insert Nozzle', canInteract = function(ctx) return canInsert(ctx.entity) end, onSelect = insert }
        end,
    },
    remove = {
        wanted = nozzleInACar,
        parts = FILLERS,
        action = function(part)
            return { id = 'nozzle_out:' .. part, at = { vehiclePart = part }, icon = 'nozzle', first = true,
                     label = 'Remove Nozzle', canInteract = function(ctx) return canRemove(ctx.entity) end, onSelect = remove }
        end,
    },
}

local up = {}   -- [offer] = true while its actions are added

--- Puts each offer up or takes it down to match what is wanted now. Cheap when nothing changed: natives and a look at
--- the sides. Our own code (events, the pump's word), so whip_core goes through Whip.core.
local function refreshOffers()
    if not Whip.isReady() then return end
    for name, offer in pairs(OFFERS) do
        local want = offer.wanted() == true
        if want ~= (up[name] == true) then
            up[name] = want or nil
            for _, part in ipairs(offer.parts) do
                local def = offer.action(part)
                if want then
                    local ok, why = Whip.core:AddAction(def)
                    if not ok then print(('[whip_fuel] no %s at %s: %s'):format(name, part, tostring(why))) end
                else
                    Whip.core:RemoveAction(def.id)
                end
            end
        end
    end
end

-- The nozzle in the hand or a side's word changed (client/pumps.lua).
Nozzle.changed = refreshOffers

-- whip_core ready: the jerry can's, up for good (whip_core asks it only while the can is held), and the nozzle's as wanted.
Whip.register(function()
    for _, door in ipairs(DOORS) do
        local ok, why = exports.whip_core:AddAction({
            id = 'jerrycan:' .. door, at = { vehiclePart = door }, icon = 'fuel', first = true,
            label = 'Refuel (jerry can)',
            require = { held = Nozzle.JERRY_CAN_ITEM },
            canInteract = function(ctx)
                return not Nozzle.myKey and not Nozzle.busy and not Nozzle.filling and Nozzle.jerryCanInHand(true)
                    and not tankFull(ctx.entity) and not Tank.isElectric(ctx.entity)
            end,
            onSelect = pour,
        })
        if not ok then print(('[whip_fuel] no jerry can at %s: %s'):format(door, tostring(why))) end
    end
    up = {}
    refreshOffers()
end)
