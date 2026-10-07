#lang racket/base
;; ============================================================
;; D6 防回归：pNext / sType 辅助
;;
;;   * vk-struct 自动填 sType（由 struct 名查表）并置 pNext=#f，登记到 arena
;;   * vk-chain! 按各节点 sType 查 setter，串成 pNext 链并保活
;;   * 生成的 vk-struct-sType / vk-pNext-setters 表可用
;; ============================================================

(require rackunit
         racket/list
         ffi/unsafe
         vulkan)

;; 1. 生成的表
(check-equal? (hash-ref vk-struct-sType 'VkBufferCreateInfo)
              VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)
(check-equal? (hash-ref vk-struct-sType 'VkInstanceCreateInfo)
              VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO)
(check-true (procedure? (hash-ref vk-pNext-setters VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)))

;; 2. vk-struct 自动 sType
(define a (make-vk-arena))
(define bci
  (parameterize ([current-vk-arena a])
    (vk-struct make-VkBufferCreateInfo 0 16
               VK_BUFFER_USAGE_STORAGE_BUFFER_BIT VK_SHARING_MODE_EXCLUSIVE 0 #f)))
(check-equal? (VkBufferCreateInfo-sType bci) VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)
(check-false (VkBufferCreateInfo-pNext bci))
(check-not-false (memq bci (vk-arena-kept a)))

;; 3. vk-chain! 串链
(define ici (vk-struct make-VkInstanceCreateInfo 0 #f 0 #f 0 #f))
(define dbg
  (vk-struct make-VkDebugUtilsMessengerCreateInfoEXT
             0 VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
             VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT #f #f))
(vk-chain! ici dbg)
(check-true (equal? (VkInstanceCreateInfo-pNext ici) dbg)
            "parent pNext points at child")
(check-false (VkDebugUtilsMessengerCreateInfoEXT-pNext dbg)
             "last node pNext is NULL")
(check-equal? (VkDebugUtilsMessengerCreateInfoEXT-sType dbg)
              VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT)

;; 4. 三节点链 a -> b -> c
(define a2 (vk-struct make-VkApplicationInfo #f 0 #f 0 VK_API_VERSION_1_0))
(define b2 (vk-struct make-VkDebugUtilsMessengerCreateInfoEXT 0 0 0 #f #f))
(define c2 (vk-struct make-VkDebugUtilsMessengerCreateInfoEXT 0 0 0 #f #f))
(vk-chain! a2 b2 c2)
(check-true (equal? (VkApplicationInfo-pNext a2) b2))
(check-true (equal? (VkDebugUtilsMessengerCreateInfoEXT-pNext b2) c2))
(check-false (VkDebugUtilsMessengerCreateInfoEXT-pNext c2))

(printf "pnext: all checks passed\n")
