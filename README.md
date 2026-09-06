# cmdctl

> *Your Command Code subscription has a panic attack so you don't have to.*

`cmdctl` is a tiny bash sidekick that keeps an eye on all your [Command Code](https://commandcode.ai) accounts and casually shoves a fresh one into the driver's seat the moment the current one runs out of tokens. It's the multi-account manager you didn't know you needed, until the words `windowLimits.exceeded` ruined your afternoon.

One-liner: `cmdctl` lets you juggle multiple accounts, peek at who's exhausted, and auto-rotate mid-conversation so your agent keeps typing while you keep your sanity.

---

## The awkward part first: what it actually does

```
cmd (your alias)
 └─ cmdctl run --
      ├─ 1. Pre-flight: is the current account dead? → pick a live one instead
      ├─ 2. Launch the real `cmd` with your args (TTY intact, promises kept)
      ├─ 3. A background watcher polls quota state every 15s
      │      └─ sees "exceeded" or a QUOTA/AUTH error? → kills session → rotates
      ├─ 4. On rotation: swaps auth.json atomically → relaunches with --continue --yolo
      └─ 5. Max 1 rotation cycle, then an honest "we tried" message
```

Token limits stop being your problem and start being cmdctl's. It's like having a friend who quietly refills your coffee while you're mid-flow — except the coffee is API keys and the friend is a shell script with trust issues.

---

## Install

```bash
git clone https://github.com/yourusername/cmdctl.git
cd cmdctl
bash install.sh
```

Then teach your shell the magic words:

```bash
alias cmd='cmdctl run --'
```

And, if you want turn-boundary detection (recommended):

```bash
cmdctl install-hook
```

### Requirements

- **Bash** 4+ (the script will judge you if you bring anything older)
- **curl** and **jq** (the quiet workhorses)
- **Node.js** 18+ (for command-code itself)
- **command-code** — `npm i -g command-code`
- **ccusage** — optional but recommended, powers the `usage` and `dashboard` views. Any of these works:
  ```bash
  npm i -g ccusage       # or just have npm/bun installed and cmdctl will npx/bunx it
  ```

---

## Quick start

For each account you want cmdctl to babysit:

```bash
cmd logout && cmd login          # sign into account N in the browser
cmdctl accounts add work-account # capture the key (or omit the name to auto-label)
```

Rinse and repeat, then admire your handiwork:

```bash
cmdctl accounts ls
cmdctl check
cmdctl dashboard
```

From here on, just type `cmd` like always. cmdctl silently picks the healthiest account, watches for the dreaded limit, and rotates when needed.

---

## Commands

| Command | What it does |
|---------|-------------|
| `cmdctl accounts ls` | List every saved account (masked keys, obviously) |
| `cmdctl accounts add [NAME]` | Capture the currently logged-in account |
| `cmdctl accounts rm NAME` | Yeet an account from the registry |
| `cmdctl accounts rename OLD NEW` | Give an account a better name |
| `cmdctl accounts show [NAME]` | Inspect one account's details |
| `cmdctl use NAME` | Manually switch accounts |
| `cmdctl next` | Jump to the best available account |
| `cmdctl prev` | Undo that jump and restore the previous one |
| `cmdctl usage [daily\|weekly\|monthly\|session]` | Token usage across all your coding agents |
| `cmdctl dashboard` | One-screen account + agent overview (the fun one) |
| `cmdctl status` | Current account health, with a usage bar |
| `cmdctl check` | Force-probe every account right now |
| `cmdctl run -- [args]` | Auto-switch launch (what the alias calls) |
| `cmdctl alias` | Print the alias line to paste into your rc file |
| `cmdctl doctor` | Diagnose your environment like a concerned GP |
| `cmdctl install-hook` | Install the Stop hook for turn-boundary detection |

Most commands accept `--json` where it makes sense (`usage`, `dashboard`), so you can pipe cmdctl into your own dashboards, spreadsheets, or existential spreadsheets.

---

## The dashboard

`cmdctl dashboard` is the centerpiece. One command, three acts:

1. **Accounts table** — status, plan, tokens burned, cost, and credits for every account, plus a running total so you know exactly how fast your money is learning to code.
2. **Agent usage** — delegated to `ccusage`, so Claude Code, Codex, OpenCode, Amp, Droid, Goose, and a bunch of other coding CLIs get rolled into one local report.
3. **No data leaves your machine** — ccusage reads local logs, never uploads them. It's nosy, but in a respectful, read-only way.

```
cmdctl dashboard
━━━━━━━━━━━━━━━━
Accounts: 3   Current: work-account

ACCOUNT                 STATUS     PLAN       TOKENS      COST          CREDITS
-------                 ------     ----       ------      -----         -------
*work-account           active     pro        12.4M       $8.21         5.0M + 0
 personal-account       active     pro        480.0M      $61.10        800.0k + 0
 weekend-account        exhausted  pro        0           $0.00         0 + 0

TOTAL ACROSS ACCOUNTS — 492.4M tokens, $69.31

AGENT USAGE (local, across Claude Code / Codex / etc.)
...
```

---

## Multi-agent support

Yes — cmdctl doesn't just watch Command Code. The `usage` and `dashboard` commands hand off to [ccusage](https://github.com/ryoppippi/ccusage), which reads local usage data from a genuinely absurd list of coding CLIs:

- **Claude Code**, **Codex**, **OpenCode**, **Amp**, **Droid**, **Codebuff**, **Hermes Agent**, **pi-agent**, **Goose**, **OpenClaw**, **Kilo**, **Kimi**, **Qwen**, **GitHub Copilot CLI**, **Gemini CLI**, **Antigravity**, **Grok Build CLI**, and **ZCode**.

That means one `cmdctl dashboard` gives you the "where did all my tokens go" answer across your entire agent menagerie, not just Command Code.

> Note: agent usage reads **local logs** and estimates costs from token counts + model pricing. It's a best-effort sanity check, not an invoice.

---

## How auto-switch works (the deep dive)

Auth.json is swapped atomically via tmp-file-and-rename, so there's never a half-written key file staring at you. The current auth is backed up to `auth.json.cmdctl-bak` before each swap.

The watcher has three ways to realize you're in trouble:

1. The credits endpoint reports `windowLimits.exceeded`.
2. An API call comes back `QUOTA` or `AUTH`.
3. You set a `TOKEN_CAP` and the account smashes through it before the hard limit even happens.

On a quota signal, cmdctl kills the child, marks that account exhausted (with a TTL so it gets a second chance later), picks the next healthiest account, and relaunches with `--continue --yolo` so the conversation resumes instead of restarting from scratch.

---

## Configuration

Everything lives in `~/.config/cmdctl/`:

| File | Purpose |
|------|---------|
| `accounts.json` | Account registry (names + API keys) |
| `state.json` | Current account, exhaustion marks, probe cache |

### Environment variables

| Variable | Default | What it does |
|----------|---------|-------------|
| `CMDCTL_DIR` | `~/.config/cmdctl` | Config directory |
| `AUTH_FILE` | `~/.commandcode/auth.json` | Command Code auth file |
| `REAL_CLI` | auto-detected | Path to command-code entrypoint |
| `EXHAUSTED_TTL` | `3600` | Seconds before retrying an exhausted account |
| `PROBE_CACHE_TTL` | `300` | Seconds to cache usage API probes |
| `POLL_INTERVAL` | `15` | Seconds between watcher polls |
| `TOKEN_CAP` | `0` (off) | Proactive rotation threshold |
| `NO_COLOR` | unset | Disable colored output |

---

## License

MIT. Go build something silly with it.
