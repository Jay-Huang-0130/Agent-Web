# Agent Web Agent 整合指南

這份文件定義 OpenClaw、其他現有 Agent，或自行開發的 Agent 如何發現與整合 Agent Web。

## 目前能力邊界

目前穩定版提供：

- 持續運行的 Chromium
- 固定且持久的 Chromium Profile
- 人類可用的 HTTPS/noVNC 操作入口
- systemd 生命週期管理
- 無秘密的能力發現指令

目前穩定版尚未提供：

- 對外 CDP endpoint
- REST 點擊／輸入 API
- Agent Token
- 操作佇列或人工審批 API
- 多個 Agent 同時操作的鎖定機制

這是刻意的安全預設。安裝完成不代表任何程式都能直接取得瀏覽器控制權。

## 1. Agent 如何發現 Agent Web

先確認控制器存在：

```bash
command -v agent-webctl
```

再取得穩定、無秘密的能力資訊：

```bash
agent-webctl info
```

目前輸出格式：

```text
AGENT_WEB_INFO_VERSION=1
INSTALLED=true
READY=true
HUMAN_URL=https://192.168.31.75:6901/
HUMAN_CONTROL_PROTOCOL=novnc
AGENT_CONTROL_AVAILABLE=false
AGENT_CONTROL_PROTOCOL=none
BROWSER_SERVICE=active
NOVNC_SERVICE=active
WEB_SERVICE=active
HTTPS_AUTH_CHECK=401
PROFILE_DIR=/var/lib/agent-web/profile
DOWNLOAD_DIR=/var/lib/agent-web/downloads
```

整合程式應遵守：

- 只解析自己認識的 Key，忽略未知 Key。
- 使用 `AGENT_WEB_INFO_VERSION` 判斷格式版本。
- `READY=true` 才代表三個服務及 HTTPS 驗證都正常。
- `AGENT_CONTROL_AVAILABLE=false` 時，不得假設有 CDP 或自動化 API。
- 此輸出永遠不應包含密碼、Cookie、Token 或 TLS 私鑰。

Shell 探測範例：

```bash
if command -v agent-webctl >/dev/null 2>&1; then
  agent-webctl info
else
  echo "Agent Web is not installed"
fi
```

## 2. 人類通道與 Agent 通道必須分開

推薦架構：

```text
人類
  └── HTTPS + noVNC ──────────┐
                              ▼
                        同一個 Chromium
                              ▲
Agent                         │
  └── Agent Adapter + CDP ────┘
```

noVNC 的責任是：

- 顯示 Agent 正在做什麼
- 讓使用者登入網站或完成 MFA
- 在需要時人工接管
- 處理難以由 DOM API 操作的系統視窗

Agent Adapter 的責任是：

- 列出與選擇分頁
- 導航
- 取得 DOM／Accessibility Snapshot
- 點擊、輸入、拖曳與鍵盤操作
- 截圖
- 追蹤下載
- 管理逾時、錯誤、鎖定和審批

不要把 noVNC 密碼當成 Agent API Token，也不要讓 Agent 用像素座標當主要控制方式。

## 3. 推薦控制後端

### 方案 A：本機 CDP Adapter（推薦方向）

Chromium 可以透過 Chrome DevTools Protocol 提供分頁、DOM、輸入、網路和截圖控制。未來 Agent Web 可讓 Chromium 只在 loopback 或 Unix socket 邊界提供 CDP，再由 Adapter 封裝成較小且可審計的介面。

概念：

```text
Agent -> Agent Web Adapter -> 127.0.0.1 CDP -> Chromium
```

CDP 幾乎等同完整瀏覽器權限，因此：

- 不得監聽 `0.0.0.0`。
- 不得直接暴露到內網或 Internet。
- 遠端 Agent 應透過部署在 Pi 上的 node、SSH tunnel，或有雙向認證的 Relay。
- Adapter 應限制任意 JavaScript、任意檔案讀取和任意 URL。

### 方案 B：Chrome Extension Relay

擴充功能可使用 `chrome.debugger` 只把允許的分頁交給 Agent。適合需要 Pause／Allow、分頁範圍控制或既有 Gateway 配對的情境。

OpenClaw 官方支援 Chrome Extension、現有登入 Session、browser node 與遠端 Gateway 配對。實際命令和設定可能隨版本改變，導入時應以 [OpenClaw Browser 文件](https://docs.openclaw.ai/browser) 與 [Chrome Extension 文件](https://docs.openclaw.ai/tools/chrome-extension) 為準。

### 方案 C：VNC 像素控制（備援）

Agent 可以截取畫面、用視覺模型找座標，再送出滑鼠鍵盤事件。這適合瀏覽器權限視窗或沒有 DOM 的畫面，但不適合作為主要控制方式：

- 解析度或縮放會改變座標。
- 延遲會造成畫面與操作不同步。
- 無法穩定取得元素語意。
- 圖片 Token 與推論成本較高。

## 4. 建議的通用 Adapter 契約

自製 Agent 不應直接依賴 OpenClaw 專用命令。建議先定義一層 `BrowserProvider`，再為 OpenClaw、其他 Agent 或自製模型建立 Adapter。

最小能力：

```text
health()                 -> 安裝、版本、就緒狀態
capabilities()           -> 支援的操作及限制
tabs.list()              -> 分頁清單
tabs.open(url)           -> 開啟分頁
tabs.focus(tab_id)       -> 選擇分頁
tabs.close(tab_id)       -> 關閉分頁
page.snapshot(tab_id)    -> DOM／Accessibility Tree 與穩定 ref
page.screenshot(tab_id)  -> 畫面
page.navigate(tab_id,url)-> 導航
page.act(tab_id, action) -> click/type/press/scroll/select
downloads.list()         -> 下載狀態
session.pause()          -> 暫停 Agent，交給人類
session.resume()         -> 恢復 Agent
```

建議所有寫入操作都帶：

- `request_id`：去重與追蹤
- `session_id`：工作階段隔離
- `tab_id`：禁止錯誤分頁操作
- `expected_revision`：防止 Agent 使用過期 Snapshot
- `timeout_ms`：避免永久卡住
- `risk`：`read`、`write`、`external_effect`

## 5. 操作鎖與人工接管

人類與 Agent 同時操作同一個桌面會產生競爭，例如 Agent 準備點擊時，人類切換了分頁。

建議未來加入單一控制租約：

```text
owner=human | agent:<session_id>
lease_expires_at=<timestamp>
```

原則：

- 同一時間只有一個主要操作者。
- 人類可以隨時強制接管。
- Agent 超時或斷線後租約自動釋放。
- 頁面導航後舊 Snapshot ref 全部失效。
- 付款、寄信、刪除、發布及帳號安全操作需要人工確認。

## 6. OpenClaw 導入方式

### 同一台 Raspberry Pi

推薦讓 OpenClaw Gateway 或 browser node 與 Chromium 位於同一台 Pi。Adapter 可以只監聽 loopback，不需要開放新的內網控制埠。

流程：

1. OpenClaw 執行 `agent-webctl info`。
2. 確認 `READY=true`。
3. 確認 `AGENT_CONTROL_AVAILABLE=true`；目前版本會是 `false`。
4. 未來 Adapter 啟用後，OpenClaw 使用對應 Profile 或 CDP URL。
5. 人類透過 noVNC 觀看、登入或接管。

### OpenClaw 在另一台機器

不要把 CDP 直接開放到 LAN。優先順序：

1. Pi 上部署 OpenClaw browser-capable node。
2. 使用 OpenClaw 官方 Extension Relay 與 WSS 配對。
3. 使用短期 SSH tunnel。
4. 自製具 mTLS、短效 Token、來源限制與審計的 Relay。

### OpenClaw Managed Browser 與 Agent Web Profile

OpenClaw 可以自行啟動獨立瀏覽器 Profile，也可以附加既有 Chromium Session。若希望沿用 Agent Web 中手動登入的 Cookie，必須附加同一個正在運行的 Chromium，而不是另外啟動一個新 Profile。

不要同時讓兩個 Chromium 程序使用 `/var/lib/agent-web/profile`，否則可能造成 Profile lock 或資料庫損壞。

## 7. 自製 Agent 的導入流程

建議 Agent 啟動時執行：

```text
1. 探測 agent-webctl
2. 讀取 agent-webctl info
3. 驗證 INFO_VERSION 與 READY
4. 取得 Adapter capability
5. 申請操作租約
6. 取得 tabs 與 snapshot
7. 以 ref 操作，不依賴固定 CSS selector 或座標
8. 每次導航後重新取得 snapshot
9. 高風險動作要求人類批准
10. 完成後釋放租約並輸出審計紀錄
```

Agent 的 system prompt 可以加入：

```text
This host may provide Agent Web. Run `agent-webctl info` first.
Treat `AGENT_CONTROL_AVAILABLE=false` as a hard stop for automated control.
Use the Agent Web adapter for browser actions and noVNC only for human
observation or approved manual takeover. Never expose or request browser
profile files, cookies, passwords, TLS keys, or raw CDP credentials.
```

## 8. 安全與審計要求

正式 Agent Adapter 至少應提供：

- 預設 loopback 或 Unix socket
- 獨立於 noVNC 密碼的短效憑證
- URL 與私有網段 SSRF 政策
- 下載路徑限制
- 任意 JavaScript evaluate 開關
- 每個操作的時間、Agent、分頁與結果日誌
- 敏感欄位遮罩
- 最大分頁數、逾時與速率限制
- Prompt Injection 防護與高風險人工批准
- 緊急停止與人類接管

## 9. 建議版本路線

### v1：目前版本

- noVNC 人類操作
- Profile 持久化
- systemd 管理
- `agent-webctl info` 能力發現
- Agent 控制預設關閉

### v2：本機 Agent Adapter

- loopback／Unix socket
- CDP 附加既有 Chromium
- tabs、snapshot、act、screenshot
- 單一操作租約

### v3：安全遠端 Agent

- browser node 或 mTLS Relay
- 人工批准流程
- 審計日誌
- 網站與下載政策

這條路線保留現有安裝與 noVNC 使用方式，讓 Agent 能力以可選、可偵測、預設安全的方式逐步加入。
