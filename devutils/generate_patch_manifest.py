#!/usr/bin/env python3
"""Generate the table behind chrome://aerium.

    devutils/generate_patch_manifest.py --out <path.inc> [--version X.Y.Z.W]

The page exists because a one-person fork asks people to trust a binary nobody
has audited, and the smallest honest answer to that is for the browser to show
what it changed. That answer is only worth something if the list is derived
from what the build actually applies, so nothing here is typed by hand:

  * Vanadium's rows are read from vanadium/patches/*.patch as they stand when
    this runs - which is after build.sh has deleted the ones it does not want
    and rewritten the branding - so a patch that was dropped does not appear
    and one that was added does.

  * Aerium's rows are read from a target log produced by sourcing patch.sh and
    theme.sh with their sed/perl calls stubbed out (devutils/collect-targets.sh).
    Each target is attributed to the `# ---` section it was called from, so the
    file counts move on their own when a substitution is added or removed.

A target that belongs to no section is reported under "(unsectioned)" rather
than dropped. That matters more than it looks: the failure this page has to
rule out is a change nobody mentioned, so a change nobody put a heading on has
to show up somewhere.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

VANADIUM_GROUP = "Vanadium (GrapheneOS)"
AERIUM_GROUP = "Aerium (this repo)"


def cpp_string(text):
    """Escape a UTF-8 string for a C++ narrow string literal."""
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch in "\n\r\t":
            out.append(" ")
        elif ord(ch) < 0x20:
            continue
        else:
            out.append(ch)
    return "".join(out)


def first_sentence(text):
    """The first sentence of a comment block, as one line.

    Section headings here are prose wrapped at 79 columns, so the sentence has
    to be rejoined across lines before it can be cut.
    """
    text = " ".join(text.split())
    match = re.search(r"(?<=[a-z0-9)\"'])\.(?=\s|$)", text)
    if match:
        return text[: match.end()]
    return text


def read_vanadium(patch_dir):
    """One row per patch file, with the subject and the number of files."""
    rows = []
    if not os.path.isdir(patch_dir):
        return rows
    for name in sorted(os.listdir(patch_dir)):
        if not name.endswith(".patch"):
            continue
        path = os.path.join(patch_dir, name)
        with open(path, encoding="utf-8", errors="replace") as handle:
            body = handle.read()

        # git-format-patch subjects wrap, so continuation lines are folded back
        # in before the [PATCH n/m] prefix is stripped.
        subject = ""
        lines = body.split("\n")
        for index, line in enumerate(lines):
            if not line.startswith("Subject: "):
                continue
            subject = line[len("Subject: ") :]
            for cont in lines[index + 1 :]:
                if cont.startswith(" ") and cont.strip():
                    subject += " " + cont.strip()
                else:
                    break
            break
        subject = re.sub(r"^\[[^\]]*\]\s*", "", subject).strip()

        files = len({m for m in re.findall(r"^\+\+\+ b/(\S+)", body, re.M)})
        if not files:
            files = len({m for m in re.findall(r"^--- a/(\S+)", body, re.M)})

        stem = name[: -len(".patch")]
        rows.append((VANADIUM_GROUP, stem, subject or stem, files))
    return rows


def read_sections(script_path):
    """Every `# ---` heading in a build script.

    Returns (line number, title, has_commands). A heading with nothing but
    comments under it is a note about a change that was removed or left to
    another script, not a change this build makes, so the page must not list
    it - has_commands is what tells the two apart.
    """
    with open(script_path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    starts = [i for i, line in enumerate(lines) if line.startswith("# --- ")]
    sections = []
    for position, index in enumerate(starts):
        block = [lines[index][len("# --- ") :]]
        for cont in lines[index + 1 :]:
            if cont.startswith("#"):
                block.append(cont[1:].strip())
            else:
                break
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        has_commands = any(
            line.strip() and not line.lstrip().startswith("#")
            for line in lines[index + 1 : end]
        )
        sections.append(
            (index + 1, first_sentence(" ".join(block)), has_commands)
        )
    return sections


def read_aerium(targets_tsv):
    """One row per script section, counting the files its calls write to.

    A count of zero is kept rather than dropped. The product-rename sweep near
    the top of theme.sh drives its substitution from a `grep -rl` over the
    tree, so the set of files it edits is decided at build time and cannot be
    read out of the script - the page renders that as a dash. Silently
    omitting the row would be the worse answer: it is one of the largest
    changes in the build.
    """
    per_script = {}
    with open(targets_tsv, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            script, line, target = raw.split("\t")
            per_script.setdefault(os.path.basename(script), []).append(
                (int(line), target)
            )

    rows = []
    for script in ("patch.sh", "theme.sh"):
        hits = per_script.get(script, [])
        sections = read_sections(os.path.join(ROOT, script))
        buckets = {}
        for start, title, has_commands in sections:
            if has_commands:
                buckets[start] = (title, set())
        unsectioned = set()

        for line, target in hits:
            owner = 0
            for start, _title, has_commands in sections:
                if start <= line and has_commands:
                    owner = start
                elif start > line:
                    break
            if owner:
                buckets[owner][1].add(target)
            else:
                unsectioned.add(target)

        if unsectioned:
            rows.append(
                (AERIUM_GROUP, script, "(unsectioned)", len(unsectioned))
            )
        for start in sorted(buckets):
            title, targets = buckets[start]
            rows.append(
                (AERIUM_GROUP, "%s:%d" % (script, start), title, len(targets))
            )
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--version", default="")
    # The CI run number, so a build can say which build it is. Empty for a
    # local build, which is the honest answer there - there is no run.
    parser.add_argument("--build-number", default="")
    parser.add_argument(
        "--patches", default=os.path.join(ROOT, "vanadium", "patches")
    )
    args = parser.parse_args()

    version = args.version
    if not version:
        with open(os.path.join(ROOT, "vanadium", "args.gn"), encoding="utf-8") as f:
            match = re.search(r"\d+(?:\.\d+){3}", f.read())
        version = match.group(0) if match else "unknown"

    targets = subprocess.run(
        [os.path.join(HERE, "collect-targets.sh")],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    targets_path = args.out + ".targets"
    with open(targets_path, "w", encoding="utf-8") as handle:
        handle.write(targets)

    rows = read_vanadium(args.patches) + read_aerium(targets_path)
    os.unlink(targets_path)

    # An empty list would render a page claiming this build changes nothing
    # about Chromium, which is the one statement it must never make. Fail
    # instead, and let the compile error that follows say so.
    if not rows:
        sys.stderr.write(
            "[aerium] FATAL: no patches found - refusing to write an empty "
            "chrome://aerium manifest\n"
        )
        return 1

    out = [
        "// Generated by devutils/generate_patch_manifest.py. Do not edit.",
        "",
        'inline constexpr char kAeriumChromiumVersion[] = "%s";'
        % cpp_string(version),
        'inline constexpr char kAeriumBuildNumber[] = "%s";'
        % cpp_string(args.build_number),
        "",
        "inline constexpr AeriumPatchEntry kAeriumPatches[] = {",
    ]
    for group, name, summary, files in rows:
        out.append(
            '    {"%s", "%s", "%s", %d},'
            % (cpp_string(group), cpp_string(name), cpp_string(summary), files)
        )
    out.append("};")
    out.append("")

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))

    sys.stderr.write(
        "[aerium] chrome://aerium manifest: %d rows (%d Vanadium, %d Aerium)\n"
        % (
            len(rows),
            sum(1 for r in rows if r[0] == VANADIUM_GROUP),
            sum(1 for r in rows if r[0] == AERIUM_GROUP),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
