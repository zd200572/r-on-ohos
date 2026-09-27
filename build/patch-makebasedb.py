#!/usr/bin/env python3
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()
old = 'if (file.info(baseFileBase)["size"] < 20000)'
new = 'if (FALSE)'
c2 = c.replace(old, new)
with open(p, "w") as f:
    f.write(c2)
print("patched" if c != c2 else "no change")