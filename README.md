# Plug

**Manage all your plugins, catch every update, and have AI scan the code BEFORE you update or install.**

![Plug](preview.png)

Plugins run as you, with no sandbox. A plugin you install is code you have not
read, and an update is more of it. Plug manages your installed community plugins
— toggle, remove, browse and install more — and puts the same gate in front of
both moments: before a plugin is installed, and before an update is applied, an
AI reviewer of your choice reads the actual code and tells you, in plain
English, whether it is safe.

## What it does

- **Installed** — every community plugin you have, each row with the same four
  controls in the same place: **update**, **restore**, **remove** and an
  **on/off** switch. The update control lights **green** the moment the
  plugin's repository has moved past what you installed; restore lights up once
  Plug has applied an update it can undo. Laid out two-up to save space, with a
  folded **Official** section for Omarchy's own optional bar widgets — those
  show just the on/off switch, lined up with the community rows (a built-in is
  part of Omarchy, not an installed copy, so there is nothing to update or
  remove).
- **The trust mark** on each row — a check, a circle, or an exclamation —
  is a quick capability read of the plugin's
  source — what it can reach, run and write — and it is one of three things,
  never a number:
  - ✅ **Green check — squeaky clean.** Nothing that leaves the machine, nothing
    alarming even mentioned, no install step. It keeps to itself.
  - ❗ **Red exclamation — read it first.** Not a stop sign:
    a warning that this needs your eyes. Code that *actually runs* one of:
    reading private files (`.ssh`, `id_rsa`, `.gnupg`,
    keyring, `/etc/shadow`), or hiding itself behind an encoder (`atob`,
    `eval`, a packed line). No listed plugin is expected to be red. If it
    appears, read the code before anything else.
  - 🟡 **Amber circle — the honest middle.** It reaches the network, has a setup
    script that installs or escalates, runs privileged commands (`sudo`/`pkexec`) or a package
    manager, or merely *displays* any of those for you to copy — the reason
    on the row says which. A capability held openly is not an accusation;
    most useful plugins live here.

  **The row always says which.** "reaches the network", "has a setup script",
  "shows you commands as root" — a colour you cannot account for is worse than
  no colour, so the reason travels with it.

  Run versus show still decides the wording on the row: a plugin printing
  `sudo systemctl enable …` on screen for you to copy is being helpful, and
  one running it holds a capability worth naming. Comments are ignored
  entirely, and a long line counts as packed content only when nothing breaks
  it up.

  There was a 0–100 score here until 2026-08-30. It implied a precision this
  scan has never had — nobody could say what 44 meant, the weights behind it
  were invented, and it put a plugin that talks to earbuds below one that
  clones strangers' repositories for a living.
- **Review an update** — Plug fetches the exact changes, runs a fast offline
  scan, and hands the diff to your chosen AI reviewer (read-only). You get a
  **safe / be careful / do not** verdict, a plain-English summary of what
  changed, anything to watch for, and the author's own commit notes — then you
  decide. It also judges the update the way the marketplace's own approval
  checks do (new privileges, downloads, network hosts, background processes, or
  writes outside the plugin). The reviewer is told which question it is
  answering — a first install, or a change to something already installed.
- **Restore** — undo the last update you applied, returning the plugin to the
  version it was on before. Plug then flags the update as available again, so
  nothing is lost — you can re-apply it whenever you are ready.
- **Store** — search the community marketplace, and **read a plugin before you
  install it**. Pressing install does not install: Plug clones the plugin to a
  throwaway directory, scans what it can do, has your reviewer read the whole
  source, and tells you plainly whether it looks safe — then you decide, with
  the button reading **Install anyway** if the answer was no. The copy is
  deleted either way, and nothing in it is ever run. Double-click a row to open
  the plugin's own repository page. Omarchy's built-in plugins appear here too,
  marked **OFFICIAL** and shown for discovery only.
- **Any repository, listed or not** — paste a GitHub address into the Store's
  search box and Plug offers to read that, exactly the way it reads a catalog
  entry. Plenty of plugins are never listed — a link in a forum, a friend's
  repo — and those are the ones that have had the least scrutiny, so they are
  the ones most worth reading first.
- **Manual installs** — adding a plugin only copies its files and enables it;
  it builds nothing and starts nothing. A plugin that needs packages, a
  compiled daemon or a service therefore ships a script and expects you to run
  it, and that script runs as you the moment you start it, before any of the
  plugin's own code loads. Plug finds that script, reads it, lists what it
  would do to your machine, and hands you the commands — it will not run it
  for you. Reviewing code and then executing it is the one thing this plugin
  exists not to do.

## Choosing your reviewer

The reviewer is entirely your choice, set in **Settings**. Plug offers only the
tools you actually have:

- **Command-line agents** — Claude Code, Codex, Gemini, or Opencode, if their command is
  installed. Each is run once, in an empty working directory, with a trimmed
  environment holding only that agent's own credentials and nothing else your
  shell was carrying. How contained that run actually is differs by tool, and
  the difference is worth knowing before you pick one:
  - **Claude Code** — no tools at all, in plan mode. It reads the diff it was
    given and has nothing else to act with.
  - **Codex** — a read-only sandbox, so it cannot write anything. It keeps its
    file-reading tools, so a prompt-injection buried in a plugin's source could
    in principle talk it into reading something else.
  - **Gemini** — asked for its own read-only plan mode, but Gemini overrides
    that itself when the working directory is untrusted, which Plug's
    deliberately is. Its container sandbox is not assumed either, since it
    needs a container runtime that may not be installed. Treat it as the least
    contained of the three.
  - **Opencode** — run with `opencode run --agent plan --format json`, in plan
    mode (read-only, denies edits). Like Codex it keeps read-capable tooling,
    so what contains it is the empty working directory and the read-only plan
    sandbox. Supports any provider configured in opencode (Zen models work out
    of the box with `opencode auth`). Its environment is trimmed per-model:
    `opencode/*` receives only `OPENCODE_`, `anthropic/*` only `OPENCODE_` +
    `ANTHROPIC_`, `openai/*` only `OPENCODE_` + `OPENAI_`, and an unknown
    provider only `OPENCODE_` — so e.g. `AWS_SECRET_ACCESS_KEY` never reaches
    an opencode process that does not need it.
- **Local servers** — Ollama or LM Studio, if they are running. The review is a
  request to `localhost`, so **nothing leaves your machine** — a real LLM review
  that is completely private. Their loaded models are listed automatically.

> **Setting up Opencode.** Every other reviewer's models are known here in
> advance, or come from a server on your own machine. Opencode's live on its
> servers, so Plug has to ask — and asking leaves your machine, which makes it
> a button you press rather than something that happens around you.
>
> Opening **Settings** runs `which opencode`, exactly as it does for Claude,
> Codex and Gemini, and reads your opencode configuration so the model you have
> already chosen there is the one offered. Opencode then appears with a **Set
> up Opencode** button describing what pressing it will do.
>
> Pressing it runs `opencode models`, plus `opencode models <provider>` for
> `anthropic`, `openai` and `google` every time, and for others such as
> `openrouter` or `mistral` when either the environment or
> `~/.local/share/opencode/auth.json` shows they are set up. That is up to
> eleven short-lived `opencode` processes, each given six seconds, each with
> its output capped at 512 KB, each carrying only that provider's own
> environment as described above, and the list bounded at 100 models per
> provider and 300 in total. They reach Opencode and those providers over the
> network, and where a provider has credentials stored the request carries
> them. How long that takes depends on your network and on how many providers
> you have set up; each probe is given six seconds before it is abandoned, so
> the whole run is bounded rather than open-ended.
>
> Plug writes the answer to `~/.local/state/plug/opencode_models.json` and
> builds the picker from that file afterwards, so the cost is paid on the
> press. A **Refresh models** button in the same place repeats it whenever you
> want a newer list.
- **Just the offline scan** — no AI at all; Plug reports what its own capability
  scan found. Everything stays local.

Interactive apps such as ChatGPT Desktop or Grok Bot are not offered: they are
windows, not something Plug can call for a one-shot review.

Authentication belongs to the reviewer you chose: Plug runs its command, and
that command uses the sign-in it already has. With Claude Code, that is the
Claude account set up in your terminal. If the tool is not signed in, the review
falls back to the offline scan.

**Privacy.** A cloud agent (Claude, Codex, Gemini, Opencode with a cloud model) is sent the code it is asked
to judge, and only then: the diff when you review an update, the plugin's full
source when you check one before installing it. That code is public and comes
from a public repository, but it does leave your machine. A local server (Ollama,
LM Studio) or the offline scan keeps everything on it. With Opencode the
destination depends on the model you pick — a Zen/cloud model leaves the
machine, a local model does not.

## Install

```
omarchy plugin add https://github.com/weedwhitesandwine/plug.git --enable
```

Open it from the bar icon, or from a terminal:

```
omarchy-shell shell toggle io.github.weedwhitesandwine.plug
```

A hotkey is **off by default** — set one in Settings if you want. Plug checks
every shortcut Hyprland is actually using (including Omarchy's own, which are
not in `bindings.lua`) and refuses a combination that is already taken.

## Update

```
omarchy plugin update io.github.weedwhitesandwine.plug --yes
```

## Remove

Hide the bar icon and clear the hotkey in Settings first (that removes Plug's
entry from `shell.json` and its block from `bindings.lua`), then:

```
omarchy plugin remove io.github.weedwhitesandwine.plug
```

Its state is left in `~/.local/state/plug/`, which you can delete.

## What it runs, reads and writes

**Its own state**, all inside `~/.local/state/plug/`: `state.json` (git and
scan results per plugin), `catalog.json` (the marketplace catalog, cached),
`settings.json` (your choices), `locks.json` (restore bookkeeping — which
version each applied update came from), `opencode_models.json` (cached Opencode
model list, written only when you press **Set up Opencode** / **Refresh models**).

**Outside its own directory** — only in response to something you do:

| Path | When |
|---|---|
| `~/.config/hypr/bindings.lua` | only when you set or clear a hotkey, and only Plug's own marked block, between `-- >>> plug hotkey` and `-- <<< plug hotkey`, along with the blank line it writes above that block. Resolved the same way if it is a dotfiles symlink |
| `~/.config/omarchy/shell.json` | only when you show or hide the bar icon. It adds, moves or removes its own `{"id": …}` entry and leaves every other setting as it found it, though the file is rewritten as standard JSON with two-space indentation. Where a dotfiles manager has symlinked this path into its own repository, the link is resolved and the real file written, so the link survives |
| a plugin's own checkout under `~/.config/omarchy/plugins/…` | standard git operations (`fetch`, fast-forward, and `reset` for a revert) when you update or roll back **that** plugin |
| `~/.config/opencode/opencode.json` / `opencode.jsonc` | whenever the reviewer list is built — which includes opening Settings — and again when you press **Set up Opencode** / **Refresh models**, to pick up the model you have configured in opencode so it is the one offered and used. A local read, capped at 64 KB, and the `jsonc` form may carry comments |
| `~/.local/share/opencode/auth.json` | only when you press **Set up Opencode** / **Refresh models**, read to see which providers you have set up so only those are probed. Capped at 64 KB, and only the names of the top-level entries are looked at |
| `~/.local/state/plug/opencode_models.json` | written only when you press **Set up Opencode** / **Refresh models** (the cached model list, with `fetchedAt`); read back locally each time the reviewer list is built |
| a temporary directory | a shallow clone of a plugin you asked Plug to check before installing, read and then deleted |

**Commands it runs:** `omarchy-shell shell listPlugins` / `listShellConfig` /
`setPluginEnabled` (read the list and your shell config; enable/disable on your
click); `omarchy-restart-shell` (only after you apply an update or a restore —
see below — and never while the screen is locked) with `omarchy-shell shell
ping` / `summon` to bring Plug back afterwards with the result;
`omarchy plugin add` / `remove` (install/uninstall on your click); `git` inside each plugin's checkout (read its
state, fetch updates, show the diff, apply or revert); `hyprctl binds` (read
active shortcuts) and `hyprctl reload` (after a hotkey change); `python3` (Plug's
own engine); `bash` (Plug's own `plug-ctl.sh`); `wl-copy` (only when you press
**Copy the commands** on a manual install, with the commands passed as an
argument rather than through a shell); `xdg-open` (only when you open a
plugin's repository page); and the AI reviewer you chose — either its command
(`claude` / `codex` / `gemini` / `opencode`) or a request to a local server on `localhost`.
Only when you press **Set up Opencode** / **Refresh models** in Settings (and
`opencode` is installed) does Plug run `opencode models` (+ `opencode models
<provider>` for a few providers, see above) to discover models — without
starting a review. Opening Settings itself only runs `which opencode`, like the
other CLIs.

**Network:** each installed plugin's git remote, to check for and fetch updates;
the repository of a store plugin you ask Plug to check before installing;
the marketplace catalog on `raw.githubusercontent.com`; when you review an
update with a cloud agent, that provider — never otherwise; and, only when you
press **Set up Opencode** / **Refresh models** in Settings with Opencode
installed, the `opencode models` discovery described above (which may contact
configured providers — the button says so and roughly how long it takes, and
the result is cached). A local-server reviewer stays on `localhost`.

**When the catalog is fetched.** Starting the shell never fetches it — Plug
reads the saved copy from disk and stops there. A fetch happens when you open
the Store and the saved copy is more than six hours old, or when you press the
refresh control beside the search box. There is no timer. Set `autoCatalog` to
`false` in `settings.json` to leave it to the refresh control alone. A fetch
that fails changes nothing: the saved copy is written only on success, so the
Store keeps working offline and says which copy you are looking at.

**Restarting the shell.** Applying an update or a restore ends with a shell
restart, because that is what makes changed plugin code take effect: the running
shell keeps the copy it loaded at startup, and a plugin rescan refreshes only
which plugins exist, not their code. Your windows and workspaces are untouched;
the bar and the panels reload. Nothing else Plug does restarts anything.

**Timers and background work:** none that runs on its own. The jobs you start —
install, remove, update, restore, on/off — outlive Plug's own window, since the
reload that finishes them also closes it. Each one ends by reopening Plug on the
plugin it acted on and telling you what happened.

Everything runs as your own user.

## Handling untrusted input

A plugin's repository, the marketplace catalog, the update diff and the source
of a plugin you are considering all come from outside, and Plug runs inside a
shell process that stays up for days, so all of it is treated as data:

- Every file Plug reads is read to a size ceiling, following a symlink only to a
  real regular file, so an oversized or redirected file cannot be pulled whole
  into the shell or hang it.
- Every file Plug writes is staged under an exclusively-created name in a
  directory it has verified it owns, then renamed into place, so a symlink left
  at one of those names is never written through.
- A hotkey is validated against a fixed shape in both the settings view and the
  helper script, and refused rather than escaped, because it becomes Lua source
  in `bindings.lua`.
- The AI reviewer is handed the diff as data, never as instructions, in an
  empty working directory and with an environment trimmed to that agent's own
  credentials. With **Claude Code** that is genuinely nothing to act with: no
  tools at all. **Codex** and **Gemini** keep read-capable tooling of their
  own, so what contains them is the sandbox each provides rather than an
  absence of tools — see [Choosing your reviewer](#choosing-your-reviewer) for
  what each one actually gets. Pick accordingly.
- `git` runs against each untrusted checkout with the repository's own hooks and
  config disabled, so inspecting a plugin can never run code from it.
- A repository address is checked against a plain `https` shape before git is
  ever pointed at it, and passed as an argument rather than through a shell, so
  a catalog entry cannot name a local path or another protocol.
- A plugin you ask Plug to check before installing is cloned shallow into a
  throwaway directory, read, and deleted — whether the check succeeds or not.
  Nothing in it is executed at any point.
- Source files are picked by what they are, not by what they are called. A
  script carrying no extension is opened far enough to read its shebang and
  then read as that language, because the file that does the most to your
  machine is usually the one named plainly `setup`. The peek is a fixed 128
  bytes and the number of peeks is capped.

## Maintenance

**If Plug says the catalog is bigger than it accepts.** The marketplace catalog
is one file that grows as plugins are listed, and Plug refuses one over a set
size so a runaway download cannot be held in memory. That size is a single line
near the top of `plugd.py`:

```
MAX_REGISTRY_BYTES = 32 * 1024 * 1024
```

Change `32` to `64` and save. Nothing needs restarting — the engine runs as a
fresh process for every fetch, so your next refresh in the Store uses the new
number. Saving a file inside the plugin folder makes Omarchy reload its plugins,
so the bar blinks once; that is all that happens.

Two things worth knowing. Updating Plug replaces `plugd.py`, so your edit goes
with it — a released version raising the number is the durable fix, and this is
the thing to do in the meantime. And the number is a ceiling on what is read
into memory at once, so raise it a step at a time rather than to something
enormous.

## Dependencies

`git`, `python3`, `bash` and `hyprctl`, all of which Omarchy already provides.
An AI reviewer is optional — without one, Plug uses its offline scan.

## Licence

MIT — see [LICENSE](LICENSE).

## Credits

Opencode support was contributed by [miguepollo](https://github.com/miguepollo).

Built with [Claude Code](https://claude.com/claude-code).
