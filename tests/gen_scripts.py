#!/usr/bin/env python3
"""Gera os roteiros de tests/scripts/ usando a versão Python.

Formato dos roteiros: linhas "<passos> <scancodes|->", em que cada passo é
1/120 s de física, e os scancodes são os da SDL separados por vírgula (30 = tecla
1, modo normal; 31 = tecla 2, modo ricochete). O jogo não tem sorteio, então a
mesma sequência leva ao mesmo estado final em qualquer linguagem.

Os roteiros aleatórios são filtrados: só ficam os que geram pelo menos 3
acertos (e, no modo ricochete, 10 ricochetes), para exercitar a colisão, o
empurrão e o giro do tanque atingido.

Os roteiros já estão no repositório; este arquivo só documenta como nasceram.
Uso: python3 tests/gen_scripts.py
"""
import collections
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "python"))
import tanques as game  # noqa: E402

OUT = os.path.join(ROOT, "tests", "scripts")
KEYS = [4, 7, 26, 44, 79, 80, 82, 40]  # A D W Espaço → ← ↑ Enter


def simulate(lines, mode_key):
    g = game.Game(0)
    counts = collections.Counter()
    names = {id(g.snd_shot): "tiro", id(g.snd_hit): "acerto", id(g.snd_ricochet): "ricochete", id(g.snd_end): "fim"}
    g.play = lambda s: counts.update([names[id(s)]])
    for steps, ks in lines:
        keys = [0] * 512
        for k in ks:
            keys[k] = 1
        for _ in range(steps):
            g.update(keys, game.STEP)
    return g, counts


def write(name, lines):
    with open(os.path.join(OUT, name + ".txt"), "w") as f:
        for steps, ks in lines:
            f.write(f"{steps} {','.join(map(str, sorted(ks))) or '-'}\n")


def random_scripts(mode, want):
    found = 0
    for seed in range(100000):
        rnd = random.Random(seed * 7 + mode)
        lines = [(1, [29 + mode])]
        for _ in range(120):
            lines.append((rnd.choice([2, 12, 36, 72]), rnd.sample(KEYS, rnd.randint(0, 4))))
        g, c = simulate(lines, mode)
        if c["acerto"] >= 3 and (mode == 1 or c["ricochete"] >= 10):
            name = f"modo{mode}_{chr(97 + found)}"
            write(name, lines)
            print(f"{name}: placar {g.tanks[0].score} x {g.tanks[1].score} | {dict(c)}")
            found += 1
            if found == want:
                return
    raise SystemExit(f"modo {mode}: só {found} roteiros")


os.makedirs(OUT, exist_ok=True)
random_scripts(1, 3)
random_scripts(2, 3)
# Ninguém joga: a partida inteira (2:16 = 16.320 passos) passa até o fim de jogo.
write("fim_de_partida", [(1, [31]), (16500, [])])
g, c = simulate([(1, [31]), (16500, [])], 2)
print("fim_de_partida:", "game over" if g.game_over else "NÃO acabou", dict(c))
