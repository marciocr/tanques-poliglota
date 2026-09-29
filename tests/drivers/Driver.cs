// Driver de teste (C#): completa a classe do jogo (agora "partial") com um Main.
using System;
using System.Globalization;
using System.IO;

unsafe partial class @CLASS@
{
    static int Main(string[] args)
    {
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        var g = new Game(_ => { });
        g.NewMatch(1);
        byte* keys = stackalloc byte[512];
        foreach (var line in File.ReadAllLines(args[0]))
        {
            var p = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            for (int i = 0; i < 512; i++) keys[i] = 0;
            if (p[1] != "-") foreach (var s in p[1].Split(',')) keys[int.Parse(s)] = 1;
            for (long i = 0, n = long.Parse(p[0]); i < n; i++) g.Update(keys, STEP);
        }
        foreach (var t in g.Tanks)
            Console.WriteLine($"x={t.X:F4} y={t.Y:F4} dir={t.Dir} score={t.Score} spin={t.Spin:F4} bullet={(t.Bullet.Active ? 1 : 0)}");
        Console.WriteLine($"mode={g.Mode} time={g.TimeLeft:F4}");
        return 0;
    }
}
