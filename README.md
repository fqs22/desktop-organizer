# 桌面整理工具 · Desktop Organizer

按**项目/客户**自动归档桌面文件的 Windows 小工具。PowerShell + Node.js，零框架、零后台进程。

## 为什么不是"PDF 归文档、Excel 归表格"

市面上的桌面整理工具（Hazel、File Juggler、Belvedere、Deskora）几乎都是按扩展名分组。
对下载文件夹有效，但**对工作台有害**——它会把同属一个客户的文件拆到不同目录。

本工具反过来：**先认归属，再谈类型。**

```
桌面\业务文件\
  客户A\         ← 该客户的所有 PDF / Excel / Word
  客户B\
  其他\          ← 认不出归属的
桌面\软件与安装包\
桌面\临时文件\
```

## 特性

- **只移动，不改名、不删除、不修改内容**
- **默认预览**：不加参数运行只列出计划，不动任何文件
- **一键撤销**：每次执行都留 JSON 日志，可完整还原
- **内容识别**：文件名里没有客户名时，读取 PDF 正文的 `Borrower` / `Applicant` 判定归属
- **活跃保护**：最近 N 天改过的文件默认不动（正要用的不会突然消失）
- **保守兜底**：类型拿不准的文件一律留在桌面
- **改动规则只改 `config.json`**，不碰代码

## 用法

双击即可，无需命令行：

| 入口 | 作用 |
|---|---|
| `预览整理.bat` | 只看不动 |
| `执行整理.bat` | 整理（保护期内的文件留桌面） |
| `强制归档.bat` | 连刚改过的也归档 |
| `撤销整理.bat` | 还原最近一次 |

命令行等价形式：

```powershell
powershell -File organize.ps1            # 预览
powershell -File organize.ps1 -Apply     # 执行
powershell -File organize.ps1 -Apply -ForceHot   # 强制归档
powershell -File undo.ps1                # 撤销
```

## 配置

复制 `config.example.json` 为 `config.json`，按需修改：

| 字段 | 说明 |
|---|---|
| `clients` | 客户名单：`key` 是识别用的名字，`folder` 是目标文件夹 |
| `hotDays` | 多少天内改过的文件不搬 |
| `foldersToBusiness` | 要整体归入业务大文件夹的文件夹名 |
| `exclude` / `excludePrefixes` | 永不移动的文件（`~$` 是 Office 锁文件） |
| `nodeModulesPath` | PDF 解析依赖所在目录（留空则用脚本同目录） |

真实配置含客户姓名，**已在 `.gitignore` 中排除，不会被提交**。

## 内容识别的坑（都踩过）

1. **短名误命中**：`Tran` 会命中 `Transaction`、`Transfer` → 用词边界匹配
2. **文本粘连**：PDF 常把标签与值连写成 `BorrowerAlice Sun`，要求前置词边界会漏掉真客户 → 只保留**后置**词边界
3. **扫描件读不出**：图片型 PDF 无文本层，内容识别对它们无效，落入「其他」等人工判断
4. **被占用的文件**：文件被 Excel 打开时无法移动，这是保护而非失败

## 依赖

PDF 内容识别用 `pdf-parse`（66MB，含 1176 个文件）。
为避免桌面被依赖撑爆，脚本支持**依赖与脚本分离部署**：

```bash
npm install    # 在依赖目录执行，然后在 config.json 里填 nodeModulesPath
```

不需要内容识别时，把 `enableContentScan` 设为 `false`，即可脱离 Node 运行。

## 文件结构

```
organize.ps1     主脚本（预览 / 执行 / 强制归档）
undo.ps1         撤销
scanpdf.js       PDF 正文扫描，输出 JSON 供主脚本判定归属
config.json      配置（不入库）
*.bat            Windows 双击入口
history\         撤销日志（不入库）
```

## 已知限制

- 仅 Windows / PowerShell 5.1+
- 扫描件（图片型 PDF）无法内容识别
- 单点名（如 `Qin`）依赖词边界，与常见英文单词冲突时可能漏判
