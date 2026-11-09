#!/usr/bin/env python3
"""Scrubs recorded `claude` stream-json fixtures so they carry no machine- or user-specific data.

Usage: tools/ccprobe/scrub.py [fixture.jsonl ...]
With no arguments it scrubs every Tests/*/Fixtures/*.jsonl under the repository. Safe to re-run.

- home directories (macOS and Linux)  -> /home/user
- Claude Code temp roots (`/tmp/claude-<uid>/<project slug>[/<session id>]`) -> /tmp/alloy-fixture
- probe scratchpad and temp repo dirs -> /tmp/alloy-fixture   (tests that rewrite the project path
  use the fixture's own `cwd`, or this prefix)
- socket paths                        -> /tmp/alloy-fixture.sock
- system/init plugin, skill, slash-command and agent inventories -> short placeholder lists
  (each field keeps its type; fields later code decodes are untouched)
- anything that names the machine's own setup, wherever it appears in a line: `mcp__` tool names (at most two
  placeholders stay), MCP server names, user/plugin/claude.ai skill commands, agent descriptions, `memory_paths`,
  `subscriptionType`, `plugins` and hook command paths
"""
import glob
import json
import os
import re
import sys

ROOT = "/tmp/alloy-fixture"

TEXT_RULES = [
    (re.compile(r"/private/tmp/claude-\d+/-Users-[A-Za-z0-9_.]+-Developer/[0-9a-fA-F-]+/scratchpad"), ROOT),
    (re.compile(r"/(?:private/)?tmp/claude-\d+/-[A-Za-z0-9._-]+(?:/[0-9a-fA-F-]{36})?"), ROOT),
    (re.compile(r"/private/var/folders/[^/\"\s]+/[^/\"\s]+/T/ccprobe-repo-[A-Za-z0-9_]+"), ROOT),
    (re.compile(re.escape(ROOT) + r"(?:/ccprobe2)?/ccprobe-repo-[A-Za-z0-9_]+"), ROOT),
    (re.compile(r"/private/var/folders/[^/\"\s]+/[^/\"\s]+/T"), ROOT),
    (re.compile(r"/tmp/cc-socks/[0-9]+\.sock"), ROOT + ".sock"),
    (re.compile(r"-private-var-folders-[A-Za-z0-9-]+-T-ccprobe-repo-[A-Za-z0-9_]+"), "-tmp-alloy-fixture"),
    (re.compile(r"-private-tmp-claude-\d+--Users-[A-Za-z0-9_.]+-Developer-[0-9a-fA-F-]+-scratchpad"), "-tmp-alloy-fixture"),
    (re.compile(r"-tmp-alloy-fixture(?:-ccprobe2)?-ccprobe-repo-[A-Za-z0-9_]+"), "-tmp-alloy-fixture"),
    (re.compile(r"-Users-[A-Za-z0-9_.]+-Developer"), "-home-user-Developer"),
    (re.compile(r"/(?:Users|home)/(?!user\b)[A-Za-z0-9_.]+"), "/home/user"),
    (re.compile(r"/Users/user\b"), "/home/user"),
    # Personal data: account email (and the organisation named after it), account and organisation ids, git user.
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "user@example.com"),
    (re.compile(r'("(?:accountUuid|organizationUuid)":\s*")[0-9a-fA-F-]{36}(")'), r"\g<1>00000000-0000-0000-0000-000000000000\g<2>"),
    (re.compile(r'("organization":\s*")[^"]*(")'), r"\g<1>Example Organization\g<2>"),
    (re.compile(r"Git user: [^\n\\]+"), "Git user: Example User"),
]

PLACEHOLDERS = {
    "slash_commands": ["compact", "cost"],
    "terminal_slash_commands": ["doctor"],
    "skills": ["example-skill"],
    "agents": ["general-purpose"],
    "plugins": [{"name": "example-plugin", "path": "builtin", "source": "example-plugin@builtin"}],
}


PLACEHOLDER_MCP_TOOLS = ["mcp__example__tool", "mcp__example__other"]
PLACEHOLDER_SKILL_COMMAND = {"name": "example-skill", "description": "An example skill (user)", "argumentHint": ""}
PLACEHOLDER_AGENT = {"name": "general-purpose", "description": "General-purpose agent."}
HOOK_COMMAND = "/usr/local/bin/example-hook"
# Slash commands the CLI lists for the machine's own setup: namespaced plugin skills and anything annotated with its source.
PRIVATE_COMMAND = re.compile(r"\((?:user|claude\.ai sync|MCP|dynamic workflow|plugin[^)]*|project)\)\s*$")


def is_private_command(command):
    name = command.get("name", "") if isinstance(command, dict) else ""
    return ":" in name or bool(PRIVATE_COMMAND.search(command.get("description", ""))) if isinstance(command, dict) else False


def scrub_commands(commands):
    kept = [c for c in commands if not is_private_command(c)]
    return kept + [PLACEHOLDER_SKILL_COMMAND] if len(kept) != len(commands) else commands


def scrub_value(key, value):
    """The replacement for `value` under `key`, or the value itself when there is nothing to hide."""
    if key == "memory_paths" and value:
        return {} if isinstance(value, dict) else []
    if key == "mcp_servers" and isinstance(value, list):
        return [dict(v, name="example-server") if isinstance(v, dict) else v for v in value]
    if key == "tools" and isinstance(value, list) and any(isinstance(t, str) and t.startswith("mcp__") for t in value):
        return [t for t in value if not (isinstance(t, str) and t.startswith("mcp__"))] + PLACEHOLDER_MCP_TOOLS
    if key == "subscriptionType" and isinstance(value, str):
        return "example"
    if key == "commands" and isinstance(value, list) and all(isinstance(c, dict) for c in value):
        return scrub_commands(value)
    if key == "agents" and isinstance(value, list) and value and all(isinstance(a, dict) for a in value):
        return [PLACEHOLDER_AGENT]
    if key == "hookInfos" and isinstance(value, list):
        return [dict(h, command=HOOK_COMMAND) if isinstance(h, dict) and "command" in h else h for h in value]
    return value


def scrub_object(obj):
    if isinstance(obj, dict):
        return {k: scrub_object(scrub_value(k, v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub_object(v) for v in obj]
    return obj


TRIGGERS = ("memory_paths", "mcp_servers", "mcp__", "subscriptionType", '"commands"', '"agents"', "hookInfos", '"plugins"', '"skills"')


def scrub_text(text):
    for pattern, replacement in TEXT_RULES:
        text = pattern.sub(replacement, text)
    return text


def scrub_fragments(lines):
    """`input_json_delta` events split a tool input (often a path) into arbitrary fragments, so a path can
    straddle several events. Scrub each run of fragments of one block as a whole, then spread the result
    back over the same number of events."""
    events = {}   # line index -> (block index, fragment)
    for i, line in enumerate(lines):
        if '"input_json_delta"' not in line:
            continue
        try:
            obj = json.loads(line)
            ev = obj["event"]
            if obj.get("type") == "stream_event" and ev["delta"]["type"] == "input_json_delta":
                events[i] = (ev["index"], obj, ev["delta"]["partial_json"])
        except (ValueError, KeyError, TypeError):
            continue
    runs, run = [], []
    for i in sorted(events):
        if run and (i != run[-1] + 1 or events[i][0] != events[run[-1]][0]):
            runs.append(run); run = []
        run.append(i)
    if run:
        runs.append(run)
    for run in runs:
        joined = "".join(events[i][2] for i in run)
        clean = scrub_text(joined)
        if clean == joined:
            continue
        size = -(-len(clean) // len(run))
        for n, i in enumerate(run):
            _, obj, _ = events[i]
            obj["event"]["delta"]["partial_json"] = clean[n * size:(n + 1) * size]
            lines[i] = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    return lines


def scrub_line(line):
    line = scrub_text(line)
    if not any(t in line for t in TRIGGERS):
        return line
    try:
        obj = json.loads(line)
    except ValueError:
        return line
    cleaned = scrub_object(obj)
    if isinstance(cleaned, dict) and cleaned.get("type") == "system" and cleaned.get("subtype") == "init":
        for key, value in PLACEHOLDERS.items():
            if key in cleaned and isinstance(cleaned[key], list):
                cleaned[key] = value
    if cleaned == obj and not (isinstance(obj, dict) and obj.get("subtype") == "init"):
        return line
    return json.dumps(cleaned, separators=(",", ":"), ensure_ascii=False)


def scrub_file(path):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    lines = scrub_fragments(lines)
    out = "\n".join(scrub_line(l) if l.strip() else l for l in lines)
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)


def main(argv):
    paths = argv or sorted(glob.glob(os.path.join(os.path.dirname(__file__), "..", "..", "Tests", "*", "Fixtures", "*.jsonl")))
    for p in paths:
        scrub_file(p)
        print("scrubbed", os.path.normpath(p))


if __name__ == "__main__":
    main(sys.argv[1:])
