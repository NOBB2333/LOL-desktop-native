export interface CoalescedAsyncRunner {
  run: () => Promise<void>;
  dispose: () => void;
}

/** Run at most one request at a time and collapse any overlap into one rerun. */
export function createCoalescedAsyncRunner(task: () => Promise<void>): CoalescedAsyncRunner {
  let running: Promise<void> | null = null;
  let queued = false;
  let disposed = false;

  const run = () => {
    if (disposed) return Promise.resolve();
    queued = true;
    if (running) return running;
    running = (async () => {
      do {
        queued = false;
        await task();
      } while (queued && !disposed);
    })().finally(() => {
      running = null;
    });
    return running;
  };

  return {
    run,
    dispose() {
      disposed = true;
      queued = false;
    },
  };
}
