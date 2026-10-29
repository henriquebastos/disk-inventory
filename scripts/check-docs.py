#!/usr/bin/env python3
"""Checks README.md, AGENTS.md and docs/*.md: each stays below 1,500 words, local Markdown links
resolve, and every quoted test name ("snake_case_name" or "testCamelName") is defined in the
repository's Rust or Swift sources. Usage: check-docs.py REPO"""
import pathlib
import re
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
docs = [repo / "README.md", repo / "AGENTS.md", *sorted((repo / "docs").glob("*.md"))]
# Tracked and new files only: ignored copies (such as artifacts/) do not define tests.
listed = subprocess.run(
    ["git", "-C", str(repo), "ls-files", "--cached", "--others", "--exclude-standard",
     "*.rs", "*.swift"], check=True, capture_output=True, text=True).stdout.split()
sources = "\n".join((repo / p).read_text(errors="ignore") for p in listed if (repo / p).exists())
problems = []
links = names = 0
for doc in docs:
    text = doc.read_text()
    words = len(text.split())
    if words >= 1500:
        problems.append(f"{doc.relative_to(repo)}: {words} words, the limit is below 1,500")
    for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", text):
        if re.match(r"[a-z]+:", target):
            continue
        links += 1
        if not (doc.parent / target).exists():
            problems.append(f"{doc.relative_to(repo)}: missing link {target}")
    for name in re.findall(r'"((?:test[A-Z]\w+)|(?:[a-z][a-z0-9]*_[a-z0-9_]+))"', text):
        names += 1
        keyword = "func" if name.startswith("test") else "fn"
        if not re.search(rf"\b{keyword} {name}\b", sources):
            problems.append(f"{doc.relative_to(repo)}: quoted test {name} is not defined")
for problem in problems:
    print(problem)
print(f"summary: {len(docs)} documents, {links} links, {names} quoted test names, {len(problems)} problems")
sys.exit(1 if problems else 0)
