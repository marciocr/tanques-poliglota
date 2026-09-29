"""Driver de teste (Python): aplica um roteiro à lógica do jogo, sem janela."""
import importlib
import os
import sys

sys.path.insert(0, sys.argv[1])
game = importlib.import_module(os.environ["GAME"])

g = game.Game(0)
g.play = lambda s: None
for line in open(sys.argv[2]):
    p = line.split()
    keys = [0] * 512
    if p[1] != "-":
        for k in p[1].split(","):
            keys[int(k)] = 1
    for _ in range(int(p[0])):
        g.update(keys, game.STEP)
for t in g.tanks:
    print("x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d" % (t.x, t.y, t.dir, t.score, t.spin, t.bullet.active))
print("mode=%d time=%.4f" % (g.mode, g.time_left))
