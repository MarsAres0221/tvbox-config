# live/

影视仓的直播源播放列表（TVBox live.txt 格式），由 `live-sources.ps1` 生成。

| 文件 | 频道数 |
|---|---|
| cctv.txt | 17（CCTV1–17） |
| weishi.txt | 36（各卫视） |
| zhejiang.txt | 8（浙江卫视 / 4K / 钱江都市 / 经济生活 / 民生休闲 / 教科影视 / 公共新闻 / 少儿） |

这些文件不通过 config.json 的 lives 加载，而是在 App 内 **设置 → 直播地址 → 添加直播源** 里直接登记：

| 源名 | 地址 |
|---|---|
| 央视 | https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/live/cctv.txt |
| 卫视 | https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/live/weishi.txt |
| 浙江本地 | https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/live/zhejiang.txt |

原因：影视仓一份配置只能是「多仓索引（urls）」或「单配置（sites+lives）」二选一；日检用的是多仓 DC.json，
带 lives 会冲突。独立登记后换任何点播配置都不影响直播。

更新流程：重跑 `live-sources.ps1` → `rebuild-fragment.ps1` 生成 txt → 推到本仓库 → App 端地址不变，自动生效。
