#!/usr/bin/env luajit
-- Tanques em Lua (LuaJIT) com SDL2, chamando a libSDL2 diretamente via FFI.
-- Inspirado no Combat (Atari 2600, 1977).
local ffi = require("ffi")

ffi.cdef [[
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct { int x, y, w, h; } SDL_Rect;
typedef struct {
    int freq; uint16_t format; uint8_t channels; uint8_t silence;
    uint16_t samples; uint16_t padding; uint32_t size;
    void *callback; void *userdata;
} SDL_AudioSpec;
typedef union { uint32_t type; uint8_t padding[56]; } SDL_Event;

int SDL_Init(uint32_t flags);
void SDL_Quit(void);
const char *SDL_GetError(void);
SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);
void SDL_DestroyWindow(SDL_Window *window);
SDL_Renderer *SDL_CreateRenderer(SDL_Window *window, int index, uint32_t flags);
void SDL_DestroyRenderer(SDL_Renderer *renderer);
int SDL_SetRenderDrawColor(SDL_Renderer *renderer, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
int SDL_RenderClear(SDL_Renderer *renderer);
int SDL_RenderFillRect(SDL_Renderer *renderer, const SDL_Rect *rect);
void SDL_RenderPresent(SDL_Renderer *renderer);
int SDL_PollEvent(SDL_Event *event);
const uint8_t *SDL_GetKeyboardState(int *numkeys);
uint64_t SDL_GetPerformanceCounter(void);
uint64_t SDL_GetPerformanceFrequency(void);
uint32_t SDL_OpenAudioDevice(const char *device, int iscapture, const SDL_AudioSpec *desired,
                             SDL_AudioSpec *obtained, int allowed_changes);
void SDL_PauseAudioDevice(uint32_t dev, int pause_on);
int SDL_QueueAudio(uint32_t dev, const void *data, uint32_t len);
void SDL_ClearQueuedAudio(uint32_t dev);
void SDL_CloseAudioDevice(uint32_t dev);
]]

-- "SDL2" precisa do symlink libSDL2.so (pacote -devel); sem ele, usa o soname.
local ok, sdl = pcall(ffi.load, "SDL2")
if not ok then sdl = ffi.load("libSDL2-2.0.so.0") end

local W, H = 640, 480
local TANK_GRID, TANK_CELL = 22, 2  -- tanque desenhado em 22x22 blocos de 2px
local TANK_HALF = 12                -- hitbox 24x24
local TANK_SPEED = 90.0             -- px/s
local ROT_TIME = 0.09               -- s por passo de giro (16 direções)
local BULLET_SPEED = 320.0
local BULLET_SIZE = 4
local BULLET_LIFE = 1.6
local SPIN_TIME, SPIN_STEP, PUSH_SPEED = 1.0, 0.04, 110.0
local MATCH_TIME = 136.0  -- 2:16, como no Combat
local STEP = 1.0 / 120.0
local RATE = 44100

-- Constantes dos headers da SDL2.
local SDL_INIT_AUDIO, SDL_INIT_VIDEO = 0x10, 0x20
local SDL_WINDOWPOS_CENTERED = 0x2FFF0000
local SDL_WINDOW_SHOWN = 0x04
local SDL_RENDERER_ACCELERATED, SDL_RENDERER_PRESENTVSYNC = 0x02, 0x04
local SDL_QUIT = 0x100
local SC_A, SC_D, SC_W, SC_1, SC_2 = 4, 7, 26, 30, 31
local SC_RETURN, SC_ESCAPE, SC_SPACE = 40, 41, 44
local SC_RIGHT, SC_LEFT, SC_UP = 79, 80, 82
local AUDIO_S16LSB = 0x8010

-- Bordas da arena e obstáculos {x, y, w, h}, simétricos nos dois eixos.
local WALLS = {
    { 0, 48, 640, 8 }, { 0, 472, 640, 8 }, { 0, 48, 8, 432 }, { 632, 48, 8, 432 },
    { 120, 120, 16, 80 }, { 504, 120, 16, 80 }, { 120, 328, 16, 80 }, { 504, 328, 16, 80 },
    { 256, 136, 128, 16 }, { 256, 376, 128, 16 }, { 312, 232, 16, 64 },
}

-- Forma do tanque em px {x0, y0, x1, y1}, centrada na origem e apontando
-- para +x: duas esteiras, corpo e canhão.
local TANK_SHAPE = { { -14, -14, 12, -7 }, { -14, 7, 12, 14 }, { -10, -7, 7, 7 }, { 0, -2, 20, 2 } }

-- Fonte 3x5 para os dígitos do placar.
local DIGITS = {
    [0] = "111101101101111", "001001001001001", "111001111100111", "111001111001111",
    "101101111001001", "111100111001111", "111100111101111", "111001001001001",
    "111101111101111", "111101111001111",
}

local BG, WALL_COLOR, HUD_COLOR = { 0, 0, 0 }, { 180, 140, 60 }, { 230, 230, 230 }
local TANK_COLORS = { [0] = { 90, 200, 90 }, { 110, 150, 255 } }

-- Controles de cada jogador.
local CONTROLS = {
    [0] = { fwd = SC_W, left = SC_A, right = SC_D, fire = SC_SPACE },
    { fwd = SC_UP, left = SC_LEFT, right = SC_RIGHT, fire = SC_RETURN },
}

local function sound(samples)
    local n = #samples
    local buf = ffi.new("int16_t[?]", n)
    for i = 1, n do buf[i - 1] = samples[i] end
    return { data = buf, bytes = n * 2 }
end

-- Onda quadrada mono S16.
local function square_wave(freq, ms)
    local out = {}
    for i = 0, math.floor(RATE * ms / 1000) - 1 do
        out[#out + 1] = math.floor(i * 2 * freq / RATE) % 2 == 1 and 4000 or -4000
    end
    return sound(out)
end

-- Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
-- decaindo até zero; hold = amostras por bit (maior = mais grave).
local function noise(ms, hold)
    local n = math.floor(RATE * ms / 1000)
    local lfsr, b = 0xACE1, 0
    local out = {}
    for i = 0, n - 1 do
        if i % hold == 0 then
            b = bit.band(lfsr, 1)
            lfsr = bit.rshift(lfsr, 1)
            if b == 1 then lfsr = bit.bxor(lfsr, 0xB400) end
        end
        local amp = math.floor(4000 * (n - i) / n)
        out[#out + 1] = b == 1 and amp or -amp
    end
    return sound(out)
end

local function overlaps(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

local function hits_wall(x, y, w, h)
    for _, r in ipairs(WALLS) do
        if overlaps(x, y, w, h, r[1], r[2], r[3], r[4]) then return true end
    end
    return false
end

local function dir_angle(dir) return dir * 2 * math.pi / 16 end

local function new_tank(x, y, dir)
    return {
        x = x, y = y, dir = dir, rot_timer = 0, fire_prev = false,
        spin = 0, spin_step = 0, push_x = 0, push_y = 0, score = 0,
        bullet = { active = false, x = 0, y = 0, vx = 0, vy = 0, life = 0 },
    }
end

local Game = {}
Game.__index = Game

function Game.new(audio)
    local g = setmetatable({}, Game)
    g.audio = audio
    g.snd_shot = noise(90, 3)
    g.snd_hit = noise(500, 20)
    g.snd_ricochet = square_wave(1200, 25)
    g.snd_end = square_wave(220, 700)
    g.blink = 0
    g:new_match(1)
    return g
end

function Game:play(s)
    if self.audio == 0 then return end
    sdl.SDL_ClearQueuedAudio(self.audio)
    sdl.SDL_QueueAudio(self.audio, s.data, s.bytes)
end

function Game:new_match(mode)
    self.mode = mode  -- 1 = normal, 2 = ricochete
    self.time_left = MATCH_TIME
    self.game_over = false
    self.tanks = { [0] = new_tank(60, 264, 0), new_tank(580, 264, 8) }
end

local function blocked(other, x, y)
    local s = 2 * TANK_HALF
    return hits_wall(x - TANK_HALF, y - TANK_HALF, s, s)
        or overlaps(x - TANK_HALF, y - TANK_HALF, s, s, other.x - TANK_HALF, other.y - TANK_HALF, s, s)
end

-- Move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
local function try_move(t, other, dx, dy)
    if not blocked(other, t.x + dx, t.y) then t.x = t.x + dx end
    if not blocked(other, t.x, t.y + dy) then t.y = t.y + dy end
end

function Game:update_tank(i, keys, dt)
    local t, other = self.tanks[i], self.tanks[1 - i]
    local c = CONTROLS[i]
    local fire = keys[c.fire] ~= 0

    if t.spin > 0 then
        -- Atingido: gira sozinho e é empurrado para trás.
        t.spin = t.spin - dt
        t.spin_step = t.spin_step - dt
        if t.spin_step <= 0 then
            t.dir = (t.dir + 1) % 16
            t.spin_step = t.spin_step + SPIN_STEP
        end
        try_move(t, other, t.push_x * dt, t.push_y * dt)
    else
        local turn = (keys[c.right] ~= 0 and 1 or 0) - (keys[c.left] ~= 0 and 1 or 0)
        if turn ~= 0 then
            t.rot_timer = t.rot_timer - dt
            if t.rot_timer <= 0 then
                t.dir = (t.dir + turn) % 16
                t.rot_timer = t.rot_timer + ROT_TIME
            end
        else
            t.rot_timer = 0
        end
        local a = dir_angle(t.dir)
        if keys[c.fwd] ~= 0 then
            try_move(t, other, math.cos(a) * TANK_SPEED * dt, math.sin(a) * TANK_SPEED * dt)
        end
        if fire and not t.fire_prev and not t.bullet.active then
            local bx = t.x + math.cos(a) * 20 - BULLET_SIZE / 2
            local by = t.y + math.sin(a) * 20 - BULLET_SIZE / 2
            -- Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
            if not hits_wall(bx, by, BULLET_SIZE, BULLET_SIZE) then
                t.bullet = {
                    active = true, x = bx, y = by,
                    vx = math.cos(a) * BULLET_SPEED, vy = math.sin(a) * BULLET_SPEED,
                    life = BULLET_LIFE,
                }
                self:play(self.snd_shot)
            end
        end
    end
    t.fire_prev = fire

    local b = t.bullet
    if not b.active then return end
    b.life = b.life - dt
    if b.life <= 0 then
        b.active = false
        return
    end
    -- Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
    b.x = b.x + b.vx * dt
    if hits_wall(b.x, b.y, BULLET_SIZE, BULLET_SIZE) then
        if self.mode ~= 2 then
            b.active = false
            return
        end
        b.x = b.x - b.vx * dt
        b.vx = -b.vx
        self:play(self.snd_ricochet)
    end
    b.y = b.y + b.vy * dt
    if hits_wall(b.x, b.y, BULLET_SIZE, BULLET_SIZE) then
        if self.mode ~= 2 then
            b.active = false
            return
        end
        b.y = b.y - b.vy * dt
        b.vy = -b.vy
        self:play(self.snd_ricochet)
    end
    if other.spin <= 0 and overlaps(b.x, b.y, BULLET_SIZE, BULLET_SIZE,
            other.x - TANK_HALF, other.y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF) then
        t.score = t.score + 1
        local len = math.sqrt(b.vx * b.vx + b.vy * b.vy)
        other.spin = SPIN_TIME
        other.spin_step = 0
        other.push_x = b.vx / len * PUSH_SPEED
        other.push_y = b.vy / len * PUSH_SPEED
        b.active = false
        self:play(self.snd_hit)
    end
end

function Game:update(keys, dt)
    if keys[SC_1] ~= 0 then self:new_match(1) end
    if keys[SC_2] ~= 0 then self:new_match(2) end
    self.blink = self.blink + dt
    if self.game_over then return end
    self.time_left = self.time_left - dt
    if self.time_left <= 0 then
        self.time_left = 0
        self.game_over = true
        self:play(self.snd_end)
        return
    end
    self:update_tank(0, keys, dt)
    self:update_tank(1, keys, dt)
end

local rect = ffi.new("SDL_Rect")

local function set_color(r, c) sdl.SDL_SetRenderDrawColor(r, c[1], c[2], c[3], 255) end

local function fill(r, x, y, w, h)
    rect.x, rect.y, rect.w, rect.h = math.floor(x), math.floor(y), w, h
    sdl.SDL_RenderFillRect(r, rect)
end

-- Desenha um número com blocos de tamanho s; align_right=true faz o número terminar em x.
local function draw_number(r, n, x, y, s, align_right)
    local text = tostring(n)
    if align_right then x = x - (#text * 3 * s + (#text - 1) * s) end
    for c in text:gmatch("%d") do
        local g = DIGITS[tonumber(c)]
        for i = 0, 14 do
            if g:sub(i + 1, i + 1) == "1" then
                fill(r, x + (i % 3) * s, y + math.floor(i / 3) * s, s, s)
            end
        end
        x = x + 4 * s
    end
end

-- Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
-- rotacionado de volta para o referencial do tanque, cai dentro da forma.
-- Dá o visual blocado do 2600 em qualquer uma das 16 direções.
local function draw_tank(r, t)
    local a = dir_angle(t.dir)
    local c, s = math.cos(a), math.sin(a)
    local x0 = math.floor(t.x) - TANK_GRID * TANK_CELL / 2
    local y0 = math.floor(t.y) - TANK_GRID * TANK_CELL / 2
    local half = (TANK_GRID - 1) / 2
    for i = 0, TANK_GRID - 1 do
        local py = (i - half) * TANK_CELL
        for j = 0, TANK_GRID - 1 do
            local px = (j - half) * TANK_CELL
            local u, v = px * c + py * s, -px * s + py * c
            for _, b in ipairs(TANK_SHAPE) do
                if u >= b[1] and u < b[3] and v >= b[2] and v < b[4] then
                    fill(r, x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL)
                    break
                end
            end
        end
    end
end

local function render(r, g)
    set_color(r, BG)
    sdl.SDL_RenderClear(r)

    set_color(r, WALL_COLOR)
    for _, w in ipairs(WALLS) do fill(r, w[1], w[2], w[3], w[4]) end

    for i = 0, 1 do
        local t = g.tanks[i]
        set_color(r, TANK_COLORS[i])
        draw_tank(r, t)
        if t.bullet.active then fill(r, t.bullet.x, t.bullet.y, BULLET_SIZE, BULLET_SIZE) end
        -- No fim da partida o placar pisca.
        if not g.game_over or math.fmod(g.blink, 0.5) < 0.25 then
            draw_number(r, t.score, i == 0 and 40 or 600, 6, 6, i == 1)
        end
    end

    set_color(r, HUD_COLOR)
    draw_number(r, g.mode, 314, 8, 4, false)
    fill(r, 220, 36, math.floor(200 * g.time_left / MATCH_TIME), 4)
    sdl.SDL_RenderPresent(r)
end

local function main()
    if sdl.SDL_Init(bit.bor(SDL_INIT_VIDEO, SDL_INIT_AUDIO)) ~= 0 then
        io.stderr:write("SDL_Init: ", ffi.string(sdl.SDL_GetError()), "\n")
        return 1
    end
    local win = sdl.SDL_CreateWindow("Tanques - Lua", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                     W, H, SDL_WINDOW_SHOWN)
    local ren = win ~= nil and sdl.SDL_CreateRenderer(win, -1,
        bit.bor(SDL_RENDERER_ACCELERATED, SDL_RENDERER_PRESENTVSYNC)) or nil
    if ren == nil then
        io.stderr:write("janela/renderer: ", ffi.string(sdl.SDL_GetError()), "\n")
        return 1
    end

    local want = ffi.new("SDL_AudioSpec", { freq = RATE, format = AUDIO_S16LSB, channels = 1, samples = 1024 })
    local audio = sdl.SDL_OpenAudioDevice(nil, 0, want, nil, 0)
    if audio ~= 0 then
        sdl.SDL_PauseAudioDevice(audio, 0)
    else
        io.stderr:write("sem áudio: ", ffi.string(sdl.SDL_GetError()), "\n")
    end

    local game = Game.new(audio)

    local event = ffi.new("SDL_Event")
    local freq = tonumber(sdl.SDL_GetPerformanceFrequency())
    local last = sdl.SDL_GetPerformanceCounter()
    local acc = 0
    local running = true
    while running do
        while sdl.SDL_PollEvent(event) ~= 0 do
            if event.type == SDL_QUIT then running = false end
        end
        local keys = sdl.SDL_GetKeyboardState(nil)
        if keys[SC_ESCAPE] ~= 0 then running = false end

        local now = sdl.SDL_GetPerformanceCounter()
        acc = acc + math.min(tonumber(now - last) / freq, 0.25)
        last = now
        while acc >= STEP do
            game:update(keys, STEP)
            acc = acc - STEP
        end
        render(ren, game)
    end

    if audio ~= 0 then sdl.SDL_CloseAudioDevice(audio) end
    sdl.SDL_DestroyRenderer(ren)
    sdl.SDL_DestroyWindow(win)
    sdl.SDL_Quit()
    return 0
end

-- Permite carregar o arquivo como módulo (testes) sem abrir a janela.
if ... == "tanques" then
    return { Game = Game, STEP = STEP }
end
os.exit(main())
