#lang racket/base
;; ============================================================
;; 设备内存映射薄封装（场景 7–9/14）。
;;
;; 设备内存不归 Racket GC：`vk-map` 返回的指针由驱动拥有，**不**登记到
;; arena，也不需要（`vkMapMemory` 的 address 由设备保证稳定）。用 `vk-unmap`
;; 解除映射；flush/invalidate 由 `vkFlushMappedMemoryRanges` 等糖（输入数组）负责。
;;
;; 返回约定同 R1：`vk-map` -> `(values result pointer)`；`vk-unmap` -> void。
;; ============================================================

(require ffi/unsafe
         "base.rkt"
         "memory.rkt"
         "support.rkt"
         (prefix-in raw: "commands.rkt"))

(provide vk-map
         vk-unmap)

;; 映射 [offset, offset+size) 的设备内存；flags 默认 0（VkMemoryMapFlags）。
(define (vk-map device memory offset size [flags 0])
  (define out (vk-malloc _pointer))
  (define r (raw:vkMapMemory device memory offset size flags out))
  (check-vk-result r 'vk-map)
  (values r (ptr-ref out _pointer)))

;; 解除映射（vkUnmapMemory 返回 void）。
(define (vk-unmap device memory)
  (raw:vkUnmapMemory device memory))
