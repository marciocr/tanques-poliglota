-- Driver de teste (Lua): aplica um roteiro à lógica do jogo, sem janela.
package.path = arg[1] .. "/?.lua;" .. package.path
local ffi = require("ffi")
local game = require(os.getenv("GAME"))

local g = game.Game.new(0)
g.play = function() end
for line in io.lines(arg[2]) do
    local steps, ks = line:match("^(%S+)%s+(%S+)")
    local keys = ffi.new("uint8_t[512]")
    if ks ~= "-" then for k in ks:gmatch("%d+") do keys[tonumber(k)] = 1 end end
    for _ = 1, tonumber(steps) do g:update(keys, game.STEP) end
end
for i = 0, 1 do
    local t = g.tanks[i]
    print(string.format("x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d", t.x, t.y, t.dir, t.score, t.spin, t.bullet.active and 1 or 0))
end
print(string.format("mode=%d time=%.4f", g.mode, g.time_left))
