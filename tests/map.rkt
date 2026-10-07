#lang racket/base
;; ============================================================
;; 设备内存映射（vk-map / vk-unmap）回归。
;;
;; 真实跑一遍：instance -> physical device -> device -> allocate memory ->
;; map / write / unmap / remap / read / unmap -> free。
;; ============================================================

(require rackunit
         ffi/unsafe
         racket/list
         vulkan)

;; instance
(define-values (r0 inst)
  (vkCreateInstance
   (λ ()
     (define app (vk-new make-VkApplicationInfo
                         VK_STRUCTURE_TYPE_APPLICATION_INFO #f #f 0 #f 0 VK_API_VERSION_1_0))
     (vk-new make-VkInstanceCreateInfo
             VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 app 0 #f 0 #f))
   #f))
(check-equal? r0 VK_SUCCESS)
(vk-use-instance! inst)

;; physical device + a queue family
(define-values (r1 pds) (vkEnumeratePhysicalDevices inst))
(check-equal? r1 VK_SUCCESS)
(check-true (> (vector-length pds) 0))
(define pd (vector-ref pds 0))
(check-true (> (vector-length (vkGetPhysicalDeviceQueueFamilyProperties pd)) 0))

;; logical device（queue family 0）
(define-values (r2 dev)
  (vkCreateDevice
   pd
   (λ ()
     (define prio (vk-malloc _float))
     (ptr-set! prio _float 0 1.0)
     (define qci (vk-new make-VkDeviceQueueCreateInfo
                         VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO #f 0 0 1 prio))
     (define qcis (vk-struct-array _VkDeviceQueueCreateInfo (list qci)))
     (vk-new make-VkDeviceCreateInfo
             VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO #f 0 1 qcis 0 #f 0 #f #f))
   #f))
(check-equal? r2 VK_SUCCESS)
(vk-use-device! dev)

;; host-visible memory type
(define mp (vkGetPhysicalDeviceMemoryProperties pd))
(define host-visible
  (for/first ([i (in-range (VkPhysicalDeviceMemoryProperties-memoryTypeCount mp))]
              #:when (not (zero? (bitwise-and
                                  (VkMemoryType-propertyFlags
                                   (array-ref (VkPhysicalDeviceMemoryProperties-memoryTypes mp) i))
                                  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))))
    i))
(check-not-false host-visible "device exposes a host-visible memory type")

;; allocate 4096 bytes
(define-values (r3 mem)
  (vkAllocateMemory
   dev
   (λ () (vk-new make-VkMemoryAllocateInfo
                 VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO #f 4096 host-visible))
   #f))
(check-equal? r3 VK_SUCCESS)

;; map / write / unmap / remap / read / unmap
(define-values (r4 ptr) (vk-map dev mem 0 4096))
(check-equal? r4 VK_SUCCESS)
(check-true (cpointer? ptr))
(ptr-set! ptr _uint32 0 #xDEADBEEF)
(vk-unmap dev mem)

(define-values (r5 ptr2) (vk-map dev mem 0 4096))
(check-equal? r5 VK_SUCCESS)
(check-equal? (ptr-ref ptr2 _uint32 0) #xDEADBEEF)
(vk-unmap dev mem)

;; cleanup
(vkFreeMemory dev mem #f)
(vkDestroyDevice dev #f)
(vkDestroyInstance inst #f)
(printf "map: all checks passed\n")
