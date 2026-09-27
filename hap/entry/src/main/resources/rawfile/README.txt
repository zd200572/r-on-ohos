此目录的 rhome.tar 由交叉编译脚本生成，不要手工提交：

  cd build && ./40-pack.sh
  → 把 build/out/rhome-<arch>.tar 拷贝为 entry/src/main/resources/rawfile/rhome.tar

注意：模拟器验证用 x86_64 构建产物，真机（鸿蒙 PC）用 aarch64 产物。
