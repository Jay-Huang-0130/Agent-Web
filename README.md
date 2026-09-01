# Agent Web

在沒有桌面環境的 Raspberry Pi 5 上，提供一個 24 小時常駐、可從內網瀏覽器操作的完整 Chromium。

Agent Web 直接使用 Debian 套件與 systemd，不使用 Docker 或 Podman 容器。關閉本機 noVNC 頁面不會關閉 Pi 上的 Chromium；Cookie、網站登入狀態、歷史記錄、設定與下載都會持久保存。Pi 重新開機後服務會自動啟動，但不強制恢復上次分頁。

## 支援環境

- Raspberry Pi 5 Model B
- ARM64（`aarch64` / Debian `arm64`）
- Debian 13 Trixie
- 建議 8 GB RAM
- 一般使用者必須能使用 `sudo`
- 定位為可信任內網中的私人單使用者服務

## 一條指令安裝

以一般使用者登入 Pi，不要先切換成 root：

~~~bash
curl -fsSL https://raw.githubusercontent.com/Jay-Huang-0130/Agent-Web/main/bootstrap.sh | bash
~~~

安裝器會：

1. 安裝 Chromium、TigerVNC、noVNC、Openbox 與 Nginx。
2. 建立 `agent-web` 與 `agent-web-web` 無登入系統帳號。
3. 詢問網頁登入帳號和至少 4 字元的密碼。
4. 產生私人自簽 TLS 憑證。
5. 建立並啟用 systemd 系統服務。
6. 顯示網址，例如 `https://192.168.1.50:6901/`。

第一次開啟會看到憑證警告。確認網址是自己的 Pi 後即可繼續，再輸入安裝時設定的帳號密碼。

系統允許 4 字元以上的密碼，方便私人內網快速使用；4 字元密碼很容易被猜中，若內網還有其他裝置或使用者，仍建議使用 12 字元以上的密碼。

也可以先檢查程式碼：

~~~bash
git clone https://github.com/Jay-Huang-0130/Agent-Web.git
cd Agent-Web
./validate.sh
./install.sh
~~~

供上層安裝器或 Agent 平台進行無人值守部署時，請使用只允許目前使用者讀取的密碼檔，不要把明文密碼放在命令列：

~~~bash
./install.sh \
  --non-interactive \
  --username browser \
  --password-file /secure/path/agent-web-password
~~~

`--password-file` 的內容必須至少 4 個字元。Agent-OS 等上層系統可以用這個介面安裝 Agent Web，再以 `agent-webctl info` 驗證服務。

## 從舊容器版切換

新版安裝器會自動：

- 停止並移除舊的 Agent Web Podman 容器與映像。
- 移除舊的 systemd 使用者服務。
- 將舊 profile 與 downloads 複製到原生資料目錄（僅在新目錄仍為空時）。
- 沿用既有 bcrypt 網頁驗證資料與 TLS 憑證。
- 保留 Podman Debian 套件，避免影響主機上的其他容器用途。

第一次切換仍要在主機下載一次 Chromium；容器裡的 Debian 套件不能直接當作主機套件使用。完成後不再建置或啟動容器。

## 服務架構

~~~text
內網瀏覽器
    │ HTTPS + Basic Auth（TCP 6901）
    ▼
agent-web-web（專用 Nginx 使用者）
    │ localhost:6080
    ▼
noVNC / websockify（agent-web 使用者）
    │ localhost:5901
    ▼
TigerVNC + Openbox + Chromium（agent-web 使用者）
~~~

VNC 與 noVNC 後端只監聽 `127.0.0.1`。只有 HTTPS 入口監聽內網介面。

## 隔離方式

取消容器後仍保留：

- Chromium 不使用你的 `pi` 帳號，而是無登入的 `agent-web` 系統帳號。
- HTTPS proxy 使用另一個 `agent-web-web` 帳號；Chromium不能直接讀取 TLS 私鑰或密碼雜湊。
- systemd 限制可寫目錄、程序數、記憶體、CPU、裝置與核心設定。
- Chromium 自己的 sandbox 保持啟用，不使用 `--no-sandbox`。
- VNC 不直接暴露到內網。

這比直接用 `pi` 執行 Chromium 安全，但 Linux 使用者隔離仍弱於容器或虛擬機。請勿做路由器連接埠轉發，也不要把服務公開到 Internet。

## 日常管理

~~~bash
agent-webctl status
agent-webctl info
agent-webctl logs
agent-webctl restart
agent-webctl stop
agent-webctl start
agent-webctl set-password
agent-webctl renew-certificate
agent-webctl update
agent-webctl url
~~~

管理 systemd 或更換憑證時會要求 `sudo` 密碼。

## 資料位置

~~~text
/var/lib/agent-web/
├── profile/       Chromium Cookie、登入狀態、歷史與設定
└── downloads/     下載檔案

/var/cache/agent-web/    Chromium 與 Nginx 暫存資料
/etc/agent-web/          網頁驗證、TLS 憑證與服務設定
~~~

網站是否保持登入仍取決於網站本身的 Cookie、登入逾時、裝置信任與多重要素驗證政策。

## 更新與移除

更新：

~~~bash
agent-webctl update
~~~

移除服務但保留瀏覽器資料及登入設定：

~~~bash
cd ~/.local/share/agent-web/source
./uninstall.sh
~~~

永久刪除 Agent Web 原生資料：

~~~bash
cd ~/.local/share/agent-web/source
./uninstall.sh --purge-data
~~~

永久刪除需要輸入完整確認文字。Debian 套件不會自動移除，以免影響主機上的其他軟體。

## 驗證

~~~bash
./validate.sh
~~~

驗證器會檢查 Bash、JSON、LF 換行、systemd 帳號、loopback VNC/noVNC、HTTPS 驗證及 Chromium sandbox 設定。

## Agent 整合定位

Agent Web 目前是「持續運行的瀏覽器 + 人類可操作的 noVNC 介面」，不會預設開放高權限 CDP 或自動化 API。外部程式可以先執行：

~~~bash
agent-webctl info
~~~

這會輸出不含密碼、Cookie、Token 或私鑰的 `KEY=VALUE` 能力資訊，包括服務是否正常、人類操作網址，以及 Agent 控制介面是否可用。現在會如實回報：

~~~text
AGENT_CONTROL_AVAILABLE=false
AGENT_CONTROL_PROTOCOL=none
OPENAI_OAUTH_BROWSER_AVAILABLE=true
OPENAI_OAUTH_BROWSER_PROTOCOL=agent-web-openai-oauth-v1
OPENAI_OAUTH_BROWSER_SOCKET=/run/agent-web-oauth/open.sock
~~~

OAuth bridge 是特別為遠端／無螢幕 ChatGPT 登入提供的窄介面。Socket 只允許安裝 Agent Web 的登入使用者連線，且只接受 `auth.openai.com` 或 `chatgpt.com` 的 HTTPS URL；它不是通用瀏覽器控制 API。未來建議使用雙通道架構：人類透過 HTTPS/noVNC 觀看與接管；Agent 透過只允許本機存取的 Adapter、CDP 或 Chrome Extension Relay 精確操作同一個 Chromium。禁止直接把原始 CDP 連接埠暴露到內網或 Internet。

## 完整文件

- [使用者操作手冊](docs/USER-GUIDE.md)：安裝、登入、管理、更新、備份與移除。
- [系統架構](docs/ARCHITECTURE.md)：元件、服務、資料流、隔離與安全邊界。
- [Agent 整合指南](docs/AGENT-INTEGRATION.md)：能力發現、通用 Adapter、OpenClaw、自製 Agent 與版本路線。
- [故障排查](docs/TROUBLESHOOTING.md)：`400`、`401`、`302`、服務失敗及日誌判讀。
