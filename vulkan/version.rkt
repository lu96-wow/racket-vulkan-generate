#lang racket/base
;; ============================================================
;; 绑定版本（公共稳定路径）。
;;
;;   vk-binding-version      绑定/包版本，如 "1.4.363"
;;   vk-registry-file        生成所用注册表文件（如 "vk-1.4.363.xml"）
;;   vk-generated-feature    目标 feature（如 "VK_VERSION_1_4"）
;;   vk-generated-extensions 纳入的扩展闭包（已排序字符串表）
;;
;; 实现来自生成的 vulkan/generated/version.rkt（不要手改那份）。
;; ============================================================

(require "generated/version.rkt")

(provide (all-from-out "generated/version.rkt"))
