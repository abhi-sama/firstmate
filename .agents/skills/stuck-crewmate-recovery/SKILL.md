---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `bin/fm-send.sh`.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `bin/fm-send.sh <window> --key Escape`.
4. If the crewmate's agent is gone but its pane dropped to a live shell in the worktree and an in-flight `no-mistakes` run is still advancing in the background, do NOT `fm-spawn` a fresh worktree - resume the agent in place from that worktree pane.
   The committed work, the worktree, and the running validation all survive the agent's exit, so a fresh worktree would throw them away.
   Verify the pane is a live shell sitting in the worktree first, for example `tmux list-panes -F '#{pane_current_command} #{pane_current_path}'`, then relaunch the same harness with its resume command (per `harness-adapters`) directly in that pane.
   The resume restores the crewmate's full context and it picks the run back up.
5. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
6. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.
