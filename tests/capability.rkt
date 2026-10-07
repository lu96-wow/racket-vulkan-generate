#lang racket/base
;; ============================================================
;; F1 防回归：capability 门控
;;
;;   * vk-proc-available? 解析命令存在性（不抛）
;;   * vk-instance-extension-properties / -available? 查询扩展
;;   * vk-device-extension-properties / -available?（需一台物理设备）
;;   * 命令不可用时抛 exn:fail:vulkan:unavailable（可捕获）
;; ============================================================

(require rackunit
         racket/list
         ffi/unsafe
         vulkan)

;; 1. 命令可用性
(check-true (vk-proc-available? 'vkCreateInstance 'global))
(check-false (vk-proc-available? 'vkNotARealCommand 'global))

;; 2. 不可用命令抛可捕获的专用异常
(check-exn exn:fail:vulkan:unavailable?
           (λ () (vk-lookup-proc 'vkNotARealCommand 'global (_fun -> _void))))
(check-true
 (with-handlers ([exn:fail:vulkan:unavailable?
                  (λ (e) (eq? (exn:fail:vulkan:unavailable-command e) 'vkNotARealCommand))])
   (vk-lookup-proc 'vkNotARealCommand 'global (_fun -> _void))
   #f))

;; 3. instance 扩展查询
(define iexts (vk-instance-extension-properties))
(check-true (> (length iexts) 0) "loader reports instance extensions")
(check-true (for/and ([e (in-list iexts)]) (string? e)))
(check-true (vk-instance-extension-available? (car iexts)))
(check-false (vk-instance-extension-available? "VK_THIS_IS_NOT_A_REAL_EXTENSION"))

;; 4. 建 instance，枚举物理设备，查询 device 扩展
(define-values (r inst)
  (vkCreateInstance
   (λ ()
     (define app (vk-new make-VkApplicationInfo
                         VK_STRUCTURE_TYPE_APPLICATION_INFO #f #f 0 #f 0 VK_API_VERSION_1_0))
     (vk-new make-VkInstanceCreateInfo
             VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 app 0 #f 0 #f))
   #f))
(check-equal? r VK_SUCCESS)
(vk-use-instance! inst)

(define-values (r2 devs) (vkEnumeratePhysicalDevices inst))
(check-equal? r2 VK_SUCCESS)
(unless (zero? (vector-length devs))
  (define pd (vector-ref devs 0))
  (define dexts (vk-device-extension-properties pd))
  (check-true (> (length dexts) 0) "device reports extensions")
  (check-true (vk-device-extension-available? pd (car dexts)))
  (check-false (vk-device-extension-available? pd "VK_THIS_IS_NOT_A_REAL_EXTENSION")))

(vkDestroyInstance inst #f)
(printf "capability: all checks passed\n")
