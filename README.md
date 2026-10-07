# NBInspect

NBInspect 是一个用 MoonBit 编写的 Jupyter Notebook 审阅工具。它比较两个 `.ipynb` 文件中的单元格，区分内容修改与位置移动，并在分享 Notebook 前检查常见的格式和输出问题。可以通过命令行使用，也可以在本地浏览器中导入文件生成报告。

## 能做什么

- 读取 nbformat 4.0–4.5 的常见 `code`、`markdown`、`raw` 单元格结构，统一字符串与字符串数组形式的文本，并保留未知字段。
- 依据单元格 ID、精确内容和有限相似度建立对应关系；对无法确定的匹配保留歧义，避免把插入导致的位置变化直接当作移动。
- 比较代码和文字、输出、附件、执行记录、元数据以及扩展字段；可选择显示全部差异、仅代码或代码与文字。
- 检查缺失或重复的单元格 ID、异常输出、执行计数、附件引用、输出大小以及缺失的内核或语言元数据。
- 输出文本、JSON（`schema_version` 为 `1`）或可离线打开的 HTML 报告。浏览器演示也支持下载 JSON 和 HTML。

## 命令行快速开始

下面以 Windows PowerShell 为例。需要安装 MoonBit 工具链，并具备构建 native 目标所需的 C 编译环境。在仓库根目录运行：

```powershell
moon build --target native
$bin = '.\_build\native\debug\build\cmd\nbinspect\nbinspect.exe'
& $bin --help
```

检查一个 Notebook：

```powershell
& $bin check .\notebook.ipynb
& $bin check .\notebook.ipynb --format json --fail-on warning
```

比较两个版本，并保存 HTML 报告：

```powershell
& $bin diff .\before.ipynb .\after.ipynb --view all
& $bin diff .\before.ipynb .\after.ipynb --format html --output .\review.html --exit-code
```

将示例中的文件名换成自己的文件。`--output` 要求目标文件尚不存在，不会覆盖输入文件或已有报告。

| 选项 | 用途 |
| --- | --- |
| `--format text\|json\|html` | 选择报告格式；默认 `text`。 |
| `--output FILE` | 将报告写入新文件；默认输出到终端。 |
| `--view all\|code\|content` | `diff` 的显示范围：全部、仅代码、代码与文字；默认 `all`。 |
| `--fail-on error\|warning\|info` | `check` 的阻断级别；默认 `error`。 |
| `--exit-code` | `diff` 存在可见差异时返回 `1`。 |

退出码：`0` 表示命令成功；`check` 触发所选阻断级别，或带 `--exit-code` 的 `diff` 发现可见差异时返回 `1`；参数、文件、格式或分析错误返回 `2`。普通 `diff` 即使有变化也返回 `0`。

## 浏览器演示

需要 MoonBit、PowerShell 和 Python 3。在仓库根目录运行：

```powershell
./scripts/build_web.ps1
python -m http.server 8765 --bind 127.0.0.1 --directory web
```

打开 [http://127.0.0.1:8765/](http://127.0.0.1:8765/)。选择原始 Notebook 后可以检查；再选择修改后的文件可以比较差异或审阅发布风险。风险审阅支持按新增、已有、已消除、待确认筛选，下载保留完整报告。也可以点击“试用示例”，无需准备文件。分析由本地构建的 MoonBit JS 模块在浏览器 Worker 中完成，文件不会上传。修改 MoonBit 核心代码后需重新运行构建脚本。更多操作见 [浏览器说明](web/README.md)。

## 本地验证

```powershell
moon check --target native
moon test --target native
moon check --target js
moon test --target js
moon fmt --check
moon build --target native
./scripts/cli_test.ps1
./scripts/build_web.ps1
node ./scripts/browser_core_test.mjs
node ./scripts/browser_ui_test.mjs
```

CLI 集成脚本使用 Windows 的 `.exe` 路径；浏览器核心测试需要 Node.js，且应在构建浏览器模块后运行。

## 范围与限制

- 仅分析 Notebook 数据，不执行其中的 Python 或其他代码；不提供自动修复或三方合并。
- 命令行输入必须是 UTF-8，单文件上限为 50 MiB；浏览器单文件上限为 10 MiB。解析器最多接受 10,000 个单元格，文本差异计算也有工作量限制。
- 发布检查给出需要人工复核的线索；执行计数不能证明代码曾正确运行，附件引用检查也不是完整的 Markdown 解析器。
- 当前差异分析只验证 nbformat 4.0–4.5；格式错误或未验证的更高次版本可能导致比较失败。

## 发布前风险审阅

用 review 对照修改前后的 Notebook，报告本次新增、持续、已消除和待确认的风险：

```powershell
& $bin review .\before.ipynb .\after.ipynb
& $bin review .\before.ipynb .\after.ipynb --format json --fail-on warning
```

默认在新增 error 级别风险时返回退出码 1；使用 --fail-on warning 或 --fail-on info 可以提高阻断级别。已有风险会列入报告，但不会作为本次新增风险阻断命令。匹配依据和无法确认的单元格也会保留在 JSON 与 HTML 报告中。
