/** 解包 ustar（build/40-pack.sh 生成的 rhome.tar）到沙箱目录 */
export const unpackTar: (tarPath: string, destDir: string) => boolean;

/** 启动 R 子进程，返回 pid（<0 表示失败）。onOutput 按行回推 R 输出 */
export const startR: (rBin: string, rHome: string, workDir: string, libsDir: string,
  onOutput: (chunk: string) => void) => number;

/** 向 R 的 stdin 写一行 */
export const writeR: (line: string) => void;

/** 发送 SIGINT（中断当前计算） */
export const interruptR: () => void;

/** 结束 R 进程 */
export const stopR: () => void;
