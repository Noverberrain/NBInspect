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
| `--fail-on error\|warning\|info` | `check`、`review`、`batch` 的阻断级别；默认 `error`。 |
| `--exit-code` | `diff` 存在可见差异时返回 `1`。 |

退出码：`0` 表示命令成功；`check` 触发所选阻断级别，或带 `--exit-code` 的 `diff` 发现可见差异时返回 `1`；参数、文件、格式或分析错误返回 `2`。普通 `diff` 即使有变化也返回 `0`。

## 批量检查

检查一个文件夹中的 Notebook；默认只检查当前层，添加 `--recursive` 扫描子目录：

```powershell
& $bin batch '.\课程资料' --recursive
& $bin batch '.\课程资料' --recursive --format json --fail-on warning
& $bin batch '.\课程资料' --recursive --format html --output '.\batch-report.html'
```

汇总报告列出每个文件的相对路径、检查状态与完整诊断，以及通过、阻断、读取／解析错误、未支持格式、扫描错误和跳过项的数量。HTML 提供文件导航，可直接跳到相应文件的诊断。损坏文件不会中断其他文件的检查。

- 退出码 `0`：扫描完整，全部文件通过所选阻断级别；空文件夹会明确报告文件数为 `0`。
- 退出码 `1`：扫描完整，但至少一个文件触发所选阻断级别。
- 退出码 `2`：某文件无法读取或解析、格式未受支持、子目录扫描失败或达到扫描上限；仍输出已经完成的结果，报告状态为 `incomplete`。根目录无效或无法完整列出，以及参数／报告写入错误，会输出到 stderr。
- `batch` 的 JSON 报告沿用 `schema_version: 1`，`kind` 为 `batch`；`files` 保存逐文件结果，`scan_errors` 与 `skipped` 分别记录扫描错误和跳过项。
- 跳过符号链接、Windows Junction／其他重解析点及特殊文件，排除 `.git`、`_build`、`.mooncakes`、`.ipynb_checkpoints` 和 `node_modules` 目录。
- 上限为 1,000 个 Notebook、4,096 个目录；单目录至多 10,000 项／16 MiB 文件名列表，每个 Notebook 沿用 50 MiB 输入限制。达到上限会报告检查不完整，避免静默漏检。
- `--output` 仍只允许写入新文件。目录发现为 native CLI 功能，当前浏览器仍按一个或两个 Notebook 操作。

## Git 改动审阅

在目标 Git 仓库（或其子目录）中运行 native CLI，指定两个提交、分支或标签：

```powershell
& $bin review-git HEAD~1 HEAD
& $bin review-git main feature --config .\configs\sharing.json --format json
& $bin review-git HEAD~1 HEAD --format html --output .\git-review.html
```

先将引用解析为实际提交号，再比较两个完整提交树。这里是两个端点的比较，不自动寻找 merge-base；配置文件和报告路径相对当前工作目录。运行其他仓库时，先保存 NBInspect 可执行文件的绝对路径，再进入目标仓库调用它。

- 新增 Notebook 使用发布检查，报告中的所有发现计为新增风险；修改和 Git 识别的改名使用现有风险审阅，只因新增且达到阻断等级的风险阻断。
- 删除文件保留记录，不检查旧内容，也不将其风险自动归为已消除；`.ipynb` 改成其他扩展名按离开检查范围记录，其他扩展名改成 `.ipynb` 按新增检查。扩展名匹配不区分 ASCII 大小写。
- 使用 [Git raw -z 格式](https://git-scm.com/docs/git-diff#_raw_output_format) 读取路径；支持 UTF-8 中文、空格、引号等名称。JSON 记录原路径、目标路径、前后 Blob ID、两个输入引用及实际提交号；文本和 HTML 提供逐文件状态、风险及匹配依据。
- 退出码 `0`：全部已检查文件通过，或没有 Notebook 变更；`1`：存在阻断文件；`2`：参数／Git／报告错误，或某文件读取、解析、格式检查失败。逐文件失败保留其他结果，汇总状态为 `incomplete`，不会因其他文件通过而返回 `0`。
- 直接读取提交对象，忽略暂存区和工作区内容；不切换分支、不 checkout 文件、不执行 Notebook、不自动下载缺失对象。需要 PATH 上的 Git，且支持 `--no-lazy-fetch`（本地验证 Git 2.51.0）。
- 原始清单最多 16 MiB，最多 1,000 个变更 Notebook，每个 Blob 至多 50 MiB，Git 进程在 30 秒时触发超时并终止。清单超限直接报错，不输出看似完整的部分报告；单个 Blob 超限保留为逐文件错误。
- 改名使用 Git 的 50% 相似度判断，穷举候选上限为 1,000；未识别的改名会表现为删除和新增，新增文件的历史风险无法继承。[Git 改名限制说明](https://git-scm.com/docs/git-diff#Documentation/git-diff.txt--lnum)。
- 链接、子模块及其他非普通文件不跟随，仍在逐文件错误中列出；Git LFS 指针按保存的 Blob 解析，尚不读取 LFS 实体。无法解码的非 UTF-8 路径清单会报错。
- 首版仅提供 native CLI 的提交读取入口；不包含未提交改动审阅、远程 PR 拉取或自动评论。清单解析、风险汇总和报告核心同时支持 native 与 JS。

## 发布规则配置

`check`、`review`、`batch` 和 `review-git` 支持 `--config FILE`。配置只显式读取指定文件；缺省字段沿用原有规则，不自动搜索配置文件。`diff` 不接受该选项。

```powershell
& $bin check .\notebook.ipynb --config .\configs\sharing.json
& $bin review .\before.ipynb .\after.ipynb --config .\configs\research.json --format html --output .\review-policy.html
& $bin batch '.\课程资料' --recursive --config .\configs\teaching.json --format json
```

配置示例：

```json
{
  "schema_version": 1,
  "fail_on": "warning",
  "rules": {
    "OUT001": { "enabled": true, "severity": "error" },
    "EXE002": { "enabled": false }
  },
  "limits": {
    "max_cell_output_bytes": 1048576,
    "max_total_output_bytes": 10485760
  }
}
```

`schema_version` 缺省为 `1`；所有规则默认启用。各规则可独立指定 `enabled`（布尔值）及 `severity`（`error`、`warning`、`info`）。`limits` 使用单个 Notebook 序列化输出的 UTF-8 字节数；默认单元格 1 MiB、Notebook 总输出 10 MiB，只接受 1–2,147,483,647 的整数。

| 规则 | 检查内容 | 默认等级 |
| --- | --- | --- |
| FMT001 | 未验证的 nbformat 次版本 | error |
| FMT002 | 缺失、无效或重复的单元格 ID | error |
| OUT001 | 已保存的异常输出 | warning |
| EXE001 | 单元格与结果的执行计数不一致 | warning |
| EXE002 | 执行计数倒序或重复 | info |
| ATT001 | 缺失的字面附件引用 | warning |
| SIZE001 | 输出大小超过阈值 | warning |
| META001 | 缺失内核或语言元数据 | info |

FMT001、FMT002 保持启用及 error 等级；语法／结构错误与未支持格式仍按原有方式处理。修改策略不会执行 Notebook 或修复文件。

优先级为：显式 `--fail-on` > 配置文件 `fail_on` > 默认 `error`，包括显式传入 `--fail-on error`。无效配置即使存在 CLI 覆盖也会报错，返回 `2`；错误会指出配置文件及字段路径。配置文件必须为 UTF-8 JSON，最多 1 MiB，未知字段、规则编号、错误类型和非法阈值均会拒绝。

`review` 对前后 Notebook 使用同一份有效策略；只新增且达到阻断等级的风险影响状态。`batch` 在开始扫描前加载、验证一次策略，所有文件共享它。JSON 报告新增 `policy` 字段，记录所有规则的有效开关、等级、阈值和最终阻断等级；文本与 HTML 也展示有效策略。报告 schema 仍为 `1`，未使用配置时判断行为保持原样。`--output` 不覆盖配置文件。

| 模板 | 示例取舍 |
| --- | --- |
| [teaching.json](configs/teaching.json) | 异常输出降为 info，关闭执行顺序提示，放宽输出大小 |
| [research.json](configs/research.json) | warning 阻断，执行结果计数不一致升为 error，允许较大输出 |
| [sharing.json](configs/sharing.json) | warning 阻断，异常输出升为 error、元数据缺失升为 warning，收紧输出大小 |

这些模板是项目可修改的示例，不代表通用发布标准。当前浏览器使用默认策略；本项配置文件入口在 CLI 提供，核心 API 同时支持 native 与 JS。

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
./scripts/batch_cli_test.ps1
./scripts/policy_cli_test.ps1
pwsh -NoProfile -File ./scripts/git_cli_test.ps1
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
