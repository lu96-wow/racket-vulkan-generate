#lang info
;; 多集合包：
;;   vulkan/     运行期绑定（最终目标）
;;   vulkan-gen/ 生成器（构建期）
;;   registry/   资源（vk.xml）
;; 生成器与资源不参与运行期；见 ARCHITECTURE.md §2。
(define collection 'multi)
;; 包版本 = 钉死的 Vulkan header 版本（1.4.363）。自己修 bug 时用第 4 位：
;; 1.4.363.1；生成物版本见 vulkan/generated/version.rkt，tests/version.rkt 锁定一致。
(define version "1.4.363")
(define deps '("base" "net-lib"))
(define build-deps '())
(define pkg-desc "Vulkan bindings for Racket (generated from vk.xml) + GLFW window helper")
(define pkg-authors '("lu96"))
(define license '("MIT"))
;; 历史调研目录不参与编译
(define compile-omit-paths '("experiments"))
(define test-omit-paths '("experiments"))
