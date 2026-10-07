# FIX -- 费用历史直接显示

## Status: done
## Task: 012
## Related: 011
## Baseline Commit: 1c48c06

## Problem
费用页每日历史默认折叠，用户要求直接显示。

## Root Cause
Views/CostDetailView.swift的dailyHistory使用DisclosureGroup，默认隐藏列表。

## Fix Plan
- [x] 使用普通VStack和标题直接显示历史，保留所选时间范围与日期倒序。

## Verification
- [x] 离线假数据预览核对历史直接显示。
- [x] Release构建、本地备份替换及签名/版本核验。
- [x] diff-guard：纯UI展示修改，无新增分支、持久化或测试接口；不新增镜像实现的测试。

- 近7天假数据预览已目视确认历史两行直接显示；Release 66.11构建及安装核验通过。
- 旧版备份：/Applications/.CCSwitcher-before-visible-cost-history-20261008.app。未提交、推送或请求额度。
