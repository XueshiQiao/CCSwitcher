# FIX -- 直接展示账号缓存额度

## Status: done
## Task: 014
## Related: 013
## Baseline Commit: 1c48c06

## Problem
非当前账号的已保存额度需要逐个展开，不能直接查看缓存。

## Root Cause
AccountSwitcherView.accountRow只在当前账号或expandedAccounts包含该账号时创建AccountUsageView。

## Fix Plan
- [x] 移除账号折叠状态及按钮，所有账号直接展示AccountUsageView。
- [x] 复用既有采样时间、无缓存/错误状态及只读限制，展示不调用读取或切换。

## Verification
- [x] 假数据预览确认非当前账号额度直接可见。
- [x] Release构建、本地备份替换及签名/版本核验。
- [x] diff-guard：仅移除UI折叠，不更改数据/授权/定时逻辑，不添加镜像实现的测试。

- 假数据预览确认第二账号无需点击即可显示缓存额度及历史时间，缺缓存与错误状态正常。Release66.13构建、安装签名及主程序/CLI哈希核验通过。
- 旧版备份：/Applications/.CCSwitcher-before-visible-cached-quota-20261008.app。保留五分钟本地读取，未触发额度查询，未提交或推送。
