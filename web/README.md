# 浏览器演示

在项目根目录运行：

```powershell
./scripts/build_web.ps1
python -m http.server 8765 --bind 127.0.0.1 --directory web
```

然后打开 http://127.0.0.1:8765/ 。页面使用本地构建的 MoonBit JS 模块；每次修改 MoonBit 核心后重新运行构建脚本。浏览器页面不能直接通过 `file://` 打开，因为模块 Worker 需要本地 HTTP 服务。

选择原始 `.ipynb` 后可运行发布检查；再选择修改后的文件可比较差异。显示范围支持全部、仅代码、代码与文字；结果可下载 JSON 或独立 HTML 报告。“试用示例”无需准备文件。单文件上限 10 MiB，分析在浏览器 Worker 内完成，文件不会上传，也不会执行 Notebook 中的 Python 代码。
