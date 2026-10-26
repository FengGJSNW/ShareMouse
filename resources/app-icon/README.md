# ShareMouse 应用图标

当前采用第二版「指针穿过边界」设计。生成方式：内置 imagegen，未使用 CLI/API。

- `macos-master.png`：浅瓷灰圆角底座，蓝色开放边界与深色指针，透明外缘；`ShareMouse.icns` 包含 16–1024 像素资源。
- `windows-master.png`：独立蓝色边界＋深色描边白指针；`ShareMouse.ico` 包含 16、20、24、28、30、32、36、40、48、60、64、72、80、96、128、256 像素帧，供 EXE、WPF 窗口和托盘使用。
- `MenuBarTemplate.png`：18 pt／2x 单色简化版本，macOS 以 template 图像自动适配菜单栏颜色。

在仓库根目录运行 `swift scripts/generate-app-icons.swift` 可从主图重建平台容器与菜单栏资源。原始主图透明度保留。

生成提示词要点：单个指针穿过开放蓝色圆角边界；克制、清晰、正视图、无文字、无显示器或发光装饰。Mac 使用浅瓷灰圆角底座、深蓝指针、透明留白；Windows 去除底座，白色指针配深蓝轮廓，内外区域透明。菜单栏用同构几何路径单独绘制，保证小尺寸轮廓。

## 最终编辑提示词

macOS（输入为第二版白底概念图）：

> Precise production cleanup of this ShareMouse macOS app icon. Preserve the exact emblem, dark navy pointer pointing up-right, cobalt broken rounded-square portal, and warm white squircle tile. Change only spacing and outer edge quality: shrink the ENTIRE icon to occupy exactly 80 percent of canvas width and height, centered, with 10 percent completely empty transparent padding on every side. The outer rounded-square tile edge must be a perfectly smooth clean continuous precision silhouette. Remove ALL wispy white fringe, stray flecks, speckles, rough cutout artifacts and edge noise. No diffuse outside glow, no ragged shadows. The tile should have a very subtle edge shading only inside its bounds. Keep artwork flat, crisp, carefully antialiased and minimal. No additions or text. Transparent 1024 square canvas.

Windows（输入为最终 macOS 图）：

> Create the Windows icon variant of this ShareMouse icon. Keep the exact bold up-right mouse arrow and the single cobalt-blue broken rounded-square portal. Remove the whole white rounded tile and all shadows entirely. The arrow should be white filled with a thick dark-navy outline to remain legible on both light and dark desktop backgrounds. The portal remains vivid cobalt blue with clean uniform thickness and round end caps. The gap in the portal remains at lower left. Strong precise vector-like silhouette, perfectly flat color, no texture, absolutely no highlights or glow or gradients. Single standalone glyph centered at 80 percent canvas width, transparent outside the glyph and inside the portal. Clean antialiased edges. Square canvas. No screens, no words, no text, no branding sheet, no extra symbols.

最后一次外缘修整提示词：

> Precise-object-edit: preserve this icon emblem, layout, scale, pointer and blue portal exactly. Repair only the tile silhouette: the light tile currently has ugly ragged white flecks outside the perimeter. Replace its background material with a solid cool porcelain gray #DDE3ED, and give the tile a continuous very thin 2px medium slate-gray outer contour, clean like a vector path. Use a mathematically smooth rounded-square squircle boundary, completely flat and absolutely crisp against transparent outside space. No white or gray flecks outside the edge, no fuzzy shadows, no feathering, no glow. Keep the dark navy arrow and vivid blue portal identical. Keep transparent 10 percent outer padding and the tile position. This is final production app icon cleanup, not a new concept. Genuine transparency.

## 当前导出尺寸（2026-10-20）

按不透明图案的实际边界计算缩放，不再把生成主图的透明留白一起缩小。Mac 图案最长边占画布88%，Windows占96%；保留原主图与18pt菜单栏。Windows窗口显式加载多尺寸ICO，包含150%缩放适用的36px等资源。
