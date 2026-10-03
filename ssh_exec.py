#!/usr/bin/env python3
"""SSH command executor for cloud host"""
import paramiko, sys

HOST = '100.95.132.23'
PORT = 22
USER = 'bz'
PASS = '201501'

def run(cmd, timeout=120):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        ssh.connect(HOST, port=PORT, username=USER, password=PASS, timeout=15)
        stdin, stdout, stderr = ssh.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode()
        err = stderr.read().decode()
        code = stdout.channel.recv_exit_status()
        if out:
            print(out, end='')
        if err:
            print(err, end='', file=sys.stderr)
        ssh.close()
        return code
    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    cmd = ' '.join(sys.argv[1:]) if len(sys.argv) > 1 else 'echo ok'
    sys.exit(run(cmd))