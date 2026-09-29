
// Driver de teste (Rust): o código foi cortado antes do main() da SDL. Este
// KeyboardState toma o lugar do da crate sdl2, que só existe com a SDL viva.
struct KeyboardState {
    k: [bool; 512],
}
impl KeyboardState {
    fn is_scancode_pressed(&self, s: Scancode) -> bool {
        self.k[s as usize]
    }
}

fn main() {
    let path = std::env::args().nth(1).unwrap();
    let snd = Sounds { queue: None, shot: vec![], hit: vec![], ricochet: vec![], end: vec![] };
    let mut g = Game::new();
    for line in std::fs::read_to_string(path).unwrap().lines() {
        let p: Vec<&str> = line.split_whitespace().collect();
        let mut keys = KeyboardState { k: [false; 512] };
        if p[1] != "-" {
            for k in p[1].split(',') {
                keys.k[k.parse::<usize>().unwrap()] = true;
            }
        }
        for _ in 0..p[0].parse::<u64>().unwrap() {
            g.update(&keys, STEP, &snd);
        }
    }
    for t in &g.tanks {
        println!(
            "x={:.4} y={:.4} dir={} score={} spin={:.4} bullet={}",
            t.x, t.y, t.dir, t.score, t.spin, t.bullet.active as i32
        );
    }
    println!("mode={} time={:.4}", g.mode, g.time_left);
}
