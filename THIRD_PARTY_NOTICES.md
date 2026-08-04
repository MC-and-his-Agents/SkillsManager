# Third-party notices

## CC Switch

Source repository: https://github.com/farion1231/cc-switch

Bound source commit: `12b972a66e423897e92cc915ec680bfcd9156a8b`

Copyright: `Copyright (c) 2025 Jason Young`

This work references CC Switch only for interaction contracts, data mappings,
and test inputs. No substantial Rust/React/Tauri source was copied.

Allowed migration scope:

- Recreate the relevant interaction in native SwiftUI.
- Add CC Switch security inputs to the corresponding existing Swift tests.
- Reuse Skills Manager's existing SSOT, SQLite, and writer implementations.

Prohibited migration scope:

- Do not migrate the Rust/Tauri/React runtime.
- Do not migrate the CC Switch database or SSOT.
- Do not add automatic symlink-to-copy fallback.
- Do not install directly from skills.sh.
- Do not implement destructive uninstall behavior.

The CC Switch license notice follows in full:

MIT License

Copyright (c) 2025 Jason Young

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
