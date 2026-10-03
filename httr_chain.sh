#!/bin/bash
BREW=/storage/Users/currentUser/.harmonybrew
RH=$BREW/Cellar/r/4.5.1

export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${LD_LIBRARY_PATH:-}

echo "=== Installing httr + rvest + reprex + tidyverse(meta) ==="
$RH/bin/Rscript -e 'install.packages(c("httr","rvest","reprex","tidyverse"), repos="https://cloud.r-project.org", type="source")' > /tmp/httr_chain.log 2>&1 &
echo "PID=$!"