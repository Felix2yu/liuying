# 流影 (LiuYing)

iPhone 快捷指令 → iCloud Drive → Mac 常驻 → 自动下载 B 站视频。
是旧版 Python `bili-watcher` 的 Swift 重写，多了一个菜单栏界面、图形化设置和视频库。

- 编码优先级 **av1 > hevc > avc**，画质按大会员权限取可得最高档
- 下载后按编码自动 remux：av1 → mkv、hevc → mov、avc → mp4；无损音轨装不进 mp4/mov 时退回 mkv
- 下载成功会把链接从 links.txt 里删掉（其余行逐字节保留）
- 除 iCloud 链接文件外，还支持手动粘贴、剪贴板监听、UP 主订阅追更

## 后端路由

不是「二选一」，也不是「失败后回退」，而是**按链接域名在入队时定死**：

| 链接 | 后端 | 默认 |
| --- | --- | --- |
| `b23.tv` / `bilibili.com` / `bilibili.tv` | yutto | yutto |
| 其它一切 http(s) 链接 | Downie | Downie |

两个方向都能在「设置 → Downie → 路由」里改。路由一旦确定，下载过程中不会换后端。
想看某个链接会怎么走：`liuyingctl route <url>`（只打印命令，不下载）。

> 注意：抓取面现在是**所有 http(s) 链接**。所以 links.txt 或剪贴板里混进任何网址，
> 都会被交给 Downie。剪贴板监听默认关闭，就是这个原因。

---

## 构建与安装

```bash
swift build && swift test          # 163 个单测
./build-app.sh                     # 产出 .build/release/流影.app
```

安装（`/Applications` 对 admin 组可写，**不需要 sudo**）：

```bash
pkill -f "/Applications/流影.app/Contents/MacOS/liuying"
rm -rf "/Applications/流影.app"
ditto "/Users/yufei/Git/liuying/.build/release/流影.app" "/Applications/流影.app"
open "/Applications/流影.app"
```

用 `ditto` 而不是 `cp -R`：它保留权限与扩展属性，是拷 app bundle 的标准做法。
**bundle 文件名必须保持 `流影.app`** —— TCC 授权按路径登记，换个名字就等于换了个 App，得重新授权。

`.app` 用 `Apple Development: yufei.im@gmail.com` 签名（脚本会自动选）。
**这一点很重要**：TCC 授权绑定代码签名，ad-hoc 签名每次重编都会变、授权就失效；
固定身份签名能让授权跨重编保留。

---

## 首次运行必须做的两件事

### 1. 授予文件访问权限

流影要读两个受 macOS 保护的位置：iCloud 里的 `links.txt`，以及下载目录 `~/Downloads/Bilibili`。
首次访问时系统可能弹窗询问；如果没弹（比如屏幕锁定、或用 `open` 后台启动），请求会在
syscall 层挂住，App 会在 30 秒后放弃并显示「访问被系统挂起」。

最省事的做法：**系统设置 → 隐私与安全性 → 完全磁盘访问权限**，把 `/Applications/流影.app` 加进去。
App 内「设置 → 通用 → iCloud 访问 → 打开系统设置」有直达按钮。

授权后重启 App。设置页的「iCloud 访问」应显示「可访问」。

> 如果 iCloud 实在授权不了，可以退一步：把 iPhone 快捷指令写的文件放到 iCloud 之外
> （例如 `~/Documents/Bili/links.txt`），在「设置 → 监听文件」里手动指定它。

### 2. 旧版 Python 服务已停用

旧版 `com.felix2yu.bili-watcher` 的 LaunchAgent 已被停用：
进程已终止，plist 移到了
`~/Library/Application Support/LiuYing/backups/launchagents/`，并且写进了 launchd 的 disabled 数据库。

需要恢复时：`liuyingctl legacy restore`（或设置页「恢复旧服务」）。

---

## 界面

菜单栏图标常驻，关掉窗口也继续轮询。

- **视频库**：扫下载目录，按 UP 主分组筛选；点一行就地展开缩略图与详情，可播放（mkv/AV1 可用 IINA）、访达中显示、复制路径、删除。
- **队列**：待处理 / 下载中 / 已完成 / 失败；展开当前任务能看实时 yutto 日志。
- **订阅**：填 UP 主 UID 自动追更。**首次同步只记录水位，不下载历史投稿**；要补看用「导入最近 5 条」。连续 3 次失败会自动停用（风控熔断）。
- **设置**：四个 tab，分别管路径与轮询、yutto 参数、Downie、以及高级项（SESSDATA、旧服务、一次性清理链接文件、日志目录）。

---

## 命令行

```bash
liuyingctl doctor                    # 环境自检（依赖解析、SQLite）
liuyingctl status                    # 任务库统计 + 最近记录
liuyingctl config show               # 当前配置
liuyingctl config set watch_file ""   # 改配置（重启 App 生效）
liuyingctl test <url> [额外 yutto 参数…]   # 直接下一单，绕过采集与去重
liuyingctl legacy status|retire|restore
liuyingctl bili smoke <BV>           # 实网检查：nav / view / arc-search
liuyingctl bili sign <mid>           # 打印 arc/search 的签名中间量
```

路径：`<app>/Contents/MacOS/liuyingctl`。

> iCloud 读写**只能在 .app 里**做。直接跑裸二进制时 TCC 归属终端，会 EPERM ——
> 这不是 bug，是 TCC 的责任进程规则。

---

## 数据位置

| 内容 | 路径 |
| --- | --- |
| 状态库 | `~/Library/Application Support/LiuYing/state.db` |
| 日志 | `~/Library/Logs/LiuYing/liuying.log`（1MB 轮转） |
| 缩略图缓存 | `~/Library/Application Support/LiuYing/thumbs/` |
| 备份 | `~/Library/Application Support/LiuYing/backups/` |
| 临时工作目录 | `~/Library/Application Support/LiuYing/work/task-<id>` |
| 配置 | `~/Library/Preferences/im.yufei.liuying.plist` |

---

## 已知限制

- **remux 之后 yutto 认不出已有文件**：我们把 yutto 产出的 `.mp4` remux 成 `.mkv`，
  下次同一个视频再入队时 yutto 看不到预期的 mp4，会重新下载一遍。
  正常的去重靠状态库的 BV 键，所以只有「手动 test」或换库后才会遇到。
- **多 P 命名**：yutto 的规则是 P1 无后缀、P2 起 `标题 (1).mkv`。库里会把后缀解析成页码，但页码从 1 开始对应 P2。
- **订阅追更依赖 SESSDATA**：`arc/search` 匿名访问会被 412 风控。程序从 yutto 的
  `~/.config/yutto/auth.toml` 读 `[profiles.default].sessdata`，并在被 ban 时换新签名重试最多 3 次。
- **Downie 不会自己开始下载**：`downie://` 只支持 `url` / `postprocessing` / `destination` /
  `action` / `title` 五个参数（Downie 自带帮助的 Automation 一节），**没有「立刻开始」这种参数**。
  必须先在 Downie 里打开 **设置 → 高级 → 自动化模式**，它才会抑制质量/字幕对话框直接下载。
  这个开关的作用是「抑制弹窗」而不是「自动排队」——所以还要配合「设置 → 通用 → 质量：分辨率上限」，
  否则每次仍会弹格式选择框。完整清单见设置页「Downie → 使用前必做」。
- **Downie 后端**是异步的：脚本侧只能确认「已入队」，无法知道下载是否完成。
  所以走 Downie 的任务会立刻显示「已完成」——实际进度要去 Downie 里看。
- **通知**需要用户授权；未授权时只在日志里写一条。

---

## 排错

| 现象 | 排查 |
| --- | --- |
| 设置里「iCloud 访问」显示挂起/拦截 | 给 `/Applications/流影.app` 加完全磁盘访问权限，重启 App |
| 提示「无法读取下载目录」 | 同上；或把下载目录换到不受 TCC 保护的位置 |
| 手机写了文件但没反应 | 看日志里「监听链接文件：」的真实路径；iCloud 同步本身有延迟 |
| 画质只有 360P/480P | 没登录。检查 auth.toml 是否存在、SESSDATA 是否过期 |
| 订阅一直失败 | `liuyingctl bili smoke <某个BV>` 确认网络与登录态 |
| 找不到 yutto | `liuyingctl doctor` 看解析结果；在设置里填绝对路径 |
