# `backend/packages/harness/helix/sandbox/file_operation_lock.py`

> 逐字复制的真实源码（28 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```python
import threading
import weakref

from helix.sandbox.sandbox import Sandbox

# Use WeakValueDictionary to prevent memory leak in long-running processes.
# Locks are automatically removed when no longer referenced by any thread.
_LockKey = tuple[str, str]
_FILE_OPERATION_LOCKS: weakref.WeakValueDictionary[_LockKey, threading.Lock] = weakref.WeakValueDictionary()
_FILE_OPERATION_LOCKS_GUARD = threading.Lock()


def get_file_operation_lock_key(sandbox: Sandbox, path: str) -> tuple[str, str]:
    sandbox_id = getattr(sandbox, "id", None)
    if not sandbox_id:
        sandbox_id = f"instance:{id(sandbox)}"
    return sandbox_id, path


def get_file_operation_lock(sandbox: Sandbox, path: str) -> threading.Lock:
    lock_key = get_file_operation_lock_key(sandbox, path)
    with _FILE_OPERATION_LOCKS_GUARD:
        lock = _FILE_OPERATION_LOCKS.get(lock_key)
        if lock is None:
            lock = threading.Lock()
            _FILE_OPERATION_LOCKS[lock_key] = lock
        return lock
```
