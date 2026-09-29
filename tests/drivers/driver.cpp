// Driver de teste (C++): inclui o jogo, renomeando o main() dele.
#define main jogo_main
#include "main.cpp"
#undef main
#include <cstdio>
#include <fstream>
#include <sstream>

int main(int, char** argv) {
    Game g;
    g.new_match(1);
    std::ifstream f(argv[1]);
    std::string line;
    while (std::getline(f, line)) {
        std::istringstream ss(line);
        long steps;
        std::string ks;
        ss >> steps >> ks;
        Uint8 keys[512] = {};
        if (ks != "-") {
            std::stringstream k(ks);
            std::string n;
            while (std::getline(k, n, ',')) keys[std::stoi(n)] = 1;
        }
        for (long i = 0; i < steps; ++i) g.update(keys, STEP);
    }
    for (auto& t : g.tanks)
        std::printf("x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d\n", t.x, t.y, t.dir, t.score, t.spin,
                    int(t.bullet.active));
    std::printf("mode=%d time=%.4f\n", g.mode, g.time_left);
}
