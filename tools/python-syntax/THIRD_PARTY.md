# Third-party components for the syntax experiment

The project's own code remains Apache-2.0. No upstream Python parser is claimed as an original NBInspect implementation. Dependencies are installed under the ignored `node_modules` directory using the committed lockfile and `npm ci --ignore-scripts`.

| Package | Locked version | Role | Source | License |
|---|---|---|---|---|
| web-tree-sitter | 0.25.10 | JS/WASM runtime used by the adapter | https://github.com/tree-sitter/tree-sitter | MIT |
| tree-sitter-python | 0.25.0 | Python grammar/WASM used by the adapter | https://github.com/tree-sitter/tree-sitter-python | MIT |
| node-addon-api | 8.9.2 | Transitive grammar-package dependency; unused by this WASM adapter | https://github.com/nodejs/node-addon-api | MIT |
| node-gyp-build | 4.8.4 | Transitive grammar-package dependency; install hooks are disabled | https://github.com/prebuild/node-gyp-build | MIT |

The packages retain their original license files after installation. This repository does not vendor their generated parser source, binaries or WASM artifacts. Any redistributed experimental bundle must retain the applicable original copyright and license notices. Full notices for the two runtime components actually used follow, copied from the locked distributions.

## web-tree-sitter

```text
The MIT License (MIT)

Copyright (c) 2018-2024 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## tree-sitter-python

```text
The MIT License (MIT)

Copyright (c) 2016 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
