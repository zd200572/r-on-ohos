#!/bin/bash
set -e

BREW=/storage/Users/currentUser/.harmonybrew
JAVA_HOME=$BREW/Cellar/openjdk/26.0.2.1_2
R_HOME=$BREW/Cellar/r/4.5.1
R=$R_HOME/bin/R

export JAVA_HOME
export PATH=$JAVA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$JAVA_HOME/libexec/lib/server:$BREW/lib:$LD_LIBRARY_PATH

echo "=== Java version ==="
java -version 2>&1

echo "=== R CMD javareconf ==="
$R CMD javareconf 2>&1 || true

echo "=== Check javaconf ==="
cat $R_HOME/lib/R/etc/javaconf 2>/dev/null || echo "No javaconf file"

echo "=== R capabilities ==="
$R_HOME/bin/Rscript -e 'print(capabilities()["java"])' 2>&1 || true