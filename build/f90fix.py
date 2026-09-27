#!/usr/bin/env python3
"""f90fix.py —— 把 R 源码中 f2c 不支持的 f90 构造转换为 f77（f2c 移植专用）。

处理三类问题（R 4.5.1 精确定位，逐处替换并校验命中次数）：
  1. dqrdc2.f：裸 DO ... exit ... end do → 标号 GOTO 循环
  2. cmplx.f / dlapack.f：块 IF 内的 EXIT → GOTO 到循环后的标号
  3. dlapack.f：DO WHILE → 标号循环
标签使用 9001+ 区段，避开原文件的低段标号。命中数不符即报错退出。
"""
import sys
from pathlib import Path

root = Path(sys.argv[1])

def patch(rel, old, new, expect):
    p = root / rel
    s = p.read_text(encoding="latin-1")
    if new.strip() in s:                # 幂等：已打过则跳过
        print(f"skip {rel}（已含补丁）")
        return
    n = s.count(old)
    if n != expect:
        sys.exit(f"FATAL {rel}: 期望 {expect} 处，实际 {n} 处：\n{old[:120]!r}")
    s = s.replace(old, new, 1)          # 每次替换第一处，配合循环调用实现逐处不同标号
    p.write_text(s, encoding="latin-1")
    print(f"patched {rel} ({expect} 处剩余)")

# ---------- 1) dqrdc2.f 裸 DO ----------
patch("src/appl/dqrdc2.f",
"""         do
            if (l .ge. k .or. qraux(l) .ge. work(l,2)*tol) exit""",
""" 9007       continue
            if (l .ge. k .or. qraux(l) .ge. work(l,2)*tol) goto 9008""", 1)
patch("src/appl/dqrdc2.f",
"""         end do                 ! (no index)""",
"""            goto 9007
 9008       continue""", 1)

# ---------- 2) cmplx.f 两处 EXIT（文本相同，逐处替换、标号不同）----------
swap = """                     CANSWAP = .FALSE.
                     EXIT
                  END IF
               END DO
"""
fix  = """                     CANSWAP = .FALSE.
                     GOTO {L}
                  END IF
               END DO
 {L}           CONTINUE
"""
patch("src/modules/lapack/cmplx.f", swap, fix.format(L=9001), 2)   # 共 2 处
patch("src/modules/lapack/cmplx.f", swap, fix.format(L=9002), 1)   # 替换剩余 1 处

# ---------- 3) dlapack.f 两处 CANSWAP EXIT ----------
swap2 = """                     CANSWAP = .FALSE.
                     EXIT
                  END IF
               END DO
"""
fix2  = """                     CANSWAP = .FALSE.
                     GOTO {L}
                  END IF
               END DO
 {L}           CONTINUE
"""
patch("src/modules/lapack/dlapack.f", swap2, fix2.format(L=9003), 2)
patch("src/modules/lapack/dlapack.f", swap2, fix2.format(L=9004), 1)

# ---------- 4) dlapack.f DO WHILE + EXIT ----------
patch("src/modules/lapack/dlapack.f",
"""      DO WHILE( IMAX .GT. 1 )
         IF( PHI(IMAX-1) .NE. ZERO ) THEN
            EXIT
         END IF
         IMAX = IMAX - 1
      END DO
""",
""" 9005       CONTINUE
      IF( IMAX .GT. 1 ) THEN
         IF( PHI(IMAX-1) .NE. ZERO ) GOTO 9006
         IMAX = IMAX - 1
         GOTO 9005
      END IF
 9006       CONTINUE
""", 1)

# ---------- 5) dsvdc.f / dtrsl.f：SELECT CASE 恢复为 computed GOTO（R 注释里就有原版）----------
patch("src/appl/dsvdc.f",
"""c         go to (490,520,540,570), kase
         select case(kase)
         case(1)
            goto 490
         case(2)
            goto 520
         case(3)
            goto 540
         case(4)
            goto 570
         end select
""",
"""c         go to (490,520,540,570), kase
         go to (490,520,540,570), kase
""", 1)

patch("src/appl/dtrsl.f",
"""c      go to (20,50,80,110), case
      select case(kase)
      case(1)
         goto 20
      case(2)
         goto 50
      case(3)
         goto 80
      case(4)
         goto 110
      end select
""",
"""c      go to (20,50,80,110), case
      go to (20,50,80,110), kase
""", 1)

# ---------- 6) hclust.f：INTEGER(KIND=SELECTED_INT_KIND(R=18)) → INTEGER*8 ----------
patch("src/library/stats/src/hclust.f",
"      INTEGER(KIND=SELECTED_INT_KIND(R=18)) N8,I8,J8",
"      INTEGER*8 N8,I8,J8", 1)

# ---------- 7) hclust.f：局部可调数组 FLAG(N) → 固定大小（F77 不允许局部可调数组）----------
patch("src/library/stats/src/hclust.f",
"      LOGICAL FLAG(N), isWard",
"      LOGICAL FLAG(100000), isWard", 1)

# ---------- 8) ppr.f：supsmu 中局部可调数组 h(n) → 固定大小 ----------
patch("src/library/stats/src/ppr.f",
"      double precision sy,sw, a,h(n),f, scale,vsmlsq,resmin",
"      double precision sy,sw, a,h(100000),f, scale,vsmlsq,resmin", 1)

# ---------- 9) portsrc.f：SELECT CASE → IF-THEN-ELSE（f2c 不支持 SELECT CASE）----------
def fix_select_case(rel):
    p = root / rel
    lines = p.read_text(encoding="latin-1").splitlines(keepends=True)
    out = []
    i = 0
    count = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip().lower()
        if stripped.startswith("select case("):
            count += 1
            var = stripped[len("select case("):].rstrip(")")
            i += 1
            first_case = True
            while i < len(lines):
                cl = lines[i]
                cs = cl.strip().lower()
                if cs == "end select":
                    out.append("      END IF\n")
                    i += 1
                    break
                elif cs.startswith("case default"):
                    out.append("      ELSE\n")
                    i += 1
                elif cs.startswith("case("):
                    cases = cs[len("case("):].rstrip(")")
                    conds = []
                    for part in cases.split(","):
                        part = part.strip()
                        if ":" in part:
                            lo, hi = part.split(":")
                            lo = lo.strip()
                            hi = hi.strip()
                            if lo and hi:
                                conds.append(f"{var} .ge. {lo} .and. {var} .le. {hi}")
                            elif lo:
                                conds.append(f"{var} .ge. {lo}")
                            elif hi:
                                conds.append(f"{var} .le. {hi}")
                        else:
                            conds.append(f"{var} .eq. {part}")
                    cond = " .or. ".join(conds)
                    if first_case:
                        out.append(f"      IF ({cond}) THEN\n")
                        first_case = False
                    else:
                        out.append(f"      ELSE IF ({cond}) THEN\n")
                    i += 1
                else:
                    out.append(cl)
                    i += 1
        else:
            out.append(line)
            i += 1
    p.write_text("".join(out), encoding="latin-1")
    print(f"patched {rel}: {count} 处 SELECT CASE → IF-THEN-ELSE")

fix_select_case("src/library/stats/src/portsrc.f")

# ---------- 10) portsrc.f：CHARACTER(4) → CHARACTER*4（f2c 对 CHARACTER(len) 语法处理有问题）----------
patch("src/library/stats/src/portsrc.f",
"      CHARACTER(4) CNGD(3), DFLT(3), WHICH(3)",
"      CHARACTER*4 CNGD(3), DFLT(3), WHICH(3)", 1)

print("f90fix: 全部替换完成")
