# Agent Guidelines for CCSwitcher

- **Single Source of Truth**: `project.yml` 成为了真正的、唯一的 Source of Truth。不要尝试手动编辑或生成 `Info.plist`，所有关于项目配置、打包、URL Scheme、版本号等设定都必须且只能在 `project.yml` 中进行修改，然后由 XcodeGen 自动生成项目和 Plist 文件。
- **Xcode Project**: `CCSwitcher.xcodeproj` 已经被 `gitignore` 忽略，任何对项目结构的改动（如新增文件、文件夹结构变化）都应当通过修改 `project.yml` 并在本地运行 `xcodegen generate` 来完成。