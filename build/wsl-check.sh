#!/usr/bin/env bash
# WSL 环境检查（以文件方式运行，避免 wsl.exe 传参转义问题）
for t in curl unzip zip gfortran gcc g++ make perl awk tar xz python3 cmake java; do
  if command -v "$t" >/dev/null 2>&1; then echo "have   $t"; else echo "MISS   $t"; fi
done
echo "--- headers ---"
for h in zlib.h pcre2.h bzlib.h lzma.h; do
  [ -f "/usr/include/$h" ] && echo "have   $h" || echo "MISS   $h"
done
echo "--- apt-get download 探测（无需 sudo）---"
mkdir -p /tmp/apttest && cd /tmp/apttest
timeout 60 apt-get download f2c 2>&1 | tail -2; ls *.deb 2>/dev/null && echo APT_DOWNLOAD_OK
echo "--- netlib f2c 源码候选 URL 探测 ---"
for u in "https://www.netlib.org/f2c/libf2c.zip" \
         "https://codeload.github.com/Distrotech/f2c/tar.gz/refs/heads/master"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -I --max-time 20 "$u")
  echo "$code  $u"
done