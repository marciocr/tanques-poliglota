// Tanques em C++ com SDL2: versão de referência do tanques-poliglota.
// Inspirado no Combat (Atari 2600, 1977).
#include <SDL.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace {

constexpr int W = 640, H = 480;
constexpr int TANK_GRID = 22, TANK_CELL = 2;  // tanque desenhado em 22x22 blocos de 2px
constexpr double TANK_HALF = 12;              // hitbox 24x24
constexpr double TANK_SPEED = 90.0;           // px/s
constexpr double ROT_TIME = 0.09;             // s por passo de giro (16 direções)
constexpr double BULLET_SPEED = 320.0;
constexpr int BULLET_SIZE = 4;
constexpr double BULLET_LIFE = 1.6;
constexpr double SPIN_TIME = 1.0, SPIN_STEP = 0.04, PUSH_SPEED = 110.0;
constexpr double MATCH_TIME = 136.0;  // 2:16, como no Combat
constexpr double STEP = 1.0 / 120.0;
constexpr int RATE = 44100;

struct Rect { int x, y, w, h; };
struct Box { double x0, y0, x1, y1; };
struct Color { Uint8 r, g, b; };

// Bordas da arena e obstáculos, simétricos nos dois eixos.
const Rect WALLS[] = {
    {0, 48, 640, 8},    {0, 472, 640, 8},   {0, 48, 8, 432},    {632, 48, 8, 432},
    {120, 120, 16, 80}, {504, 120, 16, 80}, {120, 328, 16, 80}, {504, 328, 16, 80},
    {256, 136, 128, 16}, {256, 376, 128, 16}, {312, 232, 16, 64},
};

// Forma do tanque em px, centrada na origem e apontando para +x:
// duas esteiras, corpo e canhão.
const Box TANK_SHAPE[] = {
    {-14, -14, 12, -7}, {-14, 7, 12, 14}, {-10, -7, 7, 7}, {0, -2, 20, 2},
};

// Fonte 3x5 para os dígitos do placar.
const char* const DIGITS[10] = {
    "111101101101111", "001001001001001", "111001111100111", "111001111001111",
    "101101111001001", "111100111001111", "111100111101111", "111001001001001",
    "111101111101111", "111101111001111"};

const Color BG{0, 0, 0}, WALL_COLOR{180, 140, 60}, HUD_COLOR{230, 230, 230};
const Color TANK_COLORS[2] = {{90, 200, 90}, {110, 150, 255}};

// Onda quadrada mono S16.
std::vector<int16_t> square_wave(int freq, int ms) {
    std::vector<int16_t> buf(RATE * ms / 1000);
    for (size_t i = 0; i < buf.size(); ++i)
        buf[i] = ((i * 2 * freq) / RATE) % 2 ? 4000 : -4000;
    return buf;
}

// Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
// decaindo até zero; "hold" = amostras por bit (maior = mais grave).
std::vector<int16_t> noise(int ms, int hold) {
    const int n = RATE * ms / 1000;
    std::vector<int16_t> buf(n);
    unsigned lfsr = 0xACE1, bit = 0;
    for (int i = 0; i < n; ++i) {
        if (i % hold == 0) {
            bit = lfsr & 1;
            lfsr >>= 1;
            if (bit) lfsr ^= 0xB400;
        }
        const int amp = 4000 * (n - i) / n;
        buf[i] = int16_t(bit ? amp : -amp);
    }
    return buf;
}

bool overlaps(double ax, double ay, double aw, double ah, double bx, double by, double bw, double bh) {
    return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;
}

bool hits_wall(double x, double y, double w, double h) {
    for (const Rect& r : WALLS)
        if (overlaps(x, y, w, h, r.x, r.y, r.w, r.h)) return true;
    return false;
}

double dir_angle(int dir) { return dir * 2 * M_PI / 16; }

struct Controls { SDL_Scancode fwd, left, right, fire; };
const Controls CONTROLS[2] = {
    {SDL_SCANCODE_W, SDL_SCANCODE_A, SDL_SCANCODE_D, SDL_SCANCODE_SPACE},
    {SDL_SCANCODE_UP, SDL_SCANCODE_LEFT, SDL_SCANCODE_RIGHT, SDL_SCANCODE_RETURN},
};

struct Bullet {
    bool active = false;
    double x = 0, y = 0, vx = 0, vy = 0, life = 0;
};

struct Tank {
    double x = 0, y = 0;
    int dir = 0;
    double rot_timer = 0;
    bool fire_prev = false;
    double spin = 0, spin_step = 0, push_x = 0, push_y = 0;
    int score = 0;
    Bullet bullet;
};

struct Game {
    Tank tanks[2];
    int mode = 1;  // 1 = normal, 2 = ricochete
    double time_left = MATCH_TIME, blink = 0;
    bool game_over = false;

    SDL_AudioDeviceID audio = 0;
    std::vector<int16_t> snd_shot = noise(90, 3);
    std::vector<int16_t> snd_hit = noise(500, 20);
    std::vector<int16_t> snd_ricochet = square_wave(1200, 25);
    std::vector<int16_t> snd_end = square_wave(220, 700);

    void play(const std::vector<int16_t>& s) {
        if (!audio) return;
        SDL_ClearQueuedAudio(audio);
        SDL_QueueAudio(audio, s.data(), static_cast<Uint32>(s.size() * sizeof(int16_t)));
    }

    void new_match(int m) {
        mode = m;
        time_left = MATCH_TIME;
        game_over = false;
        tanks[0] = Tank{};
        tanks[0].x = 60; tanks[0].y = 264; tanks[0].dir = 0;
        tanks[1] = Tank{};
        tanks[1].x = 580; tanks[1].y = 264; tanks[1].dir = 8;
    }

    static bool blocked(const Tank& other, double x, double y) {
        const double s = 2 * TANK_HALF;
        return hits_wall(x - TANK_HALF, y - TANK_HALF, s, s) ||
               overlaps(x - TANK_HALF, y - TANK_HALF, s, s,
                        other.x - TANK_HALF, other.y - TANK_HALF, s, s);
    }

    // Move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
    void try_move(Tank& t, const Tank& other, double dx, double dy) {
        if (!blocked(other, t.x + dx, t.y)) t.x += dx;
        if (!blocked(other, t.x, t.y + dy)) t.y += dy;
    }

    void update_tank(int i, const Uint8* keys, double dt) {
        Tank& t = tanks[i];
        Tank& other = tanks[1 - i];
        const Controls& c = CONTROLS[i];
        const bool fire = keys[c.fire];

        if (t.spin > 0) {
            // Atingido: gira sozinho e é empurrado para trás.
            t.spin -= dt;
            t.spin_step -= dt;
            if (t.spin_step <= 0) {
                t.dir = (t.dir + 1) % 16;
                t.spin_step += SPIN_STEP;
            }
            try_move(t, other, t.push_x * dt, t.push_y * dt);
        } else {
            const int turn = (keys[c.right] ? 1 : 0) - (keys[c.left] ? 1 : 0);
            if (turn != 0) {
                t.rot_timer -= dt;
                if (t.rot_timer <= 0) {
                    t.dir = (t.dir + turn + 16) % 16;
                    t.rot_timer += ROT_TIME;
                }
            } else {
                t.rot_timer = 0;
            }
            const double a = dir_angle(t.dir);
            if (keys[c.fwd]) try_move(t, other, std::cos(a) * TANK_SPEED * dt, std::sin(a) * TANK_SPEED * dt);
            if (fire && !t.fire_prev && !t.bullet.active) {
                const double bx = t.x + std::cos(a) * 20 - BULLET_SIZE / 2.0;
                const double by = t.y + std::sin(a) * 20 - BULLET_SIZE / 2.0;
                // Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
                if (!hits_wall(bx, by, BULLET_SIZE, BULLET_SIZE)) {
                    t.bullet = Bullet{true, bx, by, std::cos(a) * BULLET_SPEED, std::sin(a) * BULLET_SPEED,
                                      BULLET_LIFE};
                    play(snd_shot);
                }
            }
        }
        t.fire_prev = fire;

        Bullet& b = t.bullet;
        if (!b.active) return;
        b.life -= dt;
        if (b.life <= 0) { b.active = false; return; }
        // Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
        b.x += b.vx * dt;
        if (hits_wall(b.x, b.y, BULLET_SIZE, BULLET_SIZE)) {
            if (mode == 2) { b.x -= b.vx * dt; b.vx = -b.vx; play(snd_ricochet); }
            else { b.active = false; return; }
        }
        b.y += b.vy * dt;
        if (hits_wall(b.x, b.y, BULLET_SIZE, BULLET_SIZE)) {
            if (mode == 2) { b.y -= b.vy * dt; b.vy = -b.vy; play(snd_ricochet); }
            else { b.active = false; return; }
        }
        if (other.spin <= 0 && overlaps(b.x, b.y, BULLET_SIZE, BULLET_SIZE, other.x - TANK_HALF,
                                        other.y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF)) {
            ++t.score;
            const double len = std::hypot(b.vx, b.vy);
            other.spin = SPIN_TIME;
            other.spin_step = 0;
            other.push_x = b.vx / len * PUSH_SPEED;
            other.push_y = b.vy / len * PUSH_SPEED;
            b.active = false;
            play(snd_hit);
        }
    }

    void update(const Uint8* keys, double dt) {
        if (keys[SDL_SCANCODE_1]) new_match(1);
        if (keys[SDL_SCANCODE_2]) new_match(2);
        blink += dt;
        if (game_over) return;
        time_left -= dt;
        if (time_left <= 0) {
            time_left = 0;
            game_over = true;
            play(snd_end);
            return;
        }
        update_tank(0, keys, dt);
        update_tank(1, keys, dt);
    }
};

void set_color(SDL_Renderer* r, Color c) { SDL_SetRenderDrawColor(r, c.r, c.g, c.b, 255); }

void fill(SDL_Renderer* r, int x, int y, int w, int h) {
    SDL_Rect rc{x, y, w, h};
    SDL_RenderFillRect(r, &rc);
}

// Desenha um número com blocos de tamanho s; align_right=true faz o número terminar em x.
void draw_number(SDL_Renderer* r, int n, int x, int y, int s, bool align_right) {
    std::string str = std::to_string(n);
    int width = int(str.size()) * 3 * s + (int(str.size()) - 1) * s;
    if (align_right) x -= width;
    for (char c : str) {
        const char* g = DIGITS[c - '0'];
        for (int i = 0; i < 15; ++i)
            if (g[i] == '1') fill(r, x + (i % 3) * s, y + (i / 3) * s, s, s);
        x += 4 * s;
    }
}

// Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
// rotacionado de volta para o referencial do tanque, cai dentro da forma.
// Dá o visual blocado do 2600 em qualquer uma das 16 direções.
void draw_tank(SDL_Renderer* r, const Tank& t) {
    const double a = dir_angle(t.dir), c = std::cos(a), s = std::sin(a);
    const int x0 = int(t.x) - TANK_GRID * TANK_CELL / 2, y0 = int(t.y) - TANK_GRID * TANK_CELL / 2;
    for (int i = 0; i < TANK_GRID; ++i) {
        for (int j = 0; j < TANK_GRID; ++j) {
            const double px = (j - (TANK_GRID - 1) / 2.0) * TANK_CELL;
            const double py = (i - (TANK_GRID - 1) / 2.0) * TANK_CELL;
            const double u = px * c + py * s, v = -px * s + py * c;
            for (const Box& b : TANK_SHAPE) {
                if (u >= b.x0 && u < b.x1 && v >= b.y0 && v < b.y1) {
                    fill(r, x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL);
                    break;
                }
            }
        }
    }
}

void render(SDL_Renderer* r, const Game& g) {
    set_color(r, BG);
    SDL_RenderClear(r);

    set_color(r, WALL_COLOR);
    for (const Rect& w : WALLS) fill(r, w.x, w.y, w.w, w.h);

    for (int i = 0; i < 2; ++i) {
        const Tank& t = g.tanks[i];
        set_color(r, TANK_COLORS[i]);
        draw_tank(r, t);
        if (t.bullet.active) fill(r, int(t.bullet.x), int(t.bullet.y), BULLET_SIZE, BULLET_SIZE);
        // No fim da partida o placar pisca.
        if (!g.game_over || std::fmod(g.blink, 0.5) < 0.25)
            draw_number(r, t.score, i == 0 ? 40 : 600, 6, 6, i == 1);
    }

    set_color(r, HUD_COLOR);
    draw_number(r, g.mode, 314, 8, 4, false);
    fill(r, 220, 36, int(200 * g.time_left / MATCH_TIME), 4);
    SDL_RenderPresent(r);
}

}  // namespace

int main(int, char**) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) != 0) {
        SDL_Log("SDL_Init: %s", SDL_GetError());
        return 1;
    }
    SDL_Window* win = SDL_CreateWindow("Tanques - C++", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                       W, H, SDL_WINDOW_SHOWN);
    SDL_Renderer* ren = win ? SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC)
                            : nullptr;
    if (!ren) {
        SDL_Log("janela/renderer: %s", SDL_GetError());
        return 1;
    }

    Game game;
    SDL_AudioSpec want{};
    want.freq = RATE;
    want.format = AUDIO_S16SYS;
    want.channels = 1;
    want.samples = 1024;
    game.audio = SDL_OpenAudioDevice(nullptr, 0, &want, nullptr, 0);
    if (game.audio) SDL_PauseAudioDevice(game.audio, 0);
    else SDL_Log("sem áudio: %s", SDL_GetError());

    game.new_match(1);

    Uint64 last = SDL_GetPerformanceCounter();
    double acc = 0;
    bool running = true;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e))
            if (e.type == SDL_QUIT) running = false;
        const Uint8* keys = SDL_GetKeyboardState(nullptr);
        if (keys[SDL_SCANCODE_ESCAPE]) running = false;

        Uint64 now = SDL_GetPerformanceCounter();
        acc += std::min(double(now - last) / SDL_GetPerformanceFrequency(), 0.25);
        last = now;
        while (acc >= STEP) {
            game.update(keys, STEP);
            acc -= STEP;
        }
        render(ren, game);
    }

    if (game.audio) SDL_CloseAudioDevice(game.audio);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
