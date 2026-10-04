# Quota Board

macOS 菜单栏里的剩余额度。读取这台机器上已经登录的 Claude、Codex、Cursor 和 Grok，显示各自最紧的窗口还剩多少、何时重置。

额度接口是这些客户端自己在用的接口，不是公开稳定 API。字段变了，读数会失败并停在上次成功的结果上。

## 运行

```sh
swift run --disable-sandbox QuotaBoard --self-test
swift run --disable-sandbox QuotaBoard
```

需要关掉沙箱，否则读不到家目录里的登录信息。菜单栏出现剩余百分比。点开可以看到每个窗口。面板里的刷新会立刻重读，平时每 5 分钟读一次。

每张卡有一行账单日。Cursor 用 `billingCycleEnd`，Grok 用 `billingPeriodEnd`（和每周额度重置分开），Codex 用登录令牌或 sub2api、CPA 里已有的订阅周期结束时间。Claude 的用量接口没有账单日。没有自动读数时可以设置；已经读到的也可以改。日期记在 `~/.quota-board/billing.json`。已经过去的日期按每月同一天推到下一次，短月用当月最后一天。手动日期优先，清除后恢复自动读数。

终端里看一次读数，不打开菜单栏：

```sh
swift run --disable-sandbox QuotaBoard --dump
```

## 登录从哪里来

- Claude：`~/.claude/.credentials.json`，以及钥匙串项 `Claude Code-credentials`。过期时用原来的 refresh token 换新登录，并写回原处。
- Codex：`$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`。
- Cursor：Cursor 本地状态库里的访问令牌，只读两个字段。
- Grok：`$GROK_HOME/auth.json`，默认 `~/.grok/auth.json`。不替 Grok 轮换令牌；过期时打开一次 `grok`，让它自己刷新。

## 从网关读 Codex

同一份订阅如果同时出现在本机、`sub2api`、`new-api` 和 CPA，菜单栏只留一张卡。去重用的是账号标识、用户标识或邮箱，这些值不会显示出来。邮箱样子的渠道名也不会拿来做标题。不按重置时间或每周用量百分比合并。

Pro 200 没有 5 小时窗口。`sub2api` 仍可能返回这一档；计划是 Pro 200，或列表里的 `codex_5h_window_minutes` 小于等于 0 时，这一行不显示。其它计划在分钟数大于 0 时保留。分钟数没给出时不凭这条规定丢掉。

配置放在 `~/.quota-board/upstreams.json`，样例是仓库里的 `upstreams.example.json`。管理凭证放进钥匙串，不写进这个文件：

```sh
security add-generic-password -U -s quota-board -a sub2api -w
security add-generic-password -U -s quota-board -a new-api -w
security add-generic-password -U -s quota-board -a cpa -w
```

`baseURL` 填站点根地址。sub2api 用管理员 JWT，new-api 用管理员访问令牌并在配置里写 `userID`，CPA 用管理密钥。程序只请求账号列表和用量，不下载登录文件，不读取渠道密钥，也不消耗重置次数。

令牌只用来向对应的用量接口发请求，不上传到别的地方。
