export function createShortcutSendQueue() {
  let tail: Promise<unknown> = Promise.resolve();
  const pending = new Map<string, Promise<unknown>>();

  return function send<T>(key: string, execute: () => Promise<T>): Promise<T> {
    const existing = pending.get(key);
    if (existing) return existing as Promise<T>;
    if (pending.size >= 4) return Promise.reject(new Error("发送队列已满，请等待当前消息完成"));
    const queuedAt = Date.now();
    const request = tail.catch(() => undefined).then(() => {
      if (Date.now() - queuedAt > 10_000) throw new Error("消息等待过久，已取消本次排队发送");
      return execute();
    }).finally(() => { pending.delete(key); });
    pending.set(key, request);
    tail = request;
    return request;
  };
}
