# Agent Web 系統架構

這份文件描述 Agent Web 的元件、程序、網路、資料、生命週期與安全邊界。

## 設計目標

Agent Web 解決的核心問題是：Linux 伺服器沒有實體螢幕或桌面環境，但使用者仍需要一個像普通電腦一樣可登入網站、保存 Cookie、長時間運作並可從內網操作的 Chromium。

設計原則：

- 瀏覽器生命週期不依附使用者電腦上的分頁。
- 使用 Debian 原生套件與 systemd，降低 Raspberry Pi 的部署成本。
- 人類只需要一般現代瀏覽器。
- Profile 與下載持久化，快取可重建。
- 只對內網暴露一個有 HTTPS 與密碼保護的入口。
- 預留 Agent 控制能力，但預設不開放高權限自動化埠。

## 完整資料流

```text
使用者 Chrome / Edge / Firefox
    │
    │ HTTPS :6901
    │ HTTP Basic Authentication
    │ WebSocket Upgrade
    ▼
Nginx
使用者：agent-web-web
    │
    │ http://127.0.0.1:6080
    ▼
noVNC 靜態前端 + websockify
使用者：agent-web
    │
    │ VNC TCP 127.0.0.1:5901
    ▼
TigerVNC 虛擬 X11 Display :1
    │
    ▼
Openbox 視窗管理器
    │
    ▼
Chromium + /var/lib/agent-web/profile
```

## 元件責任

### Chromium

真正執行網站、JavaScript、Cookie、下載、登入 Session 與頁面渲染。使用獨立的 `agent-web` Profile，而不是 `pi` 使用者的個人 Profile。

Chromium 關閉或崩潰時，瀏覽器工作階段腳本會等待 3 秒後重新啟動。Profile 保留，但是否恢復分頁取決於 Chromium 與網站本身。

### Openbox

提供輕量 X11 視窗管理。它讓 Chromium 能在虛擬桌面中最大化、顯示視窗及處理基本視窗事件，不安裝完整 GNOME 或 KDE。

### TigerVNC

建立 `:1` 虛擬 X11 螢幕，預設解析度 `1280x720x24`，並在 `127.0.0.1:5901` 提供 VNC 畫面與輸入事件。

VNC 層使用 `SecurityTypes None`，因為它嚴格限制為 loopback；外部驗證與加密統一由 Nginx 負責。若未來改成非 loopback，必須先重新設計 VNC 認證。

### noVNC 與 websockify

noVNC 是瀏覽器中的 VNC 用戶端。websockify 把 WebSocket 轉成傳統 VNC TCP。服務只監聽 `127.0.0.1:6080`，不能直接從內網連線。

### Nginx

唯一對內網監聽的服務，位於 `0.0.0.0:6901`，負責：

- TLS 1.2／1.3
- bcrypt HTTP Basic Authentication
- `/` 導向 noVNC 頁面
- noVNC 靜態內容反向代理
- WebSocket Upgrade
- 安全回應標頭

### systemd

管理四個單元：

```text
agent-web.target
├── agent-web-browser.service
├── agent-web-novnc.service
└── agent-web-web.service
```

服務在開機時啟動，異常退出後每 5 秒重新啟動。瀏覽器先啟動，接著是 noVNC，最後是 HTTPS Gateway。

## 網路邊界

| 連接埠 | 監聽位址 | 功能 | 外部可連 |
|---:|---|---|---|
| 6901 | `0.0.0.0` | HTTPS、Basic Auth、noVNC | 是，限內網策略 |
| 6080 | `127.0.0.1` | noVNC/websockify | 否 |
| 5901 | `127.0.0.1` | VNC | 否 |

檢查實際監聽：

```bash
sudo ss -ltnp | grep -E ':(5901|6080|6901)\b'
```

## 身分與檔案權限

### `agent-web`

執行 TigerVNC、Openbox、Chromium 與 websockify。它是無登入 shell 的系統帳號，只能寫入瀏覽器資料、下載、Chromium 快取與自己的 runtime 目錄。

### `agent-web-web`

執行 Nginx Gateway，可讀取 htpasswd 與 TLS 私鑰，但不能讀取 Chromium Profile。這樣即使 Web Gateway 發生問題，也不會直接取得網站 Cookie。

### `root`

只在安裝、更新、systemd 管理、變更密碼或憑證時使用。瀏覽器與 Web Gateway 平時都不是 root 程序。

## 持久資料與暫存

| 路徑 | 類型 | 說明 |
|---|---|---|
| `/var/lib/agent-web/profile` | 持久 | Cookie、Session、歷史、網站儲存與 Chromium 設定 |
| `/var/lib/agent-web/downloads` | 持久 | 下載檔案 |
| `/etc/agent-web` | 持久 | Basic Auth、TLS、環境與 Nginx 設定 |
| `/var/cache/agent-web` | 可重建 | Chromium 與 Nginx 暫存 |
| `/run/agent-web*` | 暫時 | PID、Xauthority、XDG runtime；重新開機重建 |

## 關閉頁面後為何仍運行

使用者電腦只是 noVNC 用戶端。關閉頁面只會關閉 WebSocket，不會向 systemd 發送停止命令。

Chromium 的父生命週期由 `agent-web-browser.service` 管理，因此：

```text
本機分頁關閉 ≠ noVNC 服務停止 ≠ Chromium 停止
```

## 隔離與安全邊界

目前隔離由三層組成：

1. 不同 Linux 系統帳號。
2. systemd 的檔案系統、裝置、核心介面、程序數、CPU 與記憶體限制。
3. Chromium 自身 sandbox；專案不使用 `--no-sandbox`。

這比直接以 `pi` 帳號執行瀏覽器安全，但不是容器或虛擬機。所有程序仍共用主機 Kernel。

### 主要風險

- 知道 noVNC 密碼的人等同能操作所有已登入網站。
- 自簽憑證提供加密，但第一次信任時不能自動證明主機身分。
- Profile 是高價值敏感資料；root 或 `agent-web` 帳號可以讀取。
- 惡意網站可能利用 Chromium 漏洞；應保持 Debian 和 Chromium 更新。
- 下載可能填滿磁碟，長期快取與頻繁寫入也會影響 SD 卡壽命。
- 未來 Agent 會增加 Prompt Injection、誤點擊、資料外洩與高風險操作問題。

### 安全建議

- 只在可信任內網使用，不做路由器 port forwarding。
- 使用至少 16 字元的隨機密碼。
- 用防火牆限制可連 `6901` 的網段或裝置。
- 重要帳號啟用 MFA，不把付款或管理員帳號交給無審批 Agent。
- 定期更新並加密備份 Profile。
- Agent 控制介面只允許 loopback、Unix socket、SSH tunnel 或有強認證的專用 Relay。

## Agent 擴充點

目前 noVNC 是人類控制介面，不是 Agent API。未來建議保留 noVNC 當可視化與人工接管通道，再增加本機 Agent Adapter：

```text
Agent Runtime
    │ Unix socket / loopback + authentication
    ▼
Agent Web Adapter
    │ CDP / Chrome Extension Relay
    ▼
現有 Chromium
```

這樣不必重做 VNC、HTTPS、Profile 或 systemd，只新增一條有明確權限與生命週期的機器控制通道。詳細契約見 [Agent 整合指南](AGENT-INTEGRATION.md)。
