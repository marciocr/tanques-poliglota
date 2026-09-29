// Driver de teste (Go): roda no mesmo pacote do jogo, cujo main() foi renomeado.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func main() {
	g := &Game{}
	g.newMatch(1)
	f, _ := os.Open(os.Args[1])
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		p := strings.Fields(sc.Text())
		steps, _ := strconv.Atoi(p[0])
		keys := make([]uint8, 512)
		if p[1] != "-" {
			for _, k := range strings.Split(p[1], ",") {
				n, _ := strconv.Atoi(k)
				keys[n] = 1
			}
		}
		for i := 0; i < steps; i++ {
			g.update(keys, Step)
		}
	}
	for _, t := range g.tanks {
		b := 0
		if t.bullet.active {
			b = 1
		}
		fmt.Printf("x=%.4f y=%.4f dir=%d score=%d spin=%.4f bullet=%d\n", t.x, t.y, t.dir, t.score, t.spin, b)
	}
	fmt.Printf("mode=%d time=%.4f\n", g.mode, g.timeLeft)
}
