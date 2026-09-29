// Tanques em Go com SDL2 (github.com/veandco/go-sdl2).
// Inspirado no Combat (Atari 2600, 1977).
package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"runtime"
	"strconv"

	"github.com/veandco/go-sdl2/sdl"
)

const (
	W           = 640
	H           = 480
	TankGrid    = 22 // tanque desenhado em 22x22 blocos de 2px
	TankCell    = 2
	TankHalf    = 12.0 // hitbox 24x24
	TankSpeed   = 90.0 // px/s
	RotTime     = 0.09 // s por passo de giro (16 direções)
	BulletSpeed = 320.0
	BulletSize  = 4
	BulletLife  = 1.6
	SpinTime    = 1.0
	SpinStep    = 0.04
	PushSpeed   = 110.0
	MatchTime   = 136.0 // 2:16, como no Combat
	Step        = 1.0 / 120.0
	Rate        = 44100
)

// Bordas da arena e obstáculos, simétricos nos dois eixos.
var walls = []sdl.Rect{
	{X: 0, Y: 48, W: 640, H: 8}, {X: 0, Y: 472, W: 640, H: 8}, {X: 0, Y: 48, W: 8, H: 432}, {X: 632, Y: 48, W: 8, H: 432},
	{X: 120, Y: 120, W: 16, H: 80}, {X: 504, Y: 120, W: 16, H: 80}, {X: 120, Y: 328, W: 16, H: 80}, {X: 504, Y: 328, W: 16, H: 80},
	{X: 256, Y: 136, W: 128, H: 16}, {X: 256, Y: 376, W: 128, H: 16}, {X: 312, Y: 232, W: 16, H: 64},
}

// Forma do tanque em px {x0, y0, x1, y1}, centrada na origem e apontando
// para +x: duas esteiras, corpo e canhão.
var tankShape = [][4]float64{
	{-14, -14, 12, -7}, {-14, 7, 12, 14}, {-10, -7, 7, 7}, {0, -2, 20, 2},
}

// (cosseno, seno) das 16 direções, a cada 22,5°. Valores literais: sin/cos das
// bibliotecas diferem no último bit entre as linguagens, e as versões passariam
// a divergir. Assim também o tanque anda em linha reta nas 4 direções cardeais.
var dirTable = [16][2]float64{
	{1, 0}, {0.9238795325112867, 0.3826834323650898},
	{0.7071067811865476, 0.7071067811865476}, {0.3826834323650898, 0.9238795325112867},
	{0, 1}, {-0.3826834323650898, 0.9238795325112867},
	{-0.7071067811865476, 0.7071067811865476}, {-0.9238795325112867, 0.3826834323650898},
	{-1, 0}, {-0.9238795325112867, -0.3826834323650898},
	{-0.7071067811865476, -0.7071067811865476}, {-0.3826834323650898, -0.9238795325112867},
	{0, -1}, {0.3826834323650898, -0.9238795325112867},
	{0.7071067811865476, -0.7071067811865476}, {0.9238795325112867, -0.3826834323650898},
}

// Fonte 3x5 para os dígitos do placar.
var digits = [10]string{
	"111101101101111", "001001001001001", "111001111100111", "111001111001111",
	"101101111001001", "111100111001111", "111100111101111", "111001001001001",
	"111101111101111", "111101111001111",
}

type color struct{ r, g, b uint8 }

var (
	bgColor    = color{0, 0, 0}
	wallColor  = color{180, 140, 60}
	hudColor   = color{230, 230, 230}
	tankColors = [2]color{{90, 200, 90}, {110, 150, 255}}
	controls   = [2][4]sdl.Scancode{ // frente, esquerda, direita, tiro
		{sdl.SCANCODE_W, sdl.SCANCODE_A, sdl.SCANCODE_D, sdl.SCANCODE_SPACE},
		{sdl.SCANCODE_UP, sdl.SCANCODE_LEFT, sdl.SCANCODE_RIGHT, sdl.SCANCODE_RETURN},
	}
)

func toBytes(samples []int16) []byte {
	buf := make([]byte, len(samples)*2)
	for i, v := range samples {
		binary.LittleEndian.PutUint16(buf[i*2:], uint16(v))
	}
	return buf
}

// squareWave gera uma onda quadrada mono S16.
func squareWave(freq, ms int) []byte {
	s := make([]int16, Rate*ms/1000)
	for i := range s {
		s[i] = -4000
		if (i*2*freq/Rate)%2 == 1 {
			s[i] = 4000
		}
	}
	return toBytes(s)
}

// noise gera ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com
// volume decaindo até zero; hold = amostras por bit (maior = mais grave).
func noise(ms, hold int) []byte {
	n := Rate * ms / 1000
	s := make([]int16, n)
	lfsr, bit := uint32(0xACE1), uint32(0)
	for i := range s {
		if i%hold == 0 {
			bit = lfsr & 1
			lfsr >>= 1
			if bit == 1 {
				lfsr ^= 0xB400
			}
		}
		amp := int16(4000 * (n - i) / n)
		if bit == 1 {
			s[i] = amp
		} else {
			s[i] = -amp
		}
	}
	return toBytes(s)
}

func overlaps(ax, ay, aw, ah, bx, by, bw, bh float64) bool {
	return ax < bx+bw && ax+aw > bx && ay < by+bh && ay+ah > by
}

func hitsWall(x, y, w, h float64) bool {
	for _, r := range walls {
		if overlaps(x, y, w, h, float64(r.X), float64(r.Y), float64(r.W), float64(r.H)) {
			return true
		}
	}
	return false
}

func dirAngle(dir int) float64 { return float64(dir) * 2 * math.Pi / 16 }

type Bullet struct {
	active             bool
	x, y, vx, vy, life float64
}

type Tank struct {
	x, y                         float64
	dir                          int
	rotTimer                     float64
	firePrev                     bool
	spin, spinStep, pushX, pushY float64
	score                        int
	bullet                       Bullet
}

type Game struct {
	tanks       [2]Tank
	mode        int // 1 = normal, 2 = ricochete
	timeLeft    float64
	blink       float64
	gameOver    bool
	audio       sdl.AudioDeviceID
	sndShot     []byte
	sndHit      []byte
	sndRicochet []byte
	sndEnd      []byte
}

func (g *Game) play(s []byte) {
	if g.audio == 0 {
		return
	}
	sdl.ClearQueuedAudio(g.audio)
	sdl.QueueAudio(g.audio, s)
}

func (g *Game) newMatch(mode int) {
	g.mode = mode
	g.timeLeft = MatchTime
	g.gameOver = false
	g.tanks = [2]Tank{{x: 60, y: 264, dir: 0}, {x: 580, y: 264, dir: 8}}
}

func blocked(other *Tank, x, y float64) bool {
	const s = 2 * TankHalf
	return hitsWall(x-TankHalf, y-TankHalf, s, s) ||
		overlaps(x-TankHalf, y-TankHalf, s, s, other.x-TankHalf, other.y-TankHalf, s, s)
}

// tryMove move um eixo de cada vez, para o tanque deslizar ao longo das paredes.
func tryMove(t, other *Tank, dx, dy float64) {
	if !blocked(other, t.x+dx, t.y) {
		t.x += dx
	}
	if !blocked(other, t.x, t.y+dy) {
		t.y += dy
	}
}

func (g *Game) updateTank(i int, keys []uint8, dt float64) {
	t, other := &g.tanks[i], &g.tanks[1-i]
	c := controls[i]
	fire := keys[c[3]] != 0

	if t.spin > 0 {
		// Atingido: gira sozinho e é empurrado para trás.
		t.spin -= dt
		t.spinStep -= dt
		if t.spinStep <= 0 {
			t.dir = (t.dir + 1) % 16
			t.spinStep += SpinStep
		}
		tryMove(t, other, t.pushX*dt, t.pushY*dt)
	} else {
		turn := 0
		if keys[c[2]] != 0 {
			turn++
		}
		if keys[c[1]] != 0 {
			turn--
		}
		if turn != 0 {
			t.rotTimer -= dt
			if t.rotTimer <= 0 {
				t.dir = (t.dir + turn + 16) % 16
				t.rotTimer += RotTime
			}
		} else {
			t.rotTimer = 0
		}
		dc, ds := dirTable[t.dir][0], dirTable[t.dir][1]
		if keys[c[0]] != 0 {
			tryMove(t, other, dc*TankSpeed*dt, ds*TankSpeed*dt)
		}
		if fire && !t.firePrev && !t.bullet.active {
			bx := t.x + dc*20 - BulletSize/2.0
			by := t.y + ds*20 - BulletSize/2.0
			// Canhão encostado na parede: o tiro não sai (nasceria dentro dela).
			if !hitsWall(bx, by, BulletSize, BulletSize) {
				t.bullet = Bullet{true, bx, by, dc * BulletSpeed, ds * BulletSpeed, BulletLife}
				g.play(g.sndShot)
			}
		}
	}
	t.firePrev = fire

	b := &t.bullet
	if !b.active {
		return
	}
	b.life -= dt
	if b.life <= 0 {
		b.active = false
		return
	}
	// Eixo x e depois y: assim sabemos qual componente refletir no ricochete.
	b.x += b.vx * dt
	if hitsWall(b.x, b.y, BulletSize, BulletSize) {
		if g.mode != 2 {
			b.active = false
			return
		}
		b.x -= b.vx * dt
		b.vx = -b.vx
		g.play(g.sndRicochet)
	}
	b.y += b.vy * dt
	if hitsWall(b.x, b.y, BulletSize, BulletSize) {
		if g.mode != 2 {
			b.active = false
			return
		}
		b.y -= b.vy * dt
		b.vy = -b.vy
		g.play(g.sndRicochet)
	}
	if other.spin <= 0 && overlaps(b.x, b.y, BulletSize, BulletSize,
		other.x-TankHalf, other.y-TankHalf, 2*TankHalf, 2*TankHalf) {
		t.score++
		l := math.Sqrt(b.vx*b.vx + b.vy*b.vy)
		other.spin = SpinTime
		other.spinStep = 0
		other.pushX = b.vx / l * PushSpeed
		other.pushY = b.vy / l * PushSpeed
		b.active = false
		g.play(g.sndHit)
	}
}

func (g *Game) update(keys []uint8, dt float64) {
	if keys[sdl.SCANCODE_1] != 0 {
		g.newMatch(1)
	}
	if keys[sdl.SCANCODE_2] != 0 {
		g.newMatch(2)
	}
	g.blink += dt
	if g.gameOver {
		return
	}
	g.timeLeft -= dt
	if g.timeLeft <= 0 {
		g.timeLeft = 0
		g.gameOver = true
		g.play(g.sndEnd)
		return
	}
	g.updateTank(0, keys, dt)
	g.updateTank(1, keys, dt)
}

func setColor(r *sdl.Renderer, c color) { r.SetDrawColor(c.r, c.g, c.b, 255) }

func fill(r *sdl.Renderer, x, y, w, h int32) {
	r.FillRect(&sdl.Rect{X: x, Y: y, W: w, H: h})
}

// drawNumber desenha um número com blocos de tamanho s; alignRight=true faz o
// número terminar em x.
func drawNumber(r *sdl.Renderer, n int, x, y, s int32, alignRight bool) {
	str := strconv.Itoa(n)
	l := int32(len(str))
	if alignRight {
		x -= l*3*s + (l-1)*s
	}
	for _, c := range str {
		g := digits[c-'0']
		for i := int32(0); i < 15; i++ {
			if g[i] == '1' {
				fill(r, x+(i%3)*s, y+(i/3)*s, s, s)
			}
		}
		x += 4 * s
	}
}

// drawTank rasteriza o tanque em blocos: cada bloco da grade acende se o seu
// centro, rotacionado de volta para o referencial do tanque, cai dentro da
// forma. Dá o visual blocado do 2600 em qualquer uma das 16 direções.
func drawTank(r *sdl.Renderer, t *Tank) {
	a := dirAngle(t.dir)
	c, s := math.Cos(a), math.Sin(a)
	x0 := int32(t.x) - TankGrid*TankCell/2
	y0 := int32(t.y) - TankGrid*TankCell/2
	const half = (TankGrid - 1) / 2.0
	for i := int32(0); i < TankGrid; i++ {
		for j := int32(0); j < TankGrid; j++ {
			px := (float64(j) - half) * TankCell
			py := (float64(i) - half) * TankCell
			u, v := px*c+py*s, -px*s+py*c
			for _, b := range tankShape {
				if u >= b[0] && u < b[2] && v >= b[1] && v < b[3] {
					fill(r, x0+j*TankCell, y0+i*TankCell, TankCell, TankCell)
					break
				}
			}
		}
	}
}

func render(r *sdl.Renderer, g *Game) {
	setColor(r, bgColor)
	r.Clear()

	setColor(r, wallColor)
	for i := range walls {
		r.FillRect(&walls[i])
	}

	for i := range g.tanks {
		t := &g.tanks[i]
		setColor(r, tankColors[i])
		drawTank(r, t)
		if t.bullet.active {
			fill(r, int32(t.bullet.x), int32(t.bullet.y), BulletSize, BulletSize)
		}
		// No fim da partida o placar pisca.
		if !g.gameOver || math.Mod(g.blink, 0.5) < 0.25 {
			x := int32(40)
			if i == 1 {
				x = 600
			}
			drawNumber(r, t.score, x, 6, 6, i == 1)
		}
	}

	setColor(r, hudColor)
	drawNumber(r, g.mode, 314, 8, 4, false)
	fill(r, 220, 36, int32(200*g.timeLeft/MatchTime), 4)
	r.Present()
}

func run() error {
	if err := sdl.Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO); err != nil {
		return err
	}
	defer sdl.Quit()

	win, err := sdl.CreateWindow("Tanques - Go", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		W, H, sdl.WINDOW_SHOWN)
	if err != nil {
		return err
	}
	defer win.Destroy()
	ren, err := sdl.CreateRenderer(win, -1, sdl.RENDERER_ACCELERATED|sdl.RENDERER_PRESENTVSYNC)
	if err != nil {
		return err
	}
	defer ren.Destroy()

	g := &Game{
		sndShot:     noise(90, 3),
		sndHit:      noise(500, 20),
		sndRicochet: squareWave(1200, 25),
		sndEnd:      squareWave(220, 700),
	}
	want := sdl.AudioSpec{Freq: Rate, Format: sdl.AUDIO_S16LSB, Channels: 1, Samples: 1024}
	if dev, err := sdl.OpenAudioDevice("", false, &want, nil, 0); err == nil {
		g.audio = dev
		sdl.PauseAudioDevice(dev, false)
		defer sdl.CloseAudioDevice(dev)
	} else {
		fmt.Fprintln(os.Stderr, "sem áudio:", err)
	}
	g.newMatch(1)

	last := sdl.GetPerformanceCounter()
	acc := 0.0
	for {
		for e := sdl.PollEvent(); e != nil; e = sdl.PollEvent() {
			if _, ok := e.(*sdl.QuitEvent); ok {
				return nil
			}
		}
		keys := sdl.GetKeyboardState()
		if keys[sdl.SCANCODE_ESCAPE] != 0 {
			return nil
		}

		now := sdl.GetPerformanceCounter()
		acc += math.Min(float64(now-last)/float64(sdl.GetPerformanceFrequency()), 0.25)
		last = now
		for acc >= Step {
			g.update(keys, Step)
			acc -= Step
		}
		render(ren, g)
	}
}

// A SDL exige que vídeo/eventos rodem na thread principal do SO.
func init() { runtime.LockOSThread() }

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "erro:", err)
		os.Exit(1)
	}
}
