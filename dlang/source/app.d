// Tanques em D com SDL2 (bindbc-sdl, carregamento dinâmico da libSDL2).
// Inspirado no Combat (Atari 2600, 1977).
module app;

import bindbc.sdl;
import std.algorithm : any, min;
import std.conv : to;
import std.math : cos, fmod, sin, sqrt, PI;
import std.stdio : stderr;

enum W = 640, H = 480;
enum TANK_GRID = 22, TANK_CELL = 2;  // tanque desenhado em 22x22 blocos de 2px
enum double TANK_HALF = 12;          // hitbox 24x24
enum double TANK_SPEED = 90.0;       // px/s
enum double ROT_TIME = 0.09;         // s por passo de giro (16 direções)
enum double BULLET_SPEED = 320.0;
enum BULLET_SIZE = 4;
enum double BULLET_LIFE = 1.6;
enum double SPIN_TIME = 1.0, SPIN_STEP = 0.04, PUSH_SPEED = 110.0;
enum double MATCH_TIME = 136.0;  // 2:16, como no Combat
enum double STEP = 1.0 / 120.0;
enum RATE = 44_100;

// Bordas da arena e obstáculos, simétricos nos dois eixos.
immutable SDL_Rect[] WALLS = [
    SDL_Rect(0, 48, 640, 8), SDL_Rect(0, 472, 640, 8), SDL_Rect(0, 48, 8, 432), SDL_Rect(632, 48, 8, 432),
    SDL_Rect(120, 120, 16, 80), SDL_Rect(504, 120, 16, 80), SDL_Rect(120, 328, 16, 80), SDL_Rect(504, 328, 16, 80),
    SDL_Rect(256, 136, 128, 16), SDL_Rect(256, 376, 128, 16), SDL_Rect(312, 232, 16, 64),
];

// Forma do tanque em px [x0, y0, x1, y1], centrada na origem e apontando
// para +x: duas esteiras, corpo e canhão.
immutable double[4][] TANK_SHAPE = [
    [-14, -14, 12, -7], [-14, 7, 12, 14], [-10, -7, 7, 7], [0, -2, 20, 2],
];

// (cosseno, seno) das 16 direções, a cada 22,5°. Valores literais: sin/cos das
// bibliotecas diferem no último bit entre as linguagens, e as versões passariam
// a divergir. Assim também o tanque anda em linha reta nas 4 direções cardeais.
immutable double[2][16] DIR_TABLE = [
    [1, 0], [0.9238795325112867, 0.3826834323650898],
    [0.7071067811865476, 0.7071067811865476], [0.3826834323650898, 0.9238795325112867],
    [0, 1], [-0.3826834323650898, 0.9238795325112867],
    [-0.7071067811865476, 0.7071067811865476], [-0.9238795325112867, 0.3826834323650898],
    [-1, 0], [-0.9238795325112867, -0.3826834323650898],
    [-0.7071067811865476, -0.7071067811865476], [-0.3826834323650898, -0.9238795325112867],
    [0, -1], [0.3826834323650898, -0.9238795325112867],
    [0.7071067811865476, -0.7071067811865476], [0.9238795325112867, -0.3826834323650898],
];

// Fonte 3x5 para os dígitos do placar.
immutable string[10] DIGITS = [
    "111101101101111", "001001001001001", "111001111100111", "111001111001111",
    "101101111001001", "111100111001111", "111100111101111", "111001001001001",
    "111101111101111", "111101111001111",
];

struct Color { ubyte r, g, b; }
immutable Color BG = Color(0, 0, 0), WALL_COLOR = Color(180, 140, 60), HUD_COLOR = Color(230, 230, 230);
immutable Color[2] TANK_COLORS = [Color(90, 200, 90), Color(110, 150, 255)];

struct Controls { SDL_Scancode fwd, left, right, fire; }
immutable Controls[2] CONTROLS = [
    Controls(SDL_SCANCODE_W, SDL_SCANCODE_A, SDL_SCANCODE_D, SDL_SCANCODE_SPACE),
    Controls(SDL_SCANCODE_UP, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT, SDL_SCANCODE_RETURN),
];

// Onda quadrada mono S16.
short[] squareWave(int freq, int ms)
{
    auto buf = new short[RATE * ms / 1000];
    foreach (i, ref s; buf)
        s = ((i * 2 * freq) / RATE) % 2 ? 4000 : -4000;
    return buf;
}

// Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
// decaindo até zero; hold = amostras por bit (maior = mais grave).
short[] noise(int ms, int hold)
{
    const n = RATE * ms / 1000;
    auto buf = new short[n];
    uint lfsr = 0xACE1, bit = 0;
    foreach (i; 0 .. n)
    {
        if (i % hold == 0)
        {
            bit = lfsr & 1;
            lfsr >>= 1;
            if (bit) lfsr ^= 0xB400;
        }
        const amp = cast(short)(4000 * (n - i) / n);
        buf[i] = bit ? amp : cast(short) -amp;
    }
    return buf;
}

bool overlaps(double ax, double ay, double aw, double ah, double bx, double by, double bw, double bh)
{
    return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;
}

bool hitsWall(double x, double y, double w, double h)
{
    return WALLS.any!(r => overlaps(x, y, w, h, r.x, r.y, r.w, r.h));
}

double dirAngle(int dir) { return dir * 2 * PI / 16; }

struct Bullet
{
    bool active;
    double x = 0, y = 0, vx = 0, vy = 0, life = 0;
}

struct Tank
{
    double x = 0, y = 0;
    int dir;
    double rotTimer = 0;
    bool firePrev;
    double spin = 0, spinStep = 0, pushX = 0, pushY = 0;
    int score;
    Bullet bullet;
}

struct Game
{
    Tank[2] tanks;
    int mode = 1;  // 1 = normal, 2 = ricochete
    double timeLeft = MATCH_TIME, blink = 0;
    bool gameOver;

    SDL_AudioDeviceID audio;
    short[] sndShot, sndHit, sndRicochet, sndEnd;

    void play(const short[] s)
    {
        if (!audio) return;
        SDL_ClearQueuedAudio(audio);
        SDL_QueueAudio(audio, s.ptr, cast(uint)(s.length * short.sizeof));
    }

    void newMatch(int m)
    {
        mode = m;
        timeLeft = MATCH_TIME;
        gameOver = false;
        tanks[0] = Tank(60, 264, 0);
        tanks[1] = Tank(580, 264, 8);
    }

    static bool blocked(ref const Tank other, double x, double y)
    {
        enum s = 2 * TANK_HALF;
        return hitsWall(x - TANK_HALF, y - TANK_HALF, s, s)
            || overlaps(x - TANK_HALF, y - TANK_HALF, s, s, other.x - TANK_HALF, other.y - TANK_HALF, s, s);
    }

    // Move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
    static void tryMove(ref Tank t, ref const Tank other, double dx, double dy)
    {
        if (!blocked(other, t.x + dx, t.y)) t.x += dx;
        if (!blocked(other, t.x, t.y + dy)) t.y += dy;
    }

    void updateTank(int i, const(ubyte)* keys, double dt)
    {
        auto t = &tanks[i];
        auto other = &tanks[1 - i];
        const c = CONTROLS[i];
        const fire = keys[c.fire] != 0;

        if (t.spin > 0)
        {
            // Atingido: gira sozinho e é empurrado para trás.
            t.spin -= dt;
            t.spinStep -= dt;
            if (t.spinStep <= 0)
            {
                t.dir = (t.dir + 1) % 16;
                t.spinStep += SPIN_STEP;
            }
            tryMove(*t, *other, t.pushX * dt, t.pushY * dt);
        }
        else
        {
            const turn = (keys[c.right] ? 1 : 0) - (keys[c.left] ? 1 : 0);
            if (turn != 0)
            {
                t.rotTimer -= dt;
                if (t.rotTimer <= 0)
                {
                    t.dir = (t.dir + turn + 16) % 16;
                    t.rotTimer += ROT_TIME;
                }
            }
            else
                t.rotTimer = 0;
            const dc = DIR_TABLE[t.dir][0], ds = DIR_TABLE[t.dir][1];
            if (keys[c.fwd]) tryMove(*t, *other, dc * TANK_SPEED * dt, ds * TANK_SPEED * dt);
            if (fire && !t.firePrev && !t.bullet.active)
            {
                const bx = t.x + dc * 20 - BULLET_SIZE / 2.0, by = t.y + ds * 20 - BULLET_SIZE / 2.0;
                // Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
                if (!hitsWall(bx, by, BULLET_SIZE, BULLET_SIZE))
                {
                    t.bullet = Bullet(true, bx, by, dc * BULLET_SPEED, ds * BULLET_SPEED, BULLET_LIFE);
                    play(sndShot);
                }
            }
        }
        t.firePrev = fire;

        auto b = &t.bullet;
        if (!b.active) return;
        b.life -= dt;
        if (b.life <= 0) { b.active = false; return; }
        // Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
        b.x += b.vx * dt;
        if (hitsWall(b.x, b.y, BULLET_SIZE, BULLET_SIZE))
        {
            if (mode != 2) { b.active = false; return; }
            b.x -= b.vx * dt;
            b.vx = -b.vx;
            play(sndRicochet);
        }
        b.y += b.vy * dt;
        if (hitsWall(b.x, b.y, BULLET_SIZE, BULLET_SIZE))
        {
            if (mode != 2) { b.active = false; return; }
            b.y -= b.vy * dt;
            b.vy = -b.vy;
            play(sndRicochet);
        }
        if (other.spin <= 0 && overlaps(b.x, b.y, BULLET_SIZE, BULLET_SIZE, other.x - TANK_HALF,
                                         other.y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF))
        {
            ++t.score;
            const len = sqrt(b.vx * b.vx + b.vy * b.vy);
            other.spin = SPIN_TIME;
            other.spinStep = 0;
            other.pushX = b.vx / len * PUSH_SPEED;
            other.pushY = b.vy / len * PUSH_SPEED;
            b.active = false;
            play(sndHit);
        }
    }

    void update(const(ubyte)* keys, double dt)
    {
        if (keys[SDL_SCANCODE_1]) newMatch(1);
        if (keys[SDL_SCANCODE_2]) newMatch(2);
        blink += dt;
        if (gameOver) return;
        timeLeft -= dt;
        if (timeLeft <= 0)
        {
            timeLeft = 0;
            gameOver = true;
            play(sndEnd);
            return;
        }
        updateTank(0, keys, dt);
        updateTank(1, keys, dt);
    }
}

void setColor(SDL_Renderer* r, Color c) { SDL_SetRenderDrawColor(r, c.r, c.g, c.b, 255); }

void fill(SDL_Renderer* r, int x, int y, int w, int h)
{
    auto rc = SDL_Rect(x, y, w, h);
    SDL_RenderFillRect(r, &rc);
}

// Desenha um número com blocos de tamanho s; alignRight=true faz o número terminar em x.
void drawNumber(SDL_Renderer* r, int n, int x, int y, int s, bool alignRight)
{
    const str = n.to!string;
    const len = cast(int) str.length;
    if (alignRight) x -= len * 3 * s + (len - 1) * s;
    foreach (c; str)
    {
        const g = DIGITS[c - '0'];
        foreach (i; 0 .. 15)
            if (g[i] == '1') fill(r, x + (i % 3) * s, y + (i / 3) * s, s, s);
        x += 4 * s;
    }
}

// Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
// rotacionado de volta para o referencial do tanque, cai dentro da forma.
// Dá o visual blocado do 2600 em qualquer uma das 16 direções.
void drawTank(SDL_Renderer* r, ref const Tank t)
{
    const a = dirAngle(t.dir), c = cos(a), s = sin(a);
    const x0 = cast(int) t.x - TANK_GRID * TANK_CELL / 2, y0 = cast(int) t.y - TANK_GRID * TANK_CELL / 2;
    enum half = (TANK_GRID - 1) / 2.0;
    foreach (i; 0 .. TANK_GRID)
    {
        foreach (j; 0 .. TANK_GRID)
        {
            const px = (j - half) * TANK_CELL, py = (i - half) * TANK_CELL;
            const u = px * c + py * s, v = -px * s + py * c;
            if (TANK_SHAPE.any!(b => u >= b[0] && u < b[2] && v >= b[1] && v < b[3]))
                fill(r, x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL);
        }
    }
}

void render(SDL_Renderer* r, ref const Game g)
{
    setColor(r, BG);
    SDL_RenderClear(r);

    setColor(r, WALL_COLOR);
    foreach (w; WALLS) fill(r, w.x, w.y, w.w, w.h);

    foreach (i, ref t; g.tanks)
    {
        setColor(r, TANK_COLORS[i]);
        drawTank(r, t);
        if (t.bullet.active)
            fill(r, cast(int) t.bullet.x, cast(int) t.bullet.y, BULLET_SIZE, BULLET_SIZE);
        // No fim da partida o placar pisca.
        if (!g.gameOver || fmod(g.blink, 0.5) < 0.25)
            drawNumber(r, t.score, i == 0 ? 40 : 600, 6, 6, i == 1);
    }

    setColor(r, HUD_COLOR);
    drawNumber(r, g.mode, 314, 8, 4, false);
    fill(r, 220, 36, cast(int)(200 * g.timeLeft / MATCH_TIME), 4);
    SDL_RenderPresent(r);
}

int main()
{
    const loaded = loadSDL();
    if (loaded != sdlSupport)
    {
        stderr.writeln(loaded == SDLSupport.noLibrary ? "libSDL2 não encontrada"
                                                      : "libSDL2 antiga demais (precisa >= 2.0.18)");
        return 1;
    }
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) != 0)
    {
        stderr.writeln("SDL_Init: ", SDL_GetError().to!string);
        return 1;
    }
    scope (exit) SDL_Quit();

    auto win = SDL_CreateWindow("Tanques - D", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                W, H, SDL_WINDOW_SHOWN);
    auto ren = win ? SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC)
                   : null;
    if (!ren)
    {
        stderr.writeln("janela/renderer: ", SDL_GetError().to!string);
        return 1;
    }
    scope (exit) { SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); }

    Game game;
    game.sndShot = noise(90, 3);
    game.sndHit = noise(500, 20);
    game.sndRicochet = squareWave(1200, 25);
    game.sndEnd = squareWave(220, 700);

    SDL_AudioSpec want;
    want.freq = RATE;
    want.format = AUDIO_S16SYS;
    want.channels = 1;
    want.samples = 1024;
    game.audio = SDL_OpenAudioDevice(null, 0, &want, null, 0);
    if (game.audio) SDL_PauseAudioDevice(game.audio, 0);
    else stderr.writeln("sem áudio: ", SDL_GetError().to!string);
    scope (exit) if (game.audio) SDL_CloseAudioDevice(game.audio);

    game.newMatch(1);

    ulong last = SDL_GetPerformanceCounter();
    double acc = 0;
    for (;;)
    {
        SDL_Event e;
        while (SDL_PollEvent(&e))
            if (e.type == SDL_QUIT) return 0;
        const keys = SDL_GetKeyboardState(null);
        if (keys[SDL_SCANCODE_ESCAPE]) return 0;

        const now = SDL_GetPerformanceCounter();
        acc += min(double(now - last) / SDL_GetPerformanceFrequency(), 0.25);
        last = now;
        while (acc >= STEP)
        {
            game.update(keys, STEP);
            acc -= STEP;
        }
        render(ren, game);
    }
}
