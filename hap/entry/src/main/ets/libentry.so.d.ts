export const unpackTar: (tarPath: string, destDir: string) => boolean;
export const startR: (rBin: string, rHome: string, workDir: string, libsDir: string, onOutput: (chunk: string) => void) => number;
export const writeR: (line: string) => void;
export const interruptR: () => void;
export const stopR: () => void;
export const pollOutput: () => string;