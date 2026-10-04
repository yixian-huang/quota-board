# Quota Board

macOS 菜单栏里的剩余额度。读取这台机器上已经登录的 Claude、Codex、Cursor 和 Grok，也读取 `sub2api`、`new-api` 和 CPA 上的 Codex 账号。每张卡显示最紧的窗口还剩多少、何时重置，以及下一次账单日。

额度接口是这些客户端自己在用的接口，字段并不稳定。读数失败时，卡片沿用上次成功的结果。

## 菜单栏和面板

菜单栏显示额度最快刷新的那个平台的官方图标，以及这一档还剩的百分比。没有未来的重置时间时，显示剩余最少的那一档。还没有任何读数时显示「读取中」；只有错误时显示「额度不可用」。

点开菜单栏是面板：

- 标题右侧是剩余百分比。「…」在名称旁边，用来设置账单日。Codex 卡还可以改名或移除。
- 账单日紧挨「账单日」两个字，例如「10月16日」。没有读数时显示「未设置」。
- 每个用量窗口单独一行。已经过去的重置显示「已重置」。只有一个窗口时，百分比只出现在标题上。
- 卡片默认按额度重置时间从近到远排。没有未来重置时间的卡排在后面。标题栏可以改成「按名称」。
- 面板里的刷新会立刻重读。平时每 5 分钟读一次。
- 底部的「退出」结束程序。程序没有程序坞图标。

卡片上的图标和菜单栏同一套，来自各家官网。Cursor 跟随系统的浅色或深色。面板标题上的标是 Quota Board 自己的。

## 环境

macOS 14，Swift 6。用系统自带的 Swift 命令行工具即可。

`swift run` 必须关掉沙箱，否则读不到家目录里的登录信息。编译出的程序本身没有 App Sandbox。

## 运行

```sh
swift run --disable-sandbox QuotaBoard --self-test
swift run --disable-sandbox QuotaBoard
```

自测只检查解析和排序，不打开菜单栏，也不访问网络。

终端里看一次读数：

```sh
swift run --disable-sandbox QuotaBoard --dump
```

要让程序留在菜单栏里，可以先编译再直接启动二进制：

```sh
swift build --disable-sandbox
"$(swift build --disable-sandbox --show-bin-path)/QuotaBoard"
```

## 登录从哪里来

- Claude：`~/.claude/.credentials.json`，以及钥匙串项 `Claude Code-credentials`。过期时用原来的 refresh token 换新登录，并在刷新成功后写回原处。
- Codex：`$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`。本机只读这一份登录。
- Cursor：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 里的 `cursorAuth/accessToken` 和 `cursorAuth/stripeMembershipType`。
- Grok：`$GROK_HOME/auth.json`，默认 `~/.grok/auth.json`。过期时打开一次 `grok`，让它自己刷新。

## 从网关读 Codex

配置放在 `~/.quota-board/upstreams.json`。样例是仓库里的 `upstreams.example.json`。环境变量 `QUOTA_BOARD_UPSTREAMS` 可以指向另一份文件。

```json
{
  "upstreams": [
    {
      "kind": "sub2api",
      "name": "sub2api",
      "baseURL": "https://your-sub2api.example",
      "keychainAccount": "sub2api"
    },
    {
      "kind": "new-api",
      "name": "new-api",
      "baseURL": "https://your-new-api.example",
      "userID": "1",
      "keychainAccount": "new-api"
    },
    {
      "kind": "cpa",
      "name": "cpa",
      "baseURL": "https://your-cpa.example",
      "keychainAccount": "cpa"
    }
  ]
}
```

`baseURL` 填站点根地址。`kind` 是 `sub2api`、`new-api` 或 `cpa`。`new-api` 必须写 `userID`。钥匙串服务名默认 `quota-board`，可以用 `keychainService` 换掉。

管理凭证放进钥匙串，不写进配置文件。下面的命令会提示输入密码：

```sh
security add-generic-password -U -s quota-board -a sub2api -w
security add-generic-password -U -s quota-board -a new-api -w
security add-generic-password -U -s quota-board -a cpa -w
```

sub2api 用管理员 JWT，new-api 用管理员访问令牌，CPA 用管理密钥。程序只请求账号列表和用量，不下载登录文件，不读取渠道密钥，也不消耗重置次数。

同一份订阅如果同时出现在本机和这些网关里，面板只留一张卡。合并用的是账号标识、用户标识或邮箱，这些值不会显示出来。邮箱样子的渠道名也不会拿来做标题。本机登录和 new-api 的读数优先于 sub2api，再其次是 CPA。

多张 Codex 卡时，标题用网关给出的名称。名称像邮箱、像一长串账号标识，或者就是「Codex」时，显示成「Codex」或「Codex 2」。只有一张卡时标题就是「Codex」。

Pro 200 没有 5 小时窗口。`sub2api` 仍可能返回这一档；计划是 Pro 200，或 `codex_5h_window_minutes` 小于等于 0 时，这一行不显示。其它计划在分钟数大于 0 时保留。分钟数没给出时，保留已有的 5 小时窗口。

## 账单日

额度重置时间写在每个窗口上，用来决定菜单栏显示谁，以及卡片的默认排序。账单日是订阅周期的日期，单独写在卡片上。

自动读数：

- Cursor 用 `billingCycleEnd`。
- Grok 用 `billingPeriodEnd`。每周额度何时重置，仍然写在窗口那一行。
- Codex 用本机登录令牌里的订阅周期结束时间，或 sub2api 的 `subscription_expires_at`，或 CPA 令牌里的 `chatgpt_subscription_active_until`。
- Claude 的用量接口没有账单日。

没有自动读数时，从卡片菜单里设置。已经读到的也可以改。手动日期优先；清除后恢复自动读数。已经过去的日期按每月同一天推到下一次，短月用当月最后一天。

日期记在 `~/.quota-board/billing.json`。键是账号的稳定标识，值是 `yyyy-MM-dd`：

```json
{
  "claude": "2026-11-01",
  "acct:acct-a": "2026-10-16"
}
```

本机 Claude、Cursor、Grok 用卡片标识。合并后的 Codex 用 `acct:`、`user:` 或 `mail:` 开头的标识。没有这些标识时，键以 `row:` 开头。

## 名称、隐藏和排序

Codex 卡片可以改名或移除，入口在名称旁边的菜单里。名称最长 32 个字符。改过的名称会用在卡片和菜单栏上；清除后回到网关原来的名称。

移除的账号不再出现在菜单栏和面板里。刷新不会把它带回来。面板底部的「已隐藏」可以恢复。

这些选择记在 `~/.quota-board/accounts.json`：

```json
{
  "hidden": ["acct:old"],
  "names": {
    "acct:work": "公司号"
  },
  "sort": "expiry"
}
```

`sort` 取 `expiry` 或 `name`。缺省或无法识别时按到期排。`expiry` 按最近的额度重置时间从近到远。`name` 按当前显示名称排序。

Claude、Cursor 和 Grok 的卡片菜单里只有账单日。
