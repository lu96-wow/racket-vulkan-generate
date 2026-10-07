#lang racket/base
;; ============================================================
;; 内存 / 所有权原语（R5）——与具体 Vulkan 绑定解耦
;;
;; 规则：凡是交给 Vulkan/驱动的内存都必须是「不可移动」的。
;; Racket CS 里普通 'atomic 分配**仍会被 GC 移动**（只有 'atomic-interior
;; 保证地址稳定），而驱动可能在调用期间/之后持有这些指针，移动后会段错误。
;;
;; 两个正交轴（命名对应功能）：
;;   * arena 收集引用：`vk-arena-keep-current!`（挂到当前动态 arena）
;;     与 `vk-arena-keep!`（显式挂到指定 arena）。
;;   * handle 绑定 arena：`vk-handle-arena-set!` / `vk-handle-arena-remove!`。
;; 上层生成的 vk-create-*/vk-allocate-* 把 arena 绑到返回句柄；
;; vk-destroy-*/vk-free-* 解绑。
;; ============================================================

(require ffi/unsafe)

(provide (except-out (all-defined-out) vk-handle-arenas))

(struct vk-arena (kept) #:mutable)
(define (make-vk-arena) (vk-arena '()))
(define current-vk-arena (make-parameter #f))

;; 把值登记到当前动态 arena（vk-new / vk-malloc 自动调用）
(define (vk-arena-keep-current! v)
  (define a (current-vk-arena))
  (when a (set-vk-arena-kept! a (cons v (vk-arena-kept a))))
  v)

;; 构造结构体并登记到当前 arena
(define-syntax-rule (vk-new ctor arg ...) (vk-arena-keep-current! (ctor arg ...)))

;; 不可移动分配；有 arena 时登记
(define (vk-malloc t [n #f])
  (vk-arena-keep-current! (if n (malloc 'atomic-interior t n) (malloc 'atomic-interior t))))

;; 零初始化的不可移动结构体（输出/需逐字段 set 的场合）
(define (vk-zero t)
  (define p (vk-malloc t))
  (memset p 0 (ctype-sizeof t))
  (cpointer-push-tag! p t)
  p)

;; 把一组同类型结构体复制成连续数组（用于 pCreateInfos 之类数组入参）
(define (vk-struct-array t structs)
  (define n (length structs))
  (define p (vk-malloc t n))
  (for ([s structs] [i (in-naturals)]) (ptr-set! p t i s))
  p)

;; 把 Racket bytes 复制到不可移动内存（末尾补 NUL），用于 const char*/const void*。
;; 部分驱动（如 llvmpipe）会惰性引用 pCode/pName，不能直接交给它们 GC 可移动的指针。
(define (stable-bytes b)
  (define n (bytes-length b))
  (define p (vk-malloc _uint8 (add1 n)))
  (for ([i (in-range n)]) (ptr-set! p _byte i (bytes-ref b i)))
  (ptr-set! p _byte n 0)
  p)

;; 在 arena 里执行 body，返回 (values 结果 arena)。
(define (call-with-vk-arena thunk)
  (define a (make-vk-arena))
  (values (parameterize ([current-vk-arena a]) (thunk)) a))
(define-syntax-rule (with-vk-arena body ...)
  (call-with-vk-arena (λ () body ...)))

;; 显式把任意对象挂到指定 arena（手动模式：保住用户自己的内存）。
(define (vk-arena-keep! arena v)
  (set-vk-arena-kept! arena (cons v (vk-arena-kept arena)))
  v)

;; 重置 arena：放弃其登记的所有引用（内存可被 GC）。
;; 调用方必须自行保证驱动不再需要这些指针（帧作用域/手动场景）。
(define (vk-arena-reset! arena)
  (set-vk-arena-kept! arena '())
  arena)

;; 帧/复用作用域：body 内分配登记到 arena，结束后重置。
(define-syntax-rule (with-vk-frame arena body ...)
  (begin0 (parameterize ([current-vk-arena arena]) body ...)
          (vk-arena-reset! arena)))

;; 句柄 -> arena：创建时绑定，销毁时解绑。
;; 用 make-hash（equal?）：数组元素经 ptr-ref 读回时是新 cpointer 对象，
;; 只有按地址比较（equal?）才能命中；make-hasheqv 的 eqv? 会 miss。
(define vk-handle-arenas (make-hash))
(define (vk-handle-arena-set! h a) (hash-set! vk-handle-arenas h a) h)
(define (vk-handle-arena-remove! h) (hash-remove! vk-handle-arenas h))
(define (vk-handle-arena h) (hash-ref vk-handle-arenas h #f))
