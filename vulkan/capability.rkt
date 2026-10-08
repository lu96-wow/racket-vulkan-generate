#lang racket/base
;; ============================================================
;; 运行期 capability 查询：按扩展/版本优雅降级。
;;
;;   * `vk-proc-available?`（base）：命令能否在当前上下文解析，不抛异常。
;;   * 本模块：枚举 instance/device 扩展名，并判断某扩展是否可用。
;;
;; 复用 `vulkan/result` 的 `vk-enumerate-result`（两遍 + VK_INCOMPLETE 重试）。
;; 命令不可用时 `define-vk` 会抛 `exn:fail:vulkan:unavailable`（可捕获）。
;; ============================================================

(require ffi/unsafe
         "base.rkt"
         "memory.rkt"
         "result.rkt"
         (prefix-in raw: "commands.rkt"))

(provide vk-instance-extension-properties
         vk-device-extension-properties
         vk-instance-extension-available?
         vk-device-extension-available?)

;; VkExtensionProperties.extensionName 是首字段 char[VK_MAX_EXTENSION_NAME_SIZE]，
;; 直接从结构体首地址按字节读到 NUL。
(define (cstring-at p max)
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i max) (list->bytes (reverse acc))]
      [else
       (define b (ptr-ref p _byte i))
       (if (zero? b) (list->bytes (reverse acc)) (loop (add1 i) (cons b acc)))])))

(define (extension-names vec)
  (for/list ([e (in-vector vec)])
    (bytes->string/utf-8 (cstring-at e VK_MAX_EXTENSION_NAME_SIZE))))

(define (vk-instance-extension-properties [layer #f])
  (define l (and layer (stable-bytes (string->bytes/utf-8 layer))))
  (define-values (_r vec)
    (vk-enumerate-result 'vk-instance-extension-properties _VkExtensionProperties
                         (λ (cnt props)
                           (raw:vkEnumerateInstanceExtensionProperties l cnt props))))
  (extension-names vec))

(define (vk-device-extension-properties physical-device [layer #f])
  (define l (and layer (stable-bytes (string->bytes/utf-8 layer))))
  (define-values (_r vec)
    (vk-enumerate-result 'vk-device-extension-properties _VkExtensionProperties
                         (λ (cnt props)
                           (raw:vkEnumerateDeviceExtensionProperties physical-device l cnt props))))
  (extension-names vec))

(define (vk-instance-extension-available? name)
  (and (member name (vk-instance-extension-properties)) #t))

(define (vk-device-extension-available? physical-device name)
  (and (member name (vk-device-extension-properties physical-device)) #t))
