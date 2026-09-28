# Tanques — Object Pascal (Free Pascal)

Object Pascal (`{$mode objfpc}`) compilado com o FPC 3.2. O FPC não traz
units para SDL2, e o Fedora não empacota nenhuma, então `sdl2mini.pas` declara
só as ~20 funções e os records que o jogo usa (`TSDL_Rect`, `TSDL_AudioSpec`,
`TSDL_Event`). Todas as funções usam `cdecl; external 'SDL2'`, e o layout dos
records segue os headers C (`{$PACKRECORDS C}`).

O programa mascara as exceções de ponto flutuante (`SetExceptionMask`) antes
de iniciar a SDL, que é o procedimento padrão em FPC: drivers de vídeo e áudio
podem gerar exceções de FPU que o runtime do Pascal trataria como erro fatal.

O código usa `{$MINFPCONSTPREC 64}`. Desde o FPC 3.2, uma constante real sem
tipo recebe o menor tipo de ponto flutuante que representa seus literais.
Assim, `STEP = 1.0 / 120.0` seria calculado em `Single` (32 bits), e a física
divergiria das outras linguagens, que usam `Double`. A diretiva força 64 bits.

## Dependências (Fedora)

```bash
sudo dnf install fpc sdl2-compat-devel
```

O `sdl2-compat-devel` fornece o symlink `libSDL2.so` usado pelo linker.

## Build

```bash
./build.sh
```

O script roda `fpc -O2 -Xs -FUbuild -obuild/tanques tanques.pas`. Para limpar,
use `./build.sh clean`.

## Execução

```bash
./build/tanques
```
