#!/usr/bin/env python3
"""Catch workflow mistakes that GitHub only reports when it parses the file.

    python3 tools/check_workflow_contexts.py [.github/workflows/*.yml]

Two checks, both from real failures:

1. A `shell:` value may not use every context. `${{ env.X }}` in a step's `shell:`
   stops the whole workflow file from loading ("Unrecognized named-value: 'env'"),
   and for a workflow called through `workflow_call` that also breaks the caller.
   The allowed set is copied from GitHub's context availability table for
   `jobs.<id>.steps.shell` and `jobs.<id>.defaults.run.shell`.
2. The script inside a step is checked with the interpreter that step actually runs
   with, so `shell: pwsh` scripts are not handed to bash and vice versa.

Exits non-zero with one line per problem.
"""

import glob
import re
import subprocess
import sys

import yaml

# github, needs, strategy, matrix, vars, secrets, inputs - the contexts GitHub
# accepts for defaults.run.shell and steps[].shell. Notably missing: env, steps.
SHELL_CONTEXTS = {"github", "needs", "strategy", "matrix", "vars", "secrets", "inputs"}

EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)


def contexts_used(expression):
    """Every context name referenced at the start of a dotted path.

    `matrix.entry.platform` names the context `matrix`, not `entry` or `platform`,
    so a name is only a context when no dot comes right before it.
    """
    found = []
    for match in re.finditer(r"(?<![\w.'\"])([a-zA-Z_][\w]*)\s*\.", expression):
        found.append(match.group(1))
    return found


def shell_of(job, step):
    if step is not None and "shell" in step:
        return step["shell"], f"step '{step.get('name') or step.get('uses')}'"
    inherited = ((job.get("defaults") or {}).get("run") or {}).get("shell")
    if inherited is not None and step is not None:
        return inherited, "defaults.run.shell"
    return inherited, "defaults.run.shell"


def bash_is_the_interpreter(shell, job):
    """Whether a run script is executed by a POSIX shell we can syntax-check."""
    if shell is None:
        return True
    first = str(shell).split()[0] if str(shell).split() else ""
    if first.startswith("${"):
        # An expression: it resolves to bash for every platform we build for, and a
        # step that overrides it is checked on its own value.
        return True
    return first in ("bash", "sh", "bash -e", "/bin/bash")


def check(path):
    problems = []
    with open(path, encoding="utf-8") as handle:
        workflow = yaml.safe_load(handle)
    for job_name, job in (workflow.get("jobs") or {}).items():
        default_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
        if default_shell is not None:
            for expr in EXPRESSION.findall(str(default_shell)):
                for name in contexts_used(expr):
                    if name not in SHELL_CONTEXTS:
                        problems.append(
                            f"defaults.run.shell: context '{name}' is not allowed "
                            f"in a shell value ({expr.strip()})"
                        )
        for step in job.get("steps") or []:
            where = f"step '{step.get('name') or step.get('uses')}'"
            shell = step.get("shell")
            if shell is not None:
                for expr in EXPRESSION.findall(str(shell)):
                    for name in contexts_used(expr):
                        if name not in SHELL_CONTEXTS:
                            problems.append(
                                f"{where}: shell uses context '{name}', which "
                                f"GitHub rejects ({expr.strip()})"
                            )
            script = step.get("run")
            if not script:
                continue
            effective = shell if shell is not None else default_shell
            if not bash_is_the_interpreter(effective, job):
                continue
            body = EXPRESSION.sub("x", script)
            proc = subprocess.run(
                ["bash", "-n"], input=body, text=True, capture_output=True
            )
            if proc.returncode != 0:
                problems.append(f"{where}: bash cannot parse the step ({proc.stderr.strip()})")
    return problems


def main():
    paths = sys.argv[1:] or sorted(glob.glob(".github/workflows/*.yml"))
    failed = False
    for path in paths:
        for problem in check(path):
            print(f"{path}: {problem}")
            failed = True
    if failed:
        return 1
    print(f"check_workflow_contexts: {len(paths)} workflow files clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
