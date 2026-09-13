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
| `cmdctl accounts env` | Create (or show) the `accounts.env` bootstrap file |
| `cmdctl accounts import [FILE]` | Load `NAME=API_KEY` lines from an env file |
| `cmdctl use NAME` | Manually switch accounts |
| `cmdctl next` | Jump to the best available account |
| `cmdctl prev` | Undo that jump and restore the previous one |
| `cmdctl usage [HARNESS\|all] [VIEW]` | Token usage — Command Code native, others via ccusage |
| `cmdctl dashboard [--source HARNESS]` | One-screen account + agent overview (the fun one) |
| `cmdctl status` | Current account health, with a usage bar |
| `cmdctl check` | Force-probe every account right now |
| `cmdctl run -- [args]` | Auto-switch launch (what the alias calls) |
| `cmdctl alias` | Print the alias line to paste into your rc file |
| `cmdctl doctor` | Diagnose your environment like a concerned GP |
| `cmdctl install-hook` | Install the Stop hook for turn-boundary detection |

Most commands accept `--json` where it makes sense (`usage`, `dashboard`), so you can pipe cmdctl into your own dashboards, spreadsheets, or existential spreadsheets.

---

## Picking which harness you're staring at

`cmdctl usage` answers one question: *where did all my tokens go?* It gathers usage in two ways:

- **Command Code** is built in. cmdctl reads its local session logs directly (`~/.commandcode/projects/**/*.jsonl`), so you get real per-turn input/output/cache tokens and cost with no extra tooling.
- **Everything else** goes through [ccusage](https://github.com/ryoppippi/ccusage): Claude Code, Codex, OpenCode, Amp, Droid, Codebuff, Hermes, pi-agent, Goose, OpenClaw, Kilo, Kimi, Qwen, Copilot CLI, Gemini CLI, Antigravity, Grok, ZCode.

```bash
cmdctl usage                       # Command Code first, then all ccusage harnesses
cmdctl usage commandcode           # Command Code only (native, offline)
cmdctl usage commandcode monthly   # ...by month
cmdctl usage commandcode session   # ...per conversation
cmdctl usage claude                # just Claude Code, daily
cmdctl usage codex monthly         # Codex, monthly
cmdctl usage gemini session        # Gemini CLI, by session
cmdctl usage --source droid weekly # same thing, flag-flavoured
cmdctl usage --list                # list every harness + view
cmdctl usage commandcode --json    # machine-readable, because of course
```

First positional is a **harness** (if it's a known one), second is a **view** (`daily`, `weekly`, `monthly`, `session`), and anything else is passed straight through. `commandcode` has aliases: `cmd`, `cc`, `command-code`. The dashboard takes the same `--source` flag:

```bash
cmdctl dashboard --source claude
```

A native Command Code report looks like this:

```
Command Code — Daily usage

  DAILY        TURNS   INPUT      OUTPUT     CACHE      COST         MODELS
  2026-09-09   406     165.1M     312.2k     163.8M     $3.45        deepseek-v4-flash, v4-pro
  2026-09-10   67      8.0M       54.7k      7.8M       $0.14        deepseek-v4-flash

  TOTAL: 913 turns · 228.5M in · 599.0k out · 226.2M cached · $33.49
```

Under the hood it sums each turn's `usage` block and groups by day, ISO week, month, or session. It is 100% local and read-only.

---

## Accounts from an env file

Typing keys by hand is for people with spare time. Drop them in a dotenv-style file instead:

```bash
cmdctl accounts env       # writes ~/.config/cmdctl/accounts.env (chmod 600)
```

Then fill it in:

```dotenv
# one NAME=API_KEY per line; comments and blank lines are ignored
work=cmd_live_xxxxxxxxxxxxxxxx
personal="cmd_live_yyyyyyyyyyyyyyyy"
export CMDCTL_ACCOUNT_backup=cmd_live_zzzzzzzzzzzz
```

…and load it:

```bash
cmdctl accounts import                 # reads accounts.env
cmdctl accounts import ./team.env      # or any path you like
```

A few conveniences baked in:

- `export ` prefixes and surrounding quotes are stripped for you.
- A `CMDCTL_ACCOUNT_` prefix is optional — `CMDCTL_ACCOUNT_work` and `work` are the same account.
- Re-running `import` updates existing accounts instead of duplicating them.
- If `accounts.json` is empty and `accounts.env` exists, cmdctl loads it automatically on startup. No command needed.

Point it somewhere else with `CMDCTL_ENV_FILE=/path/to/file`.

---

## The dashboard

`cmdctl dashboard` is the centerpiece. One command, four acts:

1. **Accounts table** — status, plan, tokens burned, cost, and credits for every account, plus a running total so you know exactly how fast your money is learning to code.
2. **Command Code local usage** — turns, tokens, and estimated spend from your on-disk session logs, all-time and month-to-date.
3. **Agent usage** — delegated to `ccusage`, so Claude Code, Codex, OpenCode, Amp, Droid, Goose, and a bunch of other coding CLIs get rolled into one local report. Narrow it with `--source`.
4. **No data leaves your machine** — both readers go straight to local files. They're nosy, but in a respectful, read-only way.

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

COMMAND CODE — local session usage

  All time:  913 turns · 229.1M tokens · $33.49
  This month (2026-09): 612 turns · $3.84

AGENT USAGE — all other harnesses (local)
...
```

---

## Multi-agent support

cmdctl is multi-harness by design, with two engines:

- **Native (Command Code)** — cmdctl parses the per-turn `usage` blocks in `~/.commandcode/projects/**/*.jsonl` itself. No extra dependency, works fully offline.
- **ccusage** — everything else is read from local logs via [ccusage](https://github.com/ryoppippi/ccusage), which covers a genuinely absurd list of coding CLIs:

  **Claude Code**, **Codex**, **OpenCode**, **Amp**, **Droid**, **Codebuff**, **Hermes Agent**, **pi-agent**, **Goose**, **OpenClaw**, **Kilo**, **Kimi**, **Qwen**, **GitHub Copilot CLI**, **Gemini CLI**, **Antigravity**, **Grok Build CLI**, and **ZCode**.

One `cmdctl usage` gives you the "where did all my tokens go" answer across your entire agent menagerie, Command Code included.

> Note: usage is read from **local logs** and costs are estimated from token counts + model pricing. It's a best-effort sanity check, not an invoice.

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
| `accounts.env` | Optional `NAME=API_KEY` bootstrap file |
| `state.json` | Current account, exhaustion marks, probe cache |

### Environment variables

| Variable | Default | What it does |
|----------|---------|-------------|
| `CMDCTL_DIR` | `~/.config/cmdctl` | Config directory |
| `CMDCTL_ENV_FILE` | `$CMDCTL_DIR/accounts.env` | Where `accounts import` looks by default |
| `CMDCTL_DEFAULT_SOURCE` | unset (all) | Default harness for `cmdctl usage` |
| `CMDCTL_DEFAULT_VIEW` | `daily` | Default view for `cmdctl usage` |
| `COMMANDCODE_DIR` | `~/.commandcode` | Command Code data dir (session logs live here) |
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
