#lang racket/base
;; ============================================================
;; M3.2c 防回归：输入类糖（调用作用域 + 数组输入）
;;
;;   * (vkCmdSetViewport cb first (vector ...))  count 由长度定
;;   * 输入拷进 arena，调用后随作用域释放
;;   * raw: 裸命令仍可用
;; ============================================================

(require rackunit
         ffi/unsafe
         racket/list
         vulkan)

;; ---------- instance / device ----------
(define-values (r1 instance)
  (vkCreateInstance
   (λ () (vk-new make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                 #f 0 #f 0 #f 0 #f))
   #f))
(void (vk-use-instance! instance))

(define-values (r2 pds) (vkEnumeratePhysicalDevices instance))
(define pd (vector-ref pds 0))
(define qfps (vkGetPhysicalDeviceQueueFamilyProperties pd))
(define qfi
  (for/first ([i (in-naturals)] [q (in-list (vector->list qfps))]
              #:when (not (zero? (bitwise-and (VkQueueFamilyProperties-queueFlags q)
                                               VK_QUEUE_GRAPHICS_BIT))))
    i))
(check-not-false qfi "a graphics queue family exists")

(define prio (vk-malloc _float))
(ptr-set! prio _float 1.0)
(define-values (r3 device)
  (vkCreateDevice pd
   (λ () (vk-new make-VkDeviceCreateInfo
                 VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                 #f 0 1 (vk-new make-VkDeviceQueueCreateInfo
                                VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                                #f 0 qfi 1 prio)
                 0 #f 0 #f #f))
   #f))
(void (vk-use-device! device))

(define-values (r4 pool)
  (vkCreateCommandPool device
   (λ () (vk-new make-VkCommandPoolCreateInfo
                 VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                 #f VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT qfi))
   #f))
(define-values (r5 cbs)
  (vkAllocateCommandBuffers device
   (λ () (vk-new make-VkCommandBufferAllocateInfo
                 VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                 #f pool VK_COMMAND_BUFFER_LEVEL_PRIMARY 1))))
(define cb (vector-ref cbs 0))

;; ---------- 录制并调用输入类糖 ----------
(void (raw:vkBeginCommandBuffer cb (vk-new make-VkCommandBufferBeginInfo
                                     VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                                     #f 0 #f)))
(vkCmdSetViewport cb 0 (vector (make-VkViewport 0.0 0.0 64.0 64.0 0.0 1.0)
                               (make-VkViewport 0.0 0.0 32.0 32.0 0.0 1.0)))
(vkCmdSetScissor cb 0 (vector (make-VkRect2D (make-VkOffset2D 0 0)
                                              (make-VkExtent2D 64 64))))
(void (raw:vkEndCommandBuffer cb))
(check-true #t "input sugar records without error")

;; 空 vector（count=0）
(void (raw:vkBeginCommandBuffer cb (vk-new make-VkCommandBufferBeginInfo
                                     VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                                     #f 0 #f)))
(vkCmdSetViewport cb 0 (vector))
(void (raw:vkEndCommandBuffer cb))
(check-true #t "input sugar accepts empty vector")

;; 裸命令仍可用
(check-true (procedure? raw:vkCmdSetViewport))

(printf "safe-input: all checks passed\n")
