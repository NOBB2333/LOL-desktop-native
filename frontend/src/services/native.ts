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
    throw new RangeError("原生调用并发数必须是正整数");
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

export function createCommandScheduler() {
  const state = createInvocationScheduler(2);
  const roster = createInvocationScheduler(1);
  const query = createInvocationScheduler(2);
  const action = createInvocationScheduler(1);
  return function schedule<T>(name: string, task: () => Promise<T>): Promise<T> {
    if (["lol.get_live_roster", "lol.refresh_connection", "lol.get_lcu_events"].includes(name)) return roster(task);
    if (["lol.send_shortcut", "lol.delete_friend", "lol.run_automation"].includes(name)) return action(task);
    if (["lol.get_config", "lol.save_config", "lol.set_shortcut_capture", "lol.set_data_mode", "lol.get_live_lobby", "lol.get_shortcut_events", "lol.open_game_view", "lol.validate_shortcut_template"].includes(name)) return state(task);
    return query(task);
  };
}

const scheduleNativeInvocation = createCommandScheduler();

export const isNative = () => typeof window !== "undefined" && Boolean(window.zero);

export async function invokeNative<T>(name: string, payload?: unknown): Promise<T> {
  const bridge = window.zero;
  if (!bridge) throw new Error("原生桥接尚不可用");
  return scheduleNativeInvocation(name, () => bridge.invoke<T>(name, payload));
}

export function listenNative<T>(name: string, callback: (detail: T) => void): () => void {
  const bridge = window.zero;
  if (!bridge) return () => undefined;
  return bridge.on<T>(name, callback);
}
