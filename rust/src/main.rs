// Tanques em Rust com SDL2 (crate `sdl2`). Inspirado no Combat (Atari 2600, 1977).
use sdl2::audio::{AudioQueue, AudioSpecDesired};
use sdl2::event::Event;
use sdl2::keyboard::{KeyboardState, Scancode};
use sdl2::pixels::Color;
use sdl2::rect::Rect;
use sdl2::render::WindowCanvas;
use std::f64::consts::PI;
use std::time::Instant;

const W: u32 = 640;
const H: u32 = 480;
const TANK_GRID: i32 = 22; // tanque desenhado em 22x22 blocos de 2px
const TANK_CELL: i32 = 2;
const TANK_HALF: f64 = 12.0; // hitbox 24x24
const TANK_SPEED: f64 = 90.0; // px/s
const ROT_TIME: f64 = 0.09; // s por passo de giro (16 direções)
const BULLET_SPEED: f64 = 320.0;
const BULLET_SIZE: f64 = 4.0;
const BULLET_LIFE: f64 = 1.6;
const SPIN_TIME: f64 = 1.0;
const SPIN_STEP: f64 = 0.04;
const PUSH_SPEED: f64 = 110.0;
const MATCH_TIME: f64 = 136.0; // 2:16, como no Combat
const STEP: f64 = 1.0 / 120.0;
const RATE: i32 = 44100;

// Bordas da arena e obstáculos (x, y, w, h), simétricos nos dois eixos.
const WALLS: [(i32, i32, i32, i32); 11] = [
    (0, 48, 640, 8), (0, 472, 640, 8), (0, 48, 8, 432), (632, 48, 8, 432),
    (120, 120, 16, 80), (504, 120, 16, 80), (120, 328, 16, 80), (504, 328, 16, 80),
    (256, 136, 128, 16), (256, 376, 128, 16), (312, 232, 16, 64),
];

// Forma do tanque em px (x0, y0, x1, y1), centrada na origem e apontando
// para +x: duas esteiras, corpo e canhão.
const TANK_SHAPE: [(f64, f64, f64, f64); 4] = [
    (-14.0, -14.0, 12.0, -7.0), (-14.0, 7.0, 12.0, 14.0), (-10.0, -7.0, 7.0, 7.0), (0.0, -2.0, 20.0, 2.0),
];

// (cosseno, seno) das 16 direções, a cada 22,5°. Valores literais: sin/cos das
// bibliotecas diferem no último bit entre as linguagens, e as versões passariam
// a divergir. Assim também o tanque anda em linha reta nas 4 direções cardeais.
const DIR_TABLE: [(f64, f64); 16] = [
    (1.0, 0.0), (0.9238795325112867, 0.3826834323650898),
    (0.7071067811865476, 0.7071067811865476), (0.3826834323650898, 0.9238795325112867),
    (0.0, 1.0), (-0.3826834323650898, 0.9238795325112867),
    (-0.7071067811865476, 0.7071067811865476), (-0.9238795325112867, 0.3826834323650898),
    (-1.0, 0.0), (-0.9238795325112867, -0.3826834323650898),
    (-0.7071067811865476, -0.7071067811865476), (-0.3826834323650898, -0.9238795325112867),
    (0.0, -1.0), (0.3826834323650898, -0.9238795325112867),
    (0.7071067811865476, -0.7071067811865476), (0.9238795325112867, -0.3826834323650898),
];

// Fonte 3x5 para os dígitos do placar.
const DIGITS: [&str; 10] = [
    "111101101101111", "001001001001001", "111001111100111", "111001111001111",
    "101101111001001", "111100111001111", "111100111101111", "111001001001001",
    "111101111101111", "111101111001111",
];

const BG: Color = Color::RGB(0, 0, 0);
const WALL_COLOR: Color = Color::RGB(180, 140, 60);
const HUD_COLOR: Color = Color::RGB(230, 230, 230);
const TANK_COLORS: [Color; 2] = [Color::RGB(90, 200, 90), Color::RGB(110, 150, 255)];

struct Controls {
    fwd: Scancode,
    left: Scancode,
    right: Scancode,
    fire: Scancode,
}

const CONTROLS: [Controls; 2] = [
    Controls { fwd: Scancode::W, left: Scancode::A, right: Scancode::D, fire: Scancode::Space },
    Controls { fwd: Scancode::Up, left: Scancode::Left, right: Scancode::Right, fire: Scancode::Return },
];

// Onda quadrada mono S16.
fn square_wave(freq: i32, ms: i32) -> Vec<i16> {
    let n = (RATE * ms / 1000) as usize;
    (0..n)
        .map(|i| if (i * 2 * freq as usize / RATE as usize) % 2 == 1 { 4000 } else { -4000 })
        .collect()
}

// Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
// decaindo até zero; `hold` = amostras por bit (maior = mais grave).
fn noise(ms: i32, hold: i32) -> Vec<i16> {
    let n = RATE * ms / 1000;
    let (mut lfsr, mut bit) = (0xACE1u32, 0u32);
    (0..n)
        .map(|i| {
            if i % hold == 0 {
                bit = lfsr & 1;
                lfsr >>= 1;
                if bit == 1 {
                    lfsr ^= 0xB400;
                }
            }
            let amp = (4000 * (n - i) / n) as i16;
            if bit == 1 { amp } else { -amp }
        })
        .collect()
}

fn overlaps(a: (f64, f64, f64, f64), b: (f64, f64, f64, f64)) -> bool {
    a.0 < b.0 + b.2 && a.0 + a.2 > b.0 && a.1 < b.1 + b.3 && a.1 + a.3 > b.1
}

fn hits_wall(r: (f64, f64, f64, f64)) -> bool {
    WALLS.iter().any(|&(x, y, w, h)| overlaps(r, (x as f64, y as f64, w as f64, h as f64)))
}

fn dir_angle(dir: i32) -> f64 {
    dir as f64 * 2.0 * PI / 16.0
}

fn tank_box(x: f64, y: f64) -> (f64, f64, f64, f64) {
    (x - TANK_HALF, y - TANK_HALF, 2.0 * TANK_HALF, 2.0 * TANK_HALF)
}

#[derive(Default, Clone, Copy)]
struct Bullet {
    active: bool,
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    life: f64,
}

#[derive(Default, Clone, Copy)]
struct Tank {
    x: f64,
    y: f64,
    dir: i32,
    rot_timer: f64,
    fire_prev: bool,
    spin: f64,
    spin_step: f64,
    push_x: f64,
    push_y: f64,
    score: u32,
    bullet: Bullet,
}

impl Tank {
    fn new(x: f64, y: f64, dir: i32) -> Self {
        Tank { x, y, dir, ..Default::default() }
    }
}

struct Sounds {
    queue: Option<AudioQueue<i16>>,
    shot: Vec<i16>,
    hit: Vec<i16>,
    ricochet: Vec<i16>,
    end: Vec<i16>,
}

impl Sounds {
    fn play(&self, s: &[i16]) {
        if let Some(q) = &self.queue {
            q.clear();
            let _ = q.queue_audio(s);
        }
    }
}

struct Game {
    tanks: [Tank; 2],
    mode: u32, // 1 = normal, 2 = ricochete
    time_left: f64,
    blink: f64,
    game_over: bool,
}

impl Game {
    fn new() -> Self {
        let mut g = Game { tanks: [Tank::default(); 2], mode: 1, time_left: 0.0, blink: 0.0, game_over: false };
        g.new_match(1);
        g
    }

    fn new_match(&mut self, mode: u32) {
        self.mode = mode;
        self.time_left = MATCH_TIME;
        self.game_over = false;
        self.tanks = [Tank::new(60.0, 264.0, 0), Tank::new(580.0, 264.0, 8)];
    }

    fn blocked(other: &Tank, x: f64, y: f64) -> bool {
        hits_wall(tank_box(x, y)) || overlaps(tank_box(x, y), tank_box(other.x, other.y))
    }

    // Move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
    fn try_move(t: &mut Tank, other: &Tank, dx: f64, dy: f64) {
        if !Self::blocked(other, t.x + dx, t.y) {
            t.x += dx;
        }
        if !Self::blocked(other, t.x, t.y + dy) {
            t.y += dy;
        }
    }

    fn update_tank(&mut self, i: usize, keys: &KeyboardState, dt: f64, snd: &Sounds) {
        let [a, b] = &mut self.tanks;
        let (t, other) = if i == 0 { (a, b) } else { (b, a) };
        let c = &CONTROLS[i];
        let fire = keys.is_scancode_pressed(c.fire);

        if t.spin > 0.0 {
            // Atingido: gira sozinho e é empurrado para trás.
            t.spin -= dt;
            t.spin_step -= dt;
            if t.spin_step <= 0.0 {
                t.dir = (t.dir + 1) % 16;
                t.spin_step += SPIN_STEP;
            }
            let (px, py) = (t.push_x * dt, t.push_y * dt);
            Self::try_move(t, other, px, py);
        } else {
            let turn = keys.is_scancode_pressed(c.right) as i32 - keys.is_scancode_pressed(c.left) as i32;
            if turn != 0 {
                t.rot_timer -= dt;
                if t.rot_timer <= 0.0 {
                    t.dir = (t.dir + turn).rem_euclid(16);
                    t.rot_timer += ROT_TIME;
                }
            } else {
                t.rot_timer = 0.0;
            }
            let (dc, ds) = DIR_TABLE[t.dir as usize];
            if keys.is_scancode_pressed(c.fwd) {
                Self::try_move(t, other, dc * TANK_SPEED * dt, ds * TANK_SPEED * dt);
            }
            if fire && !t.fire_prev && !t.bullet.active {
                let bx = t.x + dc * 20.0 - BULLET_SIZE / 2.0;
                let by = t.y + ds * 20.0 - BULLET_SIZE / 2.0;
                // Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
                if !hits_wall((bx, by, BULLET_SIZE, BULLET_SIZE)) {
                    t.bullet = Bullet {
                        active: true,
                        x: bx,
                        y: by,
                        vx: dc * BULLET_SPEED,
                        vy: ds * BULLET_SPEED,
                        life: BULLET_LIFE,
                    };
                    snd.play(&snd.shot);
                }
            }
        }
        t.fire_prev = fire;

        let b = &mut t.bullet;
        if !b.active {
            return;
        }
        b.life -= dt;
        if b.life <= 0.0 {
            b.active = false;
            return;
        }
        // Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
        b.x += b.vx * dt;
        if hits_wall((b.x, b.y, BULLET_SIZE, BULLET_SIZE)) {
            if self.mode != 2 {
                b.active = false;
                return;
            }
            b.x -= b.vx * dt;
            b.vx = -b.vx;
            snd.play(&snd.ricochet);
        }
        b.y += b.vy * dt;
        if hits_wall((b.x, b.y, BULLET_SIZE, BULLET_SIZE)) {
            if self.mode != 2 {
                b.active = false;
                return;
            }
            b.y -= b.vy * dt;
            b.vy = -b.vy;
            snd.play(&snd.ricochet);
        }
        if other.spin <= 0.0 && overlaps((b.x, b.y, BULLET_SIZE, BULLET_SIZE), tank_box(other.x, other.y)) {
            t.score += 1;
            let len = (b.vx * b.vx + b.vy * b.vy).sqrt();
            other.spin = SPIN_TIME;
            other.spin_step = 0.0;
            other.push_x = b.vx / len * PUSH_SPEED;
            other.push_y = b.vy / len * PUSH_SPEED;
            b.active = false;
            snd.play(&snd.hit);
        }
    }

    fn update(&mut self, keys: &KeyboardState, dt: f64, snd: &Sounds) {
        if keys.is_scancode_pressed(Scancode::Num1) {
            self.new_match(1);
        }
        if keys.is_scancode_pressed(Scancode::Num2) {
            self.new_match(2);
        }
        self.blink += dt;
        if self.game_over {
            return;
        }
        self.time_left -= dt;
        if self.time_left <= 0.0 {
            self.time_left = 0.0;
            self.game_over = true;
            snd.play(&snd.end);
            return;
        }
        self.update_tank(0, keys, dt, snd);
        self.update_tank(1, keys, dt, snd);
    }
}

fn fill(c: &mut WindowCanvas, x: i32, y: i32, w: i32, h: i32) {
    let _ = c.fill_rect(Rect::new(x, y, w.max(0) as u32, h as u32));
}

// Desenha um número com blocos de tamanho s; align_right=true faz o número terminar em x.
fn draw_number(c: &mut WindowCanvas, n: u32, mut x: i32, y: i32, s: i32, align_right: bool) {
    let text = n.to_string();
    let len = text.len() as i32;
    if align_right {
        x -= len * 3 * s + (len - 1) * s;
    }
    for ch in text.bytes() {
        let g = DIGITS[(ch - b'0') as usize].as_bytes();
        for i in 0..15 {
            if g[i] == b'1' {
                fill(c, x + (i as i32 % 3) * s, y + (i as i32 / 3) * s, s, s);
            }
        }
        x += 4 * s;
    }
}

// Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
// rotacionado de volta para o referencial do tanque, cai dentro da forma.
// Dá o visual blocado do 2600 em qualquer uma das 16 direções.
fn draw_tank(c: &mut WindowCanvas, t: &Tank) {
    let a = dir_angle(t.dir);
    let (cs, sn) = (a.cos(), a.sin());
    let x0 = t.x as i32 - TANK_GRID * TANK_CELL / 2;
    let y0 = t.y as i32 - TANK_GRID * TANK_CELL / 2;
    let half = (TANK_GRID - 1) as f64 / 2.0;
    for i in 0..TANK_GRID {
        for j in 0..TANK_GRID {
            let px = (j as f64 - half) * TANK_CELL as f64;
            let py = (i as f64 - half) * TANK_CELL as f64;
            let (u, v) = (px * cs + py * sn, -px * sn + py * cs);
            if TANK_SHAPE.iter().any(|&(x0b, y0b, x1b, y1b)| u >= x0b && u < x1b && v >= y0b && v < y1b) {
                fill(c, x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL);
            }
        }
    }
}

fn render(c: &mut WindowCanvas, g: &Game) {
    c.set_draw_color(BG);
    c.clear();

    c.set_draw_color(WALL_COLOR);
    for &(x, y, w, h) in WALLS.iter() {
        fill(c, x, y, w, h);
    }

    for (i, t) in g.tanks.iter().enumerate() {
        c.set_draw_color(TANK_COLORS[i]);
        draw_tank(c, t);
        if t.bullet.active {
            let s = BULLET_SIZE as i32;
            fill(c, t.bullet.x as i32, t.bullet.y as i32, s, s);
        }
        // No fim da partida o placar pisca.
        if !g.game_over || g.blink % 0.5 < 0.25 {
            draw_number(c, t.score, if i == 0 { 40 } else { 600 }, 6, 6, i == 1);
        }
    }

    c.set_draw_color(HUD_COLOR);
    draw_number(c, g.mode, 314, 8, 4, false);
    fill(c, 220, 36, (200.0 * g.time_left / MATCH_TIME) as i32, 4);
    c.present();
}

fn main() -> Result<(), String> {
    let sdl = sdl2::init()?;
    let video = sdl.video()?;
    let window = video
        .window("Tanques - Rust", W, H)
        .position_centered()
        .build()
        .map_err(|e| e.to_string())?;
    let mut canvas = window
        .into_canvas()
        .accelerated()
        .present_vsync()
        .build()
        .map_err(|e| e.to_string())?;

    let spec = AudioSpecDesired { freq: Some(RATE), channels: Some(1), samples: Some(1024) };
    let queue = sdl
        .audio()
        .and_then(|a| a.open_queue::<i16, _>(None, &spec))
        .map_err(|e| eprintln!("sem áudio: {e}"))
        .ok();
    if let Some(q) = &queue {
        q.resume();
    }
    let snd = Sounds {
        queue,
        shot: noise(90, 3),
        hit: noise(500, 20),
        ricochet: square_wave(1200, 25),
        end: square_wave(220, 700),
    };

    let mut events = sdl.event_pump()?;
    let mut game = Game::new();
    let mut last = Instant::now();
    let mut acc = 0.0;
    'running: loop {
        for e in events.poll_iter() {
            if let Event::Quit { .. } = e {
                break 'running;
            }
        }
        let keys = events.keyboard_state();
        if keys.is_scancode_pressed(Scancode::Escape) {
            break;
        }

        let now = Instant::now();
        acc += now.duration_since(last).as_secs_f64().min(0.25);
        last = now;
        while acc >= STEP {
            game.update(&keys, STEP, &snd);
            acc -= STEP;
        }
        render(&mut canvas, &game);
    }
    Ok(())
}
