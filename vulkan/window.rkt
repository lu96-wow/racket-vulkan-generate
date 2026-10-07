#lang racket/base
;; ============================================================
;; GLFW 窗口辅助模块 —— 与 Vulkan 绑定**解耦**。
;;
;; 只依赖 ffi/unsafe + libglfw，不 require vulkan/unsafe。
;; 用途（开发期）：
;;   (glfw-init!)
;;   (define win (make-glfw-window #:width 800 #:height 600 #:title "demo"))
;;   (define surface (glfw-window-create-surface win instance))   ; raw VkSurfaceKHR
;;   (let loop ()
;;     (glfw-window-poll! win)
;;     (unless (glfw-window-should-close? win)
;;       ... render ...
;;       (loop)))
;;   (glfw-window-destroy! win)
;;   (glfw-terminate!)
;;
;; 关窗按钮、Esc、窗口尺寸都由 GLFW 处理（GLFW 自己装了 WM_DELETE_WINDOW 处理）。
;; ============================================================

(require ffi/unsafe ffi/unsafe/define)

(provide glfw-init!
         glfw-terminate!
         glfw-window?
         make-glfw-window
         glfw-window-ptr
         glfw-window-framebuffer-size
         glfw-window-size
         glfw-window-should-close?
         glfw-window-set-should-close!
         glfw-window-poll!
         glfw-window-wait!
         glfw-window-set-title!
         glfw-window-destroy!
         glfw-window-platform
         glfw-window-x11
         glfw-window-wayland
         glfw-window-create-surface
         glfw-required-instance-extensions
         glfw-error-message)

;; ------------------------------------------------------------------
(define libglfw
  (case (system-type 'os)
    [(windows) (ffi-lib "glfw3")]
    [else (ffi-lib "libglfw" '("3" ""))]))

(define-ffi-definer define-glfw libglfw)

;; GLFW constants
(define GLFW_TRUE 1)
(define GLFW_FALSE 0)
(define GLFW_CLIENT_API #x00022001)
(define GLFW_NO_API 0)
(define GLFW_RESIZABLE #x00020003)
(define GLFW_KEY_ESCAPE 256)
(define GLFW_PRESS 1)

(define-glfw glfwInit (_fun -> _int))
(define-glfw glfwTerminate (_fun -> _void))
(define-glfw glfwCreateWindow (_fun _int _int _string _pointer _pointer -> _pointer))
(define-glfw glfwDestroyWindow (_fun _pointer -> _void))
(define-glfw glfwWindowShouldClose (_fun _pointer -> _int))
(define-glfw glfwSetWindowShouldClose (_fun _pointer _int -> _void))
(define-glfw glfwPollEvents (_fun -> _void))
(define-glfw glfwWaitEvents (_fun -> _void))
(define-glfw glfwGetFramebufferSize (_fun _pointer _pointer _pointer -> _void))
(define-glfw glfwGetWindowSize (_fun _pointer _pointer _pointer -> _void))
(define-glfw glfwSetWindowTitle (_fun _pointer _string -> _void))
(define-glfw glfwGetKey (_fun _pointer _int -> _int))
(define-glfw glfwWindowHint (_fun _int _int -> _void))
(define-glfw glfwGetError (_fun (desc : (_ptr o _string/utf-8)) -> (code : _int) -> (values code desc)))

;; Vulkan 相关（仍是 raw pointer，不依赖 vulkan/unsafe）
(define-glfw glfwCreateWindowSurface (_fun _pointer _pointer _pointer _pointer -> _int))
(define-glfw glfwGetRequiredInstanceExtensions
  (_fun (count : (_ptr o _uint32)) -> (arr : _pointer) -> (values arr count)))

;; 平台句柄
(define-glfw glfwGetX11Display (_fun -> _pointer))
(define-glfw glfwGetX11Window (_fun _pointer -> _ulong))
(define-glfw glfwGetWaylandDisplay (_fun -> _pointer))
(define-glfw glfwGetWaylandWindow (_fun _pointer -> _pointer))

;; ------------------------------------------------------------------
(struct glfw-window (ptr) #:transparent #:mutable)

(define (glfw-error-message)
  (define-values (code msg) (glfwGetError))
  (if msg msg (format "GLFW error ~a" code)))

(define (glfw-init!)
  (unless (= (glfwInit) GLFW_TRUE)
    (error 'glfw-init! "glfwInit failed: ~a" (glfw-error-message)))
  (void))

(define (glfw-terminate!) (glfwTerminate))

(define (make-glfw-window #:width [width 800] #:height [height 600]
                          #:title [title "racket-vulkan"]
                          #:resizable? [resizable? #t])
  ;; 不要 GL 上下文（交给 Vulkan）
  (glfwWindowHint GLFW_CLIENT_API GLFW_NO_API)
  (glfwWindowHint GLFW_RESIZABLE (if resizable? GLFW_TRUE GLFW_FALSE))
  (define p (glfwCreateWindow width height title #f #f))
  (unless p
    (error 'make-glfw-window "glfwCreateWindow failed: ~a" (glfw-error-message)))
  (glfw-window p))

(define (glfw-window-framebuffer-size w)
  (define a (malloc 'atomic-interior _int))
  (define b (malloc 'atomic-interior _int))
  (glfwGetFramebufferSize (glfw-window-ptr w) a b)
  (values (ptr-ref a _int) (ptr-ref b _int)))

(define (glfw-window-size w)
  (define a (malloc 'atomic-interior _int))
  (define b (malloc 'atomic-interior _int))
  (glfwGetWindowSize (glfw-window-ptr w) a b)
  (values (ptr-ref a _int) (ptr-ref b _int)))

(define (glfw-window-should-close? w)
  (not (zero? (glfwWindowShouldClose (glfw-window-ptr w)))))

(define (glfw-window-set-should-close! w v)
  (glfwSetWindowShouldClose (glfw-window-ptr w) (if v GLFW_TRUE GLFW_FALSE)))

(define (glfw-window-poll! w)
  (glfwPollEvents)
  (when (and w (= (glfwGetKey (glfw-window-ptr w) GLFW_KEY_ESCAPE) GLFW_PRESS))
    (glfw-window-set-should-close! w #t)))

(define (glfw-window-wait! w) (glfwWaitEvents))

(define (glfw-window-set-title! w title)
  (glfwSetWindowTitle (glfw-window-ptr w) title))

(define (glfw-window-destroy! w)
  (glfwDestroyWindow (glfw-window-ptr w))
  (set-glfw-window-ptr! w #f))

(define (glfw-window-platform)
  (cond [(glfwGetX11Display) 'x11]
        [(glfwGetWaylandDisplay) 'wayland]
        [else 'other]))

(define (glfw-window-x11 w)
  ;; -> (values Display* Window)  （仅 X11 平台）
  (values (glfwGetX11Display) (glfwGetX11Window (glfw-window-ptr w))))

(define (glfw-window-wayland w)
  ;; -> (values wl_display* wl_surface*)  （仅 Wayland 平台）
  (values (glfwGetWaylandDisplay) (glfwGetWaylandWindow (glfw-window-ptr w))))

;; 创建 VkSurfaceKHR：instance 传原始句柄，返回原始句柄（cpointer）。
;; 调用方再用 (cast p _pointer _VkSurfaceKHR) 变成绑定里的类型。
(define (glfw-window-create-surface w instance)
  (define out (malloc 'atomic-interior _pointer))
  (define rc (glfwCreateWindowSurface instance (glfw-window-ptr w) #f out))
  (unless (zero? rc)
    (error 'glfw-window-create-surface "glfwCreateWindowSurface failed (VkResult ~a)" rc))
  (ptr-ref out _pointer))

;; GLFW 需要的 VkInstance 扩展名（如 VK_KHR_surface + VK_KHR_xlib_surface）
(define (glfw-required-instance-extensions)
  (define-values (arr n) (glfwGetRequiredInstanceExtensions))
  (for/list ([i (in-range n)])
    (ptr-ref arr _string/utf-8 i)))
