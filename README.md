# Quota Board

[English](README.en.md)

macOS 菜单栏里的剩余额度。读取这台机器上已经登录的 Claude、Codex、Cursor 和 Grok，也读取 `sub2api`、`new-api` 和 CPA 上的 Codex 账号。点开后是一块深色屏：每张卡显示最紧的窗口还剩多少、何时重置，以及下一次账单日。

额度接口是这些客户端自己在用的接口，字段并不稳定。读数失败时，卡片沿用上次成功的结果。

## 运行

macOS 14，Swift 6。`swift run` 必须关掉沙箱，否则读不到家目录里的登录信息。编译出的程序本身没有 App Sandbox。

```sh
swift run --disable-sandbox QuotaBoard --self-test
swift run --disable-sandbox QuotaBoard --dump
swift build --disable-sandbox
"$(swift build --disable-sandbox --show-bin-path)/QuotaBoard"
```

面板用了 SwiftUI。只装 Command Line Tools 时，编译会报找不到 `SwiftUIMacros`。把开发者目录指到 Xcode 再执行上面的命令：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
```

`--self-test` 检查解析、排序、电平、剩余价值和重置预告文档，不打开菜单栏，也不访问网络。`--dump` 在终端打一次读数。最后一条命令让程序留在菜单栏里。

菜单栏仍显示最快到期的那一档和剩余百分比，并跟随系统外观。点开是一块暖色底板上的深色屏。电平按剩余点亮，满条表示还没用；已用到 70% 转黄，90% 转红。平时每 5 分钟读一次额度，面板里的刷新立刻重读。程序没有程序坞图标。

屏上有两个页。「剩余额度」可以在列表和图表之间换。列表是账号卡：名称、电平、备注，账单日在最后。同一时刻重置的窗口共用一条倒计时。图表把各账号排成电平桥，下面是对数刻度的重置时间轴；没有未来的重置时间时不画时间轴。「重置预告」目前是占位，不读取汇总服务。面板外观可以跟随系统、固定浅色或固定深色，只改这块面板。

## 本机登录

- Claude：`~/.claude/.credentials.json`，以及钥匙串项 `Claude Code-credentials`。过期时用原来的 refresh token 换新登录，并在刷新成功后写回原处。
- Codex：`$CODEX_HOME/auth.json`，默认 `~/.codex/auth.json`。本机只读这一份登录。
- Cursor：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 里的 `cursorAuth/accessToken` 和 `cursorAuth/stripeMembershipType`。
- Grok：`$GROK_HOME/auth.json`，默认 `~/.grok/auth.json`。过期时打开一次 `grok`，让它自己刷新。

## 网关

配置放在 `~/.quota-board/upstreams.json`。样例是仓库里的 `upstreams.example.json`。环境变量 `QUOTA_BOARD_UPSTREAMS` 可以指向另一份文件。

`baseURL` 填站点根地址。`kind` 是 `sub2api`、`new-api` 或 `cpa`。`new-api` 必须写 `userID`。钥匙串服务名默认 `quota-board`，可以用 `keychainService` 换掉。

管理凭证放进钥匙串，不写进配置文件。下面的命令会提示输入密码：

```sh
security add-generic-password -U -s quota-board -a sub2api -w
security add-generic-password -U -s quota-board -a new-api -w
security add-generic-password -U -s quota-board -a cpa -w
```

sub2api 用管理员 API Key，放在请求头 `x-api-key`。钥匙串里如果仍是管理员 JWT，则放进 `Authorization: Bearer`。两种凭证只发其中一种。new-api 用管理员访问令牌，CPA 用管理密钥。程序只请求账号列表和用量。

同一份订阅如果同时出现在本机和这些网关里，面板只留一张卡。本机登录和 new-api 的读数优先于 sub2api，再其次是 CPA。

## 本机设置

账单日和 Codex 卡片的名称、隐藏、排序都在 `~/.quota-board/`。

`billing.json` 的键是账号标识，值是 `yyyy-MM-dd`。能自动读到的账单日：Cursor 用 `billingCycleEnd`，Grok 用 `billingPeriodEnd`，Codex 用订阅周期结束时间。Claude 没有。卡片菜单可以改；手动日期优先，清除后恢复自动读数。

`accounts.json` 记录 Codex 的 `hidden`、`names` 和 `sort`。`sort` 取 `expiry` 或 `name`，缺省按到期排。名称最长 32 个字符。移除的账号刷新后也不会回来，在列表底部的「已隐藏」里恢复。图表里只提示已隐藏的数量。Claude、Cursor 和 Grok 的卡片菜单里只有账单日。

剩余价值用内置的美元月费。价格取各家 2026-10-29 前后公开的按月标价，不含税，也不用年付折扣。对得上套餐才显示；一张能算的卡都没有时，屏顶合计也不出现。价值是月费乘以最紧一档的剩余比例，显示时取整到元。

| 平台 | 套餐 | 每月 |
| --- | --- | --- |
| Claude | Pro / Max 5x / Max 20x | $20 / $100 / $200 |
| Codex | Go / Plus / Pro 100 / Pro 200 / Pro 500 | $8 / $20 / $100 / $200 / $500 |
| Cursor、Grok | Plus / Premium / Super / Ultra | $8 / $30 / $100 / $200 |
| Cursor 旧套餐 | Pro / Pro+ | $20 / $60 |
| Grok 旧套餐 | SuperGrok | $30 |

只写着 Max 的 Claude 卡不算，因为 Max 5x 和 Max 20x 价格不同。Team、Enterprise 和按席位分档的团队套餐也没有单一月费，同样不显示。Free 按 $0。

`fees.json` 可以改掉内置价格。样例是 `fees.example.json`，把本机 Claude 标成 Max 20x 的 $200。`accounts` 的键和 `billing.json` 一样，优先于套餐价。`plans` 的键是套餐名：去掉首尾空白、转成小写、空格换成 `-`、`+` 换成 `-plus`。这里的套餐价不区分平台。数字表示美元。对象写成 `{"amount": 200, "currency": "USD"}`。

重置预告这一页先占着，面板不会请求汇总服务。Quota Board 不直接读取 x.com。

## 发布

推送 `v*` 标签后，GitHub Actions 会编译 macOS 通用二进制，并发布到 [Releases](https://github.com/yixian-huang/quota-board/releases)。

压缩包里是 `QuotaBoard` 和旁边的 `QuotaBoard_QuotaBoard.bundle`。两者要留在同一目录。从浏览器下载时，macOS 可能拦住这个程序。在同一目录执行 `xattr -d com.apple.quarantine QuotaBoard` 后再打开。

## 许可证

[MIT](LICENSE)
