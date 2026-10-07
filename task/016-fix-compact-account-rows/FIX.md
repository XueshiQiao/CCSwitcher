# FIX -- 合并账号卡顶部与底部行

## Status: done
## Task: 016
## Related: 015
## Baseline Commit: 1c48c06

## Problem
账号卡头部和底部分为多行，用户要求顶部合并、底部横排、CLI按钮仅图标。

## Root Cause
AccountSwitcherView的状态栏和邮箱为两个HStack；AccountUsageView的控制为两个HStack。

## Fix Plan
- [x] 顶部统一一行：当前勾选标记、完整邮箱、套餐、复制和菜单/切换；邮箱可换行以保留全文。
- [x] 底部统一横排：时间、自动同步、读取缓存、CLI图标；冷却信息放悬停提示，禁用条件保留。

## Verification
- [x] 假数据明暗预览，普通及长邮箱不遮挡，图标保留辅助功能名称。
- [x] Release构建、备份替换和签名/版本核验。
- [x] diff-guard检查：仅合并视图布局，不新增刷新、切换、授权或持久化行为，不新增镜像展示测试。

- 已目视核对普通邮箱浅色、长邮箱深色预览：头部合并、底部横排，CLI图标保留Label辅助功能名称和冷却提示。
- Release66.15构建及安装签名/版本/哈希/进程核验通过。备份：/Applications/.CCSwitcher-before-compact-account-rows-20261008.app。未提交推送，未调用真实CLI或额度接口。
