export interface NativeSdkApi {
  invoke<T = unknown>(command: string, payload?: unknown): Promise<T>;
  on<T = unknown>(name: string, callback: (detail: T) => void): () => void;
  off<T = unknown>(name: string, callback: (detail: T) => void): void;
  credentials: {
    get(options: { service: string; account: string }): Promise<string | null>;
    set(options: { service: string; account: string; secret: string }): Promise<boolean>;
    delete(options: { service: string; account: string }): Promise<boolean>;
  };
}

declare global {
  interface Window { zero?: NativeSdkApi; }
}

export const NATIVE_INVOCATION_CONCURRENCY = 4;

export function createInvocationScheduler(maxConcurrency = NATIVE_INVOCATION_CONCURRENCY) {
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
    throw new RangeError("Native invocation concurrency must be a positive integer");
  }

  let active = 0;
  const pending: Array<() => void> = [];

  const startNext = () => {
    if (active >= maxConcurrency) return;
    const next = pending.shift();
    if (next) next();
  };

  return function schedule<T>(task: () => Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const run = () => {
        active += 1;
        Promise.resolve()
          .then(task)
          .then(resolve, reject)
          .finally(() => {
            active -= 1;
            startNext();
          });
      };

      if (active < maxConcurrency) run();
      else pending.push(run);
    });
  };
}

const scheduleNativeInvocation = createInvocationScheduler();

export const isNative = () => typeof window !== "undefined" && Boolean(window.zero);

export async function invokeNative<T>(name: string, payload?: unknown): Promise<T> {
  const bridge = window.zero;
  if (!bridge) throw new Error("Native bridge is not available");
  return scheduleNativeInvocation(() => bridge.invoke<T>(name, payload));
}

export function listenNative<T>(name: string, callback: (detail: T) => void): () => void {
  const bridge = window.zero;
  if (!bridge) return () => undefined;
  return bridge.on<T>(name, callback);
}
