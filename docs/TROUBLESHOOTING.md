# Agent Web 故障排查

先執行以下三個指令：

```bash
agent-webctl info
agent-webctl status
sudo ss -ltnp | grep -E ':(5901|6080|6901)\b'
```

正常狀態應包含：

```text
READY=true
BROWSER_SERVICE=active
NOVNC_SERVICE=active
WEB_SERVICE=active
HTTPS_AUTH_CHECK=401
```

監聽位置應為：

```text
127.0.0.1:5901
127.0.0.1:6080
0.0.0.0:6901
```

## 瀏覽器顯示 400 Bad Request

如果頁面顯示：

```text
The plain HTTP request was sent to HTTPS port
```

代表使用了：

```text
http://192.168.x.x:6901
```

請完整輸入：

```text
https://192.168.x.x:6901/
```

## curl 回傳 302

根路徑 `/` 會正常重新導向 noVNC：

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:6901/
```

`302` 表示 Nginx HTTPS 已運作。驗證保護應檢查實際頁面：

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
  https://127.0.0.1:6901/vnc.html
```

未提供帳密時預期為 `401`。

## curl 回傳 401

這是正常結果，表示密碼驗證正在保護 noVNC。一般瀏覽器會顯示帳號密碼提示。

## curl 回傳 000 或 Connection refused

先確認服務：

```bash
sudo systemctl status agent-web.target --no-pager -l
sudo systemctl status agent-web-web.service --no-pager -l
sudo ss -ltnp | grep 6901
```

重新啟動：

```bash
agent-webctl restart
```

若仍失敗，查看日誌：

```bash
sudo journalctl \
  -u agent-web-browser.service \
  -u agent-web-novnc.service \
  -u agent-web-web.service \
  -n 200 --no-pager
```

## 忘記網頁密碼

密碼使用 bcrypt 雜湊保存，無法讀回原密碼。請直接重設：

```bash
agent-webctl set-password
```

## 自簽憑證警告

私人自簽憑證不會被作業系統預設信任，因此第一次連線出現警告是預期行為。

確認 IP 是自己的伺服器後才能繼續。若 IP 或主機名稱改變，可重新產生憑證：

```bash
agent-webctl renew-certificate
```

## noVNC 頁面出現但無法連線

檢查三層後端：

```bash
sudo systemctl is-active agent-web-browser.service
sudo systemctl is-active agent-web-novnc.service
sudo systemctl is-active agent-web-web.service
sudo ss -ltnp | grep -E ':(5901|6080|6901)\b'
```

如果 `5901` 不存在，問題在 TigerVNC／Chromium 服務；如果只有 `6080` 不存在，問題在 websockify；如果只有 `6901` 不存在，問題在 Nginx。

## 只有黑畫面

查看瀏覽器服務：

```bash
sudo systemctl status agent-web-browser.service --no-pager -l
sudo journalctl -u agent-web-browser.service -n 200 --no-pager
```

常見原因包括：

- Chromium 尚在第一次啟動。
- 記憶體不足，被 OOM Killer 終止。
- Profile lock 未清理。
- Chromium 或 X11 套件升級後需要重新啟動。

嘗試：

```bash
agent-webctl restart
free -h
df -h /
```

## 服務持續 restarting

先看具體退出原因，不要只重複執行安裝器：

```bash
sudo systemctl status agent-web-web.service --no-pager -l
sudo journalctl -u agent-web-web.service -n 100 --no-pager
```

檢查 Nginx 設定：

```bash
sudo install -d -o agent-web-web -g agent-web-web -m 0700 /run/agent-web-web
sudo nginx -t -c /etc/agent-web/nginx.conf
```

## Chromium 顯示 GCM DEPRECATED_ENDPOINT

類似以下訊息通常只是 Chromium 背景服務註冊警告：

```text
Registration response error message: DEPRECATED_ENDPOINT
```

若網頁能正常開啟與操作，可以忽略；它不代表 noVNC 或 HTTPS 故障。

## 更新失敗

```bash
cd ~/.local/share/agent-web/source
git status
git remote -v
git pull --ff-only
./validate.sh
./install.sh --update
```

如果 Git 顯示本機修改，`agent-webctl update` 不會強制覆蓋。請先備份並提交、還原或另外處理修改。

## 磁碟空間不足

```bash
df -h /
sudo du -sh \
  /var/lib/agent-web/profile \
  /var/lib/agent-web/downloads \
  /var/cache/agent-web
```

停止服務後可清理可重建的 Chromium 快取；不要在 Chromium 運行時任意刪除 Profile 資料庫。

## 收集問題資訊

回報 Issue 前請提供下列輸出，但不要提供 `/etc/agent-web/htpasswd`、TLS 私鑰、Cookie 或整個 Profile：

```bash
cat /proc/device-tree/model; echo
uname -a
cat /etc/os-release
agent-webctl info
sudo systemctl status agent-web.target --no-pager -l
sudo journalctl \
  -u agent-web-browser.service \
  -u agent-web-novnc.service \
  -u agent-web-web.service \
  -n 200 --no-pager
sudo ss -ltnp | grep -E ':(5901|6080|6901)\b'
```
