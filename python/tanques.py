#!/usr/bin/env python3
"""Tanques em Python com SDL2 (PySDL2, API de baixo nível sobre ctypes).

Inspirado no Combat (Atari 2600, 1977).
"""
import ctypes
import math
import sys
from array import array

import sdl2

W, H = 640, 480
TANK_GRID, TANK_CELL = 22, 2  # tanque desenhado em 22x22 blocos de 2px
TANK_HALF = 12                # hitbox 24x24
TANK_SPEED = 90.0             # px/s
ROT_TIME = 0.09               # s por passo de giro (16 direções)
BULLET_SPEED = 320.0
BULLET_SIZE = 4
BULLET_LIFE = 1.6
SPIN_TIME, SPIN_STEP, PUSH_SPEED = 1.0, 0.04, 110.0
MATCH_TIME = 136.0  # 2:16, como no Combat
STEP = 1.0 / 120.0
RATE = 44100

# Bordas da arena e obstáculos (x, y, w, h), simétricos nos dois eixos.
WALLS = [
    (0, 48, 640, 8), (0, 472, 640, 8), (0, 48, 8, 432), (632, 48, 8, 432),
    (120, 120, 16, 80), (504, 120, 16, 80), (120, 328, 16, 80), (504, 328, 16, 80),
    (256, 136, 128, 16), (256, 376, 128, 16), (312, 232, 16, 64),
]

# Forma do tanque em px (x0, y0, x1, y1), centrada na origem e apontando
# para +x: duas esteiras, corpo e canhão.
TANK_SHAPE = [(-14, -14, 12, -7), (-14, 7, 12, 14), (-10, -7, 7, 7), (0, -2, 20, 2)]

# (cosseno, seno) das 16 direções, a cada 22,5°. Valores literais: sin/cos das
# bibliotecas diferem no último bit entre as linguagens, e as versões passariam
# a divergir. Assim também o tanque anda em linha reta nas 4 direções cardeais.
DIR_TABLE = [
    (1, 0), (0.9238795325112867, 0.3826834323650898),
    (0.7071067811865476, 0.7071067811865476), (0.3826834323650898, 0.9238795325112867),
    (0, 1), (-0.3826834323650898, 0.9238795325112867),
    (-0.7071067811865476, 0.7071067811865476), (-0.9238795325112867, 0.3826834323650898),
    (-1, 0), (-0.9238795325112867, -0.3826834323650898),
    (-0.7071067811865476, -0.7071067811865476), (-0.3826834323650898, -0.9238795325112867),
    (0, -1), (0.3826834323650898, -0.9238795325112867),
    (0.7071067811865476, -0.7071067811865476), (0.9238795325112867, -0.3826834323650898),
]

# Fonte 3x5 para os dígitos do placar.
DIGITS = [
    "111101101101111", "001001001001001", "111001111100111", "111001111001111",
    "101101111001001", "111100111001111", "111100111101111", "111001001001001",
    "111101111101111", "111101111001111",
]

BG, WALL_COLOR, HUD_COLOR = (0, 0, 0), (180, 140, 60), (230, 230, 230)
TANK_COLORS = [(90, 200, 90), (110, 150, 255)]

# (frente, esquerda, direita, tiro) de cada jogador.
CONTROLS = [
    (sdl2.SDL_SCANCODE_W, sdl2.SDL_SCANCODE_A, sdl2.SDL_SCANCODE_D, sdl2.SDL_SCANCODE_SPACE),
    (sdl2.SDL_SCANCODE_UP, sdl2.SDL_SCANCODE_LEFT, sdl2.SDL_SCANCODE_RIGHT, sdl2.SDL_SCANCODE_RETURN),
]


def to_bytes(samples):
    buf = array("h", samples)
    if sys.byteorder != "little":
        buf.byteswap()
    return buf.tobytes()


def square_wave(freq, ms):
    """Onda quadrada mono S16."""
    n = RATE * ms // 1000
    return to_bytes(4000 if (i * 2 * freq // RATE) % 2 else -4000 for i in range(n))


def noise(ms, hold):
    """Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
    decaindo até zero; hold = amostras por bit (maior = mais grave)."""
    n = RATE * ms // 1000
    lfsr, bit, out = 0xACE1, 0, []
    for i in range(n):
        if i % hold == 0:
            bit = lfsr & 1
            lfsr >>= 1
            if bit:
                lfsr ^= 0xB400
        amp = 4000 * (n - i) // n
        out.append(amp if bit else -amp)
    return to_bytes(out)


def overlaps(ax, ay, aw, ah, bx, by, bw, bh):
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by


def hits_wall(x, y, w, h):
    return any(overlaps(x, y, w, h, *r) for r in WALLS)


def dir_angle(d):
    return d * 2 * math.pi / 16


class Bullet:
    def __init__(self):
        self.active = False
        self.x = self.y = self.vx = self.vy = self.life = 0.0


class Tank:
    def __init__(self, x, y, d):
        self.x, self.y, self.dir = x, y, d
        self.rot_timer = 0.0
        self.fire_prev = False
        self.spin = self.spin_step = self.push_x = self.push_y = 0.0
        self.score = 0
        self.bullet = Bullet()


class Game:
    def __init__(self, audio):
        self.audio = audio
        self.snd_shot = noise(90, 3)
        self.snd_hit = noise(500, 20)
        self.snd_ricochet = square_wave(1200, 25)
        self.snd_end = square_wave(220, 700)
        self.blink = 0.0
        self.new_match(1)

    def play(self, s):
        if not self.audio:
            return
        sdl2.SDL_ClearQueuedAudio(self.audio)
        sdl2.SDL_QueueAudio(self.audio, s, len(s))

    def new_match(self, mode):
        self.mode = mode  # 1 = normal, 2 = ricochete
        self.time_left = MATCH_TIME
        self.game_over = False
        self.tanks = [Tank(60, 264, 0), Tank(580, 264, 8)]

    @staticmethod
    def blocked(other, x, y):
        s = 2 * TANK_HALF
        return (hits_wall(x - TANK_HALF, y - TANK_HALF, s, s)
                or overlaps(x - TANK_HALF, y - TANK_HALF, s, s, other.x - TANK_HALF, other.y - TANK_HALF, s, s))

    def try_move(self, t, other, dx, dy):
        """Move um eixo de cada vez, para o tanque deslizar ao longo das paredes."""
        if not self.blocked(other, t.x + dx, t.y):
            t.x += dx
        if not self.blocked(other, t.x, t.y + dy):
            t.y += dy

    def update_tank(self, i, keys, dt):
        t, other = self.tanks[i], self.tanks[1 - i]
        fwd, left, right, fire_key = CONTROLS[i]
        fire = bool(keys[fire_key])

        if t.spin > 0:
            # Atingido: gira sozinho e é empurrado para trás.
            t.spin -= dt
            t.spin_step -= dt
            if t.spin_step <= 0:
                t.dir = (t.dir + 1) % 16
                t.spin_step += SPIN_STEP
            self.try_move(t, other, t.push_x * dt, t.push_y * dt)
        else:
            turn = (1 if keys[right] else 0) - (1 if keys[left] else 0)
            if turn:
                t.rot_timer -= dt
                if t.rot_timer <= 0:
                    t.dir = (t.dir + turn) % 16
                    t.rot_timer += ROT_TIME
            else:
                t.rot_timer = 0.0
            dc, ds = DIR_TABLE[t.dir]
            if keys[fwd]:
                self.try_move(t, other, dc * TANK_SPEED * dt, ds * TANK_SPEED * dt)
            if fire and not t.fire_prev and not t.bullet.active:
                bx = t.x + dc * 20 - BULLET_SIZE / 2
                by = t.y + ds * 20 - BULLET_SIZE / 2
                # Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
                if not hits_wall(bx, by, BULLET_SIZE, BULLET_SIZE):
                    b = t.bullet
                    b.active, b.x, b.y = True, bx, by
                    b.vx, b.vy = dc * BULLET_SPEED, ds * BULLET_SPEED
                    b.life = BULLET_LIFE
                    self.play(self.snd_shot)
        t.fire_prev = fire

        b = t.bullet
        if not b.active:
            return
        b.life -= dt
        if b.life <= 0:
            b.active = False
            return
        # Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
        b.x += b.vx * dt
        if hits_wall(b.x, b.y, BULLET_SIZE, BULLET_SIZE):
            if self.mode != 2:
                b.active = False
                return
            b.x -= b.vx * dt
            b.vx = -b.vx
            self.play(self.snd_ricochet)
        b.y += b.vy * dt
        if hits_wall(b.x, b.y, BULLET_SIZE, BULLET_SIZE):
            if self.mode != 2:
                b.active = False
                return
            b.y -= b.vy * dt
            b.vy = -b.vy
            self.play(self.snd_ricochet)
        if other.spin <= 0 and overlaps(b.x, b.y, BULLET_SIZE, BULLET_SIZE, other.x - TANK_HALF,
                                        other.y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF):
            t.score += 1
            length = math.sqrt(b.vx * b.vx + b.vy * b.vy)
            other.spin = SPIN_TIME
            other.spin_step = 0.0
            other.push_x = b.vx / length * PUSH_SPEED
            other.push_y = b.vy / length * PUSH_SPEED
            b.active = False
            self.play(self.snd_hit)

    def update(self, keys, dt):
        if keys[sdl2.SDL_SCANCODE_1]:
            self.new_match(1)
        if keys[sdl2.SDL_SCANCODE_2]:
            self.new_match(2)
        self.blink += dt
        if self.game_over:
            return
        self.time_left -= dt
        if self.time_left <= 0:
            self.time_left = 0.0
            self.game_over = True
            self.play(self.snd_end)
            return
        self.update_tank(0, keys, dt)
        self.update_tank(1, keys, dt)


def set_color(r, c):
    sdl2.SDL_SetRenderDrawColor(r, c[0], c[1], c[2], 255)


def fill(r, x, y, w, h):
    sdl2.SDL_RenderFillRect(r, sdl2.SDL_Rect(int(x), int(y), w, h))


def draw_number(r, n, x, y, s, align_right):
    """Desenha um número com blocos de tamanho s; align_right=True faz o número terminar em x."""
    text = str(n)
    if align_right:
        x -= len(text) * 3 * s + (len(text) - 1) * s
    for c in text:
        for i, bit in enumerate(DIGITS[int(c)]):
            if bit == "1":
                fill(r, x + (i % 3) * s, y + (i // 3) * s, s, s)
        x += 4 * s


def draw_tank(r, t):
    """Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
    rotacionado de volta para o referencial do tanque, cai dentro da forma.
    Dá o visual blocado do 2600 em qualquer uma das 16 direções."""
    a = dir_angle(t.dir)
    c, s = math.cos(a), math.sin(a)
    x0 = int(t.x) - TANK_GRID * TANK_CELL // 2
    y0 = int(t.y) - TANK_GRID * TANK_CELL // 2
    for i in range(TANK_GRID):
        py = (i - (TANK_GRID - 1) / 2) * TANK_CELL
        for j in range(TANK_GRID):
            px = (j - (TANK_GRID - 1) / 2) * TANK_CELL
            u, v = px * c + py * s, -px * s + py * c
            if any(bx0 <= u < bx1 and by0 <= v < by1 for bx0, by0, bx1, by1 in TANK_SHAPE):
                fill(r, x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL)


def render(r, g):
    set_color(r, BG)
    sdl2.SDL_RenderClear(r)

    set_color(r, WALL_COLOR)
    for w in WALLS:
        fill(r, *w)

    for i, t in enumerate(g.tanks):
        set_color(r, TANK_COLORS[i])
        draw_tank(r, t)
        if t.bullet.active:
            fill(r, t.bullet.x, t.bullet.y, BULLET_SIZE, BULLET_SIZE)
        # No fim da partida o placar pisca.
        if not g.game_over or math.fmod(g.blink, 0.5) < 0.25:
            draw_number(r, t.score, 40 if i == 0 else 600, 6, 6, i == 1)

    set_color(r, HUD_COLOR)
    draw_number(r, g.mode, 314, 8, 4, False)
    fill(r, 220, 36, int(200 * g.time_left / MATCH_TIME), 4)
    sdl2.SDL_RenderPresent(r)


def main():
    if sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO | sdl2.SDL_INIT_AUDIO) != 0:
        print("SDL_Init:", sdl2.SDL_GetError().decode(), file=sys.stderr)
        return 1
    win = sdl2.SDL_CreateWindow(b"Tanques - Python", sdl2.SDL_WINDOWPOS_CENTERED, sdl2.SDL_WINDOWPOS_CENTERED,
                                W, H, sdl2.SDL_WINDOW_SHOWN)
    ren = win and sdl2.SDL_CreateRenderer(win, -1, sdl2.SDL_RENDERER_ACCELERATED | sdl2.SDL_RENDERER_PRESENTVSYNC)
    if not ren:
        print("janela/renderer:", sdl2.SDL_GetError().decode(), file=sys.stderr)
        return 1

    want = sdl2.SDL_AudioSpec(RATE, sdl2.AUDIO_S16LSB, 1, 1024)
    audio = sdl2.SDL_OpenAudioDevice(None, 0, want, None, 0)
    if audio:
        sdl2.SDL_PauseAudioDevice(audio, 0)
    else:
        print("sem áudio:", sdl2.SDL_GetError().decode(), file=sys.stderr)

    game = Game(audio)

    event = sdl2.SDL_Event()
    freq = sdl2.SDL_GetPerformanceFrequency()
    last = sdl2.SDL_GetPerformanceCounter()
    acc = 0.0
    running = True
    while running:
        while sdl2.SDL_PollEvent(ctypes.byref(event)):
            if event.type == sdl2.SDL_QUIT:
                running = False
        keys = sdl2.SDL_GetKeyboardState(None)
        if keys[sdl2.SDL_SCANCODE_ESCAPE]:
            running = False

        now = sdl2.SDL_GetPerformanceCounter()
        acc += min((now - last) / freq, 0.25)
        last = now
        while acc >= STEP:
            game.update(keys, STEP)
            acc -= STEP
        render(ren, game)

    if audio:
        sdl2.SDL_CloseAudioDevice(audio)
    sdl2.SDL_DestroyRenderer(ren)
    sdl2.SDL_DestroyWindow(win)
    sdl2.SDL_Quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
