export class WorkerPool {
  constructor(size, workerUrl) {
    this.workers = [];
    this.queue = [];
    this.idleWorkers = [];

    for (let i = 0; i < size; i++) {
      const worker = new Worker(workerUrl, { type: "module" });
      worker.onmessage = (e) => {
        const { resolve } = worker.currentTask;
        worker.currentTask = null;
        this.idleWorkers.push(worker);
        resolve(e.data);
        this._runNext();
      };
      this.workers.push(worker);
      this.idleWorkers.push(worker);
    }
  }

  runTask(payload) {
    return new Promise((resolve) => {
      this.queue.push({ payload, resolve });
      this._runNext();
    });
  }

  _runNext() {
    if (this.queue.length === 0 || this.idleWorkers.length === 0) return;
    const worker = this.idleWorkers.shift();
    const task = this.queue.shift();
    worker.currentTask = task;
    worker.postMessage(task.payload);
  }
}

