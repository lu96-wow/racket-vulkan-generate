#lang racket/base
;; 创建逻辑设备 + 通过 GDPA 调用 device 级命令（旧绑定做不到的部分）
(require vulkan/manual ffi/unsafe racket/sequence)

(define (make-instance)
  (define app (make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO #f #f 0 #f 0 VK_API_VERSION_1_0))
  (define ici (make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 app 0 #f 0 #f))
  (define p (malloc _VkInstance))
  (vkCreateInstance ici #f p)
  (ptr-ref p _VkInstance))

(define inst (make-instance))
(vk-use-instance! inst)

(define cnt (malloc _uint32))
(vkEnumeratePhysicalDevices inst cnt #f)
(define n (ptr-ref cnt _uint32))
(define parr (malloc (* n (ctype-sizeof _VkPhysicalDevice))))
(vkEnumeratePhysicalDevices inst cnt parr)
(define pd (ptr-ref parr _VkPhysicalDevice))

;; queue family
(define qcnt (malloc _uint32))
(vkGetPhysicalDeviceQueueFamilyProperties pd qcnt #f)
(define qn (ptr-ref qcnt _uint32))
(define qarr (malloc (* qn (ctype-sizeof _VkQueueFamilyProperties))))
(vkGetPhysicalDeviceQueueFamilyProperties pd qcnt qarr)
(define q0 (ptr-ref qarr _VkQueueFamilyProperties))
(define qflags (VkQueueFamilyProperties-queueFlags q0))
(printf "queue families=~a flags=~a (graphics? ~a compute? ~a)\n" qn qflags
        (not (zero? (bitwise-and qflags VK_QUEUE_GRAPHICS_BIT)))
        (not (zero? (bitwise-and qflags VK_QUEUE_COMPUTE_BIT))))

;; device queue create info
(define prio (malloc _float))
(ptr-set! prio _float 1.0)
(define qci (make-VkDeviceQueueCreateInfo VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO #f 0 0 1 prio))
(define dci (make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO #f 0 1 qci 0 #f 0 #f #f))
(define dp (malloc _VkDevice))
(vkCreateDevice pd dci #f dp)
(define dev (ptr-ref dp _VkDevice))
(vk-use-device! dev)          ; <-- 之后 device 级命令走 vkGetDeviceProcAddr
(printf "device = ~a\n" dev)

;; 通过 GDPA 调一个 device 级命令
(define cpi (make-VkCommandPoolCreateInfo VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO #f 0 0))
(define cp (malloc _VkCommandPool))
(vkCreateCommandPool dev cpi #f cp)
(printf "command pool = ~a\n" (ptr-ref cp _VkCommandPool))

;; 直接确认 GDPA 能解析 device 命令
(define raw (vkGetDeviceProcAddr dev "vkCreateCommandPool"))
(printf "GDPA(vkCreateCommandPool) = ~a\n" raw)

;; 清理
(vkDestroyCommandPool dev (ptr-ref cp _VkCommandPool) #f)
(vkDestroyDevice dev #f)
(vkDestroyInstance inst #f)
(printf "device test done\n")
