"""Plug reviewer resolution: every defect red first, then green.

A–E  the mise-shim break (the reviewer runs with a throwaway HOME and a cwd
     outside the real home, where a shim cannot resolve the tool).
F–H  the three defects the diff review found in the first fix.
G2   the package-fetch blocker: a wrapper on PATH must resolve to nothing
     rather than to a program downloaded to satisfy it.
"""
import os, shutil, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SHIMS = os.path.expanduser("~/.local/share/mise/shims")
PATH_SHIM_ONLY = SHIMS + ":/usr/local/sbin:/usr/local/bin:/usr/bin"
os.environ["PATH"] = PATH_SHIM_ONLY

import plugd

fails = []


def check(label, cond, detail=""):
    print("%-4s %s%s" % ("PASS" if cond else "FAIL", label,
                         ("  -- " + detail) if detail else ""))
    if not cond:
        fails.append(label)


def fresh():
    plugd._CLI_BIN_CACHE.clear()


def write_new(path, text, mode=0o600):
    """Create a fixture file through an exclusively-created descriptor, never
    by name — the same rule the plugin itself is held to, so a test fixture
    cannot be written through a planted symlink either."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def as_the_reviewer_runs(binary):
    work = tempfile.mkdtemp(prefix="plug-review-")
    try:
        env = plugd.reviewer_env(work)
        code, out, err, _ = plugd.run_capped([binary, "--version"], timeout=60,
                                             cap=64 * 1024, env=env, cwd=work)
        return out.strip(), err.strip()
    finally:
        shutil.rmtree(work, ignore_errors=True)


print("== A. RED: the original defect, shim as the only claude on PATH ==")
fresh()
old = shutil.which("claude")
check("old resolution (shutil.which) picks the mise shim",
      bool(old) and os.path.basename(os.path.realpath(old)) == "mise", str(old))
out, err = as_the_reviewer_runs(old)
check("the shim produces no reply for the reviewer", out == "",
      "stdout=%r" % out)

print()
print("== B. GREEN: resolved past the shim, same conditions ==")
fresh()
new = plugd.resolve_cli_bin("claude")
check("resolve_cli_bin returns a real binary",
      bool(new) and os.path.basename(os.path.realpath(new)) != "mise", str(new))
out, err = as_the_reviewer_runs(new)
check("it answers where the shim could not", "Claude Code" in out,
      "stdout=%r" % out)

print()
print("== C. the agent is offered on a shim-only PATH ==")
fresh()
agents = {a["key"]: a for a in plugd.available_agents()}
check("claude in available_agents()", "claude" in agents, ",".join(agents))
check("default model is sonnet",
      agents.get("claude", {}).get("defaultModel") == "sonnet")

print()
print("== D. fails closed on a shim standing in for nothing ==")
fresh()
fake_shims = tempfile.mkdtemp(prefix="plug-shims-")
try:
    os.symlink(shutil.which("mise"), os.path.join(fake_shims, "notatool"))
    os.environ["PATH"] = fake_shims + ":" + PATH_SHIM_ONLY
    check("returns '' rather than the unusable shim",
          plugd.resolve_cli_bin("notatool") == "")
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    shutil.rmtree(fake_shims, ignore_errors=True)

print()
print("== E. a plain binary is returned untouched ==")
fresh()
check("resolve_cli_bin('head') is /usr/bin/head",
      plugd.resolve_cli_bin("head") == shutil.which("head"))
check("nonexistent name is ''",
      plugd.resolve_cli_bin("definitely-not-installed-xyz") == "")

print()
print("== F. a mise.toml in the cwd must not delete the reviewer ==")
d = tempfile.mkdtemp(prefix="plug-misedir-")
here = os.getcwd()
try:
    write_new(os.path.join(d, "mise.toml"), '[tools]\nclaude = "9.9.9"\n')
    # RED: asked in that directory, mise cannot resolve the tool at all.
    code, out, _, _ = plugd.run_capped([shutil.which("mise"), "which", "claude"],
                                       timeout=30, cap=64 * 1024, cwd=d)
    check("RED: `mise which` in that directory resolves nothing",
          plugd.last_line(out) == "" or not os.path.exists(plugd.last_line(out)),
          "stdout=%r" % out.strip()[:60])
    # GREEN: plugd asks from / , so the reviewer survives.
    os.chdir(d)
    fresh()
    got = plugd.resolve_cli_bin("claude")
    check("GREEN: resolve_cli_bin still finds claude", bool(got), got)
    check("and claude is still offered", plugd.agent_available("claude"))
finally:
    os.chdir(here)
    shutil.rmtree(d, ignore_errors=True)

print()
print("== G. a symlinked reviewer program is not a hard failure ==")
# An installed node package puts its programs in a `.bin` directory as links,
# so refusing every symlink would refuse the ordinary install.
link_dir = tempfile.mkdtemp(prefix="plug-link-")
try:
    real_prog = shutil.which("head")     # a real binary, not a `#!` script
    link = os.path.join(link_dir, "opencode")
    os.symlink(real_prog, link)          # what npm/mise .bin dirs look like
    # RED: the raw probe refuses to follow a link.
    raised = False
    try:
        plugd.peek_head(link, 2)
    except OSError:
        raised = True
    check("RED: peek_head refuses the symlink outright", raised)
    # GREEN: resolution asks about the file the link names, and returns it.
    os.environ["PATH"] = link_dir + ":" + PATH_SHIM_ONLY
    fresh()
    got = plugd.resolve_opencode_bin()
    check("GREEN: resolve_opencode_bin still finds the program",
          got == real_prog and os.access(got, os.X_OK), repr(got))
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    shutil.rmtree(link_dir, ignore_errors=True)

print()
print("== G2. a wrapper on PATH is refused, and NOTHING is fetched to fix it ==")
# The blocker on marketplace #5032: where `opencode` on PATH was a wrapper
# script, resolution ran `npx --yes --package opencode-ai`, which downloads and
# executes whatever the registry is serving — unreviewed code, run by a plugin
# whose promise is that you see code before it runs. A wrapper must now simply
# resolve to nothing.
wrap_dir = tempfile.mkdtemp(prefix="plug-wrapper-")
try:
    wrapper = os.path.join(wrap_dir, "opencode")
    # The shape Omarchy installs: a bash script that resolves the package at
    # run time rather than being the program.
    write_new(wrapper, '#!/bin/bash\necho "would fetch the package"\n', 0o755)
    os.environ["PATH"] = wrap_dir + ":" + PATH_SHIM_ONLY
    fresh()
    ran = []
    sv_rc = plugd.run_capped
    try:
        def spy(cmd, *a, **kw):
            ran.append(list(cmd))
            return sv_rc(cmd, *a, **kw)
        plugd.run_capped = spy
        got = plugd.resolve_opencode_bin()
    finally:
        plugd.run_capped = sv_rc
    flat = " ".join(" ".join(c) for c in ran)
    check("RED: the wrapper is on PATH and is what `which` finds",
          shutil.which("opencode") == wrapper, str(shutil.which("opencode")))
    check("GREEN: it resolves to nothing rather than to a fetched program",
          got == "", repr(got))
    check("GREEN: no package fetch was attempted",
          "npx" not in flat and "opencode-ai" not in flat, flat[:120] or "(no commands run)")
    check("and Opencode is not offered",
          "opencode" not in {a["key"] for a in plugd.available_agents()})

    # The model listing is the other way the wrapper could have been executed:
    # it used to run the bare name `opencode`, which IS the wrapper.
    ran2 = []
    sv_rc2 = plugd.run_capped

    def spy2(cmd, *a, **kw):
        ran2.append(list(cmd))
        return (0, "", "", False)
    try:
        plugd.run_capped = spy2
        plugd.opencode_models("")
    finally:
        plugd.run_capped = sv_rc2
    check("GREEN: opencode_models runs nothing without a resolved program",
          ran2 == [], str(ran2)[:120])
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    fresh()
    shutil.rmtree(wrap_dir, ignore_errors=True)

print()
print("== G3. an installed package's own launcher is kept, and stays reachable ==")
# Two things the wrapper refusal must not break.
#
# Opencode's own `bin/opencode` was a `/bin/sh` launcher in every release up
# to 1.15.0 (the native `bin/opencode.exe` arrives in 1.15.1) — it runs the
# platform binary beside it and fetches nothing, so refusing every script
# would refuse an ordinary local install.
#
# And the path handed back has to be one a review can execute: the sandbox
# binds the tree above `node_modules`, so returning the `.bin` link — which
# npm puts outside that tree — gives the sandbox nothing to run.
pkg_root = tempfile.mkdtemp(prefix="plug-pkg-")
try:
    pkg_bin = os.path.join(pkg_root, "lib", "node_modules", "opencode-ai", "bin")
    os.makedirs(pkg_bin)
    launcher = os.path.join(pkg_bin, "opencode")
    write_new(launcher, '#!/bin/sh\necho "1.14.0"\n', 0o755)   # pre-1.15.1 shape
    shim_dir = os.path.join(pkg_root, "bin")
    os.makedirs(shim_dir)
    os.symlink(launcher, os.path.join(shim_dir, "opencode"))
    os.environ["PATH"] = shim_dir + ":" + PATH_SHIM_ONLY
    fresh()
    got = plugd.resolve_opencode_bin()
    check("GREEN: a package's own `#!` launcher is accepted", bool(got), repr(got))
    # RED unless the resolved path is returned: the link lives in
    # <root>/bin while the sandbox is only given <root>/lib.
    mount = plugd.opencode_package_dir(got) if got else ""
    check("GREEN: the sandbox is given the tree the program is inside",
          bool(got) and bool(mount) and got.startswith(mount.rstrip("/") + "/"),
          "bin=%r mount=%r" % (got, mount))
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    fresh()
    shutil.rmtree(pkg_root, ignore_errors=True)

print()
print("== G4. a fetching stand-in still finds a program mise has installed ==")
# Omarchy puts a stand-in on PATH for each of its tools, so on the machines
# this plugin is written for, the stand-in is what `which` finds. Refusing to
# run it is right; concluding from that that nothing is installed is not.
# mise is asked instead, and it must be asked in a way that cannot install.
mise_dir = tempfile.mkdtemp(prefix="plug-mise-")
try:
    installed = os.path.join(mise_dir, "installs", "opencode", "bin")
    os.makedirs(installed)
    program = os.path.join(installed, "opencode")
    write_new(program, '#!/bin/sh\necho "1.18.30"\n', 0o755)

    stub_dir = os.path.join(mise_dir, "bin")
    os.makedirs(stub_dir)
    # The stand-in Omarchy writes: it installs the tool, then runs it.
    write_new(os.path.join(stub_dir, "opencode"),
              '#!/bin/bash\nmise use -g --quiet "opencode" || exit 1\n'
              'exec mise x "opencode" -- "opencode" "$@"\n', 0o755)
    # A mise that answers `which` for the installed program, and treats being
    # asked to install as the failure it would be.
    write_new(os.path.join(stub_dir, "mise"),
              '#!/bin/sh\n'
              'if [ "$1" = "which" ] && [ "$2" = "opencode" ]; then\n'
              '  [ "$MISE_AUTO_INSTALL" = "0" ] || { echo "AUTOINSTALL-ALLOWED" >&2; exit 3; }\n'
              '  echo "%s"; exit 0\n'
              'fi\n'
              'echo "INSTALL-ATTEMPTED: $*" >&2\nexit 3\n' % program, 0o755)
    os.environ["PATH"] = stub_dir + ":" + PATH_SHIM_ONLY
    fresh()
    got = plugd.resolve_opencode_bin()
    check("RED: the stand-in is what `which` finds, and must not be run",
          os.path.basename(str(shutil.which("opencode"))) == "opencode"
          and shutil.which("opencode").startswith(stub_dir), str(shutil.which("opencode")))
    check("GREEN: the installed program is found anyway", got == program, repr(got))
    check("GREEN: mise was asked with installing turned off",
          bool(got), "a fetch would have failed this check")

    # And when mise has nothing, it stays refused rather than installing one.
    write_new(os.path.join(stub_dir, "mise"),
              '#!/bin/sh\n'
              'if [ "$1" = "which" ]; then echo "not a mise bin" >&2; exit 1; fi\n'
              'echo "INSTALL-ATTEMPTED: $*" >&2\nexit 3\n', 0o755)
    fresh()
    check("GREEN: nothing installed anywhere means not offered",
          plugd.resolve_opencode_bin() == "")
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    fresh()
    shutil.rmtree(mise_dir, ignore_errors=True)

print()
print("== G5. a reviewer missing for a fixable reason says so ==")
# A stand-in on PATH means Opencode looks installed and is not offered, which
# without a word on screen reads as Plug being broken.
hint_dir = tempfile.mkdtemp(prefix="plug-hint-")
try:
    write_new(os.path.join(hint_dir, "opencode"),
              '#!/bin/bash\nmise use -g --quiet "opencode" || exit 1\n', 0o755)
    os.environ["PATH"] = hint_dir + ":" + PATH_SHIM_ONLY
    fresh()
    hints = plugd.agent_hints([{"key": "claude"}])
    check("RED: Opencode is not among the offered reviewers",
          "opencode" not in {a["key"] for a in plugd.available_agents()})
    check("GREEN: a hint explains why", len(hints) == 1, str(hints)[:80])
    check("and it carries a command to fix it",
          bool(hints) and bool(hints[0].get("command")),
          hints[0].get("command") if hints else "")
    check("no hint once Opencode is offered",
          plugd.agent_hints([{"key": "opencode"}]) == [])
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    fresh()
    shutil.rmtree(hint_dir, ignore_errors=True)

print()
print("== N. a state file an older version wrote does not survive the upgrade ==")
# The README lists what Plug keeps on disk and invites people to check it, so
# a file left behind by a previous version makes that list wrong.
state_dir = tempfile.mkdtemp(prefix="plug-state-")
saved_state = plugd.STATE_DIR
try:
    os.chmod(state_dir, 0o700)
    plugd.STATE_DIR = state_dir
    stale = os.path.join(state_dir, plugd.RETIRED_STATE_FILES[0])
    keep = os.path.join(state_dir, "settings.json")
    write_new(stale, "{}\n")
    write_new(keep, "{}\n")
    check("RED: the stale file is there to begin with", os.path.exists(stale))
    plugd.ensure_state_dir()
    check("GREEN: it is gone after the next run", not os.path.exists(stale))
    check("and a state file still in use is untouched", os.path.exists(keep))
finally:
    plugd.STATE_DIR = saved_state
    shutil.rmtree(state_dir, ignore_errors=True)

print()
print("== M. the probe uses the reviewer's environment, not your shell's ==")
# A probe that ran in the real environment would pass things that break the
# moment a review strips it — which is the entire original bug.
env_dir = tempfile.mkdtemp(prefix="plug-envtest-")
try:
    fake = os.path.join(env_dir, "claude")
    write_new(fake, '#!/bin/sh\n[ "$HOME" = "%s" ] && echo "9.9.9 (Claude "'
                    '"Code)"\nexit 0\n' % plugd.HOME, 0o755)
    os.environ["PATH"] = env_dir + ":" + PATH_SHIM_ONLY
    fresh()
    plugd._AGENT_STARTS_CACHE.clear()
    code, out, _, _ = plugd.run_capped([fake, "--version"], timeout=20,
                                       cap=4096)
    check("RED: it answers happily when run with your real HOME",
          "Claude" in out, repr(out.strip()))
    check("GREEN: the probe still refuses it, because a review has no real HOME",
          not plugd.agent_available("claude"))
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    fresh()
    plugd._AGENT_STARTS_CACHE.clear()
    shutil.rmtree(env_dir, ignore_errors=True)

print()
print("== L. the review executes the RESOLVED binary, not the bare name ==")
fresh()
plugd.resolve_cli_bin("claude")          # warm before run_capped is stubbed
seen = {}
sv_rc, sv_ls, sv_av = plugd.run_capped, plugd.load_settings, plugd.agent_available
try:
    plugd.load_settings = lambda: {"reviewAgent": "claude",
                                   "reviewModel": "sonnet"}
    plugd.agent_available = lambda k: True

    def spy(cmd, *a, **kw):
        seen.setdefault("cmd", list(cmd))
        return (0, "", "", False)
    plugd.run_capped = spy
    plugd.run_agent("diff --git a b\n+x\n", {}, "TestPlugin")
    argv0 = (seen.get("cmd") or [""])[0]
    check("RED: it is not the bare name 'claude'", argv0 != "claude", argv0)
    check("GREEN: it is the resolved, executable path",
          os.path.isabs(argv0) and os.access(argv0, os.X_OK), argv0)
finally:
    plugd.run_capped, plugd.load_settings, plugd.agent_available = \
        sv_rc, sv_ls, sv_av

print()
print("== H. an unrunnable chosen reviewer is named, not blamed on the user ==")
saved = plugd.agent_available
saved_ls = plugd.load_settings
try:
    plugd.load_settings = lambda: {"reviewAgent": "claude",
                                   "reviewModel": "sonnet"}
    plugd.agent_available = lambda k: False
    plain = plugd.offline_summary("diff --git a b\n+x\n", {}, "TestPlugin")
    res = plugd.run_agent("diff --git a b\n+x\n", {}, "TestPlugin")
    check("RED: the plain offline summary never names the reviewer",
          "could not be run" not in plain.get("watchFor", ""))
    check("GREEN: run_agent's watchFor says the chosen reviewer did not run",
          "could not be run" in res.get("watchFor", ""),
          res.get("watchFor", "")[:80])
    check("and it names which one", "claude" in res.get("watchFor", ""))
    check("the headline no longer blames the user for not setting one up",
          not str(res.get("headline", "")).startswith("No AI reviewer is set up"),
          str(res.get("headline", ""))[:70])
finally:
    plugd.agent_available = saved
    plugd.load_settings = saved_ls

print()
print("== K. a reviewer that resolves but cannot START is not offered ==")
# The property that matters is not "on PATH", it is "runs the way a review
# runs it". A command that resolves and then produces nothing must not be
# offered, whatever the mechanism that breaks it.
dud_dir = tempfile.mkdtemp(prefix="plug-dud-")
try:
    dud = os.path.join(dud_dir, "claude")
    write_new(dud, "#!/bin/sh\nexit 0\n", 0o755)   # resolves, says nothing
    os.environ["PATH"] = dud_dir + ":" + PATH_SHIM_ONLY
    fresh()
    plugd._AGENT_STARTS_CACHE.clear()
    check("RED: it resolves — presence alone would have offered it",
          plugd.resolve_cli_bin("claude") == dud, plugd.resolve_cli_bin("claude"))
    check("GREEN: agent_available says no, because it did not start",
          not plugd.agent_available("claude"))
    check("and it is absent from available_agents()",
          "claude" not in {a["key"] for a in plugd.available_agents()})

    # A command that resolves and DOES answer is still offered.
    write_new(dud, "#!/bin/sh\necho '9.9.9 (Claude Code)'\n", 0o755)
    fresh()
    plugd._AGENT_STARTS_CACHE.clear()
    check("a reviewer that answers is offered again",
          plugd.agent_available("claude"))
finally:
    os.environ["PATH"] = PATH_SHIM_ONLY
    fresh()
    plugd._AGENT_STARTS_CACHE.clear()
    shutil.rmtree(dud_dir, ignore_errors=True)

print()
print("== I. a local server with no model loaded is not offered ==")
saved_http = plugd.http_agent_models
try:
    plugd.http_agent_models = lambda spec: []      # answering, nothing loaded
    check("agent_available('ollama') is False", not plugd.agent_available("ollama"))
    check("ollama absent from available_agents()",
          "ollama" not in {a["key"] for a in plugd.available_agents()})
    plugd.http_agent_models = lambda spec: ["a-model"]
    check("offered again once a model is loaded",
          plugd.agent_available("ollama"))
    got = {a["key"]: a for a in plugd.available_agents()}
    check("and its default is that model",
          got.get("ollama", {}).get("defaultModel") == "a-model")
    plugd.http_agent_models = lambda spec: None    # not listening
    check("still not offered when nothing is listening",
          not plugd.agent_available("ollama"))
finally:
    plugd.http_agent_models = saved_http

print()
print("== J. the real local servers, as they are right now ==")
for key in ("ollama", "lmstudio"):
    m = plugd.http_agent_models(plugd.AGENTS[key])
    print("     %-9s %s models=%s" % (
        key, "answering " if m is not None else "not running", m))
live = {a["key"]: a for a in plugd.available_agents()}
print("     offered:", ", ".join("%s(%s)" % (k, v["defaultModel"])
                                 for k, v in live.items()))
check("every offered agent has a usable default model",
      all(a["defaultModel"] for a in live.values()))

print()
print("FAILURES: %d" % len(fails), fails or "")
sys.exit(1 if fails else 0)
