// Tanques em C# com SDL2, chamando a libSDL2 via P/Invoke.
// Inspirado no Combat (Atari 2600, 1977).
using System;

unsafe class Tanques
{
    const int W = 640, H = 480;
    const int TANK_GRID = 22, TANK_CELL = 2;  // tanque desenhado em 22x22 blocos de 2px
    const double TANK_HALF = 12;              // hitbox 24x24
    const double TANK_SPEED = 90.0;           // px/s
    const double ROT_TIME = 0.09;             // s por passo de giro (16 direções)
    const double BULLET_SPEED = 320.0;
    const int BULLET_SIZE = 4;
    const double BULLET_LIFE = 1.6;
    const double SPIN_TIME = 1.0, SPIN_STEP = 0.04, PUSH_SPEED = 110.0;
    const double MATCH_TIME = 136.0;  // 2:16, como no Combat
    const double STEP = 1.0 / 120.0;
    const int RATE = 44100;

    // Bordas da arena e obstáculos (x, y, w, h), simétricos nos dois eixos.
    static readonly (int X, int Y, int W, int H)[] Walls =
    [
        (0, 48, 640, 8), (0, 472, 640, 8), (0, 48, 8, 432), (632, 48, 8, 432),
        (120, 120, 16, 80), (504, 120, 16, 80), (120, 328, 16, 80), (504, 328, 16, 80),
        (256, 136, 128, 16), (256, 376, 128, 16), (312, 232, 16, 64),
    ];

    // Forma do tanque em px (x0, y0, x1, y1), centrada na origem e apontando
    // para +x: duas esteiras, corpo e canhão.
    static readonly (double X0, double Y0, double X1, double Y1)[] TankShape =
        [(-14, -14, 12, -7), (-14, 7, 12, 14), (-10, -7, 7, 7), (0, -2, 20, 2)];

    // (cosseno, seno) das 16 direções, a cada 22,5°. Valores literais: sin/cos das
    // bibliotecas diferem no último bit entre as linguagens, e as versões passariam
    // a divergir. Assim também o tanque anda em linha reta nas 4 direções cardeais.
    static readonly (double Cos, double Sin)[] DirTable =
    [
    (1, 0), (0.9238795325112867, 0.3826834323650898),
    (0.7071067811865476, 0.7071067811865476), (0.3826834323650898, 0.9238795325112867),
    (0, 1), (-0.3826834323650898, 0.9238795325112867),
    (-0.7071067811865476, 0.7071067811865476), (-0.9238795325112867, 0.3826834323650898),
    (-1, 0), (-0.9238795325112867, -0.3826834323650898),
    (-0.7071067811865476, -0.7071067811865476), (-0.3826834323650898, -0.9238795325112867),
    (0, -1), (0.3826834323650898, -0.9238795325112867),
    (0.7071067811865476, -0.7071067811865476), (0.9238795325112867, -0.3826834323650898),
    ];


    // Fonte 3x5 para os dígitos do placar.
    static readonly string[] Digits =
    [
        "111101101101111", "001001001001001", "111001111100111", "111001111001111",
        "101101111001001", "111100111001111", "111100111101111", "111001001001001",
        "111101111101111", "111101111001111",
    ];

    static readonly (byte R, byte G, byte B) Bg = (0, 0, 0), WallColor = (180, 140, 60), HudColor = (230, 230, 230);
    static readonly (byte R, byte G, byte B)[] TankColors = [(90, 200, 90), (110, 150, 255)];

    // (frente, esquerda, direita, tiro) de cada jogador.
    static readonly (int Fwd, int Left, int Right, int Fire)[] Controls =
    [
        (Sdl.SCANCODE_W, Sdl.SCANCODE_A, Sdl.SCANCODE_D, Sdl.SCANCODE_SPACE),
        (Sdl.SCANCODE_UP, Sdl.SCANCODE_LEFT, Sdl.SCANCODE_RIGHT, Sdl.SCANCODE_RETURN),
    ];

    // Onda quadrada mono S16.
    static short[] SquareWave(int freq, int ms)
    {
        var buf = new short[RATE * ms / 1000];
        for (int i = 0; i < buf.Length; i++)
            buf[i] = (short)(((long)i * 2 * freq / RATE) % 2 == 1 ? 4000 : -4000);
        return buf;
    }

    // Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
    // decaindo até zero; hold = amostras por bit (maior = mais grave).
    static short[] Noise(int ms, int hold)
    {
        int n = RATE * ms / 1000;
        var buf = new short[n];
        uint lfsr = 0xACE1, bit = 0;
        for (int i = 0; i < n; i++)
        {
            if (i % hold == 0)
            {
                bit = lfsr & 1;
                lfsr >>= 1;
                if (bit == 1) lfsr ^= 0xB400;
            }
            int amp = 4000 * (n - i) / n;
            buf[i] = (short)(bit == 1 ? amp : -amp);
        }
        return buf;
    }

    static bool Overlaps(double ax, double ay, double aw, double ah, double bx, double by, double bw, double bh) =>
        ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;

    static bool HitsWall(double x, double y, double w, double h)
    {
        foreach (var r in Walls)
            if (Overlaps(x, y, w, h, r.X, r.Y, r.W, r.H)) return true;
        return false;
    }

    static double DirAngle(int dir) => dir * 2 * Math.PI / 16;

    sealed class Bullet
    {
        public bool Active;
        public double X, Y, Vx, Vy, Life;
    }

    sealed class Tank(double x, double y, int dir)
    {
        public double X = x, Y = y;
        public int Dir = dir;
        public double RotTimer;
        public bool FirePrev;
        public double Spin, SpinStep, PushX, PushY;
        public int Score;
        public readonly Bullet Bullet = new();
    }

    // Toca um som; a implementação real enfileira na SDL.
    sealed class Game(Action<short[]> play)
    {
        public readonly Tank[] Tanks = new Tank[2];
        public int Mode;  // 1 = normal, 2 = ricochete
        public double TimeLeft, Blink;
        public bool GameOver;

        readonly short[] sndShot = Noise(90, 3), sndHit = Noise(500, 20);
        readonly short[] sndRicochet = SquareWave(1200, 25), sndEnd = SquareWave(220, 700);

        public void NewMatch(int m)
        {
            Mode = m;
            TimeLeft = MATCH_TIME;
            GameOver = false;
            Tanks[0] = new Tank(60, 264, 0);
            Tanks[1] = new Tank(580, 264, 8);
        }

        static bool Blocked(Tank other, double x, double y)
        {
            const double s = 2 * TANK_HALF;
            return HitsWall(x - TANK_HALF, y - TANK_HALF, s, s)
                || Overlaps(x - TANK_HALF, y - TANK_HALF, s, s, other.X - TANK_HALF, other.Y - TANK_HALF, s, s);
        }

        // Move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
        static void TryMove(Tank t, Tank other, double dx, double dy)
        {
            if (!Blocked(other, t.X + dx, t.Y)) t.X += dx;
            if (!Blocked(other, t.X, t.Y + dy)) t.Y += dy;
        }

        void UpdateTank(int i, byte* keys, double dt)
        {
            Tank t = Tanks[i], other = Tanks[1 - i];
            var c = Controls[i];
            bool fire = keys[c.Fire] != 0;

            if (t.Spin > 0)
            {
                // Atingido: gira sozinho e é empurrado para trás.
                t.Spin -= dt;
                t.SpinStep -= dt;
                if (t.SpinStep <= 0)
                {
                    t.Dir = (t.Dir + 1) % 16;
                    t.SpinStep += SPIN_STEP;
                }
                TryMove(t, other, t.PushX * dt, t.PushY * dt);
            }
            else
            {
                int turn = (keys[c.Right] != 0 ? 1 : 0) - (keys[c.Left] != 0 ? 1 : 0);
                if (turn != 0)
                {
                    t.RotTimer -= dt;
                    if (t.RotTimer <= 0)
                    {
                        t.Dir = (t.Dir + turn + 16) % 16;
                        t.RotTimer += ROT_TIME;
                    }
                }
                else
                {
                    t.RotTimer = 0;
                }
                var (dc, ds) = DirTable[t.Dir];
                if (keys[c.Fwd] != 0) TryMove(t, other, dc * TANK_SPEED * dt, ds * TANK_SPEED * dt);
                if (fire && !t.FirePrev && !t.Bullet.Active)
                {
                    double bx = t.X + dc * 20 - BULLET_SIZE / 2.0;
                    double by = t.Y + ds * 20 - BULLET_SIZE / 2.0;
                    // Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
                    if (!HitsWall(bx, by, BULLET_SIZE, BULLET_SIZE))
                    {
                        var nb = t.Bullet;
                        nb.Active = true;
                        nb.X = bx;
                        nb.Y = by;
                        nb.Vx = dc * BULLET_SPEED;
                        nb.Vy = ds * BULLET_SPEED;
                        nb.Life = BULLET_LIFE;
                        play(sndShot);
                    }
                }
            }
            t.FirePrev = fire;

            var b = t.Bullet;
            if (!b.Active) return;
            b.Life -= dt;
            if (b.Life <= 0) { b.Active = false; return; }
            // Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
            b.X += b.Vx * dt;
            if (HitsWall(b.X, b.Y, BULLET_SIZE, BULLET_SIZE))
            {
                if (Mode != 2) { b.Active = false; return; }
                b.X -= b.Vx * dt;
                b.Vx = -b.Vx;
                play(sndRicochet);
            }
            b.Y += b.Vy * dt;
            if (HitsWall(b.X, b.Y, BULLET_SIZE, BULLET_SIZE))
            {
                if (Mode != 2) { b.Active = false; return; }
                b.Y -= b.Vy * dt;
                b.Vy = -b.Vy;
                play(sndRicochet);
            }
            if (other.Spin <= 0 && Overlaps(b.X, b.Y, BULLET_SIZE, BULLET_SIZE,
                    other.X - TANK_HALF, other.Y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF))
            {
                t.Score++;
                double len = Math.Sqrt(b.Vx * b.Vx + b.Vy * b.Vy);
                other.Spin = SPIN_TIME;
                other.SpinStep = 0;
                other.PushX = b.Vx / len * PUSH_SPEED;
                other.PushY = b.Vy / len * PUSH_SPEED;
                b.Active = false;
                play(sndHit);
            }
        }

        public void Update(byte* keys, double dt)
        {
            if (keys[Sdl.SCANCODE_1] != 0) NewMatch(1);
            if (keys[Sdl.SCANCODE_2] != 0) NewMatch(2);
            Blink += dt;
            if (GameOver) return;
            TimeLeft -= dt;
            if (TimeLeft <= 0)
            {
                TimeLeft = 0;
                GameOver = true;
                play(sndEnd);
                return;
            }
            UpdateTank(0, keys, dt);
            UpdateTank(1, keys, dt);
        }
    }

    static void SetColor(nint r, (byte R, byte G, byte B) c) => Sdl.SetRenderDrawColor(r, c.R, c.G, c.B, 255);

    static void Fill(nint r, double x, double y, int w, int h) =>
        Sdl.RenderFillRect(r, new Sdl.Rect { X = (int)x, Y = (int)y, W = w, H = h });

    // Desenha um número com blocos de tamanho s; alignRight=true faz o número terminar em x.
    static void DrawNumber(nint r, int n, int x, int y, int s, bool alignRight)
    {
        string text = n.ToString();
        if (alignRight) x -= text.Length * 3 * s + (text.Length - 1) * s;
        foreach (char c in text)
        {
            string g = Digits[c - '0'];
            for (int i = 0; i < 15; i++)
                if (g[i] == '1') Fill(r, x + (i % 3) * s, y + (i / 3) * s, s, s);
            x += 4 * s;
        }
    }

    // Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
    // rotacionado de volta para o referencial do tanque, cai dentro da forma.
    // Dá o visual blocado do 2600 em qualquer uma das 16 direções.
    static void DrawTank(nint r, Tank t)
    {
        double a = DirAngle(t.Dir), c = Math.Cos(a), s = Math.Sin(a);
        int x0 = (int)t.X - TANK_GRID * TANK_CELL / 2, y0 = (int)t.Y - TANK_GRID * TANK_CELL / 2;
        const double half = (TANK_GRID - 1) / 2.0;
        for (int i = 0; i < TANK_GRID; i++)
        {
            for (int j = 0; j < TANK_GRID; j++)
            {
                double px = (j - half) * TANK_CELL, py = (i - half) * TANK_CELL;
                double u = px * c + py * s, v = -px * s + py * c;
                foreach (var b in TankShape)
                {
                    if (u >= b.X0 && u < b.X1 && v >= b.Y0 && v < b.Y1)
                    {
                        Fill(r, x0 + j * TANK_CELL, y0 + i * TANK_CELL, TANK_CELL, TANK_CELL);
                        break;
                    }
                }
            }
        }
    }

    static void Render(nint r, Game g)
    {
        SetColor(r, Bg);
        Sdl.RenderClear(r);

        SetColor(r, WallColor);
        foreach (var w in Walls) Fill(r, w.X, w.Y, w.W, w.H);

        for (int i = 0; i < 2; i++)
        {
            var t = g.Tanks[i];
            SetColor(r, TankColors[i]);
            DrawTank(r, t);
            if (t.Bullet.Active) Fill(r, t.Bullet.X, t.Bullet.Y, BULLET_SIZE, BULLET_SIZE);
            // No fim da partida o placar pisca.
            if (!g.GameOver || g.Blink % 0.5 < 0.25) DrawNumber(r, t.Score, i == 0 ? 40 : 600, 6, 6, i == 1);
        }

        SetColor(r, HudColor);
        DrawNumber(r, g.Mode, 314, 8, 4, false);
        Fill(r, 220, 36, (int)(200 * g.TimeLeft / MATCH_TIME), 4);
        Sdl.RenderPresent(r);
    }

    static int Main()
    {
        if (Sdl.Init(Sdl.INIT_VIDEO | Sdl.INIT_AUDIO) != 0)
        {
            Console.Error.WriteLine("SDL_Init: " + Sdl.GetError());
            return 1;
        }
        nint win = Sdl.CreateWindow("Tanques - C#", Sdl.WINDOWPOS_CENTERED, Sdl.WINDOWPOS_CENTERED, W, H, Sdl.WINDOW_SHOWN);
        nint ren = win == 0 ? 0 : Sdl.CreateRenderer(win, -1, Sdl.RENDERER_ACCELERATED | Sdl.RENDERER_PRESENTVSYNC);
        if (ren == 0)
        {
            Console.Error.WriteLine("janela/renderer: " + Sdl.GetError());
            return 1;
        }

        var want = new Sdl.AudioSpec { Freq = RATE, Format = Sdl.AUDIO_S16LSB, Channels = 1, Samples = 1024 };
        uint audio = Sdl.OpenAudioDevice(0, 0, want, 0, 0);
        if (audio != 0) Sdl.PauseAudioDevice(audio, 0);
        else Console.Error.WriteLine("sem áudio: " + Sdl.GetError());

        var game = new Game(samples =>
        {
            if (audio == 0) return;
            Sdl.ClearQueuedAudio(audio);
            fixed (short* p = samples) Sdl.QueueAudio(audio, p, (uint)(samples.Length * sizeof(short)));
        });
        game.NewMatch(1);

        byte* keys = Sdl.GetKeyboardState(null);
        double freq = Sdl.GetPerformanceFrequency();
        ulong last = Sdl.GetPerformanceCounter();
        double acc = 0;
        bool running = true;
        while (running)
        {
            while (Sdl.PollEvent(out var e) != 0)
                if (e.Type == Sdl.QUIT) running = false;
            if (keys[Sdl.SCANCODE_ESCAPE] != 0) running = false;

            ulong now = Sdl.GetPerformanceCounter();
            acc += Math.Min((now - last) / freq, 0.25);
            last = now;
            while (acc >= STEP)
            {
                game.Update(keys, STEP);
                acc -= STEP;
            }
            Render(ren, game);
        }

        if (audio != 0) Sdl.CloseAudioDevice(audio);
        Sdl.DestroyRenderer(ren);
        Sdl.DestroyWindow(win);
        Sdl.Quit();
        return 0;
    }
}
