# Python 定义与引用模型（实验）

此阶段在已接入的 Python CST 上建立可复用的定义、读取、版本和绑定关系。算法与状态维护在 MoonBit 中实现；Tree-sitter 仅提供语法结构。不执行 Python，不推断 Notebook 的实际运行历史，不进行跨单元格依赖或修改影响分析。

## 运行

```powershell
pwsh -NoProfile -File scripts/prepare_python_syntax.ps1
node tools/python-syntax/probe.mjs examples/python-bindings/rebinding.py --mode bindings --backend js
node tools/python-syntax/probe.mjs examples/python-bindings/rebinding.py --mode bindings --backend native --output bindings.json
```

仍使用同一份 Node／浏览器 WASM 语法前端。native 入口由 Node 生成语法传输记录，再调用 native MoonBit，Node 仍是实验入口依赖；不是 Python 解释器或原生 C 解析器直连。原有 `syntax` 模式保持默认，正式 `nbinspect` CLI／Notebook 发布规则和浏览器界面保持原有行为。

退出码：`0` 为 `modeled`，`1` 为 `incomplete`，`2` 为输入、适配或资源错误。这些不是原有发布规则的通过／阻断结论。

## 模型与假设

分析针对一个模块源文件，按源码顺序、语句和表达式正常完成的假设建立显式名称绑定；不模拟初始内核、异常路径、析构器、别名突变、并发修改或任意隐式用户代码。不证明程序可执行、值正确、引用必然存在或输出可信。

- `definitions`：每次支持的显式名称写入有独立 `id`、该名称的 `version`、赋值种类、所属语句和源码位置。版本是本次模型内的写入编号，不是执行计数。`scalar` 只是来自基础字面量及受支持表达式的粗粒度提示，不是运行时类型推断。
- `references`：读取记录关联之前的定义 ID。`bound` 表示模型中的前序关联；`external` 表示已建模前缀里没有定义，不能因此判断必然 NameError；`unknown-after-barrier` 表示先前遇到未知影响，当前无法给出绑定。未绑定时 JSON 省略 `definition`。
- `uncertainties`：记录原因和语法节点位置，并清空此前可用的名称环境，避免把旧绑定继续当作确定依据。之后新出现的明确赋值仍可建立新绑定，但整个报告保持 `incomplete`；历史定义和按名称编号不删除。
- 所有记录都有单调递增的 `order`，描述模型假设下的分析先后；位置沿用从零开始的 UTF-8 字节、LF 行／字节列。报告保留原始源码，字面量和注释里的文本不当作变量引用。

普通赋值先分析右侧，再写入左侧。`a=b=value` 只分析一次右侧，按 a、b 顺序写入。`x+=x` 先读取目标，再分析右侧，两次读取都关联此前版本，最后创建新版本。重新赋值只替换该名称的当前绑定，不会改写过去的引用。

## 支持边界

- 支持模块级单一名称及名称链式赋值、简单名称增强赋值、名称读取、基础字面量、括号、有限运算／双操作数比较、基本容器表达式和 `pass`。
- 调用会分析可支持的函数表达式和普通参数；关键字参数的名称不当作变量读取。调用本身随后产生未知影响。属性／下标访问记录可支持的接收者与索引读取，再产生未知影响；属性名不当作独立变量。未知对象上的运算／哈希同样保守处理。
- 调用展开参数不猜测求值顺序；函数／类、分支、循环、导入、解包或属性／下标赋值、注解、推导式／生成器、lambda、walrus、短路布尔表达式／链式比较、格式化插值等尚未分析。不会把内部名称直接扁平化到模块作用域；跳过时明确记录不确定性。
- 目前仅绑定 ASCII 标识符。Python 使用 NFKC 名称规范化；这部分尚未在 MoonBit 实现。非 ASCII 名称不会按原始文本强行与其他名称绑定，而是产生未知影响，避免把 `K` 和 `K` 等潜在同名情况分析错。
- 语法树有 ERROR／MISSING 时，不从恢复树中提取绑定，保留语法诊断并返回 `incomplete`。沿用语法前端的大小、节点及深度限制；另限制为最多 100,000 个分析事件，超限报错。

`modeled` 只表示当前输入落在此模块模型的支持范围，不是完整 Python 语义分析或运行时副作用的完备证明。不提供跨单元格依赖图、复现保证或自动执行建议；它们需要在后续阶段基于这个模型继续实现和验证。

## 验证

```powershell
moon test python_bindings --target native
moon test python_bindings --target js
node scripts/python_bindings_test.mjs
# 开发期额外对照；正式入口和默认 CI 不依赖 Python
node scripts/python_bindings_test.mjs --python-oracle
```

实际 WASM 树在两种 MoonBit 后端对照，覆盖读取／写入顺序、重新赋值、链式与增强赋值、作用域隔离、关键字／属性名、未知边界、非 ASCII 规范化边界、变量改名与空白换行变换、错误恢复和入口退出码。额外工具仅调用 CPython `ast.parse` 对照支持样例的 Name Load／Store 角色及位置，不执行输入；它不作为绑定算法正确性或完整语义分析的证明。

实现语义参考 Python 官方的[赋值语句](https://docs.python.org/3/reference/simple_stmts.html#assignment-statements)、[名称绑定](https://docs.python.org/3/reference/executionmodel.html#binding-of-names)和[标识符规范化](https://docs.python.org/3/reference/lexical_analysis.html#identifiers)。
