# Agent Web

在沒有桌面環境的 Raspberry Pi 5 上，提供一個 24 小時常駐、可從內網瀏覽器操作的完整 Chromium。

Agent Web 使用 Rootless Podman 隔離 Chromium、VNC、noVNC 與 Nginx。關閉本機網頁不會關閉 Pi 上的 Chromium；Cookie、網站登入狀態、歷史記錄與下載會持久保存。重新啟動 Pi 後，服務也會自動啟動，但不強制恢復上次開啟的分頁。

## 支援環境

- Raspberry Pi 5 Model B
- ARM64（`aarch64` / Debian `arm64`）
- Debian 13 Trixie / Raspberry Pi OS 對應版本
- 建議 8 GB RAM、至少 10 GB 可用空間
- 一般使用者必須能使用 `sudo`

## 一條指令安裝

以一般使用者登入 Pi，不要先切換成 root：

~~~bash
curl -fsSL https://raw.githubusercontent.com/Jay-Huang-0130/Agent-Web/main/bootstrap.sh | bash
~~~

安裝過程會：

1. 安裝 Podman 與 rootless 容器所需套件。
2. 詢問網頁登入帳號和密碼（密碼至少 12 個字元）。
3. 建立 Chromium 容器映像。
4. 建立並啟用 systemd 使用者服務。
5. 顯示可從內網開啟的網址，例如 `https://192.168.1.50:6901/`。

第一次開啟時，瀏覽器會警告憑證不是公開 CA 簽發。這是因為專案會在 Pi 上產生私人自簽 TLS 憑證；確認網址是你的 Pi 後即可繼續。

也可以先檢查程式碼再安裝：

~~~bash
git clone https://github.com/Jay-Huang-0130/Agent-Web.git
cd Agent-Web
./validate.sh
./install.sh
~~~

## 日常管理

~~~bash
agent-webctl status
agent-webctl logs
agent-webctl restart
agent-webctl stop
agent-webctl start
agent-webctl set-password
agent-webctl renew-certificate
agent-webctl update
agent-webctl url
~~~

關閉電腦上的 noVNC 分頁不會停止服務。`stop` 或重新啟動容器也不會刪除 Chromium 使用者資料。

## 資料位置

所有持久資料都屬於安裝時的 Linux 使用者：

~~~text
~/.local/share/agent-web/
├── data/
│   ├── profile/      Chromium Cookie、登入狀態、歷史與設定
│   ├── downloads/    下載檔案
│   └── state/        bcrypt 網頁驗證資料與私人 TLS 憑證
└── source/           Git 倉庫（用一條指令安裝時）
~~~

容器本身可以刪除和重建；上述目錄會獨立保留。初始明文密碼只會短暫寫入權限為 `0600` 的檔案，容器啟動後會轉為 bcrypt 驗證資料並刪除明文檔案。

## 隔離方式

- Chromium 以容器內非 root 使用者執行。
- Podman 本身以 Linux 一般使用者執行，沒有 root daemon。
- 容器移除所有 Linux capabilities，並限制程序數、CPU、RAM、共享記憶體與暫存空間。
- VNC 僅在容器內的 `127.0.0.1` 監聽；外部只開放 HTTPS noVNC 的 TCP 6901。
- 不使用 Chromium 的 `--no-sandbox`。
- 主機僅掛載 Agent Web 自己的 profile、downloads 與 state 目錄。

這可以大幅降低對主機環境的影響，但容器不是虛擬機，也不是面對惡意網站時的絕對安全邊界。此專案定位為可信任內網中的私人服務；請勿在路由器上做連接埠轉發。

## 更新與移除

更新到 GitHub 最新版本：

~~~bash
agent-webctl update
~~~

移除服務但保留 Cookie、登入狀態、下載與原始碼：

~~~bash
cd ~/.local/share/agent-web/source
./uninstall.sh
~~~

永久刪除所有 Agent Web 資料：

~~~bash
cd ~/.local/share/agent-web/source
./uninstall.sh --purge-data
~~~

永久刪除需要在終端機輸入完整確認文字。Podman 套件與使用者 linger 設定不會自動移除，以免影響主機上的其他容器。

## 驗證與限制

~~~bash
./validate.sh
~~~

驗證器會檢查 Bash 語法、JSON、LF 換行、systemd 樣板與主要隔離設定。實際容器映像仍應在 Raspberry Pi 上建置驗證，因為 Chromium 套件與執行環境是 ARM64 Debian。

目前固定使用 TCP `6901`，一次只設計給一位私人使用者。網站是否保留登入仍取決於網站本身的 Cookie、裝置信任、登入逾時與多重要素驗證政策。
