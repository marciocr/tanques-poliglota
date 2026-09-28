{ Tanques em Object Pascal (Free Pascal) com SDL2.
  Inspirado no Combat (Atari 2600, 1977). }
program tanques;

{$mode objfpc}{$H+}
{ Sem isto, o FPC 3.2+ dá a cada constante real o menor tipo que representa
  seus literais: STEP = 1.0 / 120.0 seria calculado em Single (32 bits) e a
  física divergiria das outras linguagens, que usam Double. }
{$MINFPCONSTPREC 64}

uses
  Math, SysUtils, sdl2mini;

const
  W = 640;
  H = 480;
  TANK_GRID = 22;  { tanque desenhado em 22x22 blocos de 2px }
  TANK_CELL = 2;
  TANK_HALF = 12.0;  { hitbox 24x24 }
  TANK_SPEED = 90.0;  { px/s }
  ROT_TIME = 0.09;  { s por passo de giro (16 direções) }
  BULLET_SPEED = 320.0;
  BULLET_SIZE = 4;
  BULLET_LIFE = 1.6;
  SPIN_TIME = 1.0;
  SPIN_STEP = 0.04;
  PUSH_SPEED = 110.0;
  MATCH_TIME = 136.0;  { 2:16, como no Combat }
  STEP = 1.0 / 120.0;
  RATE = 44100;

  { Bordas da arena e obstáculos (x, y, w, h), simétricos nos dois eixos. }
  WALLS: array[0..10] of array[0..3] of LongInt = (
    (0, 48, 640, 8), (0, 472, 640, 8), (0, 48, 8, 432), (632, 48, 8, 432),
    (120, 120, 16, 80), (504, 120, 16, 80), (120, 328, 16, 80), (504, 328, 16, 80),
    (256, 136, 128, 16), (256, 376, 128, 16), (312, 232, 16, 64));

  { Forma do tanque em px (x0, y0, x1, y1), centrada na origem e apontando
    para +x: duas esteiras, corpo e canhão. }
  TANK_SHAPE: array[0..3] of array[0..3] of Double = (
    (-14, -14, 12, -7), (-14, 7, 12, 14), (-10, -7, 7, 7), (0, -2, 20, 2));

  { Fonte 3x5 para os dígitos do placar. }
  DIGITS: array[0..9] of string[15] = (
    '111101101101111', '001001001001001', '111001111100111', '111001111001111',
    '101101111001001', '111100111001111', '111100111101111', '111001001001001',
    '111101111101111', '111101111001111');

type
  TColor = record
    R, G, B: Byte;
  end;

  TControls = record
    Fwd, Left, Right, Fire: Integer;
  end;

const
  BG: TColor = (R: 0; G: 0; B: 0);
  WALL_COLOR: TColor = (R: 180; G: 140; B: 60);
  HUD_COLOR: TColor = (R: 230; G: 230; B: 230);
  TANK_COLORS: array[0..1] of TColor = ((R: 90; G: 200; B: 90), (R: 110; G: 150; B: 255));
  CONTROLS: array[0..1] of TControls = (
    (Fwd: SDL_SCANCODE_W; Left: SDL_SCANCODE_A; Right: SDL_SCANCODE_D; Fire: SDL_SCANCODE_SPACE),
    (Fwd: SDL_SCANCODE_UP; Left: SDL_SCANCODE_LEFT; Right: SDL_SCANCODE_RIGHT; Fire: SDL_SCANCODE_RETURN));

type
  TSound = array of SmallInt;

  TBullet = record
    Active: Boolean;
    X, Y, VX, VY, Life: Double;
  end;

  TTank = record
    X, Y: Double;
    Dir: Integer;
    RotTimer: Double;
    FirePrev: Boolean;
    Spin, SpinStep, PushX, PushY: Double;
    Score: Integer;
    Bullet: TBullet;
  end;

  TGame = class
    Tanks: array[0..1] of TTank;
    Mode: Integer;  { 1 = normal, 2 = ricochete }
    TimeLeft, Blink: Double;
    GameOver: Boolean;
    Audio: TSDL_AudioDeviceID;
    SndShot, SndHit, SndRicochet, SndEnd: TSound;
    constructor Create;
    procedure Play(const S: TSound);
    procedure NewMatch(M: Integer);
    procedure UpdateTank(I: Integer; Keys: PByte; Dt: Double);
    procedure Update(Keys: PByte; Dt: Double);
  end;

{ Onda quadrada mono S16. }
function SquareWave(Freq, Ms: Integer): TSound;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, RATE * Ms div 1000);
  for I := 0 to High(Result) do
    if ((I * 2 * Freq) div RATE) mod 2 = 1 then
      Result[I] := 4000
    else
      Result[I] := -4000;
end;

{ Ruído de LFSR de 16 bits (como o gerador de ruído do TIA), com volume
  decaindo até zero; Hold = amostras por bit (maior = mais grave). }
function Noise(Ms, Hold: Integer): TSound;
var
  N, I, Amp: Integer;
  Lfsr, Bit: LongWord;
begin
  N := RATE * Ms div 1000;
  Result := nil;
  SetLength(Result, N);
  Lfsr := $ACE1;
  Bit := 0;
  for I := 0 to N - 1 do
  begin
    if I mod Hold = 0 then
    begin
      Bit := Lfsr and 1;
      Lfsr := Lfsr shr 1;
      if Bit = 1 then Lfsr := Lfsr xor $B400;
    end;
    Amp := 4000 * (N - I) div N;
    if Bit = 1 then Result[I] := Amp else Result[I] := -Amp;
  end;
end;

function Overlaps(AX, AY, AW, AH, BX, BY, BW, BH: Double): Boolean;
begin
  Result := (AX < BX + BW) and (AX + AW > BX) and (AY < BY + BH) and (AY + AH > BY);
end;

function HitsWall(X, Y, W, H: Double): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(WALLS) do
    if Overlaps(X, Y, W, H, WALLS[I][0], WALLS[I][1], WALLS[I][2], WALLS[I][3]) then
      Exit(True);
  Result := False;
end;

function DirAngle(Dir: Integer): Double;
begin
  Result := Dir * 2 * Pi / 16;
end;

function MakeTank(X, Y: Double; Dir: Integer): TTank;
begin
  Result := Default(TTank);
  Result.X := X;
  Result.Y := Y;
  Result.Dir := Dir;
end;

function Blocked(const Other: TTank; X, Y: Double): Boolean;
const
  S = 2 * TANK_HALF;
begin
  Result := HitsWall(X - TANK_HALF, Y - TANK_HALF, S, S) or
    Overlaps(X - TANK_HALF, Y - TANK_HALF, S, S, Other.X - TANK_HALF, Other.Y - TANK_HALF, S, S);
end;

{ Move um eixo de cada vez, para o tanque deslizar ao longo das paredes. }
procedure TryMove(var T: TTank; const Other: TTank; DX, DY: Double);
begin
  if not Blocked(Other, T.X + DX, T.Y) then T.X := T.X + DX;
  if not Blocked(Other, T.X, T.Y + DY) then T.Y := T.Y + DY;
end;

constructor TGame.Create;
begin
  SndShot := Noise(90, 3);
  SndHit := Noise(500, 20);
  SndRicochet := SquareWave(1200, 25);
  SndEnd := SquareWave(220, 700);
  NewMatch(1);
end;

procedure TGame.Play(const S: TSound);
begin
  if Audio = 0 then Exit;
  SDL_ClearQueuedAudio(Audio);
  SDL_QueueAudio(Audio, @S[0], Length(S) * SizeOf(SmallInt));
end;

procedure TGame.NewMatch(M: Integer);
begin
  Mode := M;
  TimeLeft := MATCH_TIME;
  GameOver := False;
  Tanks[0] := MakeTank(60, 264, 0);
  Tanks[1] := MakeTank(580, 264, 8);
end;

procedure TGame.UpdateTank(I: Integer; Keys: PByte; Dt: Double);
var
  C: TControls;
  Fire: Boolean;
  Turn: Integer;
  A, Len, BX, BY: Double;
begin
  C := CONTROLS[I];
  Fire := Keys[C.Fire] <> 0;
  with Tanks[I] do
  begin
    if Spin > 0 then
    begin
      { Atingido: gira sozinho e é empurrado para trás. }
      Spin := Spin - Dt;
      SpinStep := SpinStep - Dt;
      if SpinStep <= 0 then
      begin
        Dir := (Dir + 1) mod 16;
        SpinStep := SpinStep + SPIN_STEP;
      end;
      TryMove(Tanks[I], Tanks[1 - I], PushX * Dt, PushY * Dt);
    end
    else
    begin
      Turn := Ord(Keys[C.Right] <> 0) - Ord(Keys[C.Left] <> 0);
      if Turn <> 0 then
      begin
        RotTimer := RotTimer - Dt;
        if RotTimer <= 0 then
        begin
          Dir := (Dir + Turn + 16) mod 16;
          RotTimer := RotTimer + ROT_TIME;
        end;
      end
      else
        RotTimer := 0;
      A := DirAngle(Dir);
      if Keys[C.Fwd] <> 0 then
        TryMove(Tanks[I], Tanks[1 - I], Cos(A) * TANK_SPEED * Dt, Sin(A) * TANK_SPEED * Dt);
      if Fire and not FirePrev and not Bullet.Active then
      begin
        BX := X + Cos(A) * 20 - BULLET_SIZE / 2;
        BY := Y + Sin(A) * 20 - BULLET_SIZE / 2;
        { Canhão encostado na parede: o tiro não sai (nasceria dentro dela). }
        if not HitsWall(BX, BY, BULLET_SIZE, BULLET_SIZE) then
        begin
          Bullet.Active := True;
          Bullet.X := BX;
          Bullet.Y := BY;
          Bullet.VX := Cos(A) * BULLET_SPEED;
          Bullet.VY := Sin(A) * BULLET_SPEED;
          Bullet.Life := BULLET_LIFE;
          Play(SndShot);
        end;
      end;
    end;
    FirePrev := Fire;
  end;

  with Tanks[I].Bullet do
  begin
    if not Active then Exit;
    Life := Life - Dt;
    if Life <= 0 then
    begin
      Active := False;
      Exit;
    end;
    { Eixo x e depois y: assim sabemos qual componente refletir no ricochete. }
    X := X + VX * Dt;
    if HitsWall(X, Y, BULLET_SIZE, BULLET_SIZE) then
    begin
      if Mode <> 2 then
      begin
        Active := False;
        Exit;
      end;
      X := X - VX * Dt;
      VX := -VX;
      Play(SndRicochet);
    end;
    Y := Y + VY * Dt;
    if HitsWall(X, Y, BULLET_SIZE, BULLET_SIZE) then
    begin
      if Mode <> 2 then
      begin
        Active := False;
        Exit;
      end;
      Y := Y - VY * Dt;
      VY := -VY;
      Play(SndRicochet);
    end;
    if (Tanks[1 - I].Spin <= 0) and Overlaps(X, Y, BULLET_SIZE, BULLET_SIZE,
      Tanks[1 - I].X - TANK_HALF, Tanks[1 - I].Y - TANK_HALF, 2 * TANK_HALF, 2 * TANK_HALF) then
    begin
      Inc(Tanks[I].Score);
      Len := Hypot(VX, VY);
      Tanks[1 - I].Spin := SPIN_TIME;
      Tanks[1 - I].SpinStep := 0;
      Tanks[1 - I].PushX := VX / Len * PUSH_SPEED;
      Tanks[1 - I].PushY := VY / Len * PUSH_SPEED;
      Active := False;
      Play(SndHit);
    end;
  end;
end;

procedure TGame.Update(Keys: PByte; Dt: Double);
begin
  if Keys[SDL_SCANCODE_1] <> 0 then NewMatch(1);
  if Keys[SDL_SCANCODE_2] <> 0 then NewMatch(2);
  Blink := Blink + Dt;
  if GameOver then Exit;
  TimeLeft := TimeLeft - Dt;
  if TimeLeft <= 0 then
  begin
    TimeLeft := 0;
    GameOver := True;
    Play(SndEnd);
    Exit;
  end;
  UpdateTank(0, Keys, Dt);
  UpdateTank(1, Keys, Dt);
end;

procedure SetColor(R: PSDL_Renderer; const C: TColor);
begin
  SDL_SetRenderDrawColor(R, C.R, C.G, C.B, 255);
end;

procedure Fill(R: PSDL_Renderer; X, Y, W, H: LongInt);
var
  Rc: TSDL_Rect;
begin
  Rc.x := X; Rc.y := Y; Rc.w := W; Rc.h := H;
  SDL_RenderFillRect(R, @Rc);
end;

{ Desenha um número com blocos de tamanho S; AlignRight=True faz o número terminar em X. }
procedure DrawNumber(R: PSDL_Renderer; N, X, Y, S: Integer; AlignRight: Boolean);
var
  Txt: string;
  G: string[15];
  C, I: Integer;
begin
  Txt := IntToStr(N);
  if AlignRight then
    X := X - (Length(Txt) * 3 * S + (Length(Txt) - 1) * S);
  for C := 1 to Length(Txt) do
  begin
    G := DIGITS[Ord(Txt[C]) - Ord('0')];
    for I := 0 to 14 do
      if G[I + 1] = '1' then
        Fill(R, X + (I mod 3) * S, Y + (I div 3) * S, S, S);
    X := X + 4 * S;
  end;
end;

{ Rasteriza o tanque em blocos: cada bloco da grade acende se o seu centro,
  rotacionado de volta para o referencial do tanque, cai dentro da forma.
  Dá o visual blocado do 2600 em qualquer uma das 16 direções. }
procedure DrawTank(R: PSDL_Renderer; const T: TTank);
const
  HALF = (TANK_GRID - 1) / 2;
var
  A, C, S, PX, PY, U, V: Double;
  X0, Y0, I, J, K: Integer;
begin
  A := DirAngle(T.Dir);
  C := Cos(A);
  S := Sin(A);
  X0 := Trunc(T.X) - TANK_GRID * TANK_CELL div 2;
  Y0 := Trunc(T.Y) - TANK_GRID * TANK_CELL div 2;
  for I := 0 to TANK_GRID - 1 do
    for J := 0 to TANK_GRID - 1 do
    begin
      PX := (J - HALF) * TANK_CELL;
      PY := (I - HALF) * TANK_CELL;
      U := PX * C + PY * S;
      V := -PX * S + PY * C;
      for K := 0 to High(TANK_SHAPE) do
        if (U >= TANK_SHAPE[K][0]) and (U < TANK_SHAPE[K][2]) and
           (V >= TANK_SHAPE[K][1]) and (V < TANK_SHAPE[K][3]) then
        begin
          Fill(R, X0 + J * TANK_CELL, Y0 + I * TANK_CELL, TANK_CELL, TANK_CELL);
          Break;
        end;
    end;
end;

procedure Render(R: PSDL_Renderer; G: TGame);
var
  I, X: Integer;
begin
  SetColor(R, BG);
  SDL_RenderClear(R);

  SetColor(R, WALL_COLOR);
  for I := 0 to High(WALLS) do
    Fill(R, WALLS[I][0], WALLS[I][1], WALLS[I][2], WALLS[I][3]);

  for I := 0 to 1 do
  begin
    SetColor(R, TANK_COLORS[I]);
    DrawTank(R, G.Tanks[I]);
    with G.Tanks[I].Bullet do
      if Active then
        Fill(R, Trunc(X), Trunc(Y), BULLET_SIZE, BULLET_SIZE);
    { No fim da partida o placar pisca. }
    if (not G.GameOver) or (FMod(G.Blink, 0.5) < 0.25) then
    begin
      if I = 0 then X := 40 else X := 600;
      DrawNumber(R, G.Tanks[I].Score, X, 6, 6, I = 1);
    end;
  end;

  SetColor(R, HUD_COLOR);
  DrawNumber(R, G.Mode, 314, 8, 4, False);
  Fill(R, 220, 36, Trunc(200 * G.TimeLeft / MATCH_TIME), 4);
  SDL_RenderPresent(R);
end;

var
  Win: PSDL_Window;
  Ren: PSDL_Renderer;
  Game: TGame;
  Want: TSDL_AudioSpec;
  Ev: TSDL_Event;
  Keys: PByte;
  Last, Cur: QWord;
  Acc: Double;
  Running: Boolean;
begin
  { Drivers de vídeo/áudio podem gerar exceções de ponto flutuante que o FPC
    trataria como erro fatal; mascará-las é o procedimento padrão com SDL. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);

  if SDL_Init(SDL_INIT_VIDEO or SDL_INIT_AUDIO) <> 0 then
  begin
    WriteLn(StdErr, 'SDL_Init: ', SDL_GetError);
    Halt(1);
  end;
  Win := SDL_CreateWindow('Tanques - Object Pascal', SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    W, H, SDL_WINDOW_SHOWN);
  Ren := nil;
  if Win <> nil then
    Ren := SDL_CreateRenderer(Win, -1, SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC);
  if Ren = nil then
  begin
    WriteLn(StdErr, 'janela/renderer: ', SDL_GetError);
    Halt(1);
  end;

  Game := TGame.Create;
  FillChar(Want, SizeOf(Want), 0);
  Want.freq := RATE;
  Want.format := AUDIO_S16LSB;
  Want.channels := 1;
  Want.samples := 1024;
  Game.Audio := SDL_OpenAudioDevice(nil, 0, @Want, nil, 0);
  if Game.Audio <> 0 then
    SDL_PauseAudioDevice(Game.Audio, 0)
  else
    WriteLn(StdErr, 'sem áudio: ', SDL_GetError);

  Last := SDL_GetPerformanceCounter;
  Acc := 0;
  Running := True;
  while Running do
  begin
    while SDL_PollEvent(@Ev) <> 0 do
      if Ev.type_ = SDL_QUITEV then Running := False;
    Keys := SDL_GetKeyboardState(nil);
    if Keys[SDL_SCANCODE_ESCAPE] <> 0 then Running := False;

    Cur := SDL_GetPerformanceCounter;
    Acc := Acc + Min((Cur - Last) / SDL_GetPerformanceFrequency, 0.25);
    Last := Cur;
    while Acc >= STEP do
    begin
      Game.Update(Keys, STEP);
      Acc := Acc - STEP;
    end;
    Render(Ren, Game);
  end;

  if Game.Audio <> 0 then SDL_CloseAudioDevice(Game.Audio);
  Game.Free;
  SDL_DestroyRenderer(Ren);
  SDL_DestroyWindow(Win);
  SDL_Quit;
end.
