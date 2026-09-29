
// Driver de teste (D): anexado ao fim do app.d, cujo main() foi renomeado.
int main(string[] args)
{
    import std.stdio : File, writefln;
    import std.string : split, strip;

    Game g;
    g.newMatch(1);
    foreach (line; File(args[1]).byLine)
    {
        auto p = line.strip.split;
        ubyte[512] keys;
        if (p[1] != "-") foreach (k; p[1].split(",")) keys[k.to!int] = 1;
        foreach (_; 0 .. p[0].to!long) g.update(keys.ptr, STEP);
    }
    foreach (ref t; g.tanks)
        writefln("x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d", t.x, t.y, t.dir, t.score, t.spin,
                 t.bullet.active ? 1 : 0);
    writefln("mode=%d time=%.4f", g.mode, g.timeLeft);
    return 0;
}
