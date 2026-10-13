--[[
    The 3D engine lives in tr_core, shared with every TR resource: TR.math (rotations), TR.scene
    (props, camera, picking), TR.rope (hoses) and TR.mirror (players nearby see the game). The
    minigames use it under these names.
]]

local math3d = TR.math
Mat, Vec = math3d.Mat, math3d.Vec
Lerp, Clamp, AngleDelta = math3d.lerp, math3d.clamp, math3d.angleDelta
Rope = TR.rope

-- Loaded now, not on first use, so its events are there before anyone plays.
Mirror = TR.mirror
Mirror.configure({
    range = Config.mirror.range,
    soundRange = Config.mirror.soundRange,
    rate = Config.mirror.rate,
    volume = Config.volume,
})

if not IsDuplicityVersion() then Scene = TR.scene end
