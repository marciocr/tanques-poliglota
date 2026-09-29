import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

/** Driver de teste (Java): aplica um roteiro à lógica do jogo, sem janela. */
public class Drv {
    public static void main(String[] a) throws Exception {
        var g = new @CLASS@.Game(s -> {});
        for (String line : Files.readAllLines(Path.of(a[0]))) {
            String[] p = line.trim().split("\\s+");
            boolean[] k = new boolean[512];
            if (!p[1].equals("-")) for (String s : p[1].split(",")) k[Integer.parseInt(s)] = true;
            @CLASS@.Keys keys = sc -> k[sc];
            for (long i = 0, n = Long.parseLong(p[0]); i < n; i++) g.update(keys, @CLASS@.STEP);
        }
        for (var t : g.tanks)
            System.out.println(String.format(Locale.ROOT, "x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d",
                t.x, t.y, t.dir, t.score, t.spin, t.bullet.active ? 1 : 0));
        System.out.println(String.format(Locale.ROOT, "mode=%d time=%.4f", g.mode, g.timeLeft));
    }
}
