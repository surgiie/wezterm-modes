#!/usr/bin/env python3
"""Drives a real interactive zsh in a pty to check the SIGUSR1 prompt redraw.

Loads the user's actual 80-keys.zsh so drift between the plugin and the
dotfiles is caught. The prompt is slow on purpose (a sleep inside $(...)),
which widens the window in which zsh drops a USR1 that arrives while the
trap is still running. A naive single-redraw trap is used as a negative
control: if it does not go stale, this test cannot detect the bug.

Usage: python3 tests/zsh_trap_test.py [path/to/80-keys.zsh]
"""
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional

DEFAULT_KEYS_FILE = Path.home() / ".files/home/.zsh/conf.d/80-keys.zsh"
PANE_ID = "7"
PROMPT_RENDER_SECONDS = 0.05

NAIVE_TRAP = "TRAPUSR1() { zle || return; zle reset-prompt }"

ZSHRC_TEMPLATE = """\
setopt prompt_subst
PROMPT='[$(label=$(cat "$XDG_RUNTIME_DIR/wezterm-modes/$WEZTERM_PANE" 2>/dev/null); sleep {render_seconds}; print -r -- $label >> "$XDG_RUNTIME_DIR/rendered.log"; print -rn -- $label)] > '
source {keys_file} 2>/dev/null
{trap_override}
"""


class ShellSession:
    def __init__(self, keys_file: Path, naive_trap: bool = False) -> None:
        self.runtime_dir = Path(tempfile.mkdtemp(prefix="wezterm-modes-test-"))
        self.state_dir = self.runtime_dir / "wezterm-modes"
        self.state_dir.mkdir()
        self.state_file = self.state_dir / PANE_ID
        zdotdir = self.runtime_dir / "zdotdir"
        zdotdir.mkdir()
        (zdotdir / ".zshrc").write_text(
            ZSHRC_TEMPLATE.format(
                render_seconds=PROMPT_RENDER_SECONDS,
                keys_file=keys_file,
                trap_override=NAIVE_TRAP if naive_trap else "",
            )
        )
        self.write_state("INSERT")
        environment = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.runtime_dir),
            "ZDOTDIR": str(zdotdir),
            "XDG_RUNTIME_DIR": str(self.runtime_dir),
            "WEZTERM_PANE": PANE_ID,
            "TERM": "xterm-256color",
        }
        self.master_fd, slave_fd = pty.openpty()
        self.process = subprocess.Popen(
            ["zsh", "-i"],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            env=environment,
            start_new_session=True,
        )
        os.close(slave_fd)
        self.output = ""
        self.read_until_quiet(initial_wait=3.0)

    def write_state(self, label: str) -> None:
        temporary_path = self.state_file.with_suffix(".tmp")
        temporary_path.write_text(label)
        os.rename(temporary_path, self.state_file)

    def signal_shell(self) -> None:
        os.kill(self.process.pid, signal.SIGUSR1)

    def read_until_quiet(self, initial_wait: float = 0.0, quiet_seconds: float = 0.6) -> None:
        deadline_for_first_output = time.monotonic() + initial_wait
        last_output_time = time.monotonic()
        seen_output = False
        while True:
            readable, _, _ = select.select([self.master_fd], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(self.master_fd, 4096)
                except OSError:
                    return
                if not chunk:
                    return
                self.output += chunk.decode("utf-8", errors="replace")
                last_output_time = time.monotonic()
                seen_output = True
                continue
            if seen_output and time.monotonic() - last_output_time >= quiet_seconds:
                return
            if not seen_output and time.monotonic() >= deadline_for_first_output:
                return

    def last_rendered_label(self) -> Optional[str]:
        """Last label zsh expanded into PROMPT; zle redraws only changed
        characters, so the pty output itself cannot be parsed reliably."""
        log_file = self.runtime_dir / "rendered.log"
        if not log_file.exists():
            return None
        lines = log_file.read_text().split()
        return lines[-1] if lines else None

    def close(self) -> None:
        self.process.kill()
        self.process.wait()
        os.close(self.master_fd)


def run_scenario(
    keys_file: Path,
    naive_trap: bool,
    steps: list,
    expected_label: str,
) -> tuple:
    session = ShellSession(keys_file, naive_trap=naive_trap)
    try:
        for action, argument in steps:
            if action == "state":
                session.write_state(argument)
            elif action == "signal":
                session.signal_shell()
            elif action == "sleep":
                time.sleep(argument)
        session.read_until_quiet(initial_wait=1.0)
        rendered = session.last_rendered_label()
        return rendered == expected_label, rendered
    finally:
        session.close()


SCENARIOS = {
    "single change": (
        [("state", "NORMAL"), ("signal", None)],
        "NORMAL",
    ),
    "pair 17ms apart, state changes between": (
        [("state", "JUMP"), ("signal", None), ("sleep", 0.017), ("state", "NORMAL"), ("signal", None)],
        "NORMAL",
    ),
    "state changes while the trap is mid-render": (
        [
            ("state", "JUMP"),
            ("signal", None),
            ("sleep", PROMPT_RENDER_SECONDS / 2),
            ("state", "NORMAL"),
            ("signal", None),
        ],
        "NORMAL",
    ),
    "burst of five changes": (
        [
            step
            for label in ("JUMP", "NORMAL", "VISUAL", "NORMAL", "INSERT")
            for step in (("state", label), ("signal", None), ("sleep", 0.01))
        ],
        "INSERT",
    ),
}


def main() -> int:
    keys_file = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_KEYS_FILE
    if not keys_file.exists():
        print(f"skip: {keys_file} not found")
        return 0

    failures = 0

    for name, (steps, expected_label) in SCENARIOS.items():
        passed, rendered = run_scenario(keys_file, False, steps, expected_label)
        print(f"{'ok  ' if passed else 'FAIL'}  trap: {name} (expected {expected_label}, got {rendered})")
        failures += 0 if passed else 1

    control_steps, control_expected = SCENARIOS["state changes while the trap is mid-render"]
    control_runs = 5
    stale_runs = sum(
        1
        for _ in range(control_runs)
        if not run_scenario(keys_file, True, control_steps, control_expected)[0]
    )
    detected = stale_runs > 0
    print(
        f"{'ok  ' if detected else 'FAIL'}  control: naive trap went stale in "
        f"{stale_runs}/{control_runs} runs (test must be able to detect the bug)"
    )
    failures += 0 if detected else 1

    print(f"\n{len(SCENARIOS) + 1} checks, {failures} failed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
