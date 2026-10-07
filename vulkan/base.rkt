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
(define libvulkan-delayed
  (case (system-type 'os)
    [(windows) (delay (ffi-lib "vulkan"))]
    [else (delay (ffi-lib "libvulkan" '("1" "")))]))

(define (libvulkan) (force libvulkan-delayed))

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
(define current-vk-instance (make-parameter #f))
(define current-vk-device (make-parameter #f))
;; 命令缓存**不再是全局**：默认为当前线程惰性创建；需要跨线程共享时，
;; 由 vulkan/context 层绑定 `current-vk-proc-cache`。
;; 值形如 (owner . cache)：owner=#f 表示显式共享；否则属某个线程。
(define current-vk-proc-cache (make-parameter #f))

;; 线程拥有的参数状态：值必须是 (owner . value)；若 owner 不是当前线程（或空），
;; 就新建并写回当前线程的参数。这样继承到父线程的值不会造成隐式共享。
(define (thread-local-value param make)
  (define cur (param))
  (cond
    [(and cur (let ([o (car cur)]) (or (not o) (eq? o (current-thread))))) (cdr cur)]
    [else (define v (make)) (param (cons (current-thread) v)) v]))

(define (vk-proc-cache)
  (thread-local-value current-vk-proc-cache make-hash))
(define (vk-proc-cache-snapshot) (vk-proc-cache))
(define (vk-proc-cache-clear!) (hash-clear! (vk-proc-cache)))

;; 当前 dispatch context（#f = 未显式绑定）。基类只放 dispatch 相关字段；
;; vulkan/context 的 vk-context 继承它（加 proc-cache / arena-registry）。
(struct vk-base-context (instance device) #:mutable)
(define current-vk-context (make-parameter #f))

(define (vk-use-instance! inst)
  (current-vk-instance inst)
  (current-vk-device #f)
  (define ctx (current-vk-context))
  (when (vk-base-context? ctx)
    (set-vk-base-context-instance! ctx inst)
    (set-vk-base-context-device! ctx #f))
  inst)

(define (vk-use-device! dev)
  (current-vk-device dev)
  (define ctx (current-vk-context))
  (when (vk-base-context? ctx)
    (set-vk-base-context-device! ctx dev))
  dev)

;; vkGetInstanceProcAddr / vkGetDeviceProcAddr 必须最先可用，故手写
(define vkGetInstanceProcAddr
  (get-ffi-obj "vkGetInstanceProcAddr" (libvulkan) (_fun _pointer _string/utf-8 -> _pointer)))
(define vkGetDeviceProcAddr
  (get-ffi-obj "vkGetDeviceProcAddr" (libvulkan) (_fun _pointer _string/utf-8 -> _pointer)))

(define (vk-get-instance-proc inst name)
  (vkGetInstanceProcAddr (or inst #f) name))
(define (vk-get-device-proc dev name)
  (vkGetDeviceProcAddr (or dev #f) name))

(define (vk-lib-symbol name)
  (ffi-obj-ref name (libvulkan) (λ () #f)))

(define (vk-resolve-proc name level)
  (define inst (current-vk-instance))
  (define dev (current-vk-device))
  (case level
    [(global)   (or (vk-lib-symbol name) (vk-get-instance-proc #f name))]
    [(instance) (or (and inst (vk-get-instance-proc inst name))
                    (vk-get-instance-proc #f name)
                    (vk-lib-symbol name))]
    [(device)   (or (and dev (vk-get-device-proc dev name))
                    (and inst (vk-get-instance-proc inst name))
                    (vk-get-instance-proc #f name)
                    (vk-lib-symbol name))]
    [else (vk-lib-symbol name)]))

;; 命令不可用时抛这个（可捕获，便于 capability 降级）。
(struct exn:fail:vulkan:unavailable exn:fail (command) #:transparent)

;; 命令在当前 instance/device 上下文是否可解析（不抛异常；不缓存）。
(define (vk-proc-available? name [level 'instance])
  (and (vk-resolve-proc (if (symbol? name) (symbol->string name) name) level) #t))

(define (vk-resolve-proc-ptr name level fun-type)
  (define ptr (vk-resolve-proc (symbol->string name) level))
  (unless ptr
    (raise (exn:fail:vulkan:unavailable
            (format "Vulkan command not available: ~a" name)
            (current-continuation-marks)
            name)))
  (function-ptr ptr fun-type))

(define (vk-lookup-proc name level fun-type)
  ;; 缓存 key = (name level instance device)；用 make-hash（equal?），
  ;; 因为 cpointer 只有按地址比较才能命中。
  (define key (list name level (current-vk-instance) (current-vk-device)))
  (define cache (vk-proc-cache))
  (hash-ref cache key
            (λ ()
              (define p (vk-resolve-proc-ptr name level fun-type))
              (hash-set! cache key p)
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
(include "generated/pnext.inc")
