#!/bin/bash
BREW=/storage/Users/currentUser/.harmonybrew
RH=$BREW/Cellar/r/4.5.1

# pthread stub (needed per ci-runner experience)
export LD_PRELOAD=/usr/lib/libpthread_stub.so
export LD_LIBRARY_PATH=$BREW/lib:${LD_LIBRARY_PATH:-}

echo "=== Installing askpass (capture full log) ==="
$RH/bin/Rscript -e 'install.packages("askpass", repos="https://cloud.r-project.org", type="source")' 2>&1 | tee /tmp/askpass_install.log

echo ""
echo "=== EXIT CODE: $? ==="
echo "=== Check if installed ==="
ls $BREW/lib/R/4.5/site-library/askpass/ 2>/dev/null && echo "INSTALLED" || echo "NOT INSTALLED"