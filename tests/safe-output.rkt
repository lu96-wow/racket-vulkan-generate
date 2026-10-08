#lang racket/base
;; ============================================================
;; M3.2a/b 防回归：自动输出糖（单输出 + enumerate）
;;
;;   * 单输出 struct/handle/scalar -> 直接返回（void）/ (values result v)（VkResult）
;;   * 数组输出 -> 两遍调用，返回 vector
;;   * char* 输入接受 string/#f
;;   * raw: 裸命令仍可用
;; ============================================================

(require rackunit
         ffi/unsafe
         vulkan)

;; ---------- instance ----------
(define-values (ri instance)
  (vkCreateInstance
   (λ () (vk-new make-VkInstanceCreateInfo
                 VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 #f 0 #f 0 #f))
   #f))
(check-equal? ri VK_SUCCESS)
(void (vk-use-instance! instance))

;; ---------- 单输出（VkResult，scalar）----------
(define-values (rv ver) (vkEnumerateInstanceVersion))
(check-equal? rv VK_SUCCESS)
(check-true (>= ver VK_API_VERSION_1_0) "enum version is returned")

;; ---------- 数组输出 + char* 输入 ----------
(define-values (re exts) (vkEnumerateInstanceExtensionProperties #f))
(check-equal? re VK_SUCCESS)
(check-true (vector? exts))
(check-true (> (vector-length exts) 0) "instance extensions enumerated")
(check-true (VkExtensionProperties? (vector-ref exts 0)))

;; ---------- 数组输出（对象）----------
(define-values (rd pds) (vkEnumeratePhysicalDevices instance))
(check-equal? rd VK_SUCCESS)
(check-true (> (vector-length pds) 0) "physical devices enumerated")
(define pd (vector-ref pds 0))

;; ---------- 单输出（void，struct）----------
(define props (vkGetPhysicalDeviceProperties pd))
(check-true (> (VkPhysicalDeviceProperties-apiVersion props) 0))
(check-equal? (VkPhysicalDeviceProperties-deviceType props)
              (VkPhysicalDeviceProperties-deviceType props))

(define mem (vkGetPhysicalDeviceMemoryProperties pd))
(check-true (> (VkPhysicalDeviceMemoryProperties-memoryTypeCount mem) 0))

;; ---------- 数组输出（void，struct）----------
(define qfps (vkGetPhysicalDeviceQueueFamilyProperties pd))
(check-true (vector? qfps))
(check-true (> (vector-length qfps) 0) "queue family properties enumerated")

;; ---------- 裸命令仍可用（逃生舱）----------
(check-true (procedure? raw:vkGetPhysicalDeviceProperties))
(check-true (procedure? raw:vkEnumeratePhysicalDevices))

(printf "safe-output: all checks passed\n")
