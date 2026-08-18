"""Prompt 回归评测机(evalkit)。

从 spikes/prompt_validation(一次性脚本)提升的常驻评测设施。
设计事实源:docs/prompt评测机设计决策.md;slice 明细:docs/prompt评测机-slices/。

定位:独立本地工具,**不进生产镜像**,不碰 app/main.py。
"""
