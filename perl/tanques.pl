#!/usr/bin/env perl
# Tanques em Perl com SDL2, chamando a libSDL2 diretamente via FFI::Platypus.
# Inspirado no Combat (Atari 2600, 1977).
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));

use FFI::CheckLib qw(find_lib);
use FFI::Platypus 2.00;
use FFI::Platypus::Buffer qw(scalar_to_buffer);
use FFI::Platypus::Memory qw(malloc free);
use List::Util qw(any min);
use POSIX qw(floor fmod);

use constant {
    W => 640, H => 480,
    TANK_GRID => 22, TANK_CELL => 2,   # tanque desenhado em 22x22 blocos de 2px
    TANK_HALF => 12,                   # hitbox 24x24
    TANK_SPEED => 90.0,                # px/s
    ROT_TIME => 0.09,                  # s por passo de giro (16 direções)
    BULLET_SPEED => 320.0,
    BULLET_SIZE => 4,
    BULLET_LIFE => 1.6,
    SPIN_TIME => 1.0, SPIN_STEP => 0.04, PUSH_SPEED => 110.0,
    MATCH_TIME => 136.0,               # 2:16, como no Combat
    PI => 4 * atan2(1, 1),
    STEP => 1.0 / 120.0,
    RATE => 44100,

    # Constantes dos headers da SDL2.
    SDL_INIT_AUDIO => 0x10, SDL_INIT_VIDEO => 0x20,
    SDL_WINDOWPOS_CENTERED => 0x2FFF0000,
    SDL_WINDOW_SHOWN => 0x04,
    SDL_RENDERER_ACCELERATED => 0x02, SDL_RENDERER_PRESENTVSYNC => 0x04,
    SDL_QUIT_EVENT => 0x100,
    SDL_SCANCODE_A => 4, SDL_SCANCODE_D => 7, SDL_SCANCODE_W => 26,
    SDL_SCANCODE_1 => 30, SDL_SCANCODE_2 => 31, SDL_SCANCODE_RETURN => 40,
    SDL_SCANCODE_ESCAPE => 41, SDL_SCANCODE_SPACE => 44,
    SDL_SCANCODE_RIGHT => 79, SDL_SCANCODE_LEFT => 80, SDL_SCANCODE_UP => 82,
    AUDIO_S16LSB => 0x8010,
};

# Bordas da arena e obstáculos [x, y, w, h], simétricos nos dois eixos.
my @WALLS = (
    [0, 48, 640, 8], [0, 472, 640, 8], [0, 48, 8, 432], [632, 48, 8, 432],
    [120, 120, 16, 80], [504, 120, 16, 80], [120, 328, 16, 80], [504, 328, 16, 80],
    [256, 136, 128, 16], [256, 376, 128, 16], [312, 232, 16, 64],
);

# Forma do tanque em px [x0, y0, x1, y1], centrada na origem e apontando
# para +x: duas esteiras, corpo e canhão.
my @TANK_SHAPE = ([-14, -14, 12, -7], [-14, 7, 12, 14], [-10, -7, 7, 7], [0, -2, 20, 2]);

# (cosseno, seno) das 16 direções, a cada 22,5°. Valores literais: sin/cos das
# bibliotecas diferem no último bit entre as linguagens, e as versões passariam
# a divergir. Assim também o tanque anda em linha reta nas 4 direções cardeais.
my @DIR_TABLE = (
    [1, 0], [0.9238795325112867, 0.3826834323650898],
    [0.7071067811865476, 0.7071067811865476], [0.3826834323650898, 0.9238795325112867],
    [0, 1], [-0.3826834323650898, 0.9238795325112867],
    [-0.7071067811865476, 0.7071067811865476], [-0.9238795325112867, 0.3826834323650898],
    [-1, 0], [-0.9238795325112867, -0.3826834323650898],
    [-0.7071067811865476, -0.7071067811865476], [-0.3826834323650898, -0.9238795325112867],
    [0, -1], [0.3826834323650898, -0.9238795325112867],
    [0.7071067811865476, -0.7071067811865476], [0.9238795325112867, -0.3826834323650898],
);

# Fonte 3x5 para os dígitos do placar.
my @DIGITS = qw(
    111101101101111 001001001001001 111001111100111 111001111001111
    101101111001001 111100111001111 111100111101111 111001001001001
    111101111101111 111101111001111
);

my @BG = (0, 0, 0);
my @WALL_COLOR = (180, 140, 60);
my @HUD_COLOR = (230, 230, 230);
my @TANK_COLORS = ([90, 200, 90], [110, 150, 255]);

# Controles de cada jogador.
my @CONTROLS = (
    { fwd => SDL_SCANCODE_W,  left => SDL_SCANCODE_A,    right => SDL_SCANCODE_D,     fire => SDL_SCANCODE_SPACE },
    { fwd => SDL_SCANCODE_UP, left => SDL_SCANCODE_LEFT, right => SDL_SCANCODE_RIGHT, fire => SDL_SCANCODE_RETURN },
);

# find_lib precisa do symlink libSDL2.so (pacote -devel); sem ele, usa o soname.
my ($libsdl) = find_lib(lib => 'SDL2');
my $ffi = FFI::Platypus->new(api => 2, lib => [$libsdl // 'libSDL2-2.0.so.0']);
$ffi->attach(SDL_Init                    => ['uint32'] => 'int');
$ffi->attach(SDL_Quit                    => [] => 'void');
$ffi->attach(SDL_GetError                => [] => 'string');
$ffi->attach(SDL_CreateWindow            => ['string', 'int', 'int', 'int', 'int', 'uint32'] => 'opaque');
$ffi->attach(SDL_DestroyWindow           => ['opaque'] => 'void');
$ffi->attach(SDL_CreateRenderer          => ['opaque', 'int', 'uint32'] => 'opaque');
$ffi->attach(SDL_DestroyRenderer         => ['opaque'] => 'void');
$ffi->attach(SDL_SetRenderDrawColor      => ['opaque', 'uint8', 'uint8', 'uint8', 'uint8'] => 'int');
$ffi->attach(SDL_RenderClear             => ['opaque'] => 'int');
$ffi->attach(SDL_RenderFillRect          => ['opaque', 'sint32[4]'] => 'int');  # SDL_Rect = 4 x int
$ffi->attach(SDL_RenderPresent           => ['opaque'] => 'void');
$ffi->attach(SDL_PollEvent               => ['opaque'] => 'int');
$ffi->attach(SDL_GetKeyboardState        => ['opaque'] => 'opaque');
$ffi->attach(SDL_GetPerformanceCounter   => [] => 'uint64');
$ffi->attach(SDL_GetPerformanceFrequency => [] => 'uint64');
$ffi->attach(SDL_OpenAudioDevice         => ['string', 'int', 'opaque', 'opaque', 'int'] => 'uint32');
$ffi->attach(SDL_PauseAudioDevice        => ['uint32', 'int'] => 'void');
$ffi->attach(SDL_QueueAudio              => ['uint32', 'opaque', 'uint32'] => 'int');
$ffi->attach(SDL_ClearQueuedAudio        => ['uint32'] => 'void');
$ffi->attach(SDL_CloseAudioDevice        => ['uint32'] => 'void');

# Onda quadrada mono S16 (bytes little-endian).
sub square_wave {
    my ($freq, $ms) = @_;
    my $n = int(RATE * $ms / 1000);
    return pack 's<*', map { int($_ * 2 * $freq / RATE) % 2 ? 4000 : -4000 } 0 .. $n - 1;
}

# Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
# decaindo até zero; $hold = amostras por bit (maior = mais grave).
sub noise {
    my ($ms, $hold) = @_;
    my $n = int(RATE * $ms / 1000);
    my ($lfsr, $bit) = (0xACE1, 0);
    my @out;
    for my $i (0 .. $n - 1) {
        if ($i % $hold == 0) {
            $bit = $lfsr & 1;
            $lfsr >>= 1;
            $lfsr ^= 0xB400 if $bit;
        }
        my $amp = int(4000 * ($n - $i) / $n);
        push @out, $bit ? $amp : -$amp;
    }
    return pack 's<*', @out;
}

my %snd = (
    shot     => noise(90, 3),
    hit      => noise(500, 20),
    ricochet => square_wave(1200, 25),
    end      => square_wave(220, 700),
);

my $audio = 0;
my %g = (blink => 0);

sub play {
    my ($name) = @_;
    return unless $audio;
    SDL_ClearQueuedAudio($audio);
    my ($ptr, $len) = scalar_to_buffer($snd{$name});
    SDL_QueueAudio($audio, $ptr, $len);
}

sub overlaps {
    my ($ax, $ay, $aw, $ah, $bx, $by, $bw, $bh) = @_;
    return $ax < $bx + $bw && $ax + $aw > $bx && $ay < $by + $bh && $ay + $ah > $by;
}

sub hits_wall {
    my ($x, $y, $w, $h) = @_;
    return any { overlaps($x, $y, $w, $h, @$_) } @WALLS;
}

sub dir_angle { return $_[0] * 2 * PI / 16 }

sub new_tank {
    my ($x, $y, $dir) = @_;
    return {
        x => $x, y => $y, dir => $dir, rot_timer => 0, fire_prev => 0,
        spin => 0, spin_step => 0, push_x => 0, push_y => 0, score => 0,
        bullet => { active => 0 },
    };
}

sub new_match {
    my ($mode) = @_;
    $g{mode} = $mode;    # 1 = normal, 2 = ricochete
    $g{time_left} = MATCH_TIME;
    $g{game_over} = 0;
    $g{tanks} = [new_tank(60, 264, 0), new_tank(580, 264, 8)];
}

sub blocked {
    my ($other, $x, $y) = @_;
    my $s = 2 * TANK_HALF;
    return hits_wall($x - TANK_HALF, $y - TANK_HALF, $s, $s)
        || overlaps($x - TANK_HALF, $y - TANK_HALF, $s, $s, $other->{x} - TANK_HALF, $other->{y} - TANK_HALF, $s, $s);
}

# Move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
sub try_move {
    my ($t, $other, $dx, $dy) = @_;
    $t->{x} += $dx unless blocked($other, $t->{x} + $dx, $t->{y});
    $t->{y} += $dy unless blocked($other, $t->{x}, $t->{y} + $dy);
}

sub update_tank {
    my ($i, $keys, $dt) = @_;
    my ($t, $other) = ($g{tanks}[$i], $g{tanks}[1 - $i]);
    my $c = $CONTROLS[$i];
    my $fire = $keys->[$c->{fire}] ? 1 : 0;

    if ($t->{spin} > 0) {
        # Atingido: gira sozinho e é empurrado para trás.
        $t->{spin} -= $dt;
        $t->{spin_step} -= $dt;
        if ($t->{spin_step} <= 0) {
            $t->{dir} = ($t->{dir} + 1) % 16;
            $t->{spin_step} += SPIN_STEP;
        }
        try_move($t, $other, $t->{push_x} * $dt, $t->{push_y} * $dt);
    }
    else {
        my $turn = ($keys->[$c->{right}] ? 1 : 0) - ($keys->[$c->{left}] ? 1 : 0);
        if ($turn) {
            $t->{rot_timer} -= $dt;
            if ($t->{rot_timer} <= 0) {
                $t->{dir} = ($t->{dir} + $turn) % 16;
                $t->{rot_timer} += ROT_TIME;
            }
        }
        else {
            $t->{rot_timer} = 0;
        }
        my ($dc, $ds) = @{ $DIR_TABLE[$t->{dir}] };
        try_move($t, $other, $dc * TANK_SPEED * $dt, $ds * TANK_SPEED * $dt) if $keys->[$c->{fwd}];
        if ($fire && !$t->{fire_prev} && !$t->{bullet}{active}) {
            my $bx = $t->{x} + $dc * 20 - BULLET_SIZE / 2;
            my $by = $t->{y} + $ds * 20 - BULLET_SIZE / 2;
            # Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
            unless (hits_wall($bx, $by, BULLET_SIZE, BULLET_SIZE)) {
                $t->{bullet} = {
                    active => 1, x => $bx, y => $by,
                    vx => $dc * BULLET_SPEED, vy => $ds * BULLET_SPEED,
                    life => BULLET_LIFE,
                };
                play('shot');
            }
        }
    }
    $t->{fire_prev} = $fire;

    my $b = $t->{bullet};
    return unless $b->{active};
    $b->{life} -= $dt;
    if ($b->{life} <= 0) { $b->{active} = 0; return }
    # Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
    $b->{x} += $b->{vx} * $dt;
    if (hits_wall($b->{x}, $b->{y}, BULLET_SIZE, BULLET_SIZE)) {
        if ($g{mode} != 2) { $b->{active} = 0; return }
        $b->{x} -= $b->{vx} * $dt;
        $b->{vx} = -$b->{vx};
        play('ricochet');
    }
    $b->{y} += $b->{vy} * $dt;
    if (hits_wall($b->{x}, $b->{y}, BULLET_SIZE, BULLET_SIZE)) {
        if ($g{mode} != 2) { $b->{active} = 0; return }
        $b->{y} -= $b->{vy} * $dt;
        $b->{vy} = -$b->{vy};
        play('ricochet');
    }
    if ($other->{spin} <= 0
        && overlaps($b->{x}, $b->{y}, BULLET_SIZE, BULLET_SIZE,
                    $other->{x} - TANK_HALF, $other->{y} - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF)) {
        $t->{score}++;
        my $len = sqrt($b->{vx}**2 + $b->{vy}**2);
        $other->{spin} = SPIN_TIME;
        $other->{spin_step} = 0;
        $other->{push_x} = $b->{vx} / $len * PUSH_SPEED;
        $other->{push_y} = $b->{vy} / $len * PUSH_SPEED;
        $b->{active} = 0;
        play('hit');
    }
}

sub update {
    my ($keys, $dt) = @_;
    new_match(1) if $keys->[SDL_SCANCODE_1];
    new_match(2) if $keys->[SDL_SCANCODE_2];
    $g{blink} += $dt;
    return if $g{game_over};
    $g{time_left} -= $dt;
    if ($g{time_left} <= 0) {
        $g{time_left} = 0;
        $g{game_over} = 1;
        play('end');
        return;
    }
    update_tank(0, $keys, $dt);
    update_tank(1, $keys, $dt);
}

sub set_color { my ($r, @c) = @_; SDL_SetRenderDrawColor($r, @c, 255) }

sub fill { my ($r, @rect) = @_; SDL_RenderFillRect($r, [map { floor($_) } @rect]) }

# Desenha um número com blocos de tamanho $s; $align_right faz o número terminar em $x.
sub draw_number {
    my ($r, $n, $x, $y, $s, $align_right) = @_;
    my @chars = split //, "$n";
    $x -= @chars * 3 * $s + (@chars - 1) * $s if $align_right;
    for my $c (@chars) {
        my @bits = split //, $DIGITS[$c];
        for my $i (0 .. 14) {
            fill($r, $x + ($i % 3) * $s, $y + int($i / 3) * $s, $s, $s) if $bits[$i];
        }
        $x += 4 * $s;
    }
}

# Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
# rotacionado de volta para o referencial do tanque, cai dentro da forma.
# Dá o visual blocado do 2600 em qualquer uma das 16 direções.
sub draw_tank {
    my ($r, $t) = @_;
    my $a = dir_angle($t->{dir});
    my ($c, $s) = (cos($a), sin($a));
    my $x0 = int($t->{x}) - TANK_GRID * TANK_CELL / 2;
    my $y0 = int($t->{y}) - TANK_GRID * TANK_CELL / 2;
    my $half = (TANK_GRID - 1) / 2;
    for my $i (0 .. TANK_GRID - 1) {
        my $py = ($i - $half) * TANK_CELL;
        for my $j (0 .. TANK_GRID - 1) {
            my $px = ($j - $half) * TANK_CELL;
            my ($u, $v) = ($px * $c + $py * $s, -$px * $s + $py * $c);
            fill($r, $x0 + $j * TANK_CELL, $y0 + $i * TANK_CELL, TANK_CELL, TANK_CELL)
                if any { $u >= $_->[0] && $u < $_->[2] && $v >= $_->[1] && $v < $_->[3] } @TANK_SHAPE;
        }
    }
}

sub render {
    my ($r) = @_;
    set_color($r, @BG);
    SDL_RenderClear($r);

    set_color($r, @WALL_COLOR);
    fill($r, @$_) for @WALLS;

    for my $i (0, 1) {
        my $t = $g{tanks}[$i];
        set_color($r, @{ $TANK_COLORS[$i] });
        draw_tank($r, $t);
        fill($r, $t->{bullet}{x}, $t->{bullet}{y}, BULLET_SIZE, BULLET_SIZE) if $t->{bullet}{active};
        # No fim da partida o placar pisca.
        if (!$g{game_over} || fmod($g{blink}, 0.5) < 0.25) {
            draw_number($r, $t->{score}, $i == 0 ? 40 : 600, 6, 6, $i == 1);
        }
    }

    set_color($r, @HUD_COLOR);
    draw_number($r, $g{mode}, 314, 8, 4, 0);
    fill($r, 220, 36, int(200 * $g{time_left} / MATCH_TIME), 4);
    SDL_RenderPresent($r);
}

SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) == 0 or die 'SDL_Init: ' . SDL_GetError() . "\n";
my $win = SDL_CreateWindow('Tanques - Perl', SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, W, H, SDL_WINDOW_SHOWN);
my $ren = $win && SDL_CreateRenderer($win, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
$ren or die 'janela/renderer: ' . SDL_GetError() . "\n";

# SDL_AudioSpec: freq, format, channels, silence, samples, padding, size, callback, userdata.
my $want = pack 'l< S< C C S< S< L< Q< Q<', RATE, AUDIO_S16LSB, 1, 0, 1024, 0, 0, 0, 0;
my ($want_ptr) = scalar_to_buffer($want);
$audio = SDL_OpenAudioDevice(undef, 0, $want_ptr, undef, 0);
if ($audio) { SDL_PauseAudioDevice($audio, 0) }
else        { warn 'sem áudio: ' . SDL_GetError() . "\n" }

new_match(1);

my $event = malloc(56);  # sizeof(SDL_Event)
my $last = SDL_GetPerformanceCounter();
my $freq = SDL_GetPerformanceFrequency();
my $acc = 0;
my $running = 1;
while ($running) {
    while (SDL_PollEvent($event)) {
        $running = 0 if $ffi->cast('opaque' => 'uint32*', $event)->$* == SDL_QUIT_EVENT;
    }
    my $keys = $ffi->cast('opaque' => 'uint8[128]', SDL_GetKeyboardState(undef));
    $running = 0 if $keys->[SDL_SCANCODE_ESCAPE];

    my $now = SDL_GetPerformanceCounter();
    $acc += min(($now - $last) / $freq, 0.25);
    $last = $now;
    while ($acc >= STEP) {
        update($keys, STEP);
        $acc -= STEP;
    }
    render($ren);
}

free($event);
SDL_CloseAudioDevice($audio) if $audio;
SDL_DestroyRenderer($ren);
SDL_DestroyWindow($win);
SDL_Quit();
