import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;

import static java.lang.foreign.ValueLayout.JAVA_BYTE;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

/**
 * Tanques em Java com SDL2, chamando a libSDL2 via API FFM (Java 22+).
 * Inspirado no Combat (Atari 2600, 1977).
 */
public final class Tanques {
    static final int W = 640, H = 480;
    static final int TANK_GRID = 22, TANK_CELL = 2;  // tanque desenhado em 22x22 blocos de 2px
    static final double TANK_HALF = 12;               // hitbox 24x24
    static final double TANK_SPEED = 90.0;            // px/s
    static final double ROT_TIME = 0.09;              // s por passo de giro (16 direções)
    static final double BULLET_SPEED = 320.0;
    static final int BULLET_SIZE = 4;
    static final double BULLET_LIFE = 1.6;
    static final double SPIN_TIME = 1.0, SPIN_STEP = 0.04, PUSH_SPEED = 110.0;
    static final double MATCH_TIME = 136.0;  // 2:16, como no Combat
    static final double STEP = 1.0 / 120.0;
    static final int RATE = 44100;

    // Bordas da arena e obstáculos {x, y, w, h}, simétricos nos dois eixos.
    static final int[][] WALLS = {
        {0, 48, 640, 8}, {0, 472, 640, 8}, {0, 48, 8, 432}, {632, 48, 8, 432},
        {120, 120, 16, 80}, {504, 120, 16, 80}, {120, 328, 16, 80}, {504, 328, 16, 80},
        {256, 136, 128, 16}, {256, 376, 128, 16}, {312, 232, 16, 64},
    };

    // Forma do tanque em px {x0, y0, x1, y1}, centrada na origem e apontando
    // para +x: duas esteiras, corpo e canhão.
    static final double[][] TANK_SHAPE = {
        {-14, -14, 12, -7}, {-14, 7, 12, 14}, {-10, -7, 7, 7}, {0, -2, 20, 2},
    };

    // Fonte 3x5 para os dígitos do placar.
    static final String[] DIGITS = {
        "111101101101111", "001001001001001", "111001111100111", "111001111001111",
        "101101111001001", "111100111001111", "111100111101111", "111001001001001",
        "111101111101111", "111101111001111",
    };

    record Color(int r, int g, int b) {}

    static final Color BG = new Color(0, 0, 0), WALL_COLOR = new Color(180, 140, 60),
            HUD_COLOR = new Color(230, 230, 230);
    static final Color[] TANK_COLORS = {new Color(90, 200, 90), new Color(110, 150, 255)};

    record Controls(int fwd, int left, int right, int fire) {}

    static final Controls[] CONTROLS = {
        new Controls(Sdl.SCANCODE_W, Sdl.SCANCODE_A, Sdl.SCANCODE_D, Sdl.SCANCODE_SPACE),
        new Controls(Sdl.SCANCODE_UP, Sdl.SCANCODE_LEFT, Sdl.SCANCODE_RIGHT, Sdl.SCANCODE_RETURN),
    };

    /** Onda quadrada mono S16. */
    static short[] squareWave(int freq, int ms) {
        short[] buf = new short[RATE * ms / 1000];
        for (int i = 0; i < buf.length; i++)
            buf[i] = (short) (((long) i * 2 * freq / RATE) % 2 == 1 ? 4000 : -4000);
        return buf;
    }

    /**
     * Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
     * decaindo até zero; hold = amostras por bit (maior = mais grave).
     */
    static short[] noise(int ms, int hold) {
        int n = RATE * ms / 1000;
        short[] buf = new short[n];
        int lfsr = 0xACE1, bit = 0;
        for (int i = 0; i < n; i++) {
            if (i % hold == 0) {
                bit = lfsr & 1;
                lfsr >>>= 1;
                if (bit == 1) lfsr ^= 0xB400;
            }
            int amp = 4000 * (n - i) / n;
            buf[i] = (short) (bit == 1 ? amp : -amp);
        }
        return buf;
    }

    static boolean overlaps(double ax, double ay, double aw, double ah, double bx, double by, double bw, double bh) {
        return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;
    }

    static boolean hitsWall(double x, double y, double w, double h) {
        for (int[] r : WALLS)
            if (overlaps(x, y, w, h, r[0], r[1], r[2], r[3])) return true;
        return false;
    }

    static double dirAngle(int dir) { return dir * 2 * Math.PI / 16; }

    /** Teclado: um byte por scancode (estado da SDL, ou um array nos testes). */
    interface Keys { boolean pressed(int scancode); }

    static final class Bullet {
        boolean active;
        double x, y, vx, vy, life;
    }

    static final class Tank {
        double x, y;
        int dir;
        double rotTimer;
        boolean firePrev;
        double spin, spinStep, pushX, pushY;
        int score;
        final Bullet bullet = new Bullet();

        Tank(double x, double y, int dir) { this.x = x; this.y = y; this.dir = dir; }
    }

    /** Toca um som; a implementação real enfileira na SDL. */
    interface Audio { void play(short[] samples); }

    static final class Game {
        final Tank[] tanks = new Tank[2];
        int mode = 1;  // 1 = normal, 2 = ricochete
        double timeLeft, blink;
        boolean gameOver;

        final Audio audio;
        final short[] sndShot = noise(90, 3), sndHit = noise(500, 20);
        final short[] sndRicochet = squareWave(1200, 25), sndEnd = squareWave(220, 700);

        Game(Audio audio) {
            this.audio = audio;
            newMatch(1);
        }

        void newMatch(int m) {
            mode = m;
            timeLeft = MATCH_TIME;
            gameOver = false;
            tanks[0] = new Tank(60, 264, 0);
            tanks[1] = new Tank(580, 264, 8);
        }

        static boolean blocked(Tank other, double x, double y) {
            final double s = 2 * TANK_HALF;
            return hitsWall(x - TANK_HALF, y - TANK_HALF, s, s)
                    || overlaps(x - TANK_HALF, y - TANK_HALF, s, s, other.x - TANK_HALF, other.y - TANK_HALF, s, s);
        }

        /** Move um eixo de cada vez, para o tanque deslizar ao longo das paredes. */
        static void tryMove(Tank t, Tank other, double dx, double dy) {
            if (!blocked(other, t.x + dx, t.y)) t.x += dx;
            if (!blocked(other, t.x, t.y + dy)) t.y += dy;
        }

        void updateTank(int i, Keys keys, double dt) {
            Tank t = tanks[i], other = tanks[1 - i];
            Controls c = CONTROLS[i];
            boolean fire = keys.pressed(c.fire());

            if (t.spin > 0) {
                // Atingido: gira sozinho e é empurrado para trás.
                t.spin -= dt;
                t.spinStep -= dt;
                if (t.spinStep <= 0) {
                    t.dir = (t.dir + 1) % 16;
                    t.spinStep += SPIN_STEP;
                }
                tryMove(t, other, t.pushX * dt, t.pushY * dt);
            } else {
                int turn = (keys.pressed(c.right()) ? 1 : 0) - (keys.pressed(c.left()) ? 1 : 0);
                if (turn != 0) {
                    t.rotTimer -= dt;
                    if (t.rotTimer <= 0) {
                        t.dir = Math.floorMod(t.dir + turn, 16);
                        t.rotTimer += ROT_TIME;
                    }
                } else {
                    t.rotTimer = 0;
                }
                double a = dirAngle(t.dir);
                if (keys.pressed(c.fwd())) tryMove(t, other, Math.cos(a) * TANK_SPEED * dt, Math.sin(a) * TANK_SPEED * dt);
                if (fire && !t.firePrev && !t.bullet.active) {
                    double bx = t.x + Math.cos(a) * 20 - BULLET_SIZE / 2.0;
                    double by = t.y + Math.sin(a) * 20 - BULLET_SIZE / 2.0;
                    // Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
                    if (!hitsWall(bx, by, BULLET_SIZE, BULLET_SIZE)) {
                        Bullet b = t.bullet;
                        b.active = true;
                        b.x = bx;
                        b.y = by;
                        b.vx = Math.cos(a) * BULLET_SPEED;
                        b.vy = Math.sin(a) * BULLET_SPEED;
                        b.life = BULLET_LIFE;
                        audio.play(sndShot);
                    }
                }
            }
            t.firePrev = fire;

            Bullet b = t.bullet;
            if (!b.active) return;
            b.life -= dt;
            if (b.life <= 0) { b.active = false; return; }
            // Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
            b.x += b.vx * dt;
            if (hitsWall(b.x, b.y, BULLET_SIZE, BULLET_SIZE)) {
                if (mode != 2) { b.active = false; return; }
                b.x -= b.vx * dt;
                b.vx = -b.vx;
                audio.play(sndRicochet);
            }
            b.y += b.vy * dt;
            if (hitsWall(b.x, b.y, BULLET_SIZE, BULLET_SIZE)) {
                if (mode != 2) { b.active = false; return; }
                b.y -= b.vy * dt;
                b.vy = -b.vy;
                audio.play(sndRicochet);
            }
            if (other.spin <= 0 && overlaps(b.x, b.y, BULLET_SIZE, BULLET_SIZE,
                    other.x - TANK_HALF, other.y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF)) {
                t.score++;
                double len = Math.hypot(b.vx, b.vy);
                other.spin = SPIN_TIME;
                other.spinStep = 0;
                other.pushX = b.vx / len * PUSH_SPEED;
                other.pushY = b.vy / len * PUSH_SPEED;
                b.active = false;
                audio.play(sndHit);
            }
        }

        void update(Keys keys, double dt) {
            if (keys.pressed(Sdl.SCANCODE_1)) newMatch(1);
            if (keys.pressed(Sdl.SCANCODE_2)) newMatch(2);
            blink += dt;
            if (gameOver) return;
            timeLeft -= dt;
            if (timeLeft <= 0) {
                timeLeft = 0;
                gameOver = true;
                audio.play(sndEnd);
                return;
            }
            updateTank(0, keys, dt);
            updateTank(1, keys, dt);
        }
    }

    static final class Renderer {
        final MemorySegment r, rect;

        Renderer(Arena arena, MemorySegment r) {
            this.r = r;
            this.rect = arena.allocate(16);  // SDL_Rect = 4 x int
        }

        void setColor(Color c) { Sdl.setRenderDrawColor(r, c.r(), c.g(), c.b(), 255); }

        void fill(double x, double y, int w, int h) {
            rect.set(JAVA_INT, 0, (int) x);
            rect.set(JAVA_INT, 4, (int) y);
            rect.set(JAVA_INT, 8, w);
            rect.set(JAVA_INT, 12, h);
            Sdl.renderFillRect(r, rect);
        }

        /** Desenha um número com blocos de tamanho s; alignRight=true faz o número terminar em x. */
        void drawNumber(int n, int x, int y, int s, boolean alignRight) {
            String text = Integer.toString(n);
            if (alignRight) x -= text.length() * 3 * s + (text.length() - 1) * s;
            for (char c : text.toCharArray()) {
                String g = DIGITS[c - '0'];
                for (int i = 0; i < 15; i++)
                    if (g.charAt(i) == '1') fill(x + (i % 3) * s, y + (i / 3) * s, s, s);
                x += 4 * s;
            }
        }

        /**
         * Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
         * rotacionado de volta para o referencial do tanque, cai dentro da forma.
         * Dá o visual blocado do 2600 em qualquer uma das 16 direções.
         */
        void drawTank(Tank t) {
            double a = dirAngle(t.dir), c = Math.cos(a), s = Math.sin(a);
            int x0 = (int) t.x - TANK_GRID * TANK_CELL / 2, y0 = (int) t.y - TANK_GRID * TANK_CELL / 2;
            final double half = (TANK_GRID - 1) / 2.0;
            for (int i = 0; i < TANK_GRID; i++) {
                for (int j = 0; j < TANK_GRID; j++) {
                    double px = (j - half) * TANK_CELL, py = (i - half) * TANK_CELL;
                    double u = px * c + py * s, v = -px * s + py * c;
                    for (double[] b : TANK_SHAPE) {
                        if (u >= b[0] && u < b[2] && v >= b[1] && v < b[3]) {
                            fill(x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL);
                            break;
                        }
                    }
                }
            }
        }

        void render(Game g) {
            setColor(BG);
            Sdl.renderClear(r);

            setColor(WALL_COLOR);
            for (int[] w : WALLS) fill(w[0], w[1], w[2], w[3]);

            for (int i = 0; i < 2; i++) {
                Tank t = g.tanks[i];
                setColor(TANK_COLORS[i]);
                drawTank(t);
                if (t.bullet.active) fill(t.bullet.x, t.bullet.y, BULLET_SIZE, BULLET_SIZE);
                // No fim da partida o placar pisca.
                if (!g.gameOver || g.blink % 0.5 < 0.25) drawNumber(t.score, i == 0 ? 40 : 600, 6, 6, i == 1);
            }

            setColor(HUD_COLOR);
            drawNumber(g.mode, 314, 8, 4, false);
            fill(220, 36, (int) (200 * g.timeLeft / MATCH_TIME), 4);
            Sdl.renderPresent(r);
        }
    }

    public static void main(String[] args) {
        try (Arena arena = Arena.ofConfined()) {
            System.exit(run(arena));
        }
    }

    static int run(Arena arena) {
        if (Sdl.init(Sdl.INIT_VIDEO | Sdl.INIT_AUDIO) != 0) {
            System.err.println("SDL_Init: " + Sdl.getError());
            return 1;
        }
        MemorySegment win = Sdl.createWindow(arena.allocateFrom("Tanques - Java"), Sdl.WINDOWPOS_CENTERED,
                Sdl.WINDOWPOS_CENTERED, W, H, Sdl.WINDOW_SHOWN);
        MemorySegment ren = win.equals(MemorySegment.NULL) ? MemorySegment.NULL
                : Sdl.createRenderer(win, -1, Sdl.RENDERER_ACCELERATED | Sdl.RENDERER_PRESENTVSYNC);
        if (ren.equals(MemorySegment.NULL)) {
            System.err.println("janela/renderer: " + Sdl.getError());
            return 1;
        }

        // SDL_AudioSpec: freq (0), format (4), channels (6), samples (8); 32 bytes no total.
        MemorySegment want = arena.allocate(32);
        want.set(JAVA_INT, 0, RATE);
        want.set(JAVA_SHORT, 4, (short) Sdl.AUDIO_S16LSB);
        want.set(JAVA_BYTE, 6, (byte) 1);
        want.set(JAVA_SHORT, 8, (short) 1024);
        int dev = Sdl.openAudioDevice(want);
        if (dev != 0) Sdl.pauseAudioDevice(dev, 0);
        else System.err.println("sem áudio: " + Sdl.getError());

        // Cada som é copiado uma vez para memória nativa e reaproveitado.
        var cache = new java.util.IdentityHashMap<short[], MemorySegment>();
        Audio audio = samples -> {
            if (dev == 0) return;
            Sdl.clearQueuedAudio(dev);
            Sdl.queueAudio(dev, cache.computeIfAbsent(samples, s -> arena.allocateFrom(JAVA_SHORT, s)));
        };

        Game game = new Game(audio);
        Renderer renderer = new Renderer(arena, ren);

        MemorySegment event = arena.allocate(Sdl.EVENT_SIZE);
        MemorySegment state = Sdl.getKeyboardState();
        Keys keys = sc -> state.get(JAVA_BYTE, sc) != 0;
        double freq = Sdl.getPerformanceFrequency();
        long last = Sdl.getPerformanceCounter();
        double acc = 0;
        boolean running = true;
        while (running) {
            while (Sdl.pollEvent(event) != 0)
                if (event.get(JAVA_INT, 0) == Sdl.QUIT) running = false;
            if (keys.pressed(Sdl.SCANCODE_ESCAPE)) running = false;

            long now = Sdl.getPerformanceCounter();
            acc += Math.min((now - last) / freq, 0.25);
            last = now;
            while (acc >= STEP) {
                game.update(keys, STEP);
                acc -= STEP;
            }
            renderer.render(game);
        }

        if (dev != 0) Sdl.closeAudioDevice(dev);
        Sdl.destroyRenderer(ren);
        Sdl.destroyWindow(win);
        Sdl.quit();
        return 0;
    }
}
