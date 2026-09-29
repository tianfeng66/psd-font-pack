<p align="center">
  <img src="docs/icon.png" width="128" alt="PSD字体打包">
</p>

<h1 align="center">PSD 字体打包</h1>

<p align="center">
  把 PSD 拖进来，自动把用到的字体和 PSD 打成一个压缩包，发给别人就不会缺字体。
</p>

<p align="center">
  <a href="https://github.com/tianfeng66/psd-font-pack/releases/latest"><img src="https://img.shields.io/github/v/release/tianfeng66/psd-font-pack?label=下载" alt="下载"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/芯片-Apple%20%2F%20Intel-lightgrey" alt="Apple / Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

---

做设计时把 PSD 发给别人，对方打开一看：「缺少字体」，文字全变成了默认字体。
这个工具帮你一步解决：**拖入 PSD → 自动找出用到的字体 → 补齐本机缺的 → 和 PSD 一起打成 zip**，对方解压、装上字体就能原样打开。

## 功能

- **只打包真正用到的字体**：逐个文字图层读取实际使用的字体（按文字样式段统计），不会把 PSD 里残留的默认字体也算进去。隐藏图层、图层组、**智能对象里面的文字**都会找到。
- **缺失字体标红提醒**：你自己电脑上也没有的字体会明确列出来，告诉你用在哪个图层、哪段文字上。
- **自动补齐缺失字体**，按顺序尝试：
  1. **本机 Adobe 软件自带的字体**（如 Adobe 黑体、Myriad Pro，Photoshop 里不报缺失但系统里查不到的那种）
  2. **你自己的字体库文件夹**（平时攒的字体放一个文件夹，设置一次即可）
  3. **免费字体自动下载**：思源黑体 / 思源宋体、霞鹜文楷、Google Fonts 全部字体
  4. 都找不到的（如方正、汉仪等商用字体），给出官网和搜索链接
- **可变字体也认得**：在 PS 里拖过粗细滑块的可变字体，会自动对应回原字体文件。
- **对方用 Windows 也不缺字**：苹方等 Mac 系统字体默认也一起打包（不需要时可在选项里关掉）。Adobe Fonts 云字体按授权不能转发，不打包，对方登录 Creative Cloud 后 Photoshop 会自动激活。
- **附带字体清单**：压缩包里有一份「字体清单.txt」，写清每款字体用在哪个图层，以及对方怎么安装。
- **Windows 解压不乱码**：压缩包使用 UTF-8 文件名，支持超过 4GB 的 PSB。
- **完全本地运行**：不上传任何文件，只有下载缺失字体时才联网。

## 安装

### 方式一：一行命令安装（推荐）

打开「终端」（按 `⌘ + 空格`，输入「终端」回车），粘贴下面这行，回车：

```bash
curl -fsSL https://raw.githubusercontent.com/tianfeng66/psd-font-pack/main/install.sh | bash
```

会自动下载最新版、装到「应用程序」并打开，**不会遇到系统的安全拦截**。以后想更新，再执行一次同样的命令即可。

### 方式二：手动下载

1. 到 [Releases](https://github.com/tianfeng66/psd-font-pack/releases/latest) 下载 `PSDFontPack.zip`，解压
2. 把「PSD字体打包.app」拖进「应用程序」文件夹
3. 第一次打开会被系统拦截（因为没有购买苹果开发者签名），在终端执行一次：
   ```bash
   xattr -cr /Applications/PSD字体打包.app
   ```
   或者：双击 App → 提示框点「完成」→「系统设置」→「隐私与安全性」→ 拉到最下面点「仍要打开」

> 建议打开后在程序坞图标上右键 →「选项」→「在程序坞中保留」，以后直接把 PSD 拖到程序坞图标上就行。

## 使用

**就一步：把 PSD（可以多个，也可以直接拖整个文件夹）拖到程序坞图标上，或拖进窗口。**

松手后自动完成：找出字体 → 补齐缺失字体 → 打包 → 在访达里选中压缩包。
压缩包放在 PSD 旁边，名字是 `文件名_字体打包.zip`，直接发给对方。

压缩包里的内容：

```
海报_字体打包/
├── 海报.psd
├── 字体清单.txt      ← 每款字体用在哪个图层、对方怎么安装
└── Fonts/
    ├── SourceHanSansCN-Bold.otf
    ├── LXGWWenKai-Regular.ttf
    └── …
```

窗口里每款字体的状态：

| 标记 | 含义 |
|---|---|
| ✓ 绿色 | 已打包（包括从 Adobe 软件、字体库、网上补齐的） |
| ○ 灰色 | 不打包：Adobe Fonts 云字体（对方打开时自动激活）；关掉「打包 Mac 系统字体」时的苹方等系统字体 |
| ✗ 红色 | 缺失：你电脑上也没有、也没能补齐。点下面的链接找到字体装上，再拖一次 PSD 即可 |

有红色 ✗ 时，工具不会跳到访达，而是停在窗口里并提示音提醒你。

### 对方收到后

解压 → 打开 `Fonts` 文件夹 → `⌘A` 全选 → 双击 → 点「安装」→ 重启 Photoshop。
（Windows：全选 → 右键 →「为所有用户安装」）

## 选项

点窗口左下角「选项」，一般不用动。改过的选项会显示在按钮旁边。

| 选项 | 默认 | 说明 |
|---|---|---|
| 拖进来就自动打包 | 开 | 关掉后要手动点「打包」，可以先攒几批文件一起打 |
| 字体库文件夹 | 无 | 本机缺的字体先从这些文件夹（含子文件夹）里找，按字体内部名称精确匹配，文件名随便起都行 |
| 自动下载缺失字体 | 开 | 从思源 / 霞鹜 / Google Fonts 下载，国内网络不好时自动换镜像 |
| 补充的字体顺便装到本机 | 关 | 从字体库或网上补到的字体，也装到你自己电脑上 |
| 压缩包里包含 PSD | 开 | 关掉就只打包字体 |
| 多个 PSD 时每个单独打包 | 关 | 默认合成一个包 |
| 打包 Mac 系统字体（苹方等） | 开 | 保证对方用 Windows 也不缺字；确定对方用 Mac 时可以关掉，包会小一些（注意：苹果字体的授权仅限在苹果设备上使用） |

想换保存位置点「打包到…」；PSD 所在文件夹不能写入时会自动让你选位置。

## 命令行

App 也可以在终端里批量使用：

```bash
/Applications/PSD字体打包.app/Contents/MacOS/PSDFontPack --cli [选项] <PSD/PSB 文件或文件夹>…
```

| 参数 | 说明 |
|---|---|
| `--check` | 只检查，不下载、不打包 |
| `--no-download` | 缺失字体不自动下载 |
| `--library <目录>` | 字体库文件夹，可写多次（默认用 App 里设置的） |
| `--no-system` | 不打包 Mac 系统字体（默认打包） |
| `--no-psd` | 包里只放字体 |
| `--separate` | 多个 PSD 各打一个包（默认合并） |
| `-o <目录>` | 输出目录（默认和 PSD 放在一起） |

退出码：`0` 正常，`2` 有字体缺失，`1` 出错。

## 常见问题

<details>
<summary><b>PS 里没提示缺字体，工具却说缺失？</b></summary>

先确认用的是最新版。常见的两种情况新版都已处理：Photoshop 自带字体（Adobe 黑体、Myriad Pro 等，PS 2026 起换了存放位置）和拖过粗细滑块的可变字体。如果还有，欢迎提 Issue 并附上「字体清单.txt」里那个字体名。
</details>

<details>
<summary><b>提示「已损坏，无法打开」</b></summary>

这是系统对网上下载的未签名 App 的拦截，执行 `xattr -cr /Applications/PSD字体打包.app` 即可；或者改用上面的一行命令安装。
</details>

<details>
<summary><b>自动下载很慢或失败</b></summary>

下载源在 GitHub 和 Google。平时用代理的话，打开代理后点字体下面的「重试下载」，下载成功会自动重新打包。
</details>

<details>
<summary><b>字体库里的字体可以随便分享吗？</b></summary>

「可商用」不等于「可以转发」。开源字体（SIL OFL 等，如思源、霞鹜）可以自由分享；平台授权字体（如「仅限某电商平台使用」的汉仪、华康）、需要单独申请授权的字体（如方正免费商用字体）不要转发。工具会把字体库里匹配到的字体打进压缩包，给外部客户发 PSD 时请留意授权。
</details>

## 从源码构建

只需要 Xcode Command Line Tools（`xcode-select --install`），不依赖任何第三方库。

```bash
./build.sh        # 产物：build/PSD字体打包.app（通用二进制 arm64 + x86_64）
./打包分发.sh      # 产物：dist/PSD字体打包-v<版本>.zip 和 dist/PSDFontPack.zip（发布用）
```

### 实现要点

- **用到的字体按样式段算。** 每个文字图层的 EngineData 里，FontSet 会带着 MyriadPro、AdobeInvisFont 这类没用上的默认项；只统计 StyleRun 里真正引用到的字体序号，缺省时退回默认样式表的字体。
- **智能对象递归。** 嵌入式智能对象（`lnk2` / `liFD`）里的 PSB 会继续往下解析，图层路径显示成「卡片 ▸ 内嵌说明文字」；UUID 对回 `PlLd` / `SoLd` 找到是哪个图层。链接型智能对象（`liFE`）列为「需要一并发送的外部文件」。结构解析失败时，全文搜 `/EngineDict` 兜底。
- **字体定位走 CoreText。** 按 PostScript 名创建字体后核对名字（找不到时 CoreText 会返回替代字体），拿到的文件路径和 Photoshop 看到的一致。CoreText 看不到的（Adobe 软件私有字体目录、在「字体册」里停用的字体）再扫一遍目录补上；Adobe 软件的字体目录位置随版本变化，所以是在 `/Applications/Adobe */…/Required` 下找所有叫 `Fonts` 的文件夹。
- **可变字体实例名。** 按 [Adobe 技术说明 5902](https://adobe-type-tools.github.io/font-tech-notes/pdfs/5902.AdobePSNameGeneration.pdf)，任意坐标的实例名形如 `前缀_700wght`、`前缀_wght2BC` 或 `前缀-哈希...`，去掉坐标部分后按前缀（name ID 25 / 排版家族名）找回可变字体文件。
- **字体库。** 按文件内的 PostScript 名匹配，名字缓存在 `~/Library/Caches/PSD字体打包/library-index.json`，按修改时间和大小失效。
- **自动下载。** 思源黑体 / 宋体从 Adobe 官方 GitHub、霞鹜文楷从 GitHub Release 直接取；其余查 Google Fonts：字体目录缓存 7 天，按 PostScript 名精确匹配静态字重文件。官网连不上时走 CSS 接口和国内镜像 `fonts.loli.net`。下载后校验文件内的 PostScript 名。
- **自己写 zip。** macOS 的 ditto / zip 不设 UTF-8 文件名标记，Windows 解压中文名会乱码；`ZipWriter` 设了标记，支持 ZIP64（超过 4GB 的 PSB），PSD 只存储不压缩，字体用 zlib 压缩。

### 文件结构

| 文件 | 作用 |
|---|---|
| `Sources/PSDReader.swift` | PSD/PSB 结构解析：图层记录、分组路径、智能对象递归、全文兜底 |
| `Sources/EngineData.swift` | EngineData 解析，统计实际用到的字体 |
| `Sources/FontLocator.swift` | CoreText 定位字体文件、分类、可变字体实例名 |
| `Sources/FontLibrary.swift` | 用户字体库文件夹的索引和查找 |
| `Sources/Downloader.swift` | 免费字体自动下载、缺失字体的获取提示 |
| `Sources/ZipWriter.swift` | UTF-8 + ZIP64 的 zip 写入 |
| `Sources/Pipeline.swift` | 分析、清单生成、打包 |
| `Sources/AppModel.swift` / `ContentView.swift` | 界面 |
| `Sources/CLI.swift` | 命令行模式 |
| `Tools/makeicon.swift` | 生成图标 |
| `install.sh` | 一行命令安装脚本 |

## 许可

代码以 [MIT License](LICENSE) 开源。工具下载和打包的字体各有其授权，与本项目无关，请自行确认字体的使用授权。
