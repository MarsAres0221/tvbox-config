# TVBox 配置文件

TVBox 影视源聚合配置。

## 配置地址

主地址（jsDelivr CDN，国内可达性较好）：

```
https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/DC.json
```

备用地址（GitHub 原始文件；CDN 异常或需要刚推送的最新内容时可用）：

```
https://raw.githubusercontent.com/MarsAres0221/tvbox-config/master/DC.json
```

> 说明：两个地址内容相同，都是本仓库 `master` 分支的 `DC.json`，可任选其一或都填入客户端。
> `singles.json` 已于 2026-10-25 合并进 `DC.json`，不再单独提供，旧地址会 404。

## 使用说明

1. 打开 TVBox 或影视仓
2. 设置 -> 配置地址
3. 填入上面的地址
4. 确认，加载

## 文件说明

- `DC.json` - 主配置，多仓 + 单仓线路已合并为单一数据源
- `config.json` - 备用模板
- `live/` - 直播源目录
- `android-*.ps1` / `publish.ps1` / `weekly-update.ps1` - 校验与发布脚本

## 维护流程

每周更新配置后，运行：

```powershell
.\publish.ps1
```

脚本会验证 JSON、推送到 GitHub remote `github`，并刷新 jsDelivr 缓存。

如果需要先做源质量预筛，运行：

```powershell
.\weekly-update.ps1
```

脚本会从当前 `DC.json` / `singles.json` 展开候选入口，检查配置结构、站点数量和 spider 可访问性，并生成本地 `weekly-report.json` / `discovered-sources.json`。报告文件不会提交入库。

注意：Gitee raw 已被限制，不再作为最终配置地址；Gitee 侧仅作私有备份仓库使用。
