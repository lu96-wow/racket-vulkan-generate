#lang racket/base
;; ============================================================
;; 原始表面（vulkan/raw）——等价于 vulkan/bindings（纯语义别名，无新内容）。
;; 用途：与 vulkan/safe / vulkan（糖）并存时，用模块隔离区分裸命令。
;; 注：facade vulkan 的 raw: 裸命令直接来自 vulkan/commands（prefix-in raw:），
;; 不经过本模块；这里只是给只想要裸表面的人一个自解释的入口名。
;; ============================================================

(require "bindings.rkt")

(provide (all-from-out "bindings.rkt"))
