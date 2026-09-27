#!/usr/bin/env python3
import sys, os

src_dir = sys.argv[1] if len(sys.argv) > 1 else "."

patches = [
    {
        "files": ["Makefile.in", "Makefile"],
        "replacements": [
            ("all: Makefile Makeconf R docs recommended vignettes javaconf",
             "all: Makefile Makeconf R recommended vignettes javaconf"),
            ("docs: R FORCE\n\t@(cd doc && $(MAKE) $@)\n\t-@(cd src/library && $(MAKE) $@)",
             "docs: R FORCE\n\t@true"),
        ]
    },
    {
        "files": ["doc/Makefile.in", "doc/Makefile"],
        "replacements": [
            ("install: install-message installdirs install-sources install-sources2 install-man",
             "install: install-message installdirs install-sources install-sources2"),
        ]
    },
]

changed = False
for patch in patches:
    for fname in patch["files"]:
        p = os.path.join(src_dir, fname)
        if not os.path.exists(p):
            print(f"skip {p} (not found)")
            continue
        with open(p) as f:
            c = f.read()
        c2 = c
        for old, new in patch["replacements"]:
            c2 = c2.replace(old, new)
        if c != c2:
            with open(p, "w") as f:
                f.write(c2)
            print(f"patched {p}")
            changed = True
        else:
            print(f"no change {p}")

if not changed:
    print("WARNING: no files were modified")
