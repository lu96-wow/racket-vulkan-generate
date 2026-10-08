#lang info
;; 多集合包：vulkan/ 是绑定集合（main/manual/unsafe/safe/glfw/generate/generated/registry）。
;; vulkan/glfw.rkt 与 vulkan/manual.rkt 解耦，可单独 require。
(define collection 'multi)
(define deps '("base"))
(define build-deps '())
(define pkg-desc "Vulkan bindings for Racket (generated from vk.xml) + GLFW window helper")
(define pkg-authors '("lu96"))
(define license '("MIT"))
;; 历史调研目录不参与编译
(define compile-omit-paths '("experiments"))
(define test-omit-paths '("experiments"))
