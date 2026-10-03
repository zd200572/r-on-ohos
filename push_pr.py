#!/usr/bin/env python3
"""Commit R formula and push to AtomGit fork"""
import paramiko

HOST='100.95.132.23'; PORT=22; USER='bz'; PASS='201501'
TOKEN='f-RK96pcgCqy471HNPYMoA6x'
FORK_URL=f'https://zd2005721:{TOKEN}@atomgit.com/zd2005721/homebrew-core.git'
CLEAN_URL='https://atomgit.com/zd2005721/homebrew-core.git'

COMMIT_MSG = """r: add 4.5.1 formula

New formula for R 4.5.1 adapted for HarmonyOS (OHOS):
- Skip openblas/tcl-tk on OHOS (not available there)
- Preset mktime configure checks via ENV (OHOS musl lacks tzdata)
- Add zlib-ng-compat -L to LDFLAGS so `-lz` resolves the real zlib
  instead of the stub libz.so in the OHOS SDK sysroot (whose gzopen is
  a no-op, which makes gzfile()/read.dcf() fail during the build)
- Set LD_LIBRARY_PATH to the build-tree lib dir during make so R can
  run itself (make sysdata) before installation

Verified: `brew install -s r` succeeds in the Harmonybrew ci-runner
container; R REPL, gzfile/read.dcf, and Rcpp-based package compilation
all work.
"""

GIT_SH = f'''#!/bin/sh
TAP=/storage/Users/currentUser/.harmonybrew/Homebrew/Library/Taps/harmonybrew/homebrew-core
cp /tmp/r_formula_ohos.rb $TAP/Formula/r/r.rb
sed -i 's/\r$//' $TAP/Formula/r/r.rb
cd $TAP
git remote remove fork 2>/dev/null
git remote add fork '{FORK_URL}'
git checkout -b add-r-formula 2>/dev/null || git checkout add-r-formula
git add Formula/r/r.rb
git commit -F /tmp/r_commit_msg.txt
git push fork add-r-formula 2>&1
RC=$?
git remote set-url fork '{CLEAN_URL}'
echo "PUSH_RC=$RC"
'''

def main():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, port=PORT, username=USER, password=PASS, timeout=15)

    sftp = ssh.open_sftp()
    with open('r_formula_ohos.rb','r',encoding='utf-8') as f: formula = f.read()
    with sftp.file('/tmp/r_formula_ohos.rb','w') as f: f.write(formula)
    with sftp.file('/tmp/r_commit_msg.txt','w') as f: f.write(COMMIT_MSG)
    with sftp.file('/tmp/git_push.sh','w') as f: f.write(GIT_SH)
    sftp.close()

    def run(cmd, timeout=180):
        stdin, stdout, stderr = ssh.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode()
        err = stderr.read().decode()
        return out, err

    out, err = run('docker cp /tmp/r_formula_ohos.rb ohos:/tmp/r_formula_ohos.rb && '
                   'docker cp /tmp/r_commit_msg.txt ohos:/tmp/r_commit_msg.txt && '
                   'docker cp /tmp/git_push.sh ohos:/tmp/git_push.sh && echo COPIED')
    print(out.strip())
    if err.strip(): print('ERR:', err.strip())

    out, err = run('docker exec ohos sh /tmp/git_push.sh 2>&1', timeout=300)
    print(out)
    if err.strip(): print('STDERR:', err[-500:])

    ssh.close()

if __name__ == '__main__':
    main()