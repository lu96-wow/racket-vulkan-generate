#lang racket/base
(require vulkan/unsafe ffi/unsafe racket/sequence)

(printf "VK_HEADER_VERSION = ~a\n" VK_HEADER_VERSION)
(printf "ctype-sizeof _VkApplicationInfo = ~a\n" (ctype-sizeof _VkApplicationInfo))

;; 1. 建 instance
(define app (make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO #f #f 0 #f 0 VK_API_VERSION_1_0))
(define ici (make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 app 0 #f 0 #f))
(define inst-ptr (malloc _VkInstance))
(vkCreateInstance ici #f inst-ptr)
(define inst (ptr-ref inst-ptr _VkInstance))
(printf "instance = ~a\n" inst)
(register-vk-instance! inst)

;; 2. 枚举物理设备
(define cnt (malloc _uint32))
(vkEnumeratePhysicalDevices inst cnt #f)
(define n (ptr-ref cnt _uint32))
(printf "physical devices = ~a\n" n)
(define arr (malloc (* n (ctype-sizeof _VkPhysicalDevice))))
(vkEnumeratePhysicalDevices inst cnt arr)
(define pd (ptr-ref arr _VkPhysicalDevice))
(printf "physical device[0] = ~a\n" pd)

;; 3. 查属性
(define props (malloc _VkPhysicalDeviceProperties))
(vkGetPhysicalDeviceProperties pd props)
(define p (ptr-ref props _VkPhysicalDeviceProperties))
(define name-bytes
  (list->bytes
   (for/list ([b (in-array (VkPhysicalDeviceProperties-deviceName p))]
              #:break (= b 0))
     b)))
(printf "device name: ~a\n" (bytes->string/utf-8 name-bytes))
(printf "apiVersion: ~a.~a.~a\n"
        (VK_API_VERSION_MAJOR (VkPhysicalDeviceProperties-apiVersion p))
        (VK_API_VERSION_MINOR (VkPhysicalDeviceProperties-apiVersion p))
        (VK_API_VERSION_PATCH (VkPhysicalDeviceProperties-apiVersion p)))

;; 4. 清理
(vkDestroyInstance inst #f)
(printf "done\n")
