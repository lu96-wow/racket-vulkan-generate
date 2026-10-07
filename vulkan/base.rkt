#lang racket/base
;; ============================================================
;; Vulkan 基础绑定设施（类型/常量/分派），不含命令。
;;
;; 命令在 vulkan/commands.rkt；两者组成原始表面 vulkan/bindings。
;; 本层不做：内存所有权（memory）、错误策略/包装（safe）。
;; ============================================================

(require ffi/unsafe
         ffi/unsafe/define
         racket/promise
         racket/include)

(provide (all-defined-out))

;; ------------------------------------------------------------------
;; libvulkan
(define libvulkan
  (case (system-type 'os)
    [(windows) (delay (ffi-lib "vulkan"))]
    [else (delay (ffi-lib "libvulkan" '("1" "")))]))

(define (vk-lib) (force libvulkan))

;; ------------------------------------------------------------------
;; 版本辅助宏（C 头文件里的宏，vk.xml 无法直接生成）
(define (VK_MAKE_API_VERSION variant major minor patch)
  (bitwise-ior (arithmetic-shift variant 29)
               (arithmetic-shift major 22)
               (arithmetic-shift minor 12)
               patch))
(define (VK_MAKE_VERSION major minor patch)
  (bitwise-ior (arithmetic-shift major 22)
               (arithmetic-shift minor 12)
               patch))
(define (VK_API_VERSION_VARIANT v) (arithmetic-shift v -29))
(define (VK_API_VERSION_MAJOR v) (bitwise-and (arithmetic-shift v -22) #x7f))
(define (VK_API_VERSION_MINOR v) (bitwise-and (arithmetic-shift v -12) #x3ff))
(define (VK_API_VERSION_PATCH v) (bitwise-and v #xfff))
(define (VK_VERSION_MAJOR v) (arithmetic-shift v -22))
(define (VK_VERSION_MINOR v) (bitwise-and (arithmetic-shift v -12) #x3ff))
(define (VK_VERSION_PATCH v) (bitwise-and v #xfff))
(define VK_API_VERSION_1_0 (VK_MAKE_API_VERSION 0 1 0 0))
(define VK_API_VERSION_1_1 (VK_MAKE_API_VERSION 0 1 1 0))
(define VK_API_VERSION_1_2 (VK_MAKE_API_VERSION 0 1 2 0))
(define VK_API_VERSION_1_3 (VK_MAKE_API_VERSION 0 1 3 0))
(define VK_API_VERSION_1_4 (VK_MAKE_API_VERSION 0 1 4 0))

;; ------------------------------------------------------------------
;; VkResult 名字表（纯数据；是否抛异常由上层决定）
(define vk-result-names
  (hasheqv 0 "VK_SUCCESS" 1 "VK_NOT_READY" 2 "VK_TIMEOUT" 3 "VK_EVENT_SET"
           4 "VK_EVENT_RESET" 5 "VK_INCOMPLETE"
           -1 "VK_ERROR_OUT_OF_HOST_MEMORY" -2 "VK_ERROR_OUT_OF_DEVICE_MEMORY"
           -3 "VK_ERROR_INITIALIZATION_FAILED" -4 "VK_ERROR_DEVICE_LOST"
           -5 "VK_ERROR_MEMORY_MAP_FAILED" -6 "VK_ERROR_LAYER_NOT_PRESENT"
           -7 "VK_ERROR_EXTENSION_NOT_PRESENT" -8 "VK_ERROR_FEATURE_NOT_PRESENT"
           -9 "VK_ERROR_INCOMPATIBLE_DRIVER" -10 "VK_ERROR_TOO_MANY_OBJECTS"
           -11 "VK_ERROR_FORMAT_NOT_SUPPORTED" -12 "VK_ERROR_FRAGMENTED_POOL"
           -13 "VK_ERROR_UNKNOWN" 1000001003 "VK_SUBOPTIMAL_KHR"
           1000261000 "VK_ERROR_SURFACE_LOST_KHR"))

(define (vk-result-name r)
  (hash-ref vk-result-names r (λ () (format "VkResult(~a)" r))))

;; ------------------------------------------------------------------
;; 分派加载：global / instance / device
(define current-instance (make-parameter #f))
(define current-device (make-parameter #f))
;; 缓存 key = (name level instance device)。用 make-hash（equal?），
;; 因为 cpointer 只有按地址比较才能命中。
(define proc-cache (make-hash))

(define (vk-invalidate-cache!) (hash-clear! proc-cache))

(define (register-vk-instance! inst)
  (current-instance inst)
  (current-device #f)
  inst)

(define (register-vk-device! dev)
  (current-device dev)
  dev)

;; vkGetInstanceProcAddr / vkGetDeviceProcAddr 必须最先可用，故手写
(define vkGetInstanceProcAddr
  (get-ffi-obj "vkGetInstanceProcAddr" (vk-lib) (_fun _pointer _string/utf-8 -> _pointer)))
(define vkGetDeviceProcAddr
  (get-ffi-obj "vkGetDeviceProcAddr" (vk-lib) (_fun _pointer _string/utf-8 -> _pointer)))

(define (vk-get-instance-proc inst name)
  (vkGetInstanceProcAddr (or inst #f) name))
(define (vk-get-device-proc dev name)
  (vkGetDeviceProcAddr (or dev #f) name))

(define (vk-symbol name)
  (ffi-obj-ref name (vk-lib) (λ () #f)))

(define (vk-resolve name level)
  (define inst (current-instance))
  (define dev (current-device))
  (case level
    [(global)   (or (vk-symbol name) (vk-get-instance-proc #f name))]
    [(instance) (or (and inst (vk-get-instance-proc inst name))
                    (vk-get-instance-proc #f name)
                    (vk-symbol name))]
    [(device)   (or (and dev (vk-get-device-proc dev name))
                    (and inst (vk-get-instance-proc inst name))
                    (vk-get-instance-proc #f name)
                    (vk-symbol name))]
    [else (vk-symbol name)]))

(define (vk-lookup-proc name level fun-type)
  (define key (list name level (current-instance) (current-device)))
  (hash-ref proc-cache key
            (λ ()
              (define ptr (vk-resolve (symbol->string name) level))
              (unless ptr
                (error 'vulkan "Vulkan command not available: ~a" name))
              (define p (function-ptr ptr fun-type))
              (hash-set! proc-cache key p)
              p)))

;; define-vk：每条命令按当前 instance/device 查表（表内缓存）。
;; 生成物形如： (define-vk vkCreateInstance global 3 (_fun ... ))
(define-syntax define-vk
  (syntax-rules ()
    [(_ name level arity fun-type)
     (define name
       (procedure-rename
        (procedure-reduce-arity
         (λ args (apply (vk-lookup-proc 'name 'level fun-type) args))
         arity)
        'name))]))

;; ------------------------------------------------------------------
;; 类型/常量（命令见 vulkan/commands.rkt）
(include "generated/constants.inc")
(include "generated/types.inc")
