package migrate

import (
	"bytes"
	"fmt"
	"math"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var (
	stepsFile        string
	dbDir            string
	envFile          string
	assumeYes        bool
	force            bool
	silent           bool
	verboseCount     int
	extremelyVerbose bool
)

func envDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

const banner = "\n" +
	"   ▄████████   ▄▄▄▄███▄▄▄▄    ▄█     ▄██████▄  \n" +
	"  ███    ███ ▄██▀▀▀███▀▀▀██▄ ███    ███    ███ \n" +
	"  ███    █▀  ███   ███   ███ ███▌   ███    █▀  \n" +
	"  ███        ███   ███   ███ ███▌  ▄███        \n" +
	"▀███████████ ███   ███   ███ ███▌ ▀▀███ ████▄  \n" +
	"         ███ ███   ███   ███ ███    ███    ███ \n" +
	"   ▄█    ███ ███   ███   ███ ███    ███    ███ \n" +
	" ▄████████▀   ▀█   ███   █▀  █▀     ████████▀  \n"

const description = "smig runs structured database migrations defined in a yaml step file, with sha locked apply history, optional position based ordering, and a strict boot_check that gates CI behind operator acknowledged local upgrades."

var rootCmd = &cobra.Command{
	Use:           "smig",
	Short:         "Database migration tool with upgrade gated CI deploys",
	Long:          wrapBlock(description, 64),
	Version:       cli.Version,
	SilenceUsage:  true,
	SilenceErrors: true,
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		switch {
		case silent:
			log.Level = log.LevelSilent
		case extremelyVerbose || verboseCount >= 2:
			log.Level = log.LevelExtreme
		case verboseCount == 1:
			log.Level = log.LevelVerbose
		default:
			log.Level = log.LevelNormal
		}
	},
}

func Execute() error {
	if err := requireEqualsFlags(os.Args[1:]); err != nil {
		return err
	}
	return rootCmd.Execute()
}

func requireEqualsFlags(args []string) error {
	value := valueFlagNames()
	for _, a := range args {
		if a == "--" {
			break
		}
		if strings.HasPrefix(a, "--") && !strings.Contains(a, "=") {
			name := a[2:]
			if value[name] {
				return fmt.Errorf("long flag --%s takes its value with an equals sign: --%s=<value>", name, name)
			}
		}
	}
	return nil
}

func valueFlagNames() map[string]bool {
	out := map[string]bool{}
	add := func(fs *pflag.FlagSet) {
		fs.VisitAll(func(f *pflag.Flag) {
			if f.NoOptDefVal == "" {
				out[f.Name] = true
			}
		})
	}
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		add(c.PersistentFlags())
		add(c.Flags())
		for _, sub := range c.Commands() {
			walk(sub)
		}
	}
	walk(rootCmd)
	return out
}

func wrapBlock(s string, width int) string {
	words := strings.Fields(s)
	var lines []string
	cur := ""
	for _, w := range words {
		switch {
		case cur == "":
			cur = w
		case len(cur)+1+len(w) <= width:
			cur += " " + w
		default:
			lines = append(lines, cur)
			cur = w
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	return strings.Join(lines, "\n")
}

func stdoutTTY() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

const (
	jumpAmp   = 2
	animDelay = 60 * time.Millisecond
)

var shimmer = []string{
	"\033[38;5;39m",
	"\033[38;5;45m",
	"\033[38;5;51m",
	"\033[38;5;87m",
	"\033[38;5;123m",
	"\033[1;37m",
}

type letterSeg struct {
	start int
	end   int
}

func bannerGrid() ([][]rune, int) {
	lines := strings.Split(strings.Trim(banner, "\n"), "\n")
	grid := make([][]rune, len(lines))
	w := 0
	for i, ln := range lines {
		grid[i] = []rune(ln)
		if len(grid[i]) > w {
			w = len(grid[i])
		}
	}
	for i := range grid {
		for len(grid[i]) < w {
			grid[i] = append(grid[i], ' ')
		}
	}
	return grid, w
}

func bannerLetters(grid [][]rune, w int) []letterSeg {
	blank := make([]bool, w)
	for c := 0; c < w; c++ {
		b := true
		for r := range grid {
			if grid[r][c] != ' ' {
				b = false
				break
			}
		}
		blank[c] = b
	}
	var segs []letterSeg
	c := 0
	for c < w {
		for c < w && blank[c] {
			c++
		}
		if c >= w {
			break
		}
		start := c
		for c < w {
			if blank[c] && c+1 < w && blank[c+1] {
				break
			}
			c++
		}
		segs = append(segs, letterSeg{start, c})
	}
	return segs
}

func ownerColumns(segs []letterSeg, w int) []int {
	owner := make([]int, w)
	for c := 0; c < w; c++ {
		owner[c] = -1
		for i, s := range segs {
			if c >= s.start && c < s.end {
				owner[c] = i
				break
			}
		}
	}
	return owner
}

func renderBannerFrame(grid [][]rune, w int, owner []int, segs []letterSeg, frame int, animate bool) {
	rows := len(grid)
	height := rows + jumpAmp
	offsets := make([]int, len(segs))
	for i := range segs {
		if animate {
			v := math.Sin(float64(frame)*0.55 - float64(i)*0.9)
			if v < 0 {
				v = 0
			}
			offsets[i] = int(math.Round(v * float64(jumpAmp)))
		}
	}
	canvas := make([][]rune, height)
	for r := range canvas {
		canvas[r] = make([]rune, w)
		for c := range canvas[r] {
			canvas[r][c] = ' '
		}
	}
	for c := 0; c < w; c++ {
		off := 0
		if owner[c] >= 0 {
			off = offsets[owner[c]]
		}
		for k := 0; k < rows; k++ {
			canvas[off+k][c] = grid[k][c]
		}
	}
	for r := 0; r < height; r++ {
		var b strings.Builder
		cur := ""
		for c := 0; c < w; c++ {
			ch := canvas[r][c]
			col := ""
			if ch != ' ' && owner[c] >= 0 {
				if animate {
					col = shimmer[(frame+owner[c]*2)%len(shimmer)]
				} else {
					col = "\033[1;36m"
				}
			}
			if col != cur {
				if cur != "" {
					b.WriteString("\033[0m")
				}
				b.WriteString(col)
				cur = col
			}
			b.WriteRune(ch)
		}
		if cur != "" {
			b.WriteString("\033[0m")
		}
		fmt.Println(b.String())
	}
}

func printVersion(w int) {
	v := cli.Version
	pad := (w - len([]rune(v))) / 2
	if pad < 0 {
		pad = 0
	}
	fmt.Printf("%s\033[90m%s\033[0m\n", strings.Repeat(" ", pad), v)
}

func showBannerThenHelp(body string) {
	grid, w := bannerGrid()
	segs := bannerLetters(grid, w)
	owner := ownerColumns(segs, w)
	height := len(grid) + jumpAmp

	renderBannerFrame(grid, w, owner, segs, 0, false)
	printVersion(w)
	fmt.Print(body)

	if !stdoutTTY() || !stdinTTY() {
		return
	}
	restore := cbreak()
	if restore == nil {
		return
	}

	below := 1 + strings.Count(body, "\n")
	up := height + below
	stop := make(chan struct{})
	go func() {
		var b [1]byte
		os.Stdin.Read(b[:])
		close(stop)
	}()

	fmt.Print("\033[?25l")
	for frame := 1; ; frame++ {
		select {
		case <-stop:
			fmt.Printf("\033[%dA", up)
			renderBannerFrame(grid, w, owner, segs, 0, false)
			fmt.Printf("\033[%dB", below)
			fmt.Print("\033[?25h")
			restore()
			return
		default:
		}
		fmt.Printf("\033[%dA", up)
		renderBannerFrame(grid, w, owner, segs, frame, true)
		fmt.Printf("\033[%dB", below)
		time.Sleep(animDelay)
	}
}

func stdinTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

func cbreak() func() {
	probe := exec.Command("stty", "-g")
	probe.Stdin = os.Stdin
	out, err := probe.Output()
	if err != nil {
		return nil
	}
	saved := strings.TrimSpace(string(out))
	apply := func(args ...string) {
		c := exec.Command("stty", args...)
		c.Stdin = os.Stdin
		c.Run()
	}
	apply("-echo", "-icanon", "min", "1", "time", "0")
	done := false
	restore := func() {
		if done {
			return
		}
		done = true
		apply(saved)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		restore()
		fmt.Print("\033[?25h")
		os.Exit(130)
	}()
	return restore
}

func init() {
	defaultHelp := rootCmd.HelpFunc()
	rootCmd.SetHelpFunc(func(c *cobra.Command, args []string) {
		if c != rootCmd {
			defaultHelp(c, args)
			return
		}
		var buf bytes.Buffer
		orig := c.OutOrStdout()
		c.SetOut(&buf)
		defaultHelp(c, args)
		c.SetOut(orig)
		showBannerThenHelp(buf.String())
	})

	rootCmd.PersistentFlags().StringVar(&stepsFile, "schema", envDefault("MIGRATE_SCHEMA", "./database/migrate.yml"), "Path to migrate.yml, defaults from MIGRATE_SCHEMA")
	rootCmd.PersistentFlags().StringVar(&dbDir, "db-dir", envDefault("DB_DIR", "./database"), "Path to database directory, defaults from DB_DIR")
	rootCmd.PersistentFlags().StringVar(&envFile, "env", "", "Optional dotenv file to load")
	rootCmd.PersistentFlags().BoolVarP(&assumeYes, "yes", "y", false, "Bypass interactive confirmation prompts")
	rootCmd.PersistentFlags().BoolVar(&force, "force", false, "Bypass safety checks where supported")
	rootCmd.PersistentFlags().BoolVarP(&silent, "silent", "s", false, "Suppress all output except errors")
	rootCmd.PersistentFlags().CountVarP(&verboseCount, "verbose", "v", "Verbose output, repeat as -vv for extreme")
	rootCmd.PersistentFlags().BoolVar(&extremelyVerbose, "extremely-verbose", false, "Dump every SQL statement and all psql output")
	rootCmd.PersistentFlags().StringVar(&cli.AnthropicKey, "anthropic-key", "", "Anthropic API key (or set ANTHROPIC_API_KEY)")
	rootCmd.PersistentFlags().StringVar(&cli.Model, "model", "claude-sonnet-4-6", "Claude model id for AI commands")

	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(upgradeCmd)
	rootCmd.AddCommand(statCmd)
	rootCmd.AddCommand(checkCmd)
}
