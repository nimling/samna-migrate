package migrate

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/nimling/samna-migrate/internal/log"
	"github.com/spf13/cobra"
)

var completionAuto bool

var completionCmd = &cobra.Command{
	Use:   "completion [bash|zsh|fish|powershell]",
	Short: "Print the shell completion script, or wire it up with --auto",
	Long: `Print the completion script for one shell to stdout, or pass --auto to
install it.

--auto detects the shell from $SHELL when no shell is given, writes a smig owned
completion file under ~/.config/smig/completions, and points the shell rc file at
it inside a managed block. Rerunning --auto refreshes the smig owned file and
leaves the rc untouched, so an upgrade reinstalls completion in one step. fish
loads from its own completions directory and needs no rc change.

  smig completion zsh           print the zsh script
  smig completion --auto        detect the shell and install
  smig completion bash --auto   install for a named shell`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		shell := ""
		if len(args) == 1 {
			shell = args[0]
		}
		if completionAuto {
			return installCompletion(cmd.Root(), shell)
		}
		if shell == "" {
			return fmt.Errorf("name a shell (bash, zsh, fish, powershell) or pass --auto")
		}
		return writeCompletionScript(cmd.Root(), shell, os.Stdout)
	},
}

func writeCompletionScript(root *cobra.Command, shell string, w io.Writer) error {
	switch shell {
	case "bash":
		return root.GenBashCompletionV2(w, true)
	case "zsh":
		return root.GenZshCompletion(w)
	case "fish":
		return root.GenFishCompletion(w, true)
	case "powershell":
		return root.GenPowerShellCompletionWithDesc(w)
	default:
		return fmt.Errorf("unsupported shell %q, use bash, zsh, fish, or powershell", shell)
	}
}

func detectShell() string {
	base := filepath.Base(os.Getenv("SHELL"))
	switch {
	case strings.Contains(base, "zsh"):
		return "zsh"
	case strings.Contains(base, "bash"):
		return "bash"
	case strings.Contains(base, "fish"):
		return "fish"
	}
	return ""
}

func installCompletion(root *cobra.Command, shell string) error {
	if shell == "" {
		shell = detectShell()
	}
	if shell == "" {
		return fmt.Errorf("could not detect the shell from $SHELL, name it: smig completion <shell> --auto")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}

	var script bytes.Buffer
	if err := writeCompletionScript(root, shell, &script); err != nil {
		return err
	}

	if shell == "fish" {
		dir := filepath.Join(home, ".config", "fish", "completions")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		path := filepath.Join(dir, "smig.fish")
		if err := os.WriteFile(path, script.Bytes(), 0o644); err != nil {
			return err
		}
		log.Success("wrote %s", path)
		log.Info("fish loads it on the next shell")
		return nil
	}

	if shell != "bash" && shell != "zsh" {
		return fmt.Errorf("auto install covers bash, zsh, and fish; for %s run: smig completion %s", shell, shell)
	}

	dir := filepath.Join(home, ".config", "smig", "completions")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	name := "smig.bash"
	if shell == "zsh" {
		name = "_smig"
	}
	scriptPath := filepath.Join(dir, name)
	if err := os.WriteFile(scriptPath, script.Bytes(), 0o644); err != nil {
		return err
	}
	log.Success("wrote %s", scriptPath)

	rc := filepath.Join(home, ".bashrc")
	body := fmt.Sprintf("[ -f %q ] && source %q", scriptPath, scriptPath)
	if shell == "zsh" {
		rc = filepath.Join(home, ".zshrc")
		body = fmt.Sprintf("fpath=(%q $fpath)\nautoload -Uz compinit && compinit -u", dir)
	}
	if err := ensureManagedBlock(rc, body); err != nil {
		return err
	}
	log.Success("wired %s", rc)
	log.Info("start a new shell or run: source %s", rc)
	return nil
}

func ensureManagedBlock(path, body string) error {
	const start = "# >>> smig completion >>>"
	const end = "# <<< smig completion <<<"
	block := start + "\n" + body + "\n" + end

	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	content := string(data)

	if i := strings.Index(content, start); i >= 0 {
		if j := strings.Index(content, end); j > i {
			content = content[:i] + block + content[j+len(end):]
		} else {
			content = strings.TrimRight(content, "\n") + "\n" + block + "\n"
		}
	} else {
		if content != "" && !strings.HasSuffix(content, "\n") {
			content += "\n"
		}
		content += block + "\n"
	}
	return os.WriteFile(path, []byte(content), 0o644)
}

func init() {
	rootCmd.CompletionOptions.DisableDefaultCmd = true
	completionCmd.Flags().BoolVar(&completionAuto, "auto", false, "Detect the shell and install completion into the rc file")
	rootCmd.AddCommand(completionCmd)
}
