--[[
    whip_fuel — A PUMP, AS BOTH SIDES NAME IT

    EVERY SIDE OF EVERY PUMP HAS ITS OWN NOZZLE, named by its key: 'pump_<x>_<y>_<z>_A' — where the pump stands, in
    tenths of a metre (every game finds the same map prop at the same place), and its side: 'A' on the pump's -y, 'B'
    on its +y. The server keeps a nozzle by it; every game draws that side's circle, holster and screen by it.
]]

Pumps = {}

--- A side's key: the pump standing at `at` (its own position), side 'A' or 'B'.
function Pumps.keyOf(at, side)
    return ('pump_%d_%d_%d_%s'):format(math.floor(at.x * 10 + 0.5), math.floor(at.y * 10 + 0.5),
        math.floor(at.z * 10 + 0.5), side)
end

--- What a real key looks like.
Pumps.KEY_PATTERN = '^pump_%-?%d+_%-?%d+_%-?%d+_[AB]$'

--- The pump a key belongs to ('pump_<x>_<y>_<z>'): both its sides share it.
function Pumps.prefixOf(key) return key:sub(1, -3) end

--- The key of the same pump's other side.
function Pumps.otherSide(key) return Pumps.prefixOf(key) .. (key:sub(-1) == 'A' and '_B' or '_A') end

--- Where a circle sits on a pump of this model (its name): { offset, heading }. The pump's own circle, or with
--- `nozzle` the nozzle's (Config.NozzleCircle).
---@param model string
---@param nozzle boolean|nil
function Pumps.placingOf(model, nozzle)
    local c = nozzle and Config.NozzleCircle or Config.PumpCircle
    return (c and c.PlacingByModel and c.PlacingByModel[model]) or (c and c.Placing)
        or { offset = vector3(0.0, 0.4, 1.0), heading = 0.0 }
end

--- Which side of its pump a circle is, by its face (1, or 2: the first turned half round): from where the circle
--- sits, out from the pump's -y or its +y. `nozzle`: the nozzle's circle (placed apart from the pump's).
---@param model string  the pump's model name
---@param face number
---@param nozzle boolean|nil
---@return string 'A' | 'B'
function Pumps.sideOfFace(model, face, nozzle)
    local o = Pumps.placingOf(model, nozzle).offset
    local out = o and (o.y or o[2]) or 0.0
    local y = (face == 2) and -out or out
    if y == 0 then return face == 2 and 'B' or 'A' end
    return y < 0 and 'A' or 'B'
end
