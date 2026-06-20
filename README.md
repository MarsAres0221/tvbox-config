# TVBox 配置文件

TVBox 影视源聚合配置。

## 配置地址

```
https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/DC.json
https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/singles.json
```

## 使用说明

1. 打开 TVBox 或影视仓
2. 设置 -> 配置地址
3. 填入上面的地址
4. 确认，加载

## 文件说明

- `DC.json` - 多仓配置，7 条线路
- `singles.json` - 单仓配置，6 条线路
- `config.json` - 备用模板

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

注意：Gitee raw 已被限制，不再作为最终配置地址。
