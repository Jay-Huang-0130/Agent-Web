# Agent Web 使用者操作手冊

這份手冊說明如何在支援的 Raspberry Pi／Debian 主機安裝、使用、管理、更新及移除 Agent Web。

## 1. 使用前確認

目前正式支援：

- Raspberry Pi 5 Model B
- Debian 13 Trixie ARM64
- 建議至少 4 GB RAM
- 約 3 GB 以上可用磁碟空間
- 可以連上 Debian 套件來源與 GitHub
- 一般登入帳號可以使用 `sudo`
- 使用者電腦與伺服器位於同一個可信任內網

在伺服器上確認環境：

```bash
cat /proc/device-tree/model
uname -m
cat /etc/os-release
free -h
df -h /
```

安裝器必須以一般使用者執行，不要先執行 `sudo -i` 或切換成 root。

## 2. 一條指令安裝

```bash
curl -fsSL https://raw.githubusercontent.com/Jay-Huang-0130/Agent-Web/main/bootstrap.sh | bash
```

第一次執行時，安裝器會：

1. 安裝 Git（如果尚未安裝）。
2. 把專案下載到 `~/.local/share/agent-web/source`。
3. 安裝 Chromium、TigerVNC、noVNC、Openbox、Nginx 等 Debian 套件。
4. 建立 `agent-web` 與 `agent-web-web` 專用系統帳號。
5. 詢問網頁登入名稱與至少 12 字元的密碼。
6. 產生私人自簽 TLS 憑證。
7. 安裝並啟動 systemd 服務。
8. 等待 HTTPS、驗證頁面及後端服務就緒。

下載 Chromium 的第一次安裝可能需要一段時間。終端仍持續出現 `Get:` 或 `Setting up`，就代表仍在工作，不要中斷電源。

重複執行同一條安裝指令是安全的。已安裝套件不會重新下載，既有 Profile、登入狀態與密碼預設也會保留。

## 3. 開啟遠端 Chromium

安裝完成後執行：

```bash
agent-webctl url
```

輸出會類似：

```text
https://192.168.31.75:6901/
```

在同一個內網的電腦上，把完整網址貼到 Chrome、Edge 或 Firefox。必須保留 `https://`。

第一次連線流程：

1. 瀏覽器顯示自簽憑證警告。
2. 確認網址是自己的 Raspberry Pi IP。
3. 選擇「進階」並繼續前往。
4. 輸入安裝時設定的網頁帳號與密碼。
5. noVNC 載入後會顯示伺服器上的 Chromium。

關閉本機頁面只會中斷觀看連線，不會關閉 Raspberry Pi 上的 Chromium。再次開啟相同網址即可重新連線。

## 4. HTTP 狀態碼怎麼看

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
  https://127.0.0.1:6901/vnc.html
```

- `401`：正常。HTTPS 已運作，而且密碼驗證正在保護頁面。
- `302`：根網址正常導向 `/vnc.html`。
- `200`：提供正確帳密後，頁面成功載入。
- `000`：無法連線，通常是服務未啟動或連接埠未監聽。
- `400 The plain HTTP request was sent to HTTPS port`：使用了 `http://`，請改成 `https://`。

## 5. 日常管理指令

### 狀態與能力

```bash
agent-webctl status
agent-webctl info
agent-webctl url
```

`status` 適合人閱讀；`info` 是不包含秘密的穩定 `KEY=VALUE` 輸出，適合腳本或 Agent 判斷安裝與健康狀態。

### 啟動與停止

```bash
agent-webctl start
agent-webctl stop
agent-webctl restart
```

停止服務不會刪除 Cookie、Profile 或下載。

### 查看日誌

```bash
agent-webctl logs
```

按 `Ctrl+C` 離開即時日誌。查看最近 200 行：

```bash
sudo journalctl \
  -u agent-web-browser.service \
  -u agent-web-novnc.service \
  -u agent-web-web.service \
  -n 200 --no-pager
```

### 更換密碼

```bash
agent-webctl set-password
```

密碼必須至少 12 個字元。修改完成後 HTTPS 服務會重新啟動，Chromium 不會因此清除登入狀態。

### 更新憑證及程式

```bash
agent-webctl renew-certificate
agent-webctl update
```

更新只接受 Git fast-forward，不會強制覆蓋本機原始碼修改。

## 6. 資料位置

```text
/var/lib/agent-web/profile       Chromium Profile、Cookie、Session、歷史與設定
/var/lib/agent-web/downloads     瀏覽器下載
/var/cache/agent-web/chromium    Chromium 快取
/var/cache/agent-web/nginx       Nginx 暫存
/etc/agent-web                   驗證、TLS、顯示與控制器設定
```

Profile 與 `/etc/agent-web` 都可能包含敏感資訊。不要提交到 GitHub，也不要用未加密方式分享。

## 7. 備份

備份前先停止服務，避免複製到正在寫入的 Chromium 資料庫：

```bash
agent-webctl stop
sudo tar -C / -czf "$HOME/agent-web-backup.tar.gz" \
  var/lib/agent-web \
  etc/agent-web
agent-webctl start
```

備份包含網站 Session 與驗證資料，應放在加密且受保護的位置。還原會覆蓋目前資料，操作前應先另外備份現況。

## 8. Debian 與 Chromium 更新

Agent Web 專案更新不等於 Debian 安全更新。定期執行：

```bash
sudo apt update
sudo apt upgrade
sudo systemctl restart agent-web.target
```

系統升級前建議先備份 Profile。

## 9. 解除安裝

只移除服務並保留資料：

```bash
cd ~/.local/share/agent-web/source
./uninstall.sh
```

永久刪除 Agent Web 資料：

```bash
cd ~/.local/share/agent-web/source
./uninstall.sh --purge-data
```

永久刪除需要在互動終端輸入 `DELETE AGENT WEB`。Debian 套件不會自動移除，以免影響主機上其他程式。

## 10. 下一步

- 元件與權限：[系統架構](ARCHITECTURE.md)
- OpenClaw 或自製 Agent：[Agent 整合指南](AGENT-INTEGRATION.md)
- 連線與服務問題：[故障排查](TROUBLESHOOTING.md)
