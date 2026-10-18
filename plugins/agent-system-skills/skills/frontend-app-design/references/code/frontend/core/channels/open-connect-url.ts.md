# `frontend/core/channels/open-connect-url.ts`

> 逐字复制的真实源码（28 行），仅按品牌词映射表做机械替换；文件路径即真实仓库相对路径（品牌词替换后），结构、注释、逻辑零改动。

```typescript
export type ChannelConnectWindow = Window | null;

export function prepareConnectWindow(): ChannelConnectWindow {
  const opened = window.open("about:blank", "_blank");
  if (opened) {
    opened.opener = null;
  }
  return opened;
}

export function openConnectUrl(
  url: string,
  connectWindow: ChannelConnectWindow = prepareConnectWindow(),
) {
  if (connectWindow && !connectWindow.closed) {
    connectWindow.location.replace(url);
    return;
  }

  window.location.assign(url);
}

export function closeConnectWindow(connectWindow: ChannelConnectWindow) {
  if (connectWindow && !connectWindow.closed) {
    connectWindow.close();
  }
}
```
